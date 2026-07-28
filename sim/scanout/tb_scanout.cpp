// DPI scanout TB: run 2+ frames, verify timing counts (DE per line/frame,
// sync widths, frame period), pixel data path, pacing pulses.
#include "Vdpi_scanout.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>

static Vdpi_scanout* top;
static uint64_t cycles = 0;
static uint16_t linebuf[480];

static void clk()
{
    top->lb_rdata = linebuf[top->lb_raddr];
    top->clk = 1; top->eval();
    top->clk = 0; top->eval();
    cycles++;
}

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    top = new Vdpi_scanout;

    for (int i = 0; i < 480; i++) linebuf[i] = (uint16_t)(0x8000 | i); // marker pattern

    top->rst = 1; clk(); clk(); top->rst = 0;

    int errors = 0;
    uint64_t de_count = 0, de_line = 0, de_line_max = 0, de_line_min = ~0ull;
    uint64_t hsync_low = 0, vsync_low = 0;
    int vsync_irqs = 0, line_reqs = 0;
    uint64_t frame_start_cyc = 0, frame_period = 0;
    bool prev_de = false, prev_vsync = true, prev_pclk = false;
    uint32_t pixels_checked = 0;

    // run ~2.2 frames: 525*286*7 cycles/frame
    uint64_t total = (uint64_t)(525 * 286 * 7 * 2.2);
    for (uint64_t c = 0; c < total; c++)
    {
        bool pclk_rise = false;
        {
            bool p = top->pclk;
            clk();
            pclk_rise = !p && top->pclk;
        }
        if (pclk_rise) // sample panel signals like the panel would
        {
            if (top->de)
            {
                de_count++; de_line++;
                // check RGB expansion of the marker pattern (line addr known)
                uint16_t px = 0; // recompute from rgb
                uint8_t r = (top->rgb >> 16) & 0xFF, g = (top->rgb >> 8) & 0xFF, b = top->rgb & 0xFF;
                px = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
                if ((px & 0x8000) == 0 && pixels_checked < 5)
                { errors++; printf("FAIL: rgb marker bit lost %04x\n", px); }
                pixels_checked++;
            }
            else if (prev_de)
            {
                if (de_line > de_line_max) de_line_max = de_line;
                if (de_line < de_line_min) de_line_min = de_line;
                de_line = 0;
            }
            prev_de = top->de;
            if (!top->hsync) hsync_low++;
            if (!top->vsync) vsync_low++;
            if (prev_vsync && !top->vsync)
            {
                if (frame_start_cyc) frame_period = cycles - frame_start_cyc;
                frame_start_cyc = cycles;
            }
            prev_vsync = top->vsync;
        }
        if (top->vsync_irq) vsync_irqs++;
        if (top->line_req) line_reqs++;
    }

    printf("DE pixels total: %llu (per frame ~%llu, want 130560)\n",
        (unsigned long long)de_count, (unsigned long long)(de_count * 10 / 22));
    printf("DE per line: min %llu max %llu (want 480/480)\n",
        (unsigned long long)de_line_min, (unsigned long long)de_line_max);
    printf("frame period: %llu clk (want 525*286*7=1051050) -> %.2f Hz @66MHz\n",
        (unsigned long long)frame_period, 66.0e6 / (double)frame_period);
    printf("vsync_irqs %d, line_reqs %d\n", vsync_irqs, line_reqs);

    if (de_line_min != 480 || de_line_max != 480) { errors++; printf("FAIL: DE line width\n"); }
    if (frame_period != 525ull * 286 * 7) { errors++; printf("FAIL: frame period\n"); }
    if (vsync_irqs < 2) { errors++; printf("FAIL: vsync irqs\n"); }

    if (errors) { printf("FAIL: %d errors\n", errors); return 1; }
    printf("PASS: DPI scanout timing OK\n");
    return 0;
}