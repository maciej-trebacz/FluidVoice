#ifndef FLUID_NEMOTRON_H
#define FLUID_NEMOTRON_H
#include <stddef.h>
#include <stdbool.h>

typedef struct fv_nemotron fv_nemotron;
// Calls on a handle, including destruction, must be serialized by the caller.
fv_nemotron *fv_nemotron_create(const char *library, const char *decoder,
                               const char *encoder, char *error, size_t capacity);
bool fv_nemotron_transcribe(fv_nemotron *handle, const float *samples, size_t count,
                            const char *language, char **text, char *error, size_t capacity);
void fv_nemotron_free_text(char *text);
void fv_nemotron_destroy(fv_nemotron *handle);
#endif
