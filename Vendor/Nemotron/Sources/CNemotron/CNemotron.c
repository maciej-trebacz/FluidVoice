#include "CNemotron.h"
#include "vendor/asr.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct fv_nemotron {
    void *library;
    nemo_speech_asr_recognizer *recognizer;
    __typeof__(&nemo_speech_asr_create) create;
    __typeof__(&nemo_speech_asr_destroy) destroy;
    __typeof__(&nemo_speech_asr_recognize_f32) recognize;
    __typeof__(&nemo_speech_asr_recognition_options_default) options;
    __typeof__(&nemo_speech_asr_result_transcript) transcript;
    __typeof__(&nemo_speech_asr_result_destroy) release_result;
    __typeof__(&nemo_speech_asr_last_error) last_error;
};

static void copy_error(char *error, size_t capacity, const char *message) {
    if (error && capacity) snprintf(error, capacity, "%s", message ? message : "Nemotron failed.");
}

void fv_nemotron_destroy(fv_nemotron *h) {
    if (!h) return;
    if (h->recognizer && h->destroy) h->destroy(h->recognizer);
    if (h->library) dlclose(h->library);
    free(h);
}

fv_nemotron *fv_nemotron_create(const char *library, const char *decoder,
                               const char *encoder, char *error, size_t capacity) {
    if (!library || !decoder || !encoder || !*decoder || !*encoder) {
        copy_error(error, capacity, "Select the Nemotron decoder and encoder files.");
        return NULL;
    }
    fv_nemotron *h = calloc(1, sizeof(*h));
    if (!h) { copy_error(error, capacity, "Not enough memory."); return NULL; }
    h->library = dlopen(library, RTLD_NOW | RTLD_LOCAL);
    if (!h->library) { copy_error(error, capacity, dlerror()); goto fail; }
#define LOAD(field, symbol) \
    h->field = (__typeof__(h->field))dlsym(h->library, #symbol); \
    if (!h->field) { copy_error(error, capacity, "Missing " #symbol); goto fail; }
    LOAD(create, nemo_speech_asr_create)
    LOAD(destroy, nemo_speech_asr_destroy)
    LOAD(recognize, nemo_speech_asr_recognize_f32)
    LOAD(options, nemo_speech_asr_recognition_options_default)
    LOAD(transcript, nemo_speech_asr_result_transcript)
    LOAD(release_result, nemo_speech_asr_result_destroy)
    LOAD(last_error, nemo_speech_asr_last_error)
#undef LOAD
    nemo_speech_asr_backend_config backend = {0};
    backend.size = sizeof(backend);
    backend.gpu = 0;
    nemo_speech_asr_model_config model = {0};
    model.size = sizeof(model);
    model.path = decoder;
    nemo_speech_asr_salm_config salm = {0};
    salm.size = sizeof(salm);
    salm.encoder_path = encoder;
    // Four 8192-token slots; app requests stay below this pool. No Metal MTP.
    salm.max_sequences = 4;
    salm.mtp_draft = 0;
    nemo_speech_asr_recognizer_config config = {0};
    config.size = sizeof(config);
    config.backend = &backend;
    config.model = &model;
    config.salm = &salm;
    if (h->create(&config, &h->recognizer) != NEMO_SPEECH_ASR_OK) {
        copy_error(error, capacity, h->last_error());
        goto fail;
    }
    return h;
fail:
    fv_nemotron_destroy(h);
    return NULL;
}

bool fv_nemotron_transcribe(fv_nemotron *h, const float *samples, size_t count,
                            const char *language, char **text, char *error, size_t capacity) {
    if (text) *text = NULL;
    if (!h || !h->recognizer || !text || !samples || count < 320) {
        copy_error(error, capacity, "Nemotron requires at least 20 ms of audio.");
        return false;
    }
    nemo_speech_asr_recognition_options options = h->options();
    options.language_code = language;
    nemo_speech_asr_result *result = NULL;
    if (h->recognize(h->recognizer, &options, samples, count, 16000, &result) != NEMO_SPEECH_ASR_OK) {
        copy_error(error, capacity, h->last_error());
        if (result) h->release_result(result);
        return false;
    }
    const char *value = result ? h->transcript(result, 0) : "";
    *text = strdup(value ? value : "");
    if (result) h->release_result(result);
    if (!*text) { copy_error(error, capacity, "Not enough memory for transcript."); return false; }
    return true;
}

void fv_nemotron_free_text(char *text) { free(text); }
