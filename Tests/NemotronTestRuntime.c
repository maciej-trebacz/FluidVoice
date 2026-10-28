// Test-only C ABI fixture. Native computation completes before destruction is safe.
#include "../Vendor/Nemotron/Sources/CNemotron/vendor/asr.h"
#include <assert.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct nemo_speech_asr_recognizer { atomic_bool active; };
struct nemo_speech_asr_result { char *text; };
static _Thread_local const char *error_message = "";

nemo_speech_asr_status nemo_speech_asr_create(const nemo_speech_asr_recognizer_config *c,
                                            nemo_speech_asr_recognizer **out) {
    assert(c->size == sizeof(*c));
    assert(c->salm->max_sequences == 4 && c->salm->mtp_draft == 0);
    assert(c->backend->gpu == 0);
    if (strstr(c->model->path, "missing")) {
        error_message = "Missing decoder fixture";
        *out = NULL;
        return NEMO_SPEECH_ASR_ERROR_INVALID_ARGUMENT;
    }
    *out = calloc(1, sizeof(**out));
    return NEMO_SPEECH_ASR_OK;
}
void nemo_speech_asr_destroy(nemo_speech_asr_recognizer *h) {
    assert(!h || !atomic_load(&h->active));
    free(h);
    error_message = "destroy overwrites thread-local error";
}
nemo_speech_asr_recognition_options nemo_speech_asr_recognition_options_default(void) {
    nemo_speech_asr_recognition_options o = {0}; o.size = sizeof(o); return o;
}
nemo_speech_asr_status nemo_speech_asr_recognize_f32(nemo_speech_asr_recognizer *h,
    const nemo_speech_asr_recognition_options *o, const float *samples, size_t n,
    int32_t rate, nemo_speech_asr_result **out) {
    assert(rate == 16000 && samples && n >= 320);
    assert(!atomic_exchange(&h->active, true));
    usleep(200000);
    *out = calloc(1, sizeof(**out));
    (*out)->text = strdup(o->language_code ? o->language_code : "default");
    atomic_store(&h->active, false);
    return NEMO_SPEECH_ASR_OK;
}
const char *nemo_speech_asr_result_transcript(const nemo_speech_asr_result *r, size_t alt) {
    assert(alt == 0); return r->text;
}
void nemo_speech_asr_result_destroy(nemo_speech_asr_result *r) {
    memset(r->text, 'x', strlen(r->text)); free(r->text); free(r);
}
const char *nemo_speech_asr_last_error(void) { return error_message; }
