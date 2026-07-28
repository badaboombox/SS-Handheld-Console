// GPU SoC top TB: acts like the STM32 firmware. Uploads all assets through
// the FMC SDRAM_UP window, configures every register through the REGS window,
// enables the display, then captures a full frame from the panel pins
// (pclk/de/hsync/vsync/rgb) and compares against the golden scene.
#include "Vgpu_top.h"
#include "Vgpu_top___024root.h" // debug: peek FrameStreamingCore internals
#include "verilated.h"
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

static constexpr uint32_t W = 480, H = 272;
static constexpr uint32_t TILE_BASE = 0x8000;
static constexpr uint32_t MAP_BASE[4] = { 0x1000, 0x2000, 0x3000, 0x4000 };
static constexpr uint32_t T3D_BASE = 0x40000;
static constexpr uint16_t T3D_KEY = 0x0001;

static std::vector<uint32_t> mem(1 << 20, 0);
static uint16_t fb[W * H];        // captured from panel (converted back to 565)
static uint16_t fbsnap[W * H];    // snapshot at vsync

static Vgpu_top* top;
static uint64_t cycles = 0;

// panel capture state
static bool prev_pclk = false, prev_de = false, prev_vsync = true;
static uint32_t cap_x = 0, cap_y = 0;
static int vsync_irqs = 0;

static void clk()
{
    // one GPU clock period = two SDRAM clock periods (133.33 = 2 x 66.67).
    // clk_sdram is toggled twice per clk cycle, edges offset from clk so the
    // async-FIFO 2-FF synchronizers see a genuine cross-domain relationship.
    top->clk_sdram = 1; top->eval();
    top->clk = 1;       top->eval();
    top->clk_sdram = 0; top->eval();
    top->clk_sdram = 1; top->eval();
    top->clk = 0;       top->eval();
    top->clk_sdram = 0; top->eval();
    cycles++;

    bool pclk_rise = !prev_pclk && top->pclk;
    prev_pclk = top->pclk;
    if (pclk_rise)
    {
        if (prev_vsync && !top->vsync) cap_y = 511; // vsync start: next DE line is y=0
        prev_vsync = top->vsync;
        if (top->de)
        {
            if (!prev_de) { cap_x = 0; cap_y = (cap_y == 511) ? 0 : cap_y + 1; }
            uint8_t r = (top->rgb >> 16) & 0xFF, g = (top->rgb >> 8) & 0xFF, b = top->rgb & 0xFF;
            if (cap_x < W && cap_y < H)
                fb[cap_y * W + cap_x] = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
            cap_x++;
        }
        prev_de = top->de;
    }
    if (top->cpu_irq)
    {
        vsync_irqs++;
        for (uint32_t i = 0; i < W * H; i++) fbsnap[i] = fb[i];
    }
}

static uint64_t dbg_pixels = 0;
static uint32_t dbg_maxline = 0;
static int dbg_framedones = 0;

// FMC master

static void fmcWrite(uint16_t addr, uint16_t data)
{
    top->fmc_a = addr & 0x3FF;
    top->fmc_d_i = data;
    top->fmc_ne = 0; clk();
    top->fmc_nwe = 0; clk(); clk(); clk();
    top->fmc_nwe = 1; clk(); clk();
    top->fmc_ne = 1; clk(); clk();
}

static uint16_t fmcRead(uint16_t addr)
{
    top->fmc_a = addr & 0x3FF;
    top->fmc_ne = 0; clk();
    top->fmc_noe = 0;
    for (int i = 0; i < 4; i++) clk();
    uint16_t d = top->fmc_d_o;
    top->fmc_noe = 1; clk();
    top->fmc_ne = 1; clk(); clk();
    return d;
}

static void reg16(uint8_t a, uint16_t v) { fmcWrite(a, v); }
static void upload(uint32_t addr, uint32_t data)
{
    static uint32_t ptr = ~0u;
    if (addr != ptr)
    {
        fmcWrite(0x200, addr & 0xFFFF);
        fmcWrite(0x201, (addr >> 16) & 0x3F);
    }
    fmcWrite(0x202, data & 0xFFFF);
    fmcWrite(0x202, data >> 16);
    ptr = addr + 1;
}

// asset generation (identical scene) 

static void putTileRow(uint32_t tile, uint32_t row, const uint8_t px[8])
{
    uint32_t w = 0;
    for (int i = 7; i >= 0; i--) w = (w << 4) | (px[i] & 0xF);
    mem[TILE_BASE + tile * 8 + row] = w;
}

static void makeTiles()
{
    uint8_t px[8];
    for (uint32_t r = 0; r < 8; r++) { for (int i = 0; i < 8; i++) px[i] = 1; putTileRow(1, r, px); }
    for (uint32_t r = 0; r < 8; r++) { for (int i = 0; i < 8; i++) px[i] = (((i / 2) ^ (r / 2)) & 1) ? 1 : 2; putTileRow(2, r, px); }
    for (uint32_t r = 0; r < 8; r++) { for (int i = 0; i < 8; i++) px[i] = (((i + r) & 7) < 2) ? 3 : 0; putTileRow(3, r, px); }
    for (uint32_t r = 0; r < 8; r++)
    {
        for (int i = 0; i < 8; i++)
        {
            int dx = 2 * i - 7, dy = 2 * r - 7;
            int d2 = dx * dx + dy * dy;
            px[i] = (d2 <= 49 && d2 >= 16) ? 2 : 0;
        }
        putTileRow(4, r, px);
    }
    static const char* f[8] = { "33333300","33000000","33000000","33333000","33000000","33000000","33000000","00000000" };
    for (uint32_t r = 0; r < 8; r++) { for (int i = 0; i < 8; i++) px[i] = f[r][i] == '3' ? 3 : 0; putTileRow(5, r, px); }
    for (uint32_t r = 0; r < 8; r++) { for (int i = 0; i < 8; i++) px[i] = 1 + (r / 2); putTileRow(6, r, px); }
    for (uint32_t r = 0; r < 8; r++) { for (int i = 0; i < 8; i++) px[i] = ((i == 3 || i == 4) && (r == 3 || r == 4)) ? 2 : 0; putTileRow(7, r, px); }
    // sprites
    auto mk = [&](uint32_t baseTile, uint32_t n, auto paint) {
        uint32_t wt = n / 8;
        for (uint32_t ty = 0; ty < wt; ty++)
            for (uint32_t tx = 0; tx < wt; tx++)
                for (uint32_t r = 0; r < 8; r++)
                {
                    uint8_t p2[8];
                    for (uint32_t i = 0; i < 8; i++) p2[i] = paint(tx * 8 + i, ty * 8 + r);
                    putTileRow(baseTile + ty * wt + tx, r, p2);
                }
    };
    mk(32, 16, [](uint32_t x, uint32_t y) -> uint8_t {
        int dx = 2 * (int)x - 15, dy = 2 * (int)y - 15;
        int d2 = dx * dx + dy * dy;
        if (d2 > 225) return 0;
        if (d2 > 150) return 1;
        if (dx < -3 && dy < -3) return 4;
        return 2;
    });
    mk(48, 32, [](uint32_t x, uint32_t y) -> uint8_t {
        int dx = std::abs(2 * (int)x - 31), dy = std::abs(2 * (int)y - 31);
        if (dx + dy > 31) return 0;
        if (dx + dy > 25) return 1;
        return (uint8_t)(2 + ((x / 4 + y / 4) % 3));
    });
}

static void putMap(uint32_t base, uint32_t tx, uint32_t ty, uint16_t e)
{
    uint32_t idx = ty * 64 + tx;
    uint32_t& w = mem[base + idx / 2];
    if (idx & 1) w = (w & 0x0000FFFF) | ((uint32_t)e << 16);
    else w = (w & 0xFFFF0000) | e;
}

static uint16_t entry(uint16_t tile, bool hf, bool vf, uint16_t pal)
{
    return (tile & 0x3FF) | (hf << 10) | (vf << 11) | (pal << 12);
}

static void makeMaps()
{
    for (uint32_t ty = 0; ty < 64; ty++)
        for (uint32_t tx = 0; tx < 64; tx++)
        {
            putMap(MAP_BASE[0], tx, ty, ((tx % 7 == 2) && (ty % 5 == 1)) ? entry(5, tx & 1, ty & 1, 3) : entry(0, 0, 0, 0));
            putMap(MAP_BASE[1], tx, ty, ((tx + ty) % 3 == 0) ? entry(7, 0, 0, 2) : entry(0, 0, 0, 0));
            putMap(MAP_BASE[2], tx, ty, (ty >= 12 && ty < 24) ? entry(4, 0, 0, (tx & 1) ? 1 : 0) : entry(0, 0, 0, 0));
            putMap(MAP_BASE[3], tx, ty, (ty < 16) ? entry(6, 0, 0, 2) : entry(2, 0, 0, (ty & 1)));
        }
}

static uint16_t rgb565(uint8_t r, uint8_t g, uint8_t b)
{
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
}

static void make3dFrame()
{
    for (uint32_t y = 0; y < H; y++)
        for (uint32_t x = 0; x < W; x += 2)
        {
            uint16_t p[2];
            for (uint32_t i = 0; i < 2; i++)
            {
                uint32_t xx = x + i;
                if (xx >= 290 && xx < 462 && y >= 52 && y < 208)
                {
                    uint32_t lx = xx - 290, ly = y - 52;
                    p[i] = rgb565((uint8_t)(90 + lx * 140 / 172),
                                  (uint8_t)(200 - ly * 120 / 156),
                                  (uint8_t)(230 - lx * 80 / 172));
                    if (p[i] == T3D_KEY) p[i] = 0x0002;
                }
                else p[i] = T3D_KEY;
            }
            mem[T3D_BASE + (y * W + x) / 2] = ((uint32_t)p[1] << 16) | p[0];
        }
}

// OAM via data port 

static void oamEntry(uint32_t idx, uint32_t x, uint32_t y, uint32_t size, uint32_t pri,
    bool en, bool hf, bool vf, uint32_t pal, uint32_t tile,
    bool aff = false, uint32_t mat = 0, bool dbl = false)
{
    uint32_t w0 = (x & 0x3FF) | ((y & 0x1FF) << 10) | ((size & 3) << 19)
        | ((pri & 3) << 21) | (en << 23) | (hf << 24) | (vf << 25) | ((pal & 0xF) << 26);
    uint32_t w1 = (tile & 0x3FF) | ((mat & 0x1F) << 10) | ((uint32_t)aff << 15) | ((uint32_t)dbl << 16);
    reg16(0x42, idx * 2);
    reg16(0x43, w0 & 0xFFFF); reg16(0x43, w0 >> 16);
    reg16(0x43, w1 & 0xFFFF); reg16(0x43, w1 >> 16);
}

// 3D smoke: replay a captured RasterIX driver stream through the FMC 
// gpu_stream.bin = every writeData block the real GL driver sent in the
// headless harness (CaptureBusConnector). 2D units off, 3D layer fullscreen;
// magenta backdrop shows through anywhere the 3D path failed.

static int runSmoke3d()
{
    FILE* f = fopen("gpu_stream.bin", "rb");
    if (!f) { fprintf(stderr, "FAIL: gpu_stream.bin missing (run sim/headless capture)\n"); return 1; }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    std::vector<uint32_t> ws(sz / 4);
    if (fread(ws.data(), 4, ws.size(), f) != ws.size()) { fclose(f); return 1; }
    fclose(f);
    printf("smoke3d: %zu stream words\n", ws.size());

    while (!(fmcRead(0x301) & 1)) {}

    reg16(0x20, rgb565(255, 0, 255));   // backdrop: screaming magenta
    reg16(0x23, 0);                     // t3d_pri front
    reg16(0x24, 0);                     // key value (disabled anyway)
    reg16(0x25, 0); reg16(0x26, 0);     // t3d_base placeholder until swap latches
    reg16(0x00, (1u << 5) | (1u << 8)); // t3d_en + display_en, all 2D off

    // stream with FIFO flow control (STATUS 0x300 = free words)
    size_t i = 0;
    uint64_t guard = cycles + 120000000ULL;
    size_t last_note = 0;
    while (i < ws.size() && cycles < guard)
    {
        uint16_t free_w = fmcRead(0x300);
        uint32_t n = (free_w > 8) ? (uint32_t)(free_w - 8) : 0;
        for (uint32_t k = 0; k < n && i < ws.size(); k++, i++)
        {
            fmcWrite(0x100, ws[i] & 0xFFFF);
            fmcWrite(0x100, (uint16_t)(ws[i] >> 16));
        }
        if (i - last_note >= 2048)
        {
            last_note = i;
            printf("smoke3d: pushed %zu/%zu swaps=%u axi=%04x @%llu\n",
                i, ws.size(), top->dbg_swap_cnt, top->dbg_axi, (unsigned long long)cycles);
            fflush(stdout);
        }
        static uint64_t next_note = 0;
        if (cycles > next_note)
        {
            next_note = cycles + 2000000;
            printf("smoke3d: spin i=%zu axi=%04x dma{st=%u in=%u out=%u rdy=%u cnt=%u} rixrdy=%u @%llu\n",
                i, top->dbg_axi,
                top->rootp->gpu_top__DOT__rix__DOT__genblk1__DOT__rixif__DOT__dma__DOT__state,
                top->rootp->gpu_top__DOT__rix__DOT__genblk1__DOT__rixif__DOT__dma__DOT__muxIn,
                top->rootp->gpu_top__DOT__rix__DOT__genblk1__DOT__rixif__DOT__dma__DOT__muxOut,
                top->rootp->gpu_top__DOT__rix__DOT__genblk1__DOT__rixif__DOT__dma__DOT__axisSourceReady,
                top->rootp->gpu_top__DOT__rix__DOT__genblk1__DOT__rixif__DOT__dma__DOT__counter,
                top->rootp->gpu_top__DOT__rix__DOT__genblk1__DOT__rixif__DOT__cmd_axis_tready,
                (unsigned long long)cycles);
            fflush(stdout);
        }
    }
    printf("smoke3d: stream done at %llu cycles, swaps=%u\n",
        (unsigned long long)cycles, top->dbg_swap_cnt);

    // let the renderer finish: expect one swap per captured frame (3)
    uint64_t rguard = cycles + 120000000ULL;
    while (top->dbg_swap_cnt < 3 && cycles < rguard)
    {
        clk();
        if ((cycles % 2000000) == 0)
        { printf("smoke3d: waiting swaps=%u axi=%04x @%llu\n", top->dbg_swap_cnt, top->dbg_axi, (unsigned long long)cycles); fflush(stdout); }
    }
    printf("smoke3d: swaps=%u\n", top->dbg_swap_cnt);

    // two more displayed frames so the swapped buffer reaches the panel
    int v0 = vsync_irqs;
    uint64_t vguard = cycles + 30000000ULL;
    while (vsync_irqs < v0 + 3 && cycles < vguard) clk();

    FILE* o = fopen("gpu_frame3d.ppm", "wb");
    fprintf(o, "P6\n%u %u\n255\n", W, H);
    for (uint32_t p = 0; p < W * H; p++)
    {
        uint16_t v = fbsnap[p];
        uint8_t rgb[3] = {
            (uint8_t)(((v >> 11) & 0x1F) << 3),
            (uint8_t)(((v >> 5) & 0x3F) << 2),
            (uint8_t)((v & 0x1F) << 3)
        };
        fwrite(rgb, 1, 3, o);
    }
    fclose(o);
    printf("DONE: gpu_frame3d.ppm (swaps=%u vsyncs=%d)\n", top->dbg_swap_cnt, vsync_irqs);
    return (top->dbg_swap_cnt >= 3) ? 0 : 1;
}

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    top = new Vgpu_top;
    top->fmc_ne = 1; top->fmc_nwe = 1; top->fmc_noe = 1;

    makeTiles(); makeMaps(); make3dFrame();

    top->rst = 1; clk(); clk(); top->rst = 0; clk();

    if (getenv("SMOKE3D")) return runSmoke3d();

    // wait SDRAM init via STATUS
    while (!(fmcRead(0x301) & 1)) {}

    // upload assets
    uint32_t words = 0;
    for (uint32_t a = 0; a < mem.size(); a++)
    {
        if (!mem[a]) continue;
        upload(a, mem[a]);
        words++;
    }
    printf("uploaded %u words via FMC in %llu cycles\n", words, (unsigned long long)cycles);

    // palettes via data port
    static const uint8_t hue[4][3] = { {255,80,40}, {40,200,90}, {70,120,255}, {250,200,40} };
    reg16(0x40, 0);
    for (uint32_t p = 0; p < 4; p++)
        for (uint32_t c = 0; c < 16; c++)
        {
            uint32_t s = 55 + c * 13;
            if (c == 0 && p != 0) reg16(0x40, p * 16);
            reg16(0x41, rgb565(hue[p][0] * s / 255, hue[p][1] * s / 255, hue[p][2] * s / 255));
        }

    // scene registers
    reg16(0x01, (3 << 6) | (2 << 4) | (1 << 2) | 0);
    reg16(0x02, 97); reg16(0x03, 53); reg16(0x04, 21); reg16(0x05, 5);
    reg16(0x06, 3);  reg16(0x07, 0);  reg16(0x08, 7);  reg16(0x09, 0);
    for (int l = 0; l < 4; l++)
    {
        reg16(0x10 + l * 2, MAP_BASE[l] & 0xFFFF);
        reg16(0x11 + l * 2, MAP_BASE[l] >> 16);
        reg16(0x18 + l * 2, TILE_BASE & 0xFFFF);
        reg16(0x19 + l * 2, TILE_BASE >> 16);
    }
    reg16(0x20, rgb565(15, 15, 30));
    reg16(0x21, (6 << 11) | (10 << 6) | 0b000010); // evb=6 eva=10 blend_en=3D
    reg16(0x22, 0);
    reg16(0x23, 1);                                 // t3d_pri
    reg16(0x24, T3D_KEY);
    reg16(0x25, T3D_BASE & 0xFFFF); reg16(0x26, T3D_BASE >> 16);
    reg16(0x27, TILE_BASE & 0xFFFF); reg16(0x28, TILE_BASE >> 16);

    // affine layer 2 (unit 0): rotate 20 deg about world (256,150)
    {
        double th = 20.0 * 3.14159265 / 180.0;
        int16_t pa = (int16_t)(cos(th) * 256), pb = (int16_t)(-sin(th) * 256);
        int16_t pc = (int16_t)(sin(th) * 256), pd = (int16_t)(cos(th) * 256);
        int32_t cx = 256 << 8, cy = 150 << 8;
        int32_t ox = cx - pa * 240 - pb * 136;
        int32_t oy = cy - pc * 240 - pd * 136;
        reg16(0x29, (uint16_t)pa); reg16(0x2A, (uint16_t)pb);
        reg16(0x2B, (uint16_t)pc); reg16(0x2C, (uint16_t)pd);
        reg16(0x2D, ox & 0xFFFF); reg16(0x2E, (ox >> 16) & 3);
        reg16(0x2F, oy & 0xFFFF); reg16(0x30, (oy >> 16) & 3);
    }

    // matrices + OAM via data ports
    {
        double th = 30.0 * 3.14159265 / 180.0;
        int16_t m0[4] = { (int16_t)(cos(th) * 256), (int16_t)(-sin(th) * 256),
                          (int16_t)(sin(th) * 256), (int16_t)(cos(th) * 256) };
        int16_t m1[4] = { 128, 0, 0, 128 };
        reg16(0x44, 0);
        for (int i = 0; i < 4; i++) reg16(0x45, (uint16_t)m0[i]);
        for (int i = 0; i < 4; i++) reg16(0x45, (uint16_t)m1[i]);
    }
    const char* scn = getenv("SCENE");
    if (scn && !strcmp(scn, "sprites64"))
    {
        // 64 sprites stacked on the SAME scanline band (all 16px tall at y=100)
        // -> lines 100..115 each see 64 sprites: the worst-case per-scanline load
        for (uint32_t i = 0; i < 64; i++)
            oamEntry(i, (i * 7) % 480, 100, 1, 0, true, false, false, (i % 3), 32);
        reg16(0x42, 64 * 2);
        for (uint32_t i = 64; i < 256; i++)
        { reg16(0x43, 0); reg16(0x43, 0); reg16(0x43, 0); reg16(0x43, 0); }
    }
    else
    {
    for (uint32_t i = 0; i < 12; i++)
    {
        uint32_t x = 20 + i * 38;
        uint32_t y = 100 + (uint32_t)(60.0 * std::sin(i * 0.7));
        oamEntry(i, x, y, 1, 0, true, false, false, (i % 3), 32);
    }
    oamEntry(12, 224, 120, 2, 1, true, false, false, 3, 48);
    oamEntry(13, 1015, 40, 1, 0, true, false, false, 1, 32);
    oamEntry(14, 470, 200, 1, 0, true, true, true, 0, 32);
    oamEntry(15, 240, 130, 1, 0, false, false, false, 0, 32);
    oamEntry(16, 60, 60, 2, 0, true, false, false, 1, 48, true, 0, true);
    oamEntry(17, 360, 30, 1, 0, true, false, false, 2, 32, true, 1, true);
    // clear remaining OAM (enable=0)
    reg16(0x42, 18 * 2);
    for (uint32_t i = 18; i < 256; i++)
    { reg16(0x43, 0); reg16(0x43, 0); reg16(0x43, 0); reg16(0x43, 0); }
    }

    // CTRL: scene load selectable to gauge realistic (DS-plausible) workloads.
    // bits: [3:0] layer_en [4] spr_en [5] t3d_en [7:6] layer_affine [8] disp
    //       [9] t3d_key_en. golden "full" = 4 BG + 2 affine + spr + 3D (a load
    //       no DS could produce). SCENE=level/boss = realistic DS-era gameplay.
    const char* scene = getenv("SCENE");
    uint16_t ctrl;
    if (scene && (!strcmp(scene, "level") || !strcmp(scene, "sprites64")))  // 3 text BG + spr + 3D
        ctrl = 0x7 | (1<<4) | (1<<5) | (0<<6) | (1<<8);
    else if (scene && !strcmp(scene, "level2"))  // typical: 2 text BG + spr + 3D
        ctrl = 0x3 | (1<<4) | (1<<5) | (0<<6) | (1<<8);
    else if (scene && !strcmp(scene, "boss"))    // boss: 1 BG + spr + 3D (mostly 3D)
        ctrl = 0x1 | (1<<4) | (1<<5) | (0<<6) | (1<<8);
    else if (scene && !strcmp(scene, "aff1"))    // 2 text BG + 1 affine + spr + 3D
        ctrl = 0x7 | (1<<4) | (1<<5) | (1<<6) | (1<<8);
    else                                         // full worst-case golden
        ctrl = 0xF | (1<<4) | (1<<5) | (1<<6) | (1<<8) | (1<<9);
    reg16(0x00, ctrl);
    fprintf(stderr, "SCENE=%s CTRL=%04x\n", scene?scene:"full", ctrl);

    // run until three frames displayed after enable
    int irq0 = vsync_irqs;
    uint64_t guard = cycles + 40000000ULL;
    uint32_t prev_state = ~0u;
    int trace_left = 0; // change-trace off; ring buffer below instead
    struct Ev { uint64_t c; uint8_t arb, cb, bg1, spr, cache; };
    static Ev ring[512]; static int rw_i = 0; uint32_t prev_ev = ~0u;
    while (vsync_irqs < irq0 + 4 && cycles < guard)
    {
        clk();
        if (top->dbg_ppu_outv)
        {
            dbg_pixels++;
            if (top->dbg_ppu_line > dbg_maxline) dbg_maxline = top->dbg_ppu_line;
        }
        if (top->dbg_frame_done) dbg_framedones++;
        {
            uint32_t ev = top->dbg_arb | (top->dbg_c << 5) | ((top->dbg_bg_states >> 3 & 7) << 8)
                | (top->dbg_spr_state << 11) | (top->dbg_cache_state << 15);
            if (ev != prev_ev)
            {
                ring[rw_i % 512] = { cycles, (uint8_t)top->dbg_arb, (uint8_t)top->dbg_c,
                    (uint8_t)((top->dbg_bg_states >> 3) & 7), (uint8_t)top->dbg_spr_state,
                    (uint8_t)top->dbg_cache_state };
                rw_i++;
                prev_ev = ev;
            }
        }
        // periodic snapshot
        if ((cycles % 100000) == 0)
        {
            printf("S%llu spr=%u cache=%u arb=b%uo%u fst=%u ds=%02x bg=%u,%u,%u,%u dc=%u maxl=%u px=%llu\n",
                (unsigned long long)cycles, top->dbg_spr_state, top->dbg_cache_state,
                (top->dbg_arb >> 4) & 1, top->dbg_arb & 0xF,
                top->dbg_fstate, top->dbg_done_seen,
                top->dbg_bg_states & 7, (top->dbg_bg_states >> 3) & 7,
                (top->dbg_bg_states >> 6) & 7, (top->dbg_bg_states >> 9) & 7,
                top->dbg_done_cnt, dbg_maxline, (unsigned long long)dbg_pixels);
        }
        // trace state changes once the renderer reaches line 59+
        if (dbg_maxline >= 59 && trace_left > 0)
        {
            uint32_t s = top->dbg_spr_state | (top->dbg_cache_state << 4)
                | (top->dbg_arb << 8) | (top->dbg_arb2 << 16)
                | (top->dbg_fstate << 24);
            if (s != prev_state)
            {
                printf("T%llu spr=%u cache=%u arb=b%uo%u arb2=b%uo%u fst=%u ds=%02x bg=%u,%u,%u,%u dc=%u\n",
                    (unsigned long long)cycles, top->dbg_spr_state, top->dbg_cache_state,
                    (top->dbg_arb >> 4) & 1, top->dbg_arb & 0xF,
                    (top->dbg_arb2 >> 4) & 1, top->dbg_arb2 & 0xF,
                    top->dbg_fstate, top->dbg_done_seen,
                    top->dbg_bg_states & 7, (top->dbg_bg_states >> 3) & 7,
                    (top->dbg_bg_states >> 6) & 7, (top->dbg_bg_states >> 9) & 7,
                    top->dbg_done_cnt);
                prev_state = s;
                trace_left--;
            }
        }
    }
    printf("dbg: ppu pixels %llu, max line %u, frame_dones %d\n",
        (unsigned long long)dbg_pixels, dbg_maxline, dbg_framedones);
    printf("dbg: fstate=%u done_seen=%02x unit_en=%02x\n",
        top->dbg_fstate, top->dbg_done_seen, top->dbg_unit_en);
    printf("=== last ring events (arb={busy,owner} c={av,ar,rv} bg1 spr cache):\n");
    for (int i = (rw_i > 40 ? rw_i - 40 : 0); i < rw_i; i++)
    {
        Ev& e = ring[i % 512];
        printf("R%llu arb=b%uo%u c=%u%u%u bg1=%u spr=%u ca=%u\n",
            (unsigned long long)e.c, (e.arb >> 4) & 1, e.arb & 0xF,
            (e.cb >> 2) & 1, (e.cb >> 1) & 1, e.cb & 1, e.bg1, e.spr, e.cache);
    }
    printf("dbg: spr_state=%u cache_state=%u arb={busy%u own%u} arb2={busy%u own%u}\n",
        top->dbg_spr_state, top->dbg_cache_state,
        (top->dbg_arb >> 4) & 1, top->dbg_arb & 0xF,
        (top->dbg_arb2 >> 4) & 1, top->dbg_arb2 & 0xF);
    if (vsync_irqs < irq0 + 4) { fprintf(stderr, "FAIL: frames did not display\n"); return 1; }

    printf("captured through panel after %llu cycles (%d vsyncs)\n",
        (unsigned long long)cycles, vsync_irqs);

    FILE* f = fopen("gpu_frame.ppm", "wb");
    fprintf(f, "P6\n%u %u\n255\n", W, H);
    for (uint32_t i = 0; i < W * H; i++)
    {
        uint16_t p = fbsnap[i];
        uint8_t rgb[3] = {
            (uint8_t)(((p >> 11) & 0x1F) << 3),
            (uint8_t)(((p >> 5) & 0x3F) << 2),
            (uint8_t)((p & 0x1F) << 3)
        };
        fwrite(rgb, 1, 3, f);
    }
    fclose(f);
    printf("DONE: gpu_frame.ppm\n");
    return 0;
}