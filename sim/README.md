# Simulation

Verilator testbenches for each RTL block, plus a headless harness for the 3D core.
The frames these produce are in [proof-of-concept/](proof-of-concept/).

| Directory | What it tests |
|-----------|-------------------|
| ppu/ | 2D PPU: tile and affine backgrounds, sprites, compositor. Renders a frame to `ppu_frame.ppm`. |
| ppu_sdram/ | The PPU running over the real SDRAM controller and cache. |
| gpu/ | The full graphics SoC top (PPU, 3D, SDRAM, FMC bridge). |
| sdram/ | The SDR SDRAM controller: init, refresh, burst-8. |
| fmc/ | The STM32 FMC parallel-bus bridge. |
| scanout/ | The DPI/RGB panel timing generator. |
| headless/ | The 3D core harness (CMake). Needs the RasterIX submodule. |

Each Verilator directory builds and runs with `make`. The headless harness uses
CMake and needs `external/RasterIX` (see the top-level README for the submodule
command).

Requirements: Verilator 5.x, and for the headless harness, CMake plus the RasterIX
submodule.