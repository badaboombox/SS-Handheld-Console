// SDRAM controller TB: init, write/read verify (seq + random + byte-mask),
// throughput measurement. A2 evidence (protocol side; Fmax from nextpnr).
#include "Vsdram_tb_top.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>

static Vsdram_tb_top* top;
static uint64_t cycles = 0;

static void clk()
{
    top->clk = 1; top->eval();
    top->clk = 0; top->eval();
    cycles++;
}

static void write32(uint32_t addr, uint32_t data, uint8_t be = 0xF)
{
    while (!top->ready) clk();
    top->req = 1; top->we = 1; top->burst = 0; top->addr = addr; top->wdata = data; top->wbe = be;
    clk();
    top->req = 0;
    while (!top->wdone) clk();
}

static uint32_t read32(uint32_t addr)
{
    while (!top->ready) clk();
    top->req = 1; top->we = 0; top->burst = 0; top->addr = addr; top->wbe = 0xF;
    clk();
    top->req = 0;
    while (!top->rvalid) clk();
    return top->rdata;
}

static void readBurst8(uint32_t addr, uint32_t out[8])
{
    while (!top->ready) clk();
    top->req = 1; top->we = 0; top->burst = 1; top->addr = addr; top->wbe = 0xF;
    clk();
    top->req = 0; top->burst = 0;
    for (int i = 0; i < 8;)
    {
        if (top->rvalid) out[i++] = top->rdata;
        clk();
    }
}

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    top = new Vsdram_tb_top;

    top->rst = 1; clk(); clk(); top->rst = 0;

    while (!top->init_done && cycles < 100000) clk();
    if (!top->init_done) { fprintf(stderr, "FAIL: init timeout\n"); return 1; }
    printf("init done at cycle %llu\n", (unsigned long long)cycles);

    int errors = 0;

    // sequential pattern
    for (uint32_t i = 0; i < 512; i++) write32(i, i ^ 0xA5A50000u);
    for (uint32_t i = 0; i < 512; i++)
    {
        uint32_t d = read32(i);
        if (d != (i ^ 0xA5A50000u)) { if (errors++ < 5) printf("MISMATCH seq @%u: got %08x want %08x\n", i, d, i ^ 0xA5A50000u); }
    }

    // random addresses (cross banks/rows)
    srand(7);
    static uint32_t raddr[256], rdatav[256];
    for (uint32_t i = 0; i < 256; i++)
    {
        raddr[i] = ((uint32_t)rand() * 2654435761u) & 0x3FFFFF;
        rdatav[i] = (uint32_t)rand() * 40503u + i;
        write32(raddr[i], rdatav[i]);
    }
    for (uint32_t i = 0; i < 256; i++)
    {
        uint32_t d = read32(raddr[i]);
        // later writes may alias same address; recompute expectation
        uint32_t want = rdatav[i];
        for (uint32_t j = i + 1; j < 256; j++)
            if (raddr[j] == raddr[i]) want = rdatav[j];
        if (d != want) { if (errors++ < 5) printf("MISMATCH rnd @%06x: got %08x want %08x\n", raddr[i], d, want); }
    }

    // byte enables
    write32(0x1000, 0xFFFFFFFFu);
    write32(0x1000, 0x000000AAu, 0x1);
    write32(0x1000, 0x0000BB00u, 0x2);
    uint32_t d = read32(0x1000);
    if (d != 0xFFFFBBAAu) { errors++; printf("MISMATCH bytemask: got %08x want FFFFBBAA\n", d); }

    // burst correctness against the sequential pattern
    for (uint32_t base = 0; base < 512; base += 8)
    {
        uint32_t buf[8];
        readBurst8(base, buf);
        for (uint32_t k = 0; k < 8; k++)
            if (buf[k] != ((base + k) ^ 0xA5A50000u))
            {
                if (errors++ < 5)
                    printf("MISMATCH burst @%u+%u: got %08x want %08x\n",
                        base, k, buf[k], (base + k) ^ 0xA5A50000u);
            }
    }

    // throughput: 2048 sequential single-beat reads
    uint64_t c0 = cycles;
    for (uint32_t i = 0; i < 2048; i++) (void)read32(i);
    uint64_t rd_cyc = cycles - c0;
    double cyc_per = rd_cyc / 2048.0;
    printf("single-beat read: %.2f cyc/word -> %.1f MB/s @133MHz (%.0f%% bus efficiency)\n",
        cyc_per, 133.0e6 * 4.0 / cyc_per / 1e6, 100.0 / cyc_per);

    // throughput: 2048 words via 8-word bursts
    c0 = cycles;
    for (uint32_t i = 0; i < 2048; i += 8) { uint32_t buf[8]; readBurst8(i, buf); }
    rd_cyc = cycles - c0;
    cyc_per = rd_cyc / 2048.0;
    printf("burst-8 read:     %.2f cyc/word -> %.1f MB/s @133MHz (%.0f%% bus efficiency)\n",
        cyc_per, 133.0e6 * 4.0 / cyc_per / 1e6, 100.0 / cyc_per);

    if (errors) { printf("FAIL: %d errors\n", errors); return 1; }
    printf("PASS: all verify OK\n");
    return 0;
}