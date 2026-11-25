"""Render the mobile touch profile on macOS with a private Claude mock."""

import json
import os
import runpy
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path

here = Path(__file__).resolve().parent
root = here.parents[2]
take = Path(sys.argv[1]).resolve()
take.mkdir(parents=True, exist_ok=False)
helpers = runpy.run_path(str(root / "videos/effects/recording/record.py"))
project = helpers["stage_project"](take, "1200x1200")
cfg = project / "project.godot"
cfg.write_text(
    cfg.read_text().replace(
        "window/per_pixel_transparency/allowed=true",
        "window/per_pixel_transparency/allowed=false",
    )
)
(project / "llm-e2e").symlink_to(root / "tests/llm-e2e")
(project / "tests").unlink()
shutil.copytree(root / "frontends/godot/project/tests", project / "tests")
for name in ["scenario.gd", "android_ui.gd"]:
    p = project / "tests/client_scenarios" / name
    p.write_text(
        p.read_text().replace(
            "../../../../../tests/llm-e2e/replay/background.gd",
            "res://llm-e2e/replay/background.gd",
        )
    )
env = {
    k: v
    for k, v in os.environ.items()
    if not k.startswith(("GRAFFITTY_", "CODEX_", "CLAUDE_"))
}
cli = root / "target/debug/gft"
env.update(
    TAKE=str(take),
    GRAFFITTY_MOVIE_PAUSED="1",
    GRAFFITTY_FFMPEG=helpers["check_encoder"](),
    GRAFFITTY_AV1_CRF="15",
    GRAFFITTY_BIN=str(cli),
    XDG_CONFIG_HOME=str(take / "config"),
    XDG_STATE_HOME=str(take / "state"),
    XDG_DATA_HOME=str(take / "data"),
)
config = take / "config/graffitty/client.toml"
config.parent.mkdir(parents=True)
shutil.copyfile(root / "videos/main-demo/recording/android/client.toml", config)
agents = [
    ("workspace", "Review the layout and check the keyboard insets", "Ready."),
    (
        "tests",
        "Check the touch tests",
        "Gesture tests passed. Scroll and pinch are covered.",
    ),
    ("layout", "Inspect the pane layout", "The four panes have consistent spacing."),
    (
        "android",
        "Review keyboard insets",
        "The prompt stays visible above the keyboard.",
    ),
]
for index, (directory, prompt, response) in enumerate(agents, 1):
    (take / f"agent-t{index}.json").write_text(
        json.dumps(
            {
                "directory": "/" + directory,
                "tip": "",
                "turns": [{"prompt": prompt, "response": response}],
            }
        )
    )
shell = take / "claude"
shell.write_text(
    "#!/bin/sh\nexec "
    + shlex.join([str(cli), "dev", "claude-mock", "--config"])
    + ' "$TAKE/agent-$GRAFFITTY_PANE.json"\n'
)
shell.chmod(0o700)
descriptor = take / "server.json"
env["GRAFFITTY_SERVER_DESCRIPTOR"] = str(descriptor)
server_log = (take / "server.log").open("w")
server = subprocess.Popen(
    [
        cli,
        "server",
        "--listen",
        "127.0.0.1:0",
        "--connection",
        descriptor,
        "--auth-file",
        take / "auth.json",
        "--shell",
        shell,
    ],
    env=env,
    stdout=server_log,
    stderr=subprocess.STDOUT,
)
try:
    deadline = time.monotonic() + 60
    while not descriptor.exists():
        if server.poll() is not None or time.monotonic() > deadline:
            raise RuntimeError("Private mobile server did not start")
        time.sleep(0.05)
    subprocess.run([cli, "session", "new", "-d", "-c", take], check=True, env=env)
    args = helpers["prepare_background"](env, take / "guard")
    subprocess.run(
        [
            "godot",
            *args,
            "--path",
            project,
            "--language",
            "en",
            "--write-movie",
            str(take / "mobile.mp4"),
            "--fixed-fps",
            "60",
            "--quit-after",
            "9000",
            "--script",
            "res://videos/ui-demos/recording/MobileCapture.gd",
            "--",
            "--touch-controls",
        ],
        check=True,
        env=env,
        timeout=300,
    )
    result = json.loads((take / "camera.json").read_text())
    assert not result["failures"], result
finally:
    server.terminate()
    server.wait(timeout=10)
    server_log.close()
