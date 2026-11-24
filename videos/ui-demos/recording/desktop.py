"""Capture only the isolated Godot windows. Run with NAME and a fresh take directory."""

import os
import sys
import subprocess
import shutil
from contextlib import ExitStack
from pathlib import Path

here = Path(__file__).resolve().parent
root = here.parents[2]
sys.path.insert(0, str(root / "tests/support"))
from e2e_background import prepare_background  # noqa: E402
from e2e_server import PrivateServer  # noqa: E402

name, take = sys.argv[1], Path(sys.argv[2]).resolve()
take.mkdir(parents=True, exist_ok=True)
env = {
    k: v
    for k, v in os.environ.items()
    if not k.startswith(("GRAFFITTY_", "CODEX_", "CLAUDE_"))
}
cli = root / "target/debug/gft"
env.update(
    TAKE=str(take),
    GRAFFITTY_BIN=str(cli),
    XDG_CONFIG_HOME=str(take / "config"),
    XDG_STATE_HOME=str(take / "state"),
    XDG_DATA_HOME=str(take / "data"),
)
config = take / "config/graffitty/client.toml"
config.parent.mkdir(parents=True, exist_ok=True)
config.write_text('[world]\npath = "flat-2d"\n[mods.status-line]\nenabled = false\n')
shell = take / "notes"
shell.write_text("""#!/bin/sh
printf '\\033[2J\\033[H\\033[38;5;114m●  Workspace ready\\033[0m\\n\\n'
printf '  notes.md          saved\\n  preview.html      ready\\n\\n'
exec env PS1='demo  ❯ ' /bin/sh -i
""")
if name == "PaneTabs":
    shell.write_text(r"""#!/bin/sh
printf '\033[2J\033[H'
if [ "$GRAFFITTY_PANE" = t1 ]; then
    printf '\033[38;5;114m● Notes\033[0m\n\nREADME.md\nnotes.md\n'
else
    printf '\033[38;5;117m● Preview\033[0m\n\nGET /   200\nGET /a  200\n'
fi
exec env PS1='demo  ❯ ' /bin/sh -i
""")
if name == "RubberBand":
    env["GRAFFITTY_TOUCH_CONTROLS"] = "1"
    shutil.copyfile(here / "shell-demo.sh", shell)
shell.chmod(0o700)
os.environ["GRAFFITTY_TEST_SERVER"] = str(cli)
with ExitStack() as stack:
    if name == "PaneTabs" and shutil.which("aerospace"):
        disabled = subprocess.run(
            ["aerospace", "enable", "off", "--fail-if-noop"], capture_output=True
        )
        if disabled.returncode == 0:
            stack.callback(subprocess.run, ["aerospace", "enable", "on"], check=True)
    stack.enter_context(PrivateServer(env, take, str(shell), startup_timeout=60))
    args = prepare_background(env, take / "guard")
    subprocess.run(
        [
            "godot",
            *args,
            "--path",
            str(root / "frontends/godot/project"),
            "--fixed-fps",
            "60" if name == "RubberBand" else "30",
            "--script",
            str(here / (name + ".gd")),
        ],
        env=env,
        check=True,
        timeout=180,
    )
