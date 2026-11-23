# Render-cost measurements

## Desktop workspace density

The resting workspace requests one texel per backing pixel. It takes the
presenting viewport’s scale (at least 1), applies camera zoom, then rounds
up to the nearest half texel per layout unit. Outside flights and tab effects,
Overview (including implicit overview) uses its navigation camera zoom.
On desktop, a settled non-overview camera refines at **1.10× displayed
magnification**. The view projects a horizontal span of sheet coordinates at
the focused pane’s centre. This captures adaptive containment and excludes the
pane’s own enlargement. A stationary pose applies the new density and crop
together. During camera motion, a change across the mild threshold waits for
the magnification and crop to stay steady for 160 ms. A refined view returns
to native below 1.099×, so projection noise at 1.10× can reuse the allocation.

Large zooms continue to refine during the approach. The gesture hold keeps its
targets until navigation settles. Android and iOS retain the controller cutoff
above 1.15×. Each terminal uses the achieved canvas density times its own scale.

The canvas and terminal keep their linear HDR targets for glyph coverage.
The visible crop, including its padding, is bounded to 8192 pixels per side
and 20 MP per target on desktop, or 4 MP on Android and iOS. Active panes
also share a 32 MP desktop or 8 MP mobile budget. A world without TerminalSpace
starts with the native window’s covering rectangle at the authored aspect.
Its area cap reduces the texture while preserving the layout used for font size
and PTY rows and columns.

### Allocations and text quality

On an M1 Max with 2× backing and a 3382×2212 window, the same resting Flat 3D
scene produced these allocations in separate runs.

| Measurement | Previous fixed 2× multiplier | Native backing density |
| --- | ---: | ---: |
| Canvas, 1824×1248 logical crop | 5406×3699 | 3648×2496 |
| Terminal, 1623×982 logical body | 4869×2946 | 3246×1964 |
| Listed SubViewports | 56.784 MP | 37.924 MP |
| Reported video memory | 1122 MiB | 943 MiB |

Flat 2D saved the same 18.86 MP, going from 41.822 to 22.962 MP. At the
3× typing destination, the native Flat 3D canvas used 4224×3072 pixels
for a 704×512 crop and the terminal used 2712×1824 for a 452×304 crop.
Both reached six texels per layout unit. Matched native-pixel screenshots
showed comparable text at rest and landing in Flat 2D, Flat 3D and Edinburgh
Castle. Native text looked marginally softer mid-flight in the two 3D worlds.

In a 3600×2258 Flat 2D window on the same M1 Max, settled 1.14× fixed zoom
projected at 1.142× with the pane at scale 1. The median 10–90% transition
width across 80 bold H stem edges fell from **2.10 to 1.56 backing pixels**.
The earlier fixed-supersampling reference measured **1.66 px** at the same
pose and crop.

| Fixed zoom | Canvas, native → refined | Terminal, native → refined | Added HDR color storage |
| --- | --- | --- | ---: |
| 1.10× | 3520×2304 → 4400×2880 | 3272×2010 → 4090×2512 | 63.0 MiB |
| 1.14× | 3392×2240 → 4240×2800 | 3208×1952 → 4010×2440 | 59.5 MiB |

Both targets went from 2.0 to 2.5 texels per layout unit. Storage is
calculated at 8 bytes per pixel from the measured allocations. At 1.05× the
native bucket costs no additional storage.

A separate M5 report measured 60.05 MP of SubViewports in a 3600×2258 window.
At 2× backing, reconstructing its resting crop and pane from those dimensions
predicts 41.93 MP at native density. Estimated color storage for the two HDR
targets falls from 272.1 to 133.8 MiB. This is a model for that window.
SubViewport area counts sleeping allocations too and excludes the root viewport.

### Frame intervals

These are wall-clock intervals between Godot post-draw callbacks on the M1 Max,
with VSync off and the frame rate uncapped. Each cell is the median of two
per-run p50 / p95 values from alternating runs, in milliseconds.

| Phase | Flat 3D, previous → native | Flat 2D, previous → native |
| --- | --- | --- |
| Streaming, still camera | 9.5 / 22.5 → 8.9 / 14.7 | 10.7 / 26.8 → 10.6 / 19.1 |
| Full typing replay | 51.7 / 101.2 → 50.2 / 84.9 | 11.8 / 56.9 → 12.8 / 37.9 |
| Approach to 2.98× zoom | 78.0 / 112.7 → 57.3 / 95.3 | — |
| Manual pinch | 12.1 / 20.2 → 11.1 / 17.3 | 10.9 / 24.1 → 9.6 / 17.6 |

The first Flat 3D streaming pair went the other way at p95 (14.0 → 16.6 ms).
The allocation reduction reproduced across renderers. Frame intervals varied,
and the full Flat 3D typing replay still had a roughly 50 ms median.

### Metal diagnostics

Godot 4.7.2 can underflow its texture byte count when freeing shared or
imported Metal textures. Render stats read the signed RenderingServer counter
and print `textures=unavailable` for negative values. Zero, positive counts,
and the separate video and buffer readings are reported normally.

macOS ships the official export template. The Linux engine build patches its
pinned 4.7.2 source for Wayland, but the upstream Metal change does not apply
cleanly there. It expects a texture record with ownership metadata where 4.7.2
stores an `MTL::Texture` pointer. [Godot’s upstream fix](https://github.com/godotengine/godot/pull/124497)

## Scenery and depth of field, 2026-10-08

On M1 Max/Godot 4.7.2, lower DoF quality, unshadowed accents, and motion
scaling reduced the isolated harness from **43.3 to 12.4 ms**.
The real 2560×1440 host improved from **32.4 to 22 ms**.

| | typing frame, harness |
| --- | --- |
| before | 43.3 ms |
| DoF quality 1 (`project.godot`) and unshadowed accents | 26.4 ms |
| plus `motion_render_scale` 0.5 while the camera moves | 12.4 ms |

Motion scale 0.6 measured 16.7 ms; 0.55 measured 14.4 ms. Hiding scenery in the
real host still cost 19.4 ms, so terminal/compositor work remained significant.

## What was measured

The harness mirrored SceneryView: streamed scene, four sun cascades, 28 accents,
SSAO, sky, typing lens, MSAA 4×, 3840×2160 target at scale 0.8.
Metal GPU timestamps returned zero; these are uncapped frame times, not GPU timings.
CPU was about 0.5 ms. Baselines alternated three times and medians were compared.

| change, shipped baseline 37-41 ms | delta |
| --- | --- |
| typing DoF off | -13.6 ms, the same on an empty scene |
| DoF quality High -> Low | -11.3 ms |
| 28 accent lights removed | -14.1 ms |
| 28 accent lights unshadowed | -2.4 ms |
| MSAA off | -2.0 ms |
| SSAO off | about -1 ms |
| scenery hidden | -19.8 ms |

## Interpretation

| Finding | Evidence |
| --- | --- |
| Depth of field dominated | Full-resolution capped 32 px bokeh, quality-3 24-tap passes |
| Accents cost more than shadows | Removing lights saved 14.1 ms; removing shadows 2.4 ms |
| Shadow redraw could persist | Atlas-size mismatch failed to synchronize slot versions after changes |
| Geometry alone was cheap | Unshaded scene matched an empty frame |

The bokeh-shape setting had merged into a comment, leaving hexagonal shape.
Uniform atlas slot sizes avoid the observed perpetual shadow redraw (~2.45M triangles/frame).

## Method, and two ways of getting it wrong

- Use separate processes for pipeline/material changes; runtime specialization
  polluted one `nosky` measurement to 72 ms.
- Pair visibility-only changes inside one process using `--rt=ab_*`: 120 frames
  before/after. Thermal baseline drift was 44–68 ms across longer runs.
- Use `--rendertest --rt=CASE --fullscreen`; the tiling manager ignored resolution.

## Open

The recorded follow-ups were static-light baking, non-scenery profiling,
and per-world render settings.
The screen cap also multiplied already-pixel macOS screen size by scale.
These dated observations need fresh measurements before drawing current performance conclusions.
