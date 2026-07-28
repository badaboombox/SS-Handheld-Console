// FMC bridge TB: emulates the STM32 async-FMC master (NE/NWE/NOE waveforms
// spanning several GPU clocks) and verifies all four windows.
#include "Vfmc_bridge.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <vector>

static Vfmc_bridge* top;
static uint64_t cycles = 0;

// captured bridge outputs
struct RegWr { uint8_t addr; uint16_t data; };
static std::vector<RegWr> regwrites;
struct UpWr { uint32_t addr; uint32_t data; };
static std::vector<UpWr> upwrites;
static std::vector<uint32_t> stream_rx;
static bool stream_accept = true;

static void clk()
{
    // consume stream when allowed (models RasterIX FrameStreamingCore ready)
    top->cmd_tready = stream_accept;
    top->clk = 1; top->eval();
    if (top->rw_wen) regwrites.push_back({ (uint8_t)top->rw_addr, (uint16_t)top->rw_wdata });
    if (top->up_wen) upwrites.push_back({ top->up_addr, top->up_wdata });
    if (top->cmd_tvalid && top->cmd_tready) stream_rx.push_back(top->cmd_tdata);
    top->clk = 0; top->eval();
    cycles++;
}

// async FMC write: NE low, addr/data set, NWE low ~3 clks, NWE high, NE high
static void fmcWrite(uint16_t addr, uint16_t data)
{
    top->fmc_a = addr & 0x3FF;
    top->fmc_d_i = data;
    top->fmc_ne = 0; clk();
    top->fmc_nwe = 0; clk(); clk(); clk();
    top->fmc_nwe = 1; clk(); clk();     // data/addr held past NWE rise
    top->fmc_ne = 1; clk(); clk();
}

// async FMC read: NE low, NOE low, sample, release
static uint16_t fmcRead(uint16_t addr)
{
    top->fmc_a = addr & 0x3FF;
    top->fmc_ne = 0; clk();
    top->fmc_noe = 0;
    for (int i = 0; i < 4; i++) clk();  // OE access time
    uint16_t d = top->fmc_d_o;
    if (!top->fmc_d_oe) { printf("FAIL: d_oe not asserted on read\n"); exit(1); }
    top->fmc_noe = 1; clk();
    top->fmc_ne = 1; clk(); clk();
    return d;
}

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    top = new Vfmc_bridge;
    top->fmc_ne = 1; top->fmc_nwe = 1; top->fmc_noe = 1;
    top->status_flags = 0xC0DE;

    top->rst = 1; clk(); clk(); top->rst = 0; clk();

    int errors = 0;

    // REGS window 
    fmcWrite(0x000 | 0x12, 0xBEEF);
    fmcWrite(0x000 | 0x34, 0x1234);
    if (regwrites.size() != 2 || regwrites[0].addr != 0x12 || regwrites[0].data != 0xBEEF
        || regwrites[1].addr != 0x34 || regwrites[1].data != 0x1234)
    { errors++; printf("FAIL: reg writes (%zu captured)\n", regwrites.size()); }

    // STREAM window: 8 x 32b words as lo/hi pairs 
    for (uint32_t i = 0; i < 8; i++)
    {
        uint32_t w = 0xA0000000u + i * 0x10001u;
        fmcWrite(0x100, w & 0xFFFF);
        fmcWrite(0x100, w >> 16);
    }
    for (int i = 0; i < 8; i++) clk();
    if (stream_rx.size() != 8) { errors++; printf("FAIL: stream got %zu words\n", stream_rx.size()); }
    for (uint32_t i = 0; i < stream_rx.size() && i < 8; i++)
        if (stream_rx[i] != 0xA0000000u + i * 0x10001u)
        { errors++; printf("FAIL: stream[%u]=%08x\n", i, stream_rx[i]); break; }

    // STREAM backpressure: stall consumer, check STATUS free count 
    stream_accept = false;
    for (uint32_t i = 0; i < 4; i++)
    {
        fmcWrite(0x100, i);
        fmcWrite(0x100, 0);
    }
    uint16_t freew = fmcRead(0x300);
    if (freew != 512 - 4) { errors++; printf("FAIL: fifo_free=%u want 508\n", freew); }
    stream_accept = true;
    for (int i = 0; i < 8; i++) clk();

    // STATUS flags 
    uint16_t fl = fmcRead(0x301);
    if (fl != 0xC0DE) { errors++; printf("FAIL: flags=%04x\n", fl); }

    // SDRAM_UP window
    fmcWrite(0x200, 0x5000);        // PTR_LO
    fmcWrite(0x201, 0x0002);        // PTR_HI -> word addr 0x25000
    for (uint32_t i = 0; i < 4; i++)
    {
        uint32_t w = 0x11110000u + i;
        fmcWrite(0x202, w & 0xFFFF);
        fmcWrite(0x202, w >> 16);
    }
    if (upwrites.size() != 4) { errors++; printf("FAIL: up writes %zu\n", upwrites.size()); }
    for (uint32_t i = 0; i < upwrites.size() && i < 4; i++)
    {
        if (upwrites[i].addr != 0x25000u + i || upwrites[i].data != 0x11110000u + i)
        { errors++; printf("FAIL: up[%u] addr=%06x data=%08x\n", i, upwrites[i].addr, upwrites[i].data); break; }
    }

    if (errors) { printf("FAIL: %d errors\n", errors); return 1; }
    printf("PASS: FMC bridge all windows OK (%llu cycles)\n", (unsigned long long)cycles);
    return 0;
}