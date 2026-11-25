"""Exercise the host settings dialog against a private owner and encrypted clients."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import tomllib
import unittest

from test_session_transfer import Peer, PrivateServer, ROOT


class HostRemoteSettingsTests(unittest.TestCase):
    def test_live_listener_and_manual_password(self):
        with tempfile.TemporaryDirectory(prefix="gft-host-", dir=None if os.name == "nt" else "/tmp") as folder:
            root = Path(folder)
            env = {k: v for k, v in os.environ.items() if not k.startswith("GRAFFITTY_")}
            for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
                env[f"XDG_{kind}_HOME"] = str(root / kind.lower())
            config = root / "config/graffitty/server.toml"
            config.parent.mkdir(parents=True)
            config.write_text("# Keep this comment\n[terminal]\nlogin_shell = false\n")
            config.chmod(0o640)
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", 0))
                port = probe.getsockname()[1]
            with socket.socket() as occupied, PrivateServer(env, root, None if os.name == "nt" else "/bin/sh") as server:
                occupied.bind(("127.0.0.1", 0))
                occupied.listen()
                env["GRAFFITTY_TEST_TAKEN_PORT"] = str(occupied.getsockname()[1])
                local = Peer(json.loads(server.descriptor.read_text())["local"], new=True)
                try:
                    pane = local.topology["panes"][0]["id"]
                    env.update(GRAFFITTY_TEST_LISTEN_PORT=str(port), GRAFFITTY_TEST_AUTH_PATH=str(server.directory / "auth.json"))
                    run = subprocess.run(["godot", "--headless", "--path", str(ROOT / "frontends/godot/project"),
                                          "--script", "tests/remote_listener_settings_smoke.gd"],
                                         env=env, capture_output=True, text=True, timeout=120)
                    self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
                    self.assertNotIn("SCRIPT ERROR:", run.stderr)
                    self.assertIn("New password authenticates", run.stdout)
                    self.assertEqual(local.sync()["panes"][0]["id"], pane)
                    self.assertEqual(json.loads(server.descriptor.read_text())["pid"], server.process.pid)
                    source = config.read_text()
                    self.assertIn("# Keep this comment", source)
                    self.assertEqual(tomllib.loads(source)["remote"], {"enabled": False, "bind_address": "0.0.0.0", "port": port})
                    if os.name != "nt":
                        self.assertEqual(config.stat().st_mode & 0o777, 0o640)
                finally:
                    local.socket.close()
