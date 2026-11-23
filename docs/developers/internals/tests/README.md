# Test dashboard

Open [the video wall](index.html) to watch recorded replays.

**90 passed · 1 needs attention · 128 not recorded (of 219 cases).** Unrecorded cases are not passes.

## Suites

| Suite | Passed | Needs attention | Not recorded |
| --- | ---: | ---: | ---: |
| [agent-graph](index.html#agent-graph) | 0 | 0 | 9 |
| [android-runtime](index.html#android-runtime) | 32 | 1 | 34 |
| [android-simulated](index.html#android-simulated) | 23 | 0 | 10 |
| [bistro-world](index.html#bistro-world) | 4 | 0 | 3 |
| [chromium](index.html#chromium) | 0 | 0 | 1 |
| [configuration](index.html#configuration) | 0 | 0 | 1 |
| [filetree](index.html#filetree) | 0 | 0 | 1 |
| [flat-world](index.html#flat-world) | 5 | 0 | 8 |
| [integration](index.html#integration) | 0 | 0 | 16 |
| [mac-trackpad](index.html#mac-trackpad) | 0 | 0 | 8 |
| [media-transport](index.html#media-transport) | 0 | 0 | 3 |
| [remote-control](index.html#remote-control) | 0 | 0 | 2 |
| [sessions](index.html#sessions) | 0 | 0 | 4 |
| [tabs-and-panes](index.html#tabs-and-panes) | 25 | 0 | 14 |
| [terminal-appearance](index.html#terminal-appearance) | 0 | 0 | 2 |
| [terminal-effects](index.html#terminal-effects) | 0 | 0 | 1 |
| [terminal-protocol](index.html#terminal-protocol) | 0 | 0 | 2 |
| [terminal-tools](index.html#terminal-tools) | 0 | 0 | 1 |
| [text-quality](index.html#text-quality) | 1 | 0 | 1 |
| [windows](index.html#windows) | 0 | 0 | 7 |

## Update recordings

1. Record Mac replays: `uv run tests/godot/test_dashboard.py record`.
2. Import APK evidence: `uv run tests/godot/test_dashboard.py import-android EVIDENCE_DIRECTORY`.
3. Rebuild this page and the video wall: `uv run tests/godot/test_dashboard.py build`.

## Fast rules (745 passed, 0 failed in 10.3 s)

Run them: `cargo build -p graffitty-workspace-core --example graph_fixture`, then
`godot --headless --path frontends/godot/project --script tests/run.gd`.
No application sessions or model calls are used.

All fast rules pass.
