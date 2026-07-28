// SS Handheld - GPU chip top (board / synthesis)
//
// The real top level that maps to ECP5 pins. Wraps gpu_top (SIM_SDRAM=0) and:
//   - turns the split FMC data (d_i / d_o / d_oe) into a bidirectional bus pad
//   - turns the split SDRAM dq (i / o / oe) into a bidirectional bus pad
//   - drops all sim-only dbg_* taps (left unconnected -> optimized away)
// Clocking: an on-chip PLL (clkgen) derives clk_gpu (66.67 MHz) and clk_sdram
// (133.33 MHz) from the external 50 MHz reference (clk_ref); dpi_scanout
// CE-divides clk_gpu for the ~9.52 MHz pixel clock, and clk_sdram is mirrored
// to the SDRAM CLK pin via ODDRX1F. Reset is held until the PLL locks.

module gpu_chip (
    input  wire        clk_ref,      // 50 MHz reference oscillator
    input  wire        rst,

    // FMC (STM32) - data is a real bidirectional bus
    input  wire        fmc_ne,
    input  wire        fmc_nwe,
    input  wire        fmc_noe,
    input  wire [9:0]  fmc_a,
    inout  wire [15:0] fmc_d,
    output wire        fmc_nwait,
    output wire        cpu_irq,

    // RGB panel
    output wire        pclk,
    output wire        hsync,
    output wire        vsync,
    output wire        de,
    output wire [23:0] rgb,

    // SDRAM
    output wire        sdram_clk,    // forwarded 133 MHz to the SDRAM chips
    output wire        sdram_cke,
    output wire        sdram_cs_n,
    output wire        sdram_ras_n,
    output wire        sdram_cas_n,
    output wire        sdram_we_n,
    output wire [1:0]  sdram_ba,
    output wire [11:0] sdram_a,
    output wire [3:0]  sdram_dqm,
    inout  wire [31:0] sdram_dq
);

    // clocks: 50 MHz ref -> PLL -> 66.67 (GPU) + 133.33 (SDRAM)
    wire clk_gpu, clk_sdram, pll_locked;
    clkgen u_clk (
        .clk_ref(clk_ref), .clk_gpu(clk_gpu), .clk_sdram(clk_sdram),
        .pll_locked(pll_locked)
    );
    wire rst_int = rst || !pll_locked;   // hold reset until the PLL locks

    // Forward clk_sdram to the SDRAM CLK pin through an ODDRX1F clock-mirror:
    // D0=1 / D1=0 toggled on clk_sdram makes Q a clean, PIO-registered copy of
    // the 133 MHz clock (sharper pad edges than a fabric-routed `assign`).
    // Board bring-up phase knob: if SDRAM setup/hold needs it, drive this from a
    // phase-shifted CLKOS2 (CPHASE offset in clkgen) instead of clk_sdram - the
    // ODDR just mirrors whatever clock it is fed.
    ODDRX1F u_sdram_clk (
        .SCLK (clk_sdram),
        .RST  (1'b0),
        .D0   (1'b1),
        .D1   (1'b0),
        .Q    (sdram_clk)
    );

    // FMC data bus tristate 
    wire [15:0] fmc_d_o;
    wire        fmc_d_oe;
    assign fmc_d = fmc_d_oe ? fmc_d_o : 16'bz;

    // SDRAM dq bus tristate 
    wire [31:0] sdram_dq_o;
    wire        sdram_dq_oe;
    assign sdram_dq = sdram_dq_oe ? sdram_dq_o : 32'bz;

    gpu_top #(
        .SIM_SDRAM(0)
    ) core (
        .clk(clk_gpu), .clk_sdram(clk_sdram), .rst(rst_int),

        .fmc_ne(fmc_ne), .fmc_nwe(fmc_nwe), .fmc_noe(fmc_noe),
        .fmc_a(fmc_a),
        .fmc_d_i(fmc_d), .fmc_d_o(fmc_d_o), .fmc_d_oe(fmc_d_oe),
        .fmc_nwait(fmc_nwait), .cpu_irq(cpu_irq),

        .pclk(pclk), .hsync(hsync), .vsync(vsync), .de(de), .rgb(rgb),

        .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n),
        .sdram_ras_n(sdram_ras_n), .sdram_cas_n(sdram_cas_n),
        .sdram_we_n(sdram_we_n), .sdram_ba(sdram_ba), .sdram_a(sdram_a),
        .sdram_dqm(sdram_dqm),
        .sdram_dq_o(sdram_dq_o), .sdram_dq_oe(sdram_dq_oe), .sdram_dq_i(sdram_dq),

        // sim-only debug taps: unconnected -> synthesis prunes the logic
        .dbg_ppu_line(), .dbg_ppu_outv(), .dbg_frame_done(),
        .dbg_fstate(), .dbg_done_seen(), .dbg_unit_en(),
        .dbg_spr_state(), .dbg_cache_state(), .dbg_arb(), .dbg_arb2(),
        .dbg_bg_states(), .dbg_done_cnt(), .dbg_c(),
        .dbg_swap_cnt(), .dbg_cmd_tready(), .dbg_axi()
    );

endmodule