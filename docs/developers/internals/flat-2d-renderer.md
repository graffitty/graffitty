# Flat 2D renderer and evidence

Implementation details and recorded comparisons for the bundled Flat 2D world. These results apply to the hardware and cases listed below.

## Built-in Flat 2D world

Launch with `--plugin=flat-2d`, set `[world] path = "flat-2d"` in the application
config, or add a **View (<img class="menu-icon" src="../../images/menu/eye.svg" alt=""
width="18" height="18">) → World → Flat 2D** `SwitchWorld` menu entry with `path =
"flat-2d"` in `client.toml`. World menu entries are explicitly configured; the built-in
world is not automatically added to an existing menu.

Flat remains available. This built-in world requires no additional DVC assets. Switching
preserves live terminals, panes, tabs, graph wires, and chromium sessions.

The renderer uses Camera2D, one workspace Sprite2D, a flat background, batched
MultiMeshInstance2D typing effects, and a Polygon2D cursor trail. Sparks share the 3D
renderer’s tapered streak, fork, glow and color shader. Tab transitions capture native
glyph layers separately from whole pane frames; they do not tile a screenshot.

The common TerminalSpace canvas supplies exactly the same pane chrome, terminal text,
images, graph links, and input controls. It retains the shared host/session helpers;
their inherited Node3D root is only an API container, with no 3D render camera,
surfaces, lights, or scenery passes. The world viewport disables 3D.

### 3D flight overlay

Flying letters and dust render in real 3D, the same pieces Flat 3D flies; everything
else stays 2D. `FlightOverlay3D.gd` owns a transparent window-sized 3D viewport that
exists only while a transition holds it, composited over the workspace canvas inside
its clip. Pane backings, chrome and graph wires remain 2D panels.

- Resting letters (first and last frames) draw as a 2D panel in their own pane, so
  later panes still cover them. Once they move they draw in the overlay, over every
  pane, as in Flat 3D.
- Each frame, a piece's plane follows its pane's 2D transform; the overlay camera
  never moves.
- The world warms each piece mesh variant once when it opens, so the first switch
  compiles nothing.

Camera2D's inverse transform maps pointer input and IME placement.

### Supported effects

Compatible effects remain: typing zoom, cursor following, pan, drift, shake,
ripple/splash, cursor trails and particle presets. Tab and session switches fly
their letters and dust in the 3D overlay, with eased camera movement. Typing
particles stay planar; camera tilt, saddle curvature, lens depth of field, depth
tint, and lifted image planes are omitted. Zoom and workspace navigation retain
their existing configuration and gestures.

## Recorded flight comparison — 2026-11-26

**Result:** the 3D overlay costs the same frame time as the earlier 2D scatter and
adds 60–95 MiB of video memory while a flight runs (freed afterwards). No shader
compilation stall appears in the first frames.

Godot 4.7.2, Metal Forward+, Apple M1 Max, 1240×2038 window, VSync off. The same
benchmark ran on the 2D-only commit and on the overlay; 180 fixed poses per flight,
two rounds each. Medians of per-frame time:

| Panes / flight | 2D scatter | 3D overlay | Extra video memory |
| --- | ---: | ---: | ---: |
| 1 / fly away | 3.11–3.14 ms | 3.11–3.27 ms | +90–95 MiB |
| 1 / fly away and in | 3.50 ms | 3.36–3.45 ms | +75 MiB |
| 4 / fly away | 3.06–3.09 ms | 2.99–3.07 ms | +90 MiB |
| 4 / fly away and in | 3.22–3.34 ms | 3.08–3.13 ms | +60 MiB |

<details><summary>Method and limits</summary>

Idle frames measured 2.1–2.4 ms median with an 11–12 ms p95 from other desktop load,
so differences under about 0.5 ms are noise. Metal returned no GPU timestamps; these
are CPU frame intervals. Build time stayed within the same 16–62 ms range.

Memory is almost all the overlay's own Forward+ render targets at the window's
native pixels (2.5 MP here): 70 MiB empty with its 8-bit sRGB output, 80 MiB with a
16-bit output, 132 MiB with 2× MSAA. Terminal captures are not duplicated. The
memory column comes from the 8-bit build, measured during a parallel native build,
so its frame times are not used; the frame times above come from the 16-bit build
on a quiet desktop. The output format does not change the 3D work per frame.

```sh
godot --path frontends/godot/project --script tools/benchmark_flat_2d_flight.gd -- --no-focus-skip --shell=/bin/sh [--side=-1]
```

Raw samples: [flat-2d-flight-macos.json](../../benchmarks/flat-2d-flight-macos.json).

</details>

### Visual boundary

The resting view matches Flat's framing, including its small decal magnification,
and uses the same sheet shader calculations. On the Windows comparison below,
all pixels matched within 2/255 per color channel (mean absolute difference
0.302/255). The remaining difference is render-pipeline rounding, so this is
visually matching rather than byte-identical output.

## Recorded comparison — 2026-10-02

Godot 4.7.2, Direct3D 12 Forward+, GTX 1660 SUPER, i9-12900KS, 1600×1000 window. Same
process, live PowerShell sessions, pane layout and source texture resolution; uncapped,
VSync disabled. Each case runs in A/B/B/A order, with one second warmup and three
seconds sampling per run. Values average the two runs per renderer.

Extra effects are disabled in both; zoom/pan uses the same scripted camera path. These
measurements compare the renderer, not LLM throughput or all-effects cost.

| Panes / scenario | Flat FPS | Flat 2D FPS | Flat mean frame | Flat 2D mean frame | FPS gain |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 / resting | 589 | 836 | 1.699 ms | 1.197 ms | 42% |
| 1 / zoom + pan | 556 | 772 | 1.798 ms | 1.296 ms | 39% |
| 8 / resting | 275 | 320 | 3.634 ms | 3.125 ms | 16% |
| 8 / zoom + pan | 264 | 305 | 3.786 ms | 3.277 ms | 16% |

Reproduce in native PowerShell (set `$godot` to the engine executable):

```powershell
$env:GRAFFITTY_2D_ARTIFACTS = "$PWD/shots/flat-2d"
& $godot --path frontends/godot/project --script tests/flat_2d_smoke.gd -- --no-fx --no-focus-skip --shell=pwsh.exe
& $godot --path frontends/godot/project --script tools/benchmark_flat_2d.gd -- --no-fx --no-focus-skip --no-tabfx --shell=pwsh.exe
```

The smoke test checks screenshot parity, persistent sessions, 2D input projection,
real typing events, zoom/pan, multiple panes, tab switching, particles and restoration
to Flat, and fails on engine/script/shader errors. It writes screenshots and
`parity.json`. The benchmark writes individual samples and hardware metadata to
`benchmark.json`; frame p95, draw calls and reported video memory are included.
Raw measurements are also saved in [flat-2d-windows.json](../../benchmarks/flat-2d-windows.json).
