// PPU v0.3 testbench: 4 BG layers + sprites (OAM), behavioral memory, PPM.
#include "Vppu_top.h"
#include "verilated.h"
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <vector>

static constexpr uint32_t W = 480, H = 272;
static constexpr uint32_t TILE_BASE = 0x8000;
static constexpr uint32_t MAP_BASE[4] = { 0x1000, 0x2000, 0x3000, 0x4000 };
static constexpr uint32_t T3D_BASE = 0x40000;
static constexpr uint16_t T3D_KEY = 0x0001;

static std::vector<uint32_t> mem(1 << 20, 0);
static uint16_t fb[W * H];

// asset generation

static void putTileRow(uint32_t tile, uint32_t row, const uint8_t px[8])
{
    uint32_t w = 0;
    for (int i = 7; i >= 0; i--)
        w = (w << 4) | (px[i] & 0xF);
    mem[TILE_BASE + tile * 8 + row] = w;
}

static void makeTiles()
{
    uint8_t px[8];
    // 0: transparent; 1: solid c1; 2: checker; 3: diag stripe on transparent;
    // 4: ring on transparent; 5: 'F' glyph; 6: horizon gradient rows; 7: dots
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
}

// paint an NxN sprite (1D tile mapping starting at baseTile) from a lambda
template <typename F>
static void makeSprite(uint32_t baseTile, uint32_t n, F paint)
{
    uint32_t wt = n / 8;
    for (uint32_t ty = 0; ty < wt; ty++)
        for (uint32_t tx = 0; tx < wt; tx++)
            for (uint32_t r = 0; r < 8; r++)
            {
                uint8_t px[8];
                for (uint32_t i = 0; i < 8; i++)
                    px[i] = paint(tx * 8 + i, ty * 8 + r);
                putTileRow(baseTile + ty * wt + tx, r, px);
            }
}

static void makeSpriteTiles()
{
    // tiles 32..35: 16x16 ball (shaded circle)
    makeSprite(32, 16, [](uint32_t x, uint32_t y) -> uint8_t {
        int dx = 2 * (int)x - 15, dy = 2 * (int)y - 15;
        int d2 = dx * dx + dy * dy;
        if (d2 > 225) return 0;
        if (d2 > 150) return 1;
        if (dx < -3 && dy < -3) return 4; // highlight
        return 2;
    });
    // tiles 48..63: 32x32 diamond
    makeSprite(48, 32, [](uint32_t x, uint32_t y) -> uint8_t {
        int dx = std::abs(2 * (int)x - 31), dy = std::abs(2 * (int)y - 31);
        if (dx + dy > 31) return 0;
        if (dx + dy > 25) return 1;
        return (uint8_t)(2 + ((x / 4 + y / 4) % 3));
    });
}

static void putOam(Vppu_top& top, uint32_t idx, uint32_t x, uint32_t y, uint32_t size,
    uint32_t pri, bool en, bool hf, bool vf, uint32_t pal, uint32_t tile,
    const std::function<void()>& clk, bool aff = false, uint32_t mat = 0, bool dbl = false)
{
    uint32_t w0 = (x & 0x3FF) | ((y & 0x1FF) << 10) | ((size & 3) << 19)
        | ((pri & 3) << 21) | (en << 23) | (hf << 24) | (vf << 25) | ((pal & 0xF) << 26);
    uint32_t w1 = (tile & 0x3FF) | ((mat & 0x1F) << 10) | ((uint32_t)aff << 15) | ((uint32_t)dbl << 16);
    top.oam_wen = 1;
    top.oam_waddr = idx * 2;
    top.oam_wdata = w0;
    clk();
    top.oam_waddr = idx * 2 + 1;
    top.oam_wdata = w1;
    clk();
    top.oam_wen = 0;
}

static void putMat(Vppu_top& top, uint32_t idx, double a, double b, double c, double d,
    const std::function<void()>& clk)
{
    int16_t v[4] = { (int16_t)(a * 256), (int16_t)(b * 256), (int16_t)(c * 256), (int16_t)(d * 256) };
    top.mat_wen = 1;
    for (uint32_t i = 0; i < 4; i++)
    {
        top.mat_waddr = idx * 4 + i;
        top.mat_wdata = (uint16_t)v[i];
        clk();
    }
    top.mat_wen = 0;
}

static void putMap(uint32_t base, uint32_t tx, uint32_t ty, uint16_t entry)
{
    uint32_t idx = ty * 64 + tx;
    uint32_t& w = mem[base + idx / 2];
    if (idx & 1)
        w = (w & 0x0000FFFF) | ((uint32_t)entry << 16);
    else
        w = (w & 0xFFFF0000) | entry;
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
            // L0 (front, pri 0): sparse F glyphs on transparent
            putMap(MAP_BASE[0], tx, ty, ((tx % 7 == 2) && (ty % 5 == 1)) ? entry(5, tx & 1, ty & 1, 3) : entry(0, 0, 0, 0));
            // L1 (pri 1): dots field, transparent elsewhere
            putMap(MAP_BASE[1], tx, ty, ((tx + ty) % 3 == 0) ? entry(7, 0, 0, 2) : entry(0, 0, 0, 0));
            // L2 (pri 2): rings band in the middle, transparent elsewhere
            putMap(MAP_BASE[2], tx, ty, (ty >= 12 && ty < 24) ? entry(4, 0, 0, (tx & 1) ? 1 : 0) : entry(0, 0, 0, 0));
            // L3 (back, pri 3): opaque ground -- gradient sky rows then checker ground
            putMap(MAP_BASE[3], tx, ty, (ty < 16) ? entry(6, 0, 0, 2) : entry(2, 0, 0, (ty & 1)));
        }
}

static uint16_t rgb565(uint8_t r, uint8_t g, uint8_t b)
{
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
}

// fake RasterIX color buffer: key-filled frame + shaded quad ("3D panel")
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
                else
                {
                    p[i] = T3D_KEY;
                }
            }
            mem[T3D_BASE + (y * W + x) / 2] = ((uint32_t)p[1] << 16) | p[0];
        }
}

// main 

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    Vppu_top top;

    makeTiles();
    makeSpriteTiles();
    makeMaps();
    make3dFrame();

    std::function<void()> clk = [&]() {
        top.clk = 1; top.eval();
        top.clk = 0; top.eval();
    };

    top.rst = 1; clk(); clk(); top.rst = 0;

    static const uint8_t hue[4][3] = { {255,80,40}, {40,200,90}, {70,120,255}, {250,200,40} };
    for (uint32_t p = 0; p < 4; p++)
        for (uint32_t c = 0; c < 16; c++)
        {
            uint32_t s = 55 + c * 13;
            top.pal_wen = 1;
            top.pal_waddr = p * 16 + c;
            top.pal_wdata = rgb565(hue[p][0] * s / 255, hue[p][1] * s / 255, hue[p][2] * s / 255);
            clk();
        }
    top.pal_wen = 0;

    // layer config: parallax scrolls, pri = layer index (0 front .. 3 back)
    top.layer_en  = 0xF;
    top.layer_pri = (3 << 6) | (2 << 4) | (1 << 2) | 0;
    uint64_t sx = 0;
    sx |= (uint64_t)(97 & 0x3FF) << 0;   // L0 fastest
    sx |= (uint64_t)(53 & 0x3FF) << 10;  // L1
    sx |= (uint64_t)(21 & 0x3FF) << 20;  // L2
    sx |= (uint64_t)(5  & 0x3FF) << 30;  // L3 slowest
    top.scroll_x_all = sx;
    uint64_t sy = 0;
    sy |= (uint64_t)(3 & 0x1FF) << 0;
    sy |= (uint64_t)(0 & 0x1FF) << 9;
    sy |= (uint64_t)(7 & 0x1FF) << 18;
    sy |= (uint64_t)(0 & 0x1FF) << 27;
    top.scroll_y_all = sy;
    for (int l = 0; l < 4; l++)
    {
        top.map_base_all[l]  = MAP_BASE[l];   // WData array: 32b words
        top.tile_base_all[l] = TILE_BASE;
    }
    top.backdrop = rgb565(15, 15, 30);

    // layer 2 -> affine: rotate 20deg, scale 1, world center on screen center
    {
        double th = 20.0 * 3.14159265 / 180.0;
        int16_t pa = (int16_t)(cos(th) * 256), pb = (int16_t)(-sin(th) * 256);
        int16_t pc = (int16_t)(sin(th) * 256), pd = (int16_t)(cos(th) * 256);
        int32_t cx = 256 << 8, cy = 150 << 8; // world point at screen center
        int32_t ox = cx - pa * 240 - pb * 136;
        int32_t oy = cy - pc * 240 - pd * 136;
        top.layer_affine = 0x1; // layer2 affine, layer3 text
        top.aff_pa_all = (uint16_t)pa;
        top.aff_pb_all = (uint16_t)pb;
        top.aff_pc_all = (uint16_t)pc;
        top.aff_pd_all = (uint16_t)pd;
        top.aff_ox_all = (uint64_t)(ox & 0x3FFFF);
        top.aff_oy_all = (uint64_t)(oy & 0x3FFFF);
    }

    // sprites
    top.spr_en = 1;
    top.spr_tile_base = TILE_BASE;
    // 12 balls (16x16, pri 0 = front), arcing across the screen
    for (uint32_t i = 0; i < 12; i++)
    {
        uint32_t x = 20 + i * 38;
        uint32_t y = 100 + (uint32_t)(60.0 * std::sin(i * 0.7));
        putOam(top, i, x, y, 1, 0, true, false, false, (i % 3), 32, clk);
    }
    // 32x32 diamond "player" (pri 1: in front of rings/back, behind front glyphs? L0 pri0 wins ties over... sprite pri1 vs BG pri0: BG wins)
    putOam(top, 12, 224, 120, 2, 1, true, false, false, 3, 48, clk);
    // clip tests: ball halfway off left (x=1015 wraps) + off right
    putOam(top, 13, 1015, 40, 1, 0, true, false, false, 1, 32, clk);
    putOam(top, 14, 470, 200, 1, 0, true, true, true, 0, 32, clk);
    // disabled sprite (must not render)
    putOam(top, 15, 240, 130, 1, 0, false, false, false, 0, 32, clk);

    // affine sprites: mat0 = rotate 30deg; mat1 = scale up 2x (inverse = 0.5)
    {
        double th = 30.0 * 3.14159265 / 180.0;
        putMat(top, 0, cos(th), -sin(th), sin(th), cos(th), clk);
        putMat(top, 1, 0.5, 0.0, 0.0, 0.5, clk);
    }
    // rotated 32x32 diamond (double-size window so corners don't clip)
    putOam(top, 16, 60, 60, 2, 0, true, false, false, 1, 48, clk, true, 0, true);
    // 2x-scaled 16x16 ball (32px on screen, double window)
    putOam(top, 17, 360, 30, 1, 0, true, false, false, 2, 32, clk, true, 1, true);

    // 3D layer: pri 1, color-keyed, alpha-blended over what's below
    top.t3d_en = 1;
    top.t3d_pri = 1;
    top.t3d_base = T3D_BASE;
    top.t3d_key_en = 1;
    top.t3d_key = T3D_KEY;
    top.blend_en = 0b000010; // blend the 3D layer only
    top.eva = 10;            // 10/16 top
    top.evb = 6;             // 6/16 below
    top.bright_mode = 0;
    top.bright = 0;

    top.frame_start = 1; clk(); top.frame_start = 0;

    uint64_t cycles = 0;
    uint32_t beats = 0;      // beats remaining on current transaction
    uint32_t pend_addr = 0;
    while (!top.frame_done && cycles < 60000000ULL)
    {
        top.m_arready = (beats == 0);
        top.m_rvalid = (beats != 0);
        top.m_rdata = (beats != 0) ? mem[pend_addr & (mem.size() - 1)] : 0;
        if (beats != 0)
        {
            pend_addr++;
            beats--;
        }
        else if (top.m_arvalid)
        {
            pend_addr = top.m_araddr;
            beats = top.m_burst ? 8 : 1;
        }
        if (top.out_valid)
            fb[top.out_line * W + top.out_x] = top.out_pixel;
        clk();
        cycles++;
    }

    if (!top.frame_done)
    {
        fprintf(stderr, "FAIL: frame did not complete\n");
        return 1;
    }
    printf("frame complete in %llu cycles (%.2f us @100MHz, %.2f us/line, 4 layers)\n",
        (unsigned long long)cycles, cycles / 100.0, cycles / 100.0 / H);
    printf("cache: %u hits / %u misses (%.1f%% hit rate)\n",
        top.stat_hits, top.stat_misses,
        100.0 * top.stat_hits / (double)(top.stat_hits + top.stat_misses));

    FILE* f = fopen("ppu_frame.ppm", "wb");
    fprintf(f, "P6\n%u %u\n255\n", W, H);
    for (uint32_t i = 0; i < W * H; i++)
    {
        uint16_t p = fb[i];
        uint8_t rgb[3] = {
            (uint8_t)(((p >> 11) & 0x1F) << 3),
            (uint8_t)(((p >> 5) & 0x3F) << 2),
            (uint8_t)((p & 0x1F) << 3)
        };
        fwrite(rgb, 1, 3, f);
    }
    fclose(f);
    printf("DONE: ppu_frame.ppm\n");
    return 0;
}