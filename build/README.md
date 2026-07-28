# Board-top bitstream

The ready-to-flash FPGA configuration for the board top (`gpu_chip`), built at a
pinned place-and-route seed. This is NOT a final build, so you should
rebuild it after any RTL change. A few things are still unfinished (command
response readback, NWAIT polarity, and real SDRAM pad timing).

The `.bit` and `.svf` binaries are git-ignored and regenerable. This README and the
verilog itself are tracked.

## Artifacts

- `gpuchip.bit` (about 2.3 MB): the SPI-flash image for the W25Q32 config flash,
  which the ECP5 boots from on power-up.
- `gpuchip.svf` (about 4.8 MB): a JTAG program file for a direct volatile load
  during bring-up.

## Provenance

- RTL: `rtl/gpu_chip.v` (the board top, with an ODDR-driven SDRAM clock), the rest
  of `rtl/`, and the RasterIX submodule.
- Pinout: `rtl/gpu_chip.lpf` (LFE5U-85F, CABGA381, 117 IO). nextpnr places all 117
  with no conflicts.
- Tools: Yosys, nextpnr-ecp5, and ecppack from Project Trellis.
- The build is pinned to a place-and-route seed because the GPU clock is
  seed-sensitive. The pinned seed gives clean margin and is deterministic.
- Post-route timing: GPU clock 73.46 MHz against a 66.67 target, SDRAM clock
  174.58 MHz against a 133.33 target, so both pass.

## Regenerate

```sh
yosys gpuchip.ys                 # creates gpuchip_ecp5.json
nextpnr-ecp5 --85k --package CABGA381 --speed 8 \
  --json gpuchip_ecp5.json --lpf ../rtl/gpu_chip.lpf --lpf-allow-unconstrained \
  --seed 4 --textcfg gpuchip.config
ecppack gpuchip.config gpuchip.bit         # SPI-flash image
ecppack --svf gpuchip.svf gpuchip.config   # JTAG
```

## Flashing at bring-up

- SPI flash: write `gpuchip.bit` to the W25Q32, for example with
  `openFPGALoader -c <cable> -f gpuchip.bit`, or through the config-flash header.
  The ECP5 boots it during power on, with the config straps set to Master SPI.
- JTAG bench load: `openFPGALoader -c <cable> gpuchip.svf` for a quick volatile
  load without touching flash.