"""The Linux build cache keeps one pinned checkout per source, with its build
objects, and replaces a cached checkout that is not clean at its tag."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("build_native", Path(__file__).with_name("build_native.py"))
build_native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build_native)


def git(*args, cwd):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)


class BuildCacheTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.upstream = self.root / "upstream"
        self.upstream.mkdir()
        git("init", "-q", cwd=self.upstream)
        (self.upstream / ".gitignore").write_text("*.o\n")
        (self.upstream / "main.c").write_text("int main(void) { return 0; }\n")
        git("add", ".", cwd=self.upstream)
        git("-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "-m", "one", cwd=self.upstream)
        git("tag", "v1", cwd=self.upstream)
        self.cache = self.root / "cache"
        self.cache.mkdir()

    def tearDown(self):
        self.temporary.cleanup()

    def test_without_a_cache_sources_go_in_the_build_folder(self):
        build = self.root / "build"
        self.assertEqual(build_native.sources_for(None, build, "godot", "4.7.2-stable"), build / "godot")

    def test_the_cache_keeps_only_the_pinned_version(self):
        (self.cache / "godot-4.7.1-stable").mkdir()
        (self.cache / "neovim-v0.11.0").mkdir()
        path = build_native.sources_for(self.cache, self.root / "build", "godot", "4.7.2-stable")
        self.assertEqual(path, self.cache / "godot-4.7.2-stable")
        self.assertFalse((self.cache / "godot-4.7.1-stable").exists())
        self.assertTrue((self.cache / "neovim-v0.11.0").exists(), "other sources are left alone")

    def test_a_clean_cached_checkout_keeps_its_build_objects(self):
        destination = self.cache / "demo-v1"
        build_native.checkout(str(self.upstream), "v1", destination)
        (destination / "main.o").write_text("compiled")
        build_native.checkout(str(self.upstream), "v1", destination)
        self.assertEqual((destination / "main.o").read_text(), "compiled")

    def test_a_dirty_cached_checkout_is_cloned_again(self):
        destination = self.cache / "demo-v1"
        build_native.checkout(str(self.upstream), "v1", destination)
        (destination / "main.c").write_text("edited\n")
        (destination / "main.o").write_text("compiled")
        build_native.checkout(str(self.upstream), "v1", destination)
        self.assertEqual((destination / "main.c").read_text(), "int main(void) { return 0; }\n")
        self.assertFalse((destination / "main.o").exists())

    def test_an_untagged_release_is_checked_out_by_commit(self):
        commit = subprocess.run(["git", "rev-parse", "HEAD"], cwd=self.upstream, check=True,
                                capture_output=True, text=True).stdout.strip()
        destination = self.cache / "demo-snapshot"
        build_native.checkout(str(self.upstream), "snapshot", destination, commit)
        (destination / "main.o").write_text("compiled")
        build_native.checkout(str(self.upstream), "snapshot", destination, commit)
        self.assertEqual((destination / "main.o").read_text(), "compiled")
        self.assertTrue(build_native.clean_at("snapshot", destination, commit))
        self.assertFalse(build_native.clean_at("snapshot", destination, "0" * 40))

    def test_linux_and_windows_engines_are_pinned(self):
        for name in ("linux", "windows"):
            self.assertRegex(build_native.godot_engine(name)["version"], r"^\d+\.\d+(\.\d+)?-\w+$")
        self.assertRegex(build_native.godot_engine("linux")["commit"], r"^[0-9a-f]{40}$")


if __name__ == "__main__":
    unittest.main()
