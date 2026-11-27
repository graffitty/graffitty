"""A second launch opens its window, or its restore, in the app already running.

One app per session server: later launches hand their request to it and exit,
and a checkpoint restore adds exactly one window however many sessions it holds.
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import ExitStack
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / "tests/support")]
from e2e_server import PrivateServer

GODOT = os.environ.get("GRAFFITTY_TEST_GODOT") or shutil.which("godot") or "/Applications/Godot.app/Contents/MacOS/Godot"
CLI = Path(os.environ.get("GRAFFITTY_TEST_CLI", ROOT / "target/release/gft"))


@unittest.skipUnless(sys.platform != "win32" and Path(GODOT).is_file() and CLI.is_file(), "Unix, Godot and gft required")
class SingleAppTests(unittest.TestCase):
    def test_later_launches_and_restores_reuse_the_running_app(self):
        with tempfile.TemporaryDirectory(prefix="gft-single-", dir="/tmp") as temporary, ExitStack() as stack:
            root = Path(temporary)
            env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_", "GFT_", "CODEX_"))}
            for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
                env[f"XDG_{kind}_HOME"] = str(root / kind.lower())
            env["GRAFFITTY_CHECKPOINT_DIR"] = str(root / "checkpoints")
            config = root / "config/graffitty/client.toml"
            config.parent.mkdir(parents=True)
            config.write_text('[world]\npath="flat-2d"\n[power]\nenabled=false\n[effects]\nprofile="off"\n')
            server = stack.enter_context(PrivateServer(env, root, "/bin/sh"))
            app = server.descriptor.parent / "dev-app.json"
            log = stack.enter_context((root / "app.log").open("w"))
            command = [GODOT, "--headless", "--path", str(ROOT / "frontends/godot/project"), "res://scenes/terminal.tscn", "--"]
            first = subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            stack.callback(lambda: first.poll() is None and (first.kill(), first.wait(10)))

            def until(condition, message, timeout=30):
                deadline = time.monotonic() + timeout
                while not condition():
                    self.assertIsNone(first.poll(), (root / "app.log").read_text())
                    self.assertLess(time.monotonic(), deadline, message + "\n" + (root / "app.log").read_text())
                    time.sleep(0.1)

            def windows():
                data = json.loads(app.read_text())
                with socket.socket(socket.AF_UNIX) as connection:
                    connection.settimeout(10)
                    connection.connect(data["socket"])
                    connection.sendall(json.dumps({"version": 1, "id": 1, "token": data["token"],
                                                   "method": "session.capture", "params": {"layout": True}}).encode() + b"\n")
                    reply = json.loads(connection.makefile("rb").readline())
                return len(reply.get("result", {}).get("windows", [])) if "result" in reply else -1

            def sessions():
                listed = subprocess.run([str(CLI), "session", "list", "--json"], env=env, capture_output=True, text=True, timeout=10)
                self.assertEqual(listed.returncode, 0, listed.stderr)
                return json.loads(listed.stdout)

            until(lambda: app.exists(), "The first launch publishes its socket")
            data = json.loads(app.read_text())
            self.assertEqual(data["pid"], first.pid)
            self.assertEqual(app.stat().st_mode & 0o777, 0o600)
            until(lambda: windows() == 1, "The first window opens")

            # A plain second launch opens a new window in the first app and exits.
            second = subprocess.run(command + [f"--cwd={root}"], env=env, capture_output=True, text=True, timeout=60)
            self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
            self.assertIn("already running", second.stdout)
            until(lambda: windows() == 2 and len(sessions()) == 2, "The forwarded launch opens one window")

            # Restoring three saved sessions from the CLI adds one window in the same app.
            fixture = json.loads((ROOT / "tests/fixtures/checkpoint-layout.json").read_text())
            third = json.loads(json.dumps(fixture["windows"][1]))
            for pane in third["panes"]: pane["id"] += 20
            for tab in third["tabs"]:
                tab["id"] += 20
                tab["focused"] = f"t{int(tab['focused'][1:]) + 20}"
                tree = tab["tree"]
                for leaf in tree.get("windows", [tree]):
                    leaf["pane"] = f"t{int(leaf['pane'][1:]) + 20}"
            third["active"] += 20
            fixture["windows"].append(third)
            checkpoint = root / "checkpoint.json"
            checkpoint.write_text(json.dumps(fixture))
            restored = subprocess.run([str(CLI), "checkpoint", "restore", "--checkpoint", str(checkpoint)],
                                      env=env, capture_output=True, text=True, timeout=90)
            self.assertEqual(restored.returncode, 0, restored.stderr + (root / "app.log").read_text())
            self.assertEqual(json.loads(restored.stdout)["pid"], first.pid, "The running app restored it")
            until(lambda: windows() == 3 and len(sessions()) == 5, "One window, every saved session")
            panes = sorted(len(session.get("panes", [])) if isinstance(session.get("panes"), list) else session.get("panes") for session in sessions())
            self.assertEqual(panes.count(3), 3, sessions())

            # A second app launched to restore hands the restore over as well.
            prepared = subprocess.run([str(CLI), "checkpoint", "restore", "--checkpoint", str(checkpoint), "--prepare-only"],
                                      env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(prepared.returncode, 0, prepared.stderr)
            layout = Path(json.loads(prepared.stdout)["prepared"])
            launch = subprocess.run(command + [f"--restore-checkpoint={layout}"], env=env, capture_output=True, text=True, timeout=60)
            self.assertEqual(launch.returncode, 0, launch.stdout + launch.stderr)
            receipt = layout.parent / "ready.json"
            until(lambda: receipt.exists(), "The running app writes the receipt", 60)
            self.assertTrue(json.loads(receipt.read_text())["ok"], receipt.read_text())
            self.assertEqual(len(json.loads(receipt.read_text())["sessions"]), 3)
            until(lambda: windows() == 4 and len(sessions()) == 8, "One more window, three more sessions")
            self.assertIsNone(first.poll())
            self.assertNotIn("SCRIPT ERROR", (root / "app.log").read_text())

    def test_simultaneous_launches_elect_one_app(self):
        with tempfile.TemporaryDirectory(prefix="gft-race-", dir="/tmp") as temporary, ExitStack() as stack:
            root = Path(temporary)
            env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_", "GFT_", "CODEX_"))}
            for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
                env[f"XDG_{kind}_HOME"] = str(root / kind.lower())
            server = stack.enter_context(PrivateServer(env, root, "/bin/sh"))
            command = [GODOT, "--headless", "--path", str(ROOT / "frontends/godot/project"), "res://scenes/terminal.tscn", "--"]
            logs = [stack.enter_context((root / f"app-{n}.log").open("w")) for n in range(2)]
            apps = [subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True) for log in logs]
            for app in apps:
                stack.callback(lambda app=app: app.poll() is None and (app.kill(), app.wait(10)))
            deadline = time.monotonic() + 60
            while all(app.poll() is None for app in apps):
                self.assertLess(time.monotonic(), deadline, "One launch hands over and exits")
                time.sleep(0.1)
            time.sleep(1)
            exited = [app for app in apps if app.poll() is not None]
            self.assertEqual(len(exited), 1, "Exactly one app keeps running")
            self.assertEqual(exited[0].returncode, 0)
            descriptor = json.loads((server.descriptor.parent / "dev-app.json").read_text())
            self.assertEqual(descriptor["pid"], next(app.pid for app in apps if app.poll() is None))

    def test_menu_restore_runs_in_this_app_without_a_success_dialog(self):
        with tempfile.TemporaryDirectory(prefix="gft-menu-", dir="/tmp") as temporary, ExitStack() as stack:
            root = Path(temporary)
            env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_", "GFT_", "CODEX_"))}
            for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
                env[f"XDG_{kind}_HOME"] = str(root / kind.lower())
            env["GRAFFITTY_CHECKPOINT_DIR"] = str(root / "checkpoints")
            env["GRAFFITTY_BIN"] = str(CLI)
            config = root / "config/graffitty/client.toml"
            config.parent.mkdir(parents=True)
            config.write_text('[world]\npath="flat-2d"\n[power]\nenabled=false\n[effects]\nprofile="off"\n')
            stack.enter_context(PrivateServer(env, root, "/bin/sh"))
            fixture = json.loads((ROOT / "tests/fixtures/checkpoint-layout.json").read_text())
            third = json.loads(json.dumps(fixture["windows"][1]))
            third["panes"] = third["panes"][:1]
            third["tabs"] = [{"id": 40, "focused": "t10", "tree": {"windows": [{"pane": "t10", "shown": True, "rect": {"rect2": [20, 80, 400, 300]}}]}}]
            third["panes"][0]["id"] = 40
            third["tabs"][0]["focused"] = third["tabs"][0]["tree"]["windows"][0]["pane"] = "t40"
            third["active"] = 40
            fixture["windows"].append(third)
            checkpoint = root / "checkpoint.json"
            checkpoint.write_text(json.dumps(fixture))
            result = subprocess.run([GODOT, "--headless", "--path", str(ROOT / "frontends/godot/project"),
                                     "--script", "res://tests/checkpoint_menu_restore_smoke.gd", "--", f"--checkpoint={checkpoint}"],
                                    env=env, capture_output=True, text=True, timeout=90)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertIn("CHECKPOINT_MENU_RESTORE PASS", output)
            self.assertNotIn("SCRIPT ERROR", output)


if __name__ == "__main__":
    unittest.main()
