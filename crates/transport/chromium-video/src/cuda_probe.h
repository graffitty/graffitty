#ifndef GRAFFITTY_CUDA_PROBE_H
#define GRAFFITTY_CUDA_PROBE_H

#ifdef __cplusplus
extern "C" {
#endif
// Driver presence alone is insufficient: CUDA stubs and machines without an
// NVIDIA GPU must not reach FFmpeg's noisy CUDA/NVENC initialization.
int gv_cuda_available(void);
#ifdef __cplusplus
}
#endif

#endif
