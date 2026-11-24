#ifndef GRAFFITTY_CODEC_PROBE_H
#define GRAFFITTY_CODEC_PROBE_H

#include <libavcodec/avcodec.h>
#include <libavutil/log.h>

// Only capability discovery demotes expected failures to debug. Requested
// streams keep FFmpeg's startup diagnostics, including temporary exhaustion
// after a successful probe. Never change the process-wide logging policy.
static inline int gv_open_codec(AVCodecContext *context, const AVCodec *codec,
                                AVDictionary **options, int probe) {
    if (!probe) return avcodec_open2(context, codec, options);
    int offset = context->log_level_offset;
    context->log_level_offset += AV_LOG_DEBUG - AV_LOG_ERROR;
    int result = avcodec_open2(context, codec, options);
    context->log_level_offset = offset;
    return result;
}

#endif
