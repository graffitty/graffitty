"""Only capability opens suppress FFmpeg startup errors; stream opens retain them."""

import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "crates/transport/chromium-video/src"
HARNESS = r"""
#include "codec_probe.h"
#include <assert.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    assert(argc == 5);
    const int probe = atoi(argv[1]), success = atoi(argv[2]);
    const int offset = atoi(argv[3]), level = atoi(argv[4]);
    const AVCodec *codec = avcodec_find_decoder_by_name("h264");
    assert(codec);
    AVCodecContext *context = avcodec_alloc_context3(codec);
    assert(context);
    context->log_level_offset = offset;
    av_log_set_level(level);
    // A real FFmpeg validation error, independent of installed hardware.
    // The successful case opens a bare decoder without submitting any frames.
    if (!success) context->codec_type = AVMEDIA_TYPE_AUDIO;
    assert((gv_open_codec(context, codec, NULL, probe) == 0) == success);
    assert(context->log_level_offset == offset);
    assert(av_log_get_level() == level);
    av_log(context, AV_LOG_ERROR, "after-open-error-visible\n");
    avcodec_free_context(&context);
}
"""

CONSTRUCTOR_HARNESS = r"""
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/log.h>
#ifdef __APPLE__
#include <VideoToolbox/VideoToolbox.h>
Boolean test_decode_supported(CMVideoCodecType type) { (void)type; return 1; }
#define VTIsHardwareDecodeSupported test_decode_supported
// Surface encoding is never submitted by this constructor-only fixture.
void *gv_surface_video_pixel(void *surface) { (void)surface; abort(); }
#endif

static int probe, decoder, opens;
static AVCodecContext *opening;
static AVCodecContext *test_allocate(const AVCodec *codec) {
    AVCodecContext *context = avcodec_alloc_context3(codec);
    assert(context);
    // Let the production constructor reach the real avcodec_open2, then fail
    // FFmpeg validation before any hardware is touched.
    context->codec_type = AVMEDIA_TYPE_AUDIO;
    return context;
}
static int test_open(AVCodecContext *context, const AVCodec *codec, AVDictionary **options) {
    assert(context->log_level_offset == (probe ? AV_LOG_DEBUG - AV_LOG_ERROR : 0));
    assert(av_log_get_level() == AV_LOG_ERROR);
    av_log(NULL, AV_LOG_ERROR, "unrelated-context-error-visible\n");
    opening = context;
    ++opens;
    int result = avcodec_open2(context, codec, options);
    assert(result < 0);
    return result;
}
static void test_free(AVCodecContext **context) {
    if (*context && *context == opening) {
        assert((*context)->log_level_offset == 0);
        av_log(*context, AV_LOG_ERROR, "restored-constructor-error-visible\n");
        opening = NULL;
    }
    avcodec_free_context(context);
}
static int test_device(AVBufferRef **device, enum AVHWDeviceType type,
                       const char *name, AVDictionary *options, int flags) {
    (void)type; (void)name; (void)options; (void)flags;
    if (!decoder) return AVERROR(ENOSYS); // Skip VA/QSV frame-pool allocation.
    // Only ownership is exercised: validation fails before a device is used.
    *device = av_buffer_allocz(sizeof(AVHWDeviceContext));
    assert(*device);
    return 0;
}
int test_cuda_available(void) { return 1; }
#define gv_cuda_available test_cuda_available
#define avcodec_alloc_context3 test_allocate
#define avcodec_open2 test_open
#define avcodec_free_context test_free
#define av_hwdevice_ctx_create test_device
#include "codec.c"

int main(int argc, char **argv) {
    assert(argc == 3);
    probe = atoi(argv[2]);
    decoder = !strcmp(argv[1], "decoder") || !strcmp(argv[1], "named");
    av_log_set_level(AV_LOG_ERROR);
    Video *video;
    if (!strcmp(argv[1], "decoder")) video = gv_decoder(0, probe);
    else if (!strcmp(argv[1], "named")) {
        assert(!probe);
        video = gv_decoder_named(0, "", 256, 256);
    }
#ifdef __APPLE__
    else if (!strcmp(argv[1], "surface")) {
        assert(!probe);
        video = gv_surface_encoder(0, 256, 256, 0, 60);
    }
#endif
    else video = gv_encoder(0, 256, 256, 0, 60, probe);
    assert(!video);
    assert(opens > 0);
    assert(!opening);
    assert(av_log_get_level() == AV_LOG_ERROR);
}
"""


@unittest.skipUnless(
    sys.platform in ("linux", "darwin")
    and all(shutil.which(tool) for tool in ("cc", "pkg-config", "rustc")),
    "Unix native build tools are required",
)
class CodecProbeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        version = subprocess.check_output(["rustc", "-vV"], text=True)
        target = next(
            line.removeprefix("host: ")
            for line in version.splitlines()
            if line.startswith("host: ")
        )
        prefix = ROOT / ".cache/chromium-video" / target
        if not (prefix / ".version").exists():
            raise unittest.SkipTest("Build the pinned FFmpeg libraries first")
        env = dict(
            os.environ,
            PKG_CONFIG_PATH=str(prefix / "lib/pkgconfig"),
            PKG_CONFIG_LIBDIR=str(prefix / "lib/pkgconfig"),
        )
        cls.flags = shlex.split(
            subprocess.check_output(
                [
                    "pkg-config",
                    "--static",
                    "--cflags",
                    "--libs",
                    "libavcodec",
                    "libavutil",
                    "libswscale",
                ],
                env=env,
                text=True,
            )
        )
        cls.extra_sources = []
        if "linux" in target:
            # The Linux bundle resolves libva through this production loader.
            cls.extra_sources.append(str(SOURCE / "va_loader_linux.c"))
        cls.directory = tempfile.TemporaryDirectory(prefix="gft-codec-probe-")
        cls.addClassCleanup(cls.directory.cleanup)
        cls.root = Path(cls.directory.name)
        cls.helper = cls.compile("helper", HARNESS)
        cls.constructors = cls.compile("constructors", CONSTRUCTOR_HARNESS)

    @classmethod
    def compile(cls, name, source):
        harness = cls.root / f"{name}.c"
        harness.write_text(source)
        binary = cls.root / name
        result = subprocess.run(
            [
                "cc", "-std=c11", "-I", str(SOURCE), str(harness),
                *cls.extra_sources, *cls.flags, "-o", str(binary),
            ],
            capture_output=True, text=True,
        )
        if result.returncode:
            raise AssertionError(result.stderr)
        return binary

    def run_harness(self, binary, *args):
        result = subprocess.run(
            [str(binary), *map(str, args)], capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stderr

    def test_real_open_errors_and_restored_offsets(self):
        for probe in (0, 1):
            for success in (0, 1):
                for offset in (-8, 0, 8):
                    with self.subTest(probe=probe, success=success, offset=offset):
                        output = self.run_harness(
                            self.helper, probe, success, offset, 16 + offset
                        )
                        self.assertIn("after-open-error-visible", output)
                        self.assertEqual(
                            "Codec type or id mismatches" in output,
                            not probe and not success,
                            output,
                        )

    def test_probe_failure_remains_available_at_debug_level(self):
        output = self.run_harness(self.helper, 1, 0, 0, 48)
        self.assertIn("Codec type or id mismatches", output)
        self.assertIn("after-open-error-visible", output)

    def test_production_and_probe_constructors(self):
        for kind in ("encoder", "decoder"):
            for probe in (0, 1):
                with self.subTest(kind=kind, probe=probe):
                    output = self.run_harness(self.constructors, kind, probe)
                    self.assertIn("unrelated-context-error-visible", output)
                    self.assertIn("restored-constructor-error-visible", output)
                    self.assertEqual(
                        "Codec type or id mismatches" in output, not probe, output
                    )

    def test_named_decoder_is_a_production_open(self):
        output = self.run_harness(self.constructors, "named", 0)
        self.assertIn("Codec type or id mismatches", output)

    @unittest.skipUnless(sys.platform == "darwin", "VideoToolbox surface encoder")
    def test_apple_surface_encoder_is_a_production_open(self):
        output = self.run_harness(self.constructors, "surface", 0)
        self.assertIn("Codec type or id mismatches", output)


if __name__ == "__main__":
    unittest.main()
