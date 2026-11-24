"""Exercise viewport allocation bounds and display moves without resizing."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
from check_godot import failed


@unittest.skipUnless(shutil.which("godot"), "Godot is required")
class WorldViewportSizeTests(unittest.TestCase):
    def test_resize_bounds_and_output_pixel_budget(self):
        with tempfile.TemporaryDirectory(prefix="gft-viewport-") as scratch:
            env = {k: v for k, v in os.environ.items() if not k.startswith("GRAFFITTY_")}
            for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
                env[f"XDG_{kind}_HOME"] = str(Path(scratch) / kind.lower())
            result = subprocess.run(
                ["godot", "--headless", "--path", str(ROOT / "frontends/godot/project"),
                 "--script", "res://tests/world_viewport_size_smoke.gd"],
                env=env, capture_output=True, text=True, timeout=30,
            )
            output = result.stdout + result.stderr
            self.assertFalse(failed(result.returncode, output), output)
            self.assertIn("WORLD_VIEWPORT_SIZE failures=[]", output)


if __name__ == "__main__":
    unittest.main()
