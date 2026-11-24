#include "cuda_probe.h"
#include <dlfcn.h>
#include <pthread.h>

static pthread_once_t once = PTHREAD_ONCE_INIT;
static int (*init)(unsigned int);
static int (*count_devices)(int *);

static void probe(void) {
    void *library = dlopen("libcuda.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!library)
        return;
    init = (int (*)(unsigned int))dlsym(library, "cuInit");
    count_devices = (int (*)(int *))dlsym(library, "cuDeviceGetCount");
    // Keep the driver mapped: initialization may have started driver threads.
}

int gv_cuda_available(void) {
    pthread_once(&once, probe);
    // Keep transient device failures retryable, like the codec capability cache.
    int count = 0;
    return init && count_devices && init(0) == 0 && count_devices(&count) == 0 && count > 0;
}
