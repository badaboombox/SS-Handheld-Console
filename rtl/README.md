# RTL

All the Verilog for the SS Handheld graphics engine. It targets a Lattice
ECP5 (LFE5U-85F) and builds with Yosys and nextpnr.

## Top level

- `gpu_chip.v` is the board and synthesis top. It wraps the SoC, brings out the
  real chip pins (SDRAM, FMC, panel, clock, reset), sets up the PLL, and forwards
  the SDRAM clock through an ODDR. This is what gets synthesized into a bitstream.
- `gpu_top.v` is the SoC. It ties together the 2D PPU, the 3D core, the SDRAM
  subsystem, and the FMC bridge, along with the SDRAM arbitration and the
  framebuffer swap logic.
- `gpu_chip.lpf` holds the pin constraints (ball assignments and IO standards) for
  the CABGA381 package.
- `clkgen.v` sets up the ECP5 PLL: one 50 MHz reference in, a 66.67 MHz GPU clock
  and a 133.33 MHz SDRAM clock out.

## Blocks

| Path | What it does |
|------|--------------|
| ppu/ | 2D tile and sprite PPU: text and affine backgrounds, sprites, a shared cache and arbiter, and a scanline compositor. See [ppu/PPU_Microarch.md](ppu/PPU_Microarch.md). |
| sdram/ | 32-bit SDR SDRAM controller (init, refresh, burst-8), an AXI bridge, and the clock crossing that puts the controller in its own 133 MHz domain. |
| fmc/ | The STM32 FMC parallel-bus slave and the register file it drives. |
| scanout/ | DPI/RGB panel timing generator (480x272, sync and DE, RGB888 out). |

The 3D rasterizer is RasterIX, pulled in as a submodule at `external/RasterIX`, so
it is not part of this directory. `gpu_top` instantiates it.

## Clock domains

- GPU domain (66.67 MHz): the PPU, the 3D core, compositing, and scanout.
- SDRAM domain (133.33 MHz, exactly twice the GPU clock): the SDRAM controller,
  reached from the GPU domain through async FIFOs.

## Building

See the top-level README and [../build/README.md](../build/README.md). In short,
Yosys synthesizes `gpu_chip`, nextpnr places and routes it against `gpu_chip.lpf`,
and ecppack makes the bitstream. The build is pinned to a place-and-route seed so
timing is repeatable.

## Style

The RTL is written to synthesize cleanly with Yosys: Verilog-2005, memories as
plain arrays, no empty for-loop increments, and simulation-only asserts guarded by
`ifdef SIMULATION`.