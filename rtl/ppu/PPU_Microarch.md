# 2D PPU (Pixel Processing Unit) microarchitecture

The PPU renders one scanline at a time into a line buffer, which the scanout block
then streams to the panel. It draws four background layers (text or affine) and
sprites, composites them by priority with alpha blending, and can mix in the 3D
color buffer as another layer.

## Pipeline

All the renderers run concurrently for a given line. They share a single memory
port through a fixed-priority arbiter and a shared cache, so the per-line cost is
bounded by memory instead of the number of layers.

- The background renderers (text and affine) each produce one layer's pixels for
  the line.
- The sprite renderer scans the OAM for sprites on this line and plots them into
  a sprite line buffer.
- The 3D fetch unit reads the 3D color buffer for the line. It bypasses the cache,
  since that buffer is written once per frame and would only take up cache space.
- The compositor resolves all the sources by priority, applies alpha blending and
  brightness, and writes the final RGB565 pixel.

At 66.67 MHz the worst-case scene renders in about 35 microseconds per line, inside
the roughly 56 microsecond line budget. The shared cache runs around an 83% hit
rate on that scene.

## Backgrounds

- Text layers: 64x64 tilemaps of 8x8 4bpp tiles, 16 palettes, fine x and y scroll,
  horizontal and vertical flip.
- Affine layers: layers 2 and 3 can switch to affine mode. A DDA walks an s8.8
  matrix across a 512x512 wrapping world, with small map and tile caches.

## Sprites

- 256-entry OAM, preloaded over a write port.
- A per-line scan collects up to 64 sprites on the line.
- Square sizes from 8 to 64, 1D tile mapping, horizontal and vertical flip.
- X wraps in a 1024-wide space, so sprites clip cleanly off either edge.
- First writer wins per pixel, in OAM order, and a sprite beats a background at
  equal priority.
- Affine sprites use a 32-entry matrix table and GBA-style inverse mapping, with an
  optional double-size window.

## Compositor

- Per-pixel priority resolve across the four backgrounds, the sprite layer, and the
  3D layer.
- Alpha blending with a global eva and evb pair (in sixteenths) and a per-source
  enable.
- Brightness fade.
- The 3D color buffer is treated as a priority-assignable layer, so the compositor
  does not care about the ratio of 2D to 3D content.

## Formats

- Tilemap entry (16 bits): bits 9:0 tile index, bit 10 hflip, bit 11 vflip, bits
  15:12 palette.
- Tile: 8 rows of 32 bits, one 4bpp pixel per nibble, left pixel in the low nibble
  before flipping.
- Color 0 of each palette is transparent.
- Line-buffer color is RGB565.

## Files

| File | Role |
|------|------|
| ppu_top.v | Line sequencer and top level. |
| ppu_bg_line.v | Text background scanline renderer. |
| ppu_bg_affine_line.v | Affine background scanline renderer. |
| ppu_spr_line.v | Sprite scanline renderer: OAM scan, plotting, affine sprites. |
| ppu_arbiter.v | Fixed-priority memory arbiter. |
| ppu_cache.v | Shared direct-mapped read cache, flushed at frame start. |
| ppu_t3d_fetch.v | 3D color-buffer line fetch (bypasses the cache). |
| ppu_sdram_top.v | PPU wired to the SDRAM controller, for integration and sim. |

## Style

The RTL is Verilog-2005 and synthesizes cleanly with Yosys: memories are plain
arrays, there are no empty for-loop increments, and simulation asserts are guarded
by `ifdef SIMULATION`.