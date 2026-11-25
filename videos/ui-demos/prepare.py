"""Assemble the real-time capture layers and measured window positions in HyperFrames."""

import argparse
import json
import re
import shutil
import subprocess
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument(
    "name",
    choices=["tab-transfer", "tab-pane-tab", "rubber-band", "adaptive-zoom-demo"],
)
p.add_argument("take", type=Path)
args = p.parse_args()
take = args.take.resolve()
project = Path(__file__).parent / args.name
assets = project / "assets"
assets.mkdir(exist_ok=True, parents=True)


def ffmpeg(*options):
    subprocess.run(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *options], check=True
    )


def encode(frames, prefix, first=0, directory=take, fps=30):
    ffmpeg(
        "-framerate",
        str(fps),
        "-start_number",
        str(first),
        "-i",
        str(directory / (frames + "-%04d.jpg")),
        "-an",
        "-c:v",
        "libx264",
        "-preset",
        "fast",
        "-crf",
        "13",
        "-pix_fmt",
        "yuv420p",
        str(assets / (prefix + ".mp4")),
    )


def video(id, src, start, duration, track):
    return f'<video id="{id}" class="clip" src="assets/{src}.mp4" data-start="{start}" data-duration="{duration}" data-track-index="{track}" muted playsinline></video>'


# Keep the same Retina title-bar geometry, colors and outline as the main film.
main_demo = (project.parents[1] / "main-demo/composition/index.html").read_text()
controls_css = "\n".join(
    re.search(re.escape(selector) + r" \{[^}]+\}", main_demo)[0]
    for selector in ("#traffic-lights", ".light", ".close", ".minimize", ".maximize")
).replace("#traffic-lights", ".traffic-lights")
lights = '<div class="traffic-lights" aria-hidden="true"><span class="light close"></span><span class="light minimize"></span><span class="light maximize"></span></div>'
base_css = (
    """
*{box-sizing:border-box}html,body{margin:0}#stage{position:relative;overflow:hidden;width:1920px;height:1080px;background:linear-gradient(140deg,#273044,#475365 55%,#2b3843)}
.window{position:absolute;overflow:hidden;border-radius:16px;box-shadow:0 24px 65px #10152175,0 0 0 1px #ffffff35;background:#1f232b}
video{display:block;width:100%;height:auto}
"""
    + controls_css
)
timeline = ""
if args.name == "tab-transfer":
    samples = json.loads((take / "motion.json").read_text())
    duration = len(samples) / 30
    visible = [i for i, s in enumerate(samples) if "window" in s]
    assert visible == list(range(visible[0], visible[-1] + 1))
    dock = next(i for i, sample in enumerate(samples) if sample.get("docked"))
    hover = next(i for i, sample in enumerate(samples) if sample.get("dock_hover"))
    assert visible[0] < hover < dock == visible[-1] + 1
    assert all(sample.get("dock_hover") for sample in samples[hover:dock])
    # Both viewports are sampled at the same time as the pointer, including
    # the outgoing drag preview and the incoming tab-strip insertion preview.
    encode("main", "workspace")
    encode("tab", "detached", visible[0])
    scale = 1.08
    css = (
        base_css
        + f".window{{left:120px;top:165px;--footage-scale:{scale};width:{900 * scale}px;height:{624 * scale}px}}#cursor{{position:absolute;left:120px;top:165px;width:30px;height:37px;z-index:5}}"
    )
    body = (
        '<div id="destination" class="window">'
        + video("workspace", "workspace", 0, duration, 0)
        + lights
        + "</div>"
    )
    start = visible[0] / 30
    span = len(visible) / 30
    css += "#destination{z-index:1}#floating{visibility:hidden;z-index:2}"
    timeline += f'tl.set("#floating",{{visibility:"visible"}},{start});tl.set("#floating",{{zIndex:0}},{hover}/30);tl.set("#floating",{{visibility:"hidden"}},{dock}/30);\n'
    body += (
        '<div id="floating" class="window">'
        + video("detached", "detached", start, span, 2)
        + lights
        + "</div>"
    )
    body += '<svg id="cursor" viewBox="0 0 26 32"><path d="M2 2L23 19L13 19L18 28L13 30L8 21L2 27Z" fill="#17191d" stroke="white" stroke-width="2" stroke-linejoin="round"/></svg>'
    tracks = {
        "cursor": [(i, s["pointer"]) for i, s in enumerate(samples)],
        "floating": [(i, samples[i]["window"]) for i in visible],
    }
    for id, points in tracks.items():
        last = None
        for i, xy in points:
            if xy != last:
                timeline += f'tl.set("#{id}",{{x:{round(xy[0] * scale, 2)},y:{round(xy[1] * scale, 2)}}},{i}/30);\n'
            last = xy
elif args.name == "tab-pane-tab":
    samples = json.loads((take / "motion.json").read_text())
    duration = len(samples) / 30
    encode("main", "pane-transfer")
    scale = 1.42
    css = (
        base_css
        + ".window{left:321px;top:97px;width:1278px;--footage-scale:1.42}#cursor{position:absolute;left:321px;top:97px;width:33px;height:40px;z-index:3}"
    )
    body = (
        '<div class="window">'
        + video("workspace", "pane-transfer", 0, duration, 0)
        + lights
        + "</div>"
    )
    body += '<svg id="cursor" viewBox="0 0 26 32"><path d="M2 2L23 19L13 19L18 28L13 30L8 21L2 27Z" fill="#17191d" stroke="white" stroke-width="2" stroke-linejoin="round"/></svg>'
    last = None
    for i, sample in enumerate(samples):
        xy = sample["pointer"]
        if xy != last:
            timeline += f'tl.set("#cursor",{{x:{xy[0] * scale:.2f},y:{xy[1] * scale:.2f}}},{i}/30);\n'
        last = xy
elif args.name == "rubber-band":
    duration = len(list(take.glob("main-*.jpg"))) / 60
    encode("main", "shell-gestures", fps=60)
    css = "html,body{margin:0}#stage,#terminal{display:block;width:1920px;height:1080px;background:#15181e}#terminal{object-fit:contain}"
    body = video("terminal", "shell-gestures", 0, duration, 0)
else:
    recording = take / "mobile.mp4"
    duration = float(
        subprocess.check_output(
            [
                "ffprobe",
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=nw=1:nk=1",
                str(recording),
            ]
        )
    )
    ffmpeg(
        "-i",
        str(recording),
        "-an",
        "-c:v",
        "libx264",
        "-crf",
        "13",
        "-pix_fmt",
        "yuv420p",
        str(assets / "touch-keyboard.mp4"),
    )
    css = "*{box-sizing:border-box}html,body{margin:0}#stage,#android{width:1200px;height:1200px;background:#15181e;display:block}"
    body = video("android", "touch-keyboard", 0, duration, 0)
size = (1200, 1200) if args.name == "adaptive-zoom-demo" else (1920, 1080)
title = args.name.replace("-", " ").capitalize()
(project / "index.html").write_text(f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>{title}</title>
<script src="https://cdn.jsdelivr.net/npm/gsap@3.14.2/dist/gsap.min.js"></script><style>{css}</style></head>
<body><main id="stage" data-composition-id="{args.name}" data-width="{size[0]}" data-height="{size[1]}" data-duration="{duration}" data-fps="{30 if args.name in ("tab-transfer", "tab-pane-tab") else 60}">{body}</main>
<script>const tl=gsap.timeline({{paused:true}});{timeline}
window.__timelines=window.__timelines||{{}};window.__timelines["{args.name}"]=tl;</script></body></html>
''')
shutil.copyfile(
    Path(__file__).resolve().parents[1] / "e2e-loop/composition/hyperframes.json",
    project / "hyperframes.json",
)
