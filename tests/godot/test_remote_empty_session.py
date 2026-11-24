"""Automatic first shells, concurrent clients, and retry races use an isolated Owner."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / "tests/server")]
from test_terminal_scene import Owner


@unittest.skipUnless(shutil.which("godot"), "Godot is required")
class RemoteEmptySessionTests(unittest.TestCase):
    def test_empty_server_automatically_opens_one_real_terminal(self):
        with (
            tempfile.TemporaryDirectory(
                prefix="gft-empty-", dir="/tmp" if os.name == "posix" else None
            ) as evidence,
            patch.dict(os.environ, {"GRAFFITTY_SCENE_EVIDENCE": os.environ.get("GRAFFITTY_SCENE_EVIDENCE", evidence)}),
            Owner(network=True, empty=True) as owner,
        ):
            env = {
                k: v for k, v in os.environ.items() if not k.startswith("GRAFFITTY_")
            }
            for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
                env[f"XDG_{kind}_HOME"] = str(owner.path / "frontend" / kind.lower())
            env["GRAFFITTY_TEST_REMOTE_DESCRIPTOR"] = str(owner.descriptor)
            env["GRAFFITTY_TEST_SHELL_PATH"] = str(owner.path / "writer.py")
            result = subprocess.run(
                [
                    "godot",
                    "--headless",
                    "--path",
                    str(ROOT / "frontends/godot/project"),
                    "--script",
                    "res://tests/remote_empty_session_smoke.gd",
                ],
                env=env,
                capture_output=True,
                text=True,
                timeout=90,
            )
            output = result.stdout + result.stderr
            (owner.path / "frontend.log").write_text(output)
            self.assertEqual(result.returncode, 0, output)
            self.assertNotIn("SCRIPT ERROR:", output)
            self.assertNotRegex(output, r"(?m)^\s*ERROR:")
            self.assertNotIn("FAIL ", output)
            self.assertIn("REMOTE_EMPTY_SESSION_PASS", output)
            for regression in (
                "Connecting to an empty server opens a real shell without confirmation",
                "Concurrent empty-server connections share one session",
                "Closing the last session does not respawn a shell",
                "Reconnect to an emptied server automatically opens a shell",
            ):
                self.assertIn("PASS " + regression, output)
            if os.name != "nt":
                for regression in (
                    "Failed automatic creation does not retry on every inventory",
                    "Late failure cannot reopen a canceled error dialog",
                    "Old transport failure cannot alter the new request",
                    "Current transport failure remains retryable",
                ):
                    self.assertIn("PASS " + regression, output)


if __name__ == "__main__":
    unittest.main()
