"""Exercise the production CUDA gate with missing, stub and usable drivers."""

from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "crates/transport/chromium-video/src"

HARNESS = r"""
#include "cuda_probe.h"
#include <assert.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
static int scenario, loads;
static int init(unsigned int flags) { assert(flags == 0); return scenario == 3 ? 1 : 0; }
static int count_devices(int *count) { *count = scenario == 5 ? 0 : 1; return scenario == 4 ? 1 : 0; }
void *test_dlopen(const char *name, int flags) {
    assert(!strcmp(name, "libcuda.so.1"));
    assert(flags == (RTLD_NOW | RTLD_LOCAL));
    ++loads;
    return scenario == 0 ? NULL : &scenario;
}
void *test_dlsym(void *library, const char *name) {
    assert(library == &scenario);
    if (!strcmp(name, "cuInit")) return scenario == 1 ? NULL : (void *)init;
    assert(!strcmp(name, "cuDeviceGetCount"));
    return scenario == 2 ? NULL : (void *)count_devices;
}
int main(int argc, char **argv) {
    assert(argc == 2);
    scenario = atoi(argv[1]);
    for (int i = 0; i < 10; ++i) assert(gv_cuda_available() == (scenario == 6));
    if (scenario >= 3) {
        scenario = 6;
        assert(gv_cuda_available());
        scenario = 5;
        assert(!gv_cuda_available());
    }
    assert(loads == 1);
}
"""


@unittest.skipUnless(
    os.name == "posix" and shutil.which("cc"), "A Unix C compiler is required"
)
class CudaProbeTests(unittest.TestCase):
    def test_driver_capabilities_and_cached_absence(self):
        with tempfile.TemporaryDirectory(prefix="gft-cuda-probe-") as directory:
            root = Path(directory)
            harness = root / "test.c"
            harness.write_text(HARNESS)
            binary = root / "test"
            subprocess.run(
                [
                    "cc",
                    "-std=c11",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    "-pthread",
                    "-Ddlopen=test_dlopen",
                    "-Ddlsym=test_dlsym",
                    "-I",
                    str(SOURCE),
                    str(SOURCE / "cuda_probe.c"),
                    str(harness),
                    "-o",
                    str(binary),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            for scenario in range(7):
                with self.subTest(scenario=scenario):
                    result = subprocess.run(
                        [binary, str(scenario)], capture_output=True, text=True
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
