#include "CSherpaOnnx.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

static void *library;
static const SherpaOnnxOfflineRecognizer *(*create_recognizer)(const SherpaOnnxOfflineRecognizerConfig *);
static void (*destroy_recognizer)(const SherpaOnnxOfflineRecognizer *);
static const SherpaOnnxOfflineStream *(*create_stream)(const SherpaOnnxOfflineRecognizer *);
static void (*destroy_stream)(const SherpaOnnxOfflineStream *);
static void (*accept_waveform)(const SherpaOnnxOfflineStream *, int32_t, const float *, int32_t);
static void (*decode_stream)(const SherpaOnnxOfflineRecognizer *, const SherpaOnnxOfflineStream *);
static const SherpaOnnxOfflineRecognizerResult *(*get_result)(const SherpaOnnxOfflineStream *);
static void (*destroy_result)(const SherpaOnnxOfflineRecognizerResult *);

int mouthy_sherpa_load(const char *path) {
    if (library) return 1;
    void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!handle) return 0;
    create_recognizer = dlsym(handle, "SherpaOnnxCreateOfflineRecognizer");
    destroy_recognizer = dlsym(handle, "SherpaOnnxDestroyOfflineRecognizer");
    create_stream = dlsym(handle, "SherpaOnnxCreateOfflineStream");
    destroy_stream = dlsym(handle, "SherpaOnnxDestroyOfflineStream");
    accept_waveform = dlsym(handle, "SherpaOnnxAcceptWaveformOffline");
    decode_stream = dlsym(handle, "SherpaOnnxDecodeOfflineStream");
    get_result = dlsym(handle, "SherpaOnnxGetOfflineStreamResult");
    destroy_result = dlsym(handle, "SherpaOnnxDestroyOfflineRecognizerResult");
    if (!create_recognizer || !destroy_recognizer || !create_stream || !destroy_stream || !accept_waveform ||
        !decode_stream || !get_result || !destroy_result) {
        dlclose(handle);
        return 0;
    }
    library = handle;
    return 1;
}

const SherpaOnnxOfflineRecognizer *mouthy_sherpa_create_recognizer(const SherpaOnnxOfflineRecognizerConfig *config) {
    return library ? create_recognizer(config) : NULL;
}

void mouthy_sherpa_destroy_recognizer(const SherpaOnnxOfflineRecognizer *recognizer) {
    if (library && recognizer) destroy_recognizer(recognizer);
}

char *mouthy_sherpa_decode(const SherpaOnnxOfflineRecognizer *recognizer, const float *samples, int32_t count) {
    if (!library || !recognizer) return NULL;
    const SherpaOnnxOfflineStream *stream = create_stream(recognizer);
    if (!stream) return NULL;
    accept_waveform(stream, 16000, samples, count);
    decode_stream(recognizer, stream);
    const SherpaOnnxOfflineRecognizerResult *result = get_result(stream);
    char *text = (result && result->text) ? strdup(result->text) : NULL;
    if (result) destroy_result(result);
    destroy_stream(stream);
    return text;
}

/// Like mouthy_sherpa_decode, but keeps only the tokens from the first word that starts at or after `from` seconds:
/// the audio before it is context. Returns "" when no word starts there; sets `*found` to 0 (and returns NULL) only
/// when the result has no token times.
char *mouthy_sherpa_decode_from(const SherpaOnnxOfflineRecognizer *recognizer, const float *samples, int32_t count, float from, int *found) {
    *found = 0;
    if (!library || !recognizer) return NULL;
    const SherpaOnnxOfflineStream *stream = create_stream(recognizer);
    if (!stream) return NULL;
    accept_waveform(stream, 16000, samples, count);
    decode_stream(recognizer, stream);
    const SherpaOnnxOfflineRecognizerResult *result = get_result(stream);
    char *text = NULL;
    if (result && result->timestamps && result->tokens_arr) {
        int32_t first = -1;
        for (int32_t i = 0; i < result->count && first < 0; i++) {
            const char *token = result->tokens_arr[i];
            // A word starts with a space or SentencePiece's word mark (U+2581).
            int starts = token && (token[0] == ' ' || strncmp(token, "\xe2\x96\x81", 3) == 0);
            if (starts && result->timestamps[i] >= from) first = i;
        }
        size_t length = 1;
        for (int32_t i = first; first >= 0 && i < result->count; i++) length += strlen(result->tokens_arr[i]);
        text = calloc(length, 1);
        for (int32_t i = first; text && first >= 0 && i < result->count; i++) strcat(text, result->tokens_arr[i]);
        *found = text != NULL;
    }
    if (result) destroy_result(result);
    destroy_stream(stream);
    return text;
}
