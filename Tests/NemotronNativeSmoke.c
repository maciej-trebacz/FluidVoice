// clang -I Vendor/Nemotron/Sources/CNemotron/include Tests/NemotronNativeSmoke.c
//       Vendor/Nemotron/Sources/CNemotron/CNemotron.c -o /tmp/nemotron-smoke
// /tmp/nemotron-smoke LIBRARY DECODER ENCODER [MONO_16KHZ_FLOAT32_FILE] [LANGUAGE]
#include "CNemotron.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#ifdef NEMOTRON_TEST_TRANSCRIBE_CPP
#include "transcribe.h"
#endif
#ifdef __APPLE__
#include <mach/mach.h>
#endif

static double now(void) {
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    return time.tv_sec + time.tv_nsec / 1e9;
}
static void footprint(const char *stage) {
    (void)stage;
#ifdef __APPLE__
    task_vm_info_data_t info;
    mach_msg_type_number_t size = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &size) == KERN_SUCCESS) {
        printf("FOOTPRINT_MIB %s %.2f\n", stage, info.phys_footprint / 1048576.0);
        printf("RESIDENT_MIB %s %.2f PEAK %.2f\n", stage,
               info.resident_size / 1048576.0, info.resident_size_peak / 1048576.0);
    }
#endif
    fflush(stdout);
}

int main(int argc, char **argv) {
    if (argc < 4) return 2;
    const char *coload = getenv("NEMOTRON_COLOAD_LIBRARY");
    void *other = coload ? dlopen(coload, RTLD_NOW | RTLD_LOCAL) : NULL;
    if (coload && !other) { fprintf(stderr, "%s\n", dlerror()); return 1; }
#ifdef NEMOTRON_TEST_TRANSCRIBE_CPP
    struct transcribe_model *other_model = NULL;
    __typeof__(&transcribe_model_free) free_other = NULL;
    const char *other_path = getenv("NEMOTRON_COLOAD_MODEL");
    if (other && other_path) {
        __typeof__(&transcribe_init_backends_default) init = dlsym(other, "transcribe_init_backends_default");
        __typeof__(&transcribe_model_load_file) load = dlsym(other, "transcribe_model_load_file");
        free_other = dlsym(other, "transcribe_model_free");
        if (!init || !load || !free_other || init() != 0 || load(other_path, NULL, &other_model) != 0) {
            fputs("Could not load the second transcription model\n", stderr); return 1;
        }
        puts("TRANSCRIBE_CPP_MODEL_READY");
    }
#endif
    char error[2048] = {0};
    int status = 0;
    footprint("before");
    double start = now();
    fv_nemotron *model = fv_nemotron_create(argv[1], argv[2], argv[3], error, sizeof(error));
    if (!model) { fprintf(stderr, "%s\n", error); status = 1; goto release_other; }
    puts("MODEL_READY"); fflush(stdout);
    printf("LOAD_SECONDS %.3f\n", now() - start);
    footprint("loaded");
    if (argc >= 5) {
        FILE *file = fopen(argv[4], "rb");
        if (!file) { status = 2; goto release_model; }
        fseek(file, 0, SEEK_END);
        long bytes = ftell(file);
        rewind(file);
        if (bytes <= 0 || bytes % sizeof(float) || bytes > 16000L * 300 * 4) {
            fclose(file); status = 2; goto release_model;
        }
        float *samples = malloc((size_t)bytes);
        if (!samples) { fclose(file); status = 2; goto release_model; }
        size_t count = fread(samples, sizeof(float), (size_t)bytes / sizeof(float), file);
        fclose(file);
        char *text = NULL;
        start = now();
        if (fv_nemotron_transcribe(model, samples, count, argc >= 6 ? argv[5] : NULL, &text, error, sizeof(error))) {
            printf("TRANSCRIPT: %s\n", text);
            fv_nemotron_free_text(text);
        } else { fprintf(stderr, "%s\n", error); status = 1; }
        printf("TRANSCRIBE_SECONDS %.3f AUDIO_SECONDS %.3f\n", now() - start, count / 16000.0);
        footprint("transcribed");
        free(samples);
    }
release_model:
    fv_nemotron_destroy(model);
    puts("MODEL_RELEASED");
    sleep(1);
    footprint("released");
release_other:
#ifdef NEMOTRON_TEST_TRANSCRIBE_CPP
    if (other_model) free_other(other_model);
#endif
    if (other) dlclose(other);
    return status;
}
