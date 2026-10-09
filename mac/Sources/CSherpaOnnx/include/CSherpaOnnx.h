// Mouthy's bridge to sherpa-onnx (Apache-2.0, https://github.com/k2-fsa/sherpa-onnx). The library is loaded at
// run time from the app bundle, only on Intel Macs; nothing here links against it, so host apps that use
// MouthyKit without bundling it are unaffected. sherpa-onnx-c-api.h is the unmodified v1.13.8 header.
#ifndef MOUTHY_CSHERPAONNX_H
#define MOUTHY_CSHERPAONNX_H

#include "sherpa-onnx-c-api.h"

/// Loads libsherpa-onnx-c-api.dylib from `path`. Returns 1 when every function was found.
int mouthy_sherpa_load(const char *path);
const SherpaOnnxOfflineRecognizer *mouthy_sherpa_create_recognizer(const SherpaOnnxOfflineRecognizerConfig *config);
void mouthy_sherpa_destroy_recognizer(const SherpaOnnxOfflineRecognizer *recognizer);
/// Recognizes 16 kHz mono samples. Returns a copy of the text for the caller to free(), or NULL.
char *mouthy_sherpa_decode(const SherpaOnnxOfflineRecognizer *recognizer, const float *samples, int32_t count);
char *mouthy_sherpa_decode_from(const SherpaOnnxOfflineRecognizer *recognizer, const float *samples, int32_t count, float from, int *found);

#endif
