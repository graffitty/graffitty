# Retained graph rendering

Graph routing is independent of the camera. `AgentGraphOverlay` stores routes in sheet
coordinates; `GraphWireLayer` paints them into the same retained canvas as the panes.
Panning moves that canvas without rebuilding its wire commands.

Zooming and perspective also move the canvas; below each wire's minimum screen width,
they refresh its stroke and pattern spacing while retaining its route and unchanged
color texture. Screen projections still update socket hit boxes, reroute handles, hit
testing and message markers.

Sampled paths are projected lazily for picking or active markers, not for every edge on
every camera update.

## Invalidation rules

### Markers

- Queue blinks and delivery pulses have a separate marker layer. Their animation
  must not invalidate static wire paint.

### Pane movement

- Pane movement invalidates incident route-cache entries and return-lane peers
  sharing the affected input. Unrelated routes reuse their sampled geometry.
  Explicit reroute geometry also depends on neighboring shared stems. Each wire
  has a retained canvas item; unchanged wires keep their paint commands too,
  rather than merely caching CPU routing while repainting the entire graph.

### Geometry

- Curve sampling, endpoint deformation, return-lane ordering and dash generation
  are portable Rust in `crates/scene-core/src/graph_geometry.rs`; Godot adapts the
  results. Dashes submit a multiline batch, not a draw call per dash.
  Socket motion deforms a cached route by traveled distance, not sampled-point
  index. Adaptive sampling puts many points in a corner and few on a straight
  run; index-based deformation creates hooks when zoom spreads the ports.
  The distance blend preserves sockets and remains independent of sample density.

### Ownership and transitions

- Ownership links retain sheet geometry too. An explicit graph connection in
  either direction suppresses the redundant ownership wire, not ownership data.
- Transition captures include both retained wires and the current marker frame.

## Verify retained work

`tests/graph_retained_geometry_smoke.gd` uses 14 nodes and 42 edges to check camera
invariance, marker-only repaint and partial route invalidation. Its timing output
is diagnostic; tests assert work counts rather than hardware-dependent FPS.
`tests/ownership_links_smoke.gd` checks suppression and restoration without
mutating ownership. Existing graph editing and message-animation tests cover
interaction and lifecycle behavior.

## Process discovery is separate from graph rendering

The server refreshes foreground apps on a group change and every 400 ms. A background
thread reads the pane processes in the server. The periodic read detects an exec or a
new integration within the same foreground group.

Provider discovery runs in a separate helper every two seconds while there are panes.
A manager thread launches, times out and reaps helpers. The input thread queues requests
and collects completed results.

- macOS reads foreground group members and their parent chains back to the pane shell.
- Linux and Android walk the shell’s descendants using each thread’s `children` file.
  Kernels without this procfs interface use a process table.
- Windows uses a Toolhelp parent snapshot and opens processes in the pane trees for
  executable names and creation times. Job Objects provide terminal resource accounting.

An agent registered in a pane may keep running in the background. Its PID and start
time can be checked directly. Checkpoint capture and hook ancestry still use process
tables. Resource Monitor has its own sampling worker and native backends.

Run `python3 tests/server/private_session_latency.py` for private-server key-to-echo
and provider scan timings. Set `GRAFFITTY_TEST_SERVER` to compare binaries built with
the same profile. The probe measures a complete scene update for each numbered echo.

Test servers must be shut down after replay tests. Abandoned servers duplicate
inventory work even when no frontend is attached. Profiling should isolate these
from the live server, use separate log files, and distinguish sampled stacks from
measured callback timings. A stripped stack sample cannot attribute engine work
to a particular GDScript callback or prove GPU allocation frequency.
