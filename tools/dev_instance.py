"""Keep development windows in one application (and one remote listener).

The app itself elects one process per session server: it holds
`dev-app.lock` and publishes `dev-app.json` beside the server's
`server.json` (crates/graph-protocol/src/application.rs). This launcher only
checks startup options and opens the window itself, so a second launch never
starts Godot or rewrites the running app's log.
"""

import fcntl
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path


def open_window(descriptor: Path, args: list[str], timeout: float = 10) -> None:
    deadline = time.monotonic() + timeout
    while True:
        submitted = False
        try:
            data = json.loads(descriptor.read_text())
            with socket.socket(socket.AF_UNIX) as probe:
                probe.settimeout(2)
                probe.connect(data["socket"])
                probe.sendall(json.dumps({"version": 1, "id": "launch-info", "token": data["token"],
                                         "method": "application.launch_info", "params": {}}).encode() + b"\n")
                with probe.makefile("rb") as response:
                    info = json.loads(response.readline(65536))
                if not info.get("result", {}).get("fresh_sessions"):
                    raise RuntimeError("The running GUI uses older startup code. Close its GUI windows and run again; server sessions remain running.")
                if "--reload" in args and not info.get("result", {}).get("script_reload"):
                    raise RuntimeError("The running GUI has no source watcher. Detach its windows, then run mise dev --reload; server sessions remain running.")
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(2)
                connection.connect(data["socket"])
                request = {
                    "version": 1,
                    "id": "launch",
                    "token": data["token"],
                    "method": "application.open_window",
                    "params": {
                        "fresh_session": True,
                        "args": args,
                        "cwd": os.environ.get("GRAFFITTY_INITIAL_PWD") or os.getcwd(),
                    },
                }
                connection.sendall(json.dumps(request).encode() + b"\n")
                submitted = True
                with connection.makefile("rb") as response:
                    result = json.loads(response.readline(65536))
                if "error" in result:
                    if result["error"].get("code") == "busy":
                        submitted = False
                        raise OSError(result["error"]["message"])
                    raise RuntimeError(str(result["error"]))
                return
        except (OSError, ValueError, KeyError) as error:
            if submitted:
                # A lost reply does not mean the window was not created.
                raise RuntimeError(
                    "Graffitty did not acknowledge the new-window request"
                ) from error
            if time.monotonic() >= deadline:
                raise RuntimeError(
                    "Graffitty is running but did not answer the new-window request"
                ) from error
            time.sleep(0.05)


def run(command: list[str], directory: Path, logs: Path) -> int:
    directory.mkdir(parents=True, exist_ok=True)
    descriptor = directory / "dev-app.json"
    with (directory / "dev-app.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            running = False
        except BlockingIOError:
            running = True
        # Never hold the app's lock past this probe: the app takes it itself.
        fcntl.flock(lock, fcntl.LOCK_UN)
    if running:
        args = command[command.index("--") + 1 :] if "--" in command else []
        allowed = ("--workspace=", "--cwd=", "--working-directory=", "--shell=")
        if any(arg not in ("--attach-session", "--reload") and not arg.startswith(allowed) for arg in args):
            raise RuntimeError("Close the running GUI before changing rendering or configuration startup options.")
        open_window(descriptor, args)
        print("[dev] Opened a window in the running Graffitty (shared remote listener).")
        return 0
    log = logs / "graffitty.log"
    if log.is_file():
        shutil.copyfile(log, log.with_suffix(".log.1"))
    child = subprocess.Popen(command)
    handlers = {}

    def forward(signum, _frame):
        if child.poll() is None:
            child.send_signal(signum)

    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        handlers[signum] = signal.signal(signum, forward)
    try:
        result = child.wait()
        return result if result >= 0 else 128 - result
    finally:
        for signum, handler in handlers.items():
            signal.signal(signum, handler)
        # An app stopped by a signal cannot withdraw its own descriptor.
        with (directory / "dev-app.lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                descriptor.unlink(missing_ok=True)
                fcntl.flock(lock, fcntl.LOCK_UN)
            except BlockingIOError:
                pass


def user_state() -> Path:
    base = Path(os.environ.get("XDG_STATE_HOME", ""))
    if not base.is_absolute():
        base = Path.home() / ".local/state"
    return base / "graffitty"


def server_directory() -> Path:
    """Where the session server keeps `server.json`, and the app its lock."""
    if os.environ.get("GRAFFITTY_SERVER_DESCRIPTOR"):
        return Path(os.environ["GRAFFITTY_SERVER_DESCRIPTOR"]).absolute().parent
    return user_state()


def main() -> int:
    try:
        return run(sys.argv[1:], server_directory(), user_state())
    except RuntimeError as error:
        print(f"[dev] {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
