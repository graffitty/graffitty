# UI demos

Four silent 1× recordings for presentations. The two tab demos and the landscape rubber-band demo are 1920 × 1080. Rubber band and adaptive zoom use the Android touch layout running on macOS at 60 fps. Adaptive zoom is 1200 × 1200.

| Film | Interaction |
| --- | --- |
| Tab transfer | Pull Preview out of Notes and drop it back on the original tab strip. Both native Godot viewports and the pointer share a frame clock. The outgoing drag shows the native preview until release. After release both windows list sessions 1 and 2, with Notes selected in the original window and Preview in the detached window. On return the destination rises above the detached window. Its tab strip shows the insertion preview while the exposed part of the detached window follows the pointer until release. HyperFrames positions the windows from the recorded drag coordinates and adds macOS traffic lights. |
| Tab → pane → tab | Drag Preview onto Notes, drop to split the workspace, then drag the Preview pane title back to the tab strip. |
| Rubber band | The Android tab strip starts at the upper left. A short flick sends real eza, ripgrep and Git output coasting after the fingertip lifts. The terminal rebounds at the bottom, then a reverse flick rebounds at the top. |
| Adaptive zoom demo | Two fingers pinch out to an overview of four mock agents. The test runner sits left of Claude, with the layout and Android reviewers above. Typing “Review the layout” on the simulated Gboard-style keyboard brings Claude into a close-up. Each key flashes under the touch marker as its input reaches Claude. Graffitty follows the input and restores the previous view after the idle timeout. |

The desktop projects reuse the [main film’s Retina window controls](../main-demo/composition/design.md). Position, diameter and spacing scale with the captured window, including the detached tab.

## Render

From the repository root, with the matching assets available in the local DVC cache or remote:

```sh
name=tab-transfer  # or tab-pane-tab, rubber-band, adaptive-zoom-demo
dvc pull "videos/ui-demos/$name/assets.dvc"
hyperframes preview "videos/ui-demos/$name"
hyperframes check "videos/ui-demos/$name"
hyperframes render "videos/ui-demos/$name" --strict --format webm --video-frame-format png -o "$PWD/videos/artifacts/ui-demos/$name.webm"
```

## Record new takes

The desktop runner uses a private session server, a GPU window guard and the debug gft binary. For the tab-to-pane capture it disables AeroSpace and restores its previous state on exit. Use fresh take directories.

```sh
python3 videos/ui-demos/recording/desktop.py Tabs /tmp/gft-tabs-take
python3 videos/ui-demos/prepare.py tab-transfer /tmp/gft-tabs-take
python3 videos/ui-demos/recording/desktop.py PaneTabs /tmp/gft-pane-take
python3 videos/ui-demos/prepare.py tab-pane-tab /tmp/gft-pane-take
python3 videos/ui-demos/recording/desktop.py RubberBand /tmp/gft-rubber-take
python3 videos/ui-demos/prepare.py rubber-band /tmp/gft-rubber-take
```

The adaptive zoom recorder uses the main demo’s mobile interaction profile and fingertip overlay, four offline Claude mock sessions and a 60 fps Godot viewport capture on macOS. Both touch points advance once per rendered frame.

```sh
python3 videos/ui-demos/recording/mobile.py /tmp/gft-adaptive-take
python3 videos/ui-demos/prepare.py adaptive-zoom-demo /tmp/gft-adaptive-take
```
