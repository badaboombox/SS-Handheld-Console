// SS Handheld - clock generation (ECP5 EHXPLLL)
//
// One PLL off a 50 MHz reference oscillator makes both board clocks:
//   CLKOP = 66.67 MHz  -> GPU domain (RasterIX + PPU + FMC bridge + scanout)
//   CLKOS = 133.33 MHz -> SDRAM domain (2x GPU; async-FIFO crossing at the
//                         GPU<->SDRAM boundary, per the split-clock plan)
// Math: fPFD = 50/CLKI_DIV = 50/3 = 16.67 MHz (>=10); fVCO = fCLKOP*CLKOP_DIV
//       = 66.67*10 = 666.67 MHz (in [400,800]); CLKOP = 50*CLKFB_DIV/CLKI_DIV
//       = 50*4/3 = 66.67; CLKOS = fVCO/CLKOS_DIV = 666.67/5 = 133.33.
// The pixel clock is NOT a PLL output: dpi_scanout derives it from CLKOP with
// a clock-enable divider (66.67/7 ≈ 9.52 MHz), so no extra PLL leg is needed.
// The SDRAM chip's clock pin wants a phase-shifted copy for pad setup/hold;
// that is a board-tuning knob on a spare PLL output (CLKOS2 with a CPHASE
// offset) and is left for layout.

module clkgen (
    input  wire clk_ref,      // 50 MHz oscillator
    output wire clk_gpu,      // 66.67 MHz
    output wire clk_sdram,    // 133.33 MHz
    output wire pll_locked
);

    wire clkop;               // 66.67 (also the feedback)
    assign clk_gpu = clkop;

    (* FREQUENCY_PIN_CLKI="50" *)
    (* FREQUENCY_PIN_CLKOP="66.67" *)
    (* FREQUENCY_PIN_CLKOS="133.33" *)
    (* ICP_CURRENT="12" *) (* LPF_RESISTOR="8" *)
    EHXPLLL #(
        .PLLRST_ENA("DISABLED"),
        .INTFB_WAKE("DISABLED"),
        .STDBY_ENABLE("DISABLED"),
        .DPHASE_SOURCE("DISABLED"),
        .OUTDIVIDER_MUXA("DIVA"),
        .OUTDIVIDER_MUXB("DIVB"),
        .OUTDIVIDER_MUXC("DIVC"),
        .OUTDIVIDER_MUXD("DIVD"),
        .CLKI_DIV(3),
        .CLKOP_ENABLE("ENABLED"),
        .CLKOP_DIV(10),
        .CLKOP_CPHASE(4),
        .CLKOP_FPHASE(0),
        .CLKOS_ENABLE("ENABLED"),
        .CLKOS_DIV(5),
        .CLKOS_CPHASE(4),
        .CLKOS_FPHASE(0),
        .CLKFB_DIV(4),
        .FEEDBK_PATH("CLKOP")
    ) pll (
        .RST(1'b0),
        .STDBY(1'b0),
        .CLKI(clk_ref),
        .CLKOP(clkop),
        .CLKOS(clk_sdram),
        .CLKFB(clkop),
        .CLKINTFB(),
        .PHASESEL0(1'b0),
        .PHASESEL1(1'b0),
        .PHASEDIR(1'b0),
        .PHASESTEP(1'b0),
        .PHASELOADREG(1'b0),
        .PLLWAKESYNC(1'b0),
        .ENCLKOP(1'b0),
        .ENCLKOS(1'b0),
        .LOCK(pll_locked)
    );

endmodule