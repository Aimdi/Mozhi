/*
 * mozhi_whisper - a minimal C API over whisper.cpp (OpenAI Whisper speech
 * recognition on the ggml CPU backend), for Dart FFI.
 *
 * Copyright (c) 2026 Mozhi contributors. MIT License (see ../../LICENSE).
 * whisper.cpp and ggml (third_party/whisper.cpp) are MIT; see
 * ../THIRD_PARTY_NOTICES.md.
 *
 * Contract:
 *  - All strings are NUL-terminated UTF-8.
 *  - Strings returned by mozhi_whisper_transcribe() are allocated with
 *    malloc() and must be released with mozhi_whisper_free_string().
 *  - Every function is thread-safe. One model transcribes one recording at
 *    a time (calls on the same model are serialised by a lock in the model);
 *    call mozhi_whisper_transcribe() from a background thread/isolate, it
 *    takes seconds.
 *  - Failures return NULL (or 0) and record a message that
 *    mozhi_whisper_last_error() returns on the same thread. Engine errors
 *    are reported, never thrown across the API. (A failed internal
 *    assertion of ggml still aborts the process, after writing its message
 *    to stderr / logcat.)
 *  - Nothing is logged by whisper.cpp or ggml and nothing touches the
 *    network: the only input is the model file and the samples.
 */
#ifndef MOZHI_WHISPER_H_
#define MOZHI_WHISPER_H_

#include <stdint.h>

#if defined(_WIN32)
#define MOZHI_WHISPER_EXPORT __declspec(dllexport)
#else
#define MOZHI_WHISPER_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Bumped when a function signature changes (Dart checks it on load). */
#define MOZHI_WHISPER_ABI_VERSION 1

/* The sample rate mozhi_whisper_transcribe() expects (Whisper's). */
#define MOZHI_WHISPER_SAMPLE_RATE 16000

/* Size of the buffer for the detected language code; codes are at most 3
 * letters ("en", "haw"), so 8 is plenty. */
#define MOZHI_WHISPER_LANGUAGE_SIZE 8

/* One loaded Whisper model (ggml-*.bin). */
typedef struct MozhiWhisperModel MozhiWhisperModel;

/* MOZHI_WHISPER_ABI_VERSION of the loaded library. */
MOZHI_WHISPER_EXPORT int32_t mozhi_whisper_abi_version(void);

/* Engine version, e.g. "whisper.cpp 1.9.5 (ggml 0.26.0, CPU)". Static
 * storage: do not free. */
MOZHI_WHISPER_EXPORT const char* mozhi_whisper_version(void);

/* Loads a ggml Whisper model file (e.g. ggml-tiny.bin) for the CPU.
 * `n_threads` is the default for mozhi_whisper_transcribe() calls that pass
 * 0 or less; 0 or less here means min(4, number of cores). Returns NULL on
 * failure (missing or invalid file, out of memory). */
MOZHI_WHISPER_EXPORT MozhiWhisperModel* mozhi_whisper_model_load(
    const char* path, int32_t n_threads);

/* Releases a model (NULL is ignored). It must not be transcribing. */
MOZHI_WHISPER_EXPORT void mozhi_whisper_model_free(MozhiWhisperModel* model);

/* Whether the model knows more than English (1) or is English-only (0). */
MOZHI_WHISPER_EXPORT int32_t mozhi_whisper_model_is_multilingual(
    MozhiWhisperModel* model);

/* Transcribes `n_samples` mono samples at 16 kHz (floats in -1..1) in
 * `language` (a Whisper code such as "en", "de", "zh", "haw"; NULL, "" or
 * "auto" detects the language). Whisper reads 30 s at a time; longer audio
 * is transcribed window by window.
 *
 * Decoding: greedy (with Whisper's temperature fallback), no timestamps,
 * no context between windows, non-speech tokens (music notes, "[Music]",
 * ...) suppressed, never translated. `n_threads` <= 0 uses the model's
 * default.
 *
 * Returns the text (segments joined, leading/trailing whitespace removed;
 * "" for silence or audio shorter than 0.1 s) as a malloc'd string, or NULL
 * on failure (also when cancelled: see mozhi_whisper_cancel()). When
 * `detected_language` is not NULL, the language Whisper transcribed in
 * (the detected one for "auto") is written there as a NUL-terminated code
 * of at most `detected_language_size` - 1 bytes ("" when unknown). */
MOZHI_WHISPER_EXPORT char* mozhi_whisper_transcribe(
    MozhiWhisperModel* model, const float* samples, int32_t n_samples,
    const char* language, int32_t n_threads, char* detected_language,
    int32_t detected_language_size);

/* Aborts every mozhi_whisper_transcribe() running now, on any thread, as
 * soon as ggml checks (between graph computations, typically within a few
 * hundred milliseconds); they return NULL with the error "cancelled".
 * Transcriptions started later are not affected. */
MOZHI_WHISPER_EXPORT void mozhi_whisper_cancel(void);

/* Frees a string returned by this library (NULL is ignored). */
MOZHI_WHISPER_EXPORT void mozhi_whisper_free_string(char* text);

/* Message of the last failure on the calling thread, or NULL when the last
 * call on this thread succeeded. Valid until the next call on this thread. */
MOZHI_WHISPER_EXPORT const char* mozhi_whisper_last_error(void);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* MOZHI_WHISPER_H_ */
