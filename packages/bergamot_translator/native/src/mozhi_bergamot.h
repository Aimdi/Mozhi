/*
 * mozhi_bergamot - a minimal C API over Mozilla's Firefox Translations
 * (Bergamot) inference engine, for Dart FFI.
 *
 * Copyright (c) 2026 Mozhi contributors. MIT License (see ../../LICENSE).
 * The engine itself (third_party/translations/inference) is MPL-2.0; see
 * ../THIRD_PARTY_NOTICES.md.
 *
 * Contract:
 *  - All strings are NUL-terminated UTF-8.
 *  - Strings returned by mozhi_bergamot_translate*() are allocated with
 *    malloc() and must be released with mozhi_bergamot_free_string().
 *  - Every function is thread-safe. The engine is not re-entrant, so calls
 *    are serialised by an internal lock (one translation at a time per
 *    process); call them from a background thread/isolate.
 *  - Failures return NULL (or 0) and record a message that
 *    mozhi_bergamot_last_error() returns on the same thread. Engine errors
 *    are reported, never std::abort()ed.
 */
#ifndef MOZHI_BERGAMOT_H_
#define MOZHI_BERGAMOT_H_

#include <stdint.h>

#if defined(_WIN32)
#define MOZHI_BERGAMOT_EXPORT __declspec(dllexport)
#else
#define MOZHI_BERGAMOT_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Bumped when a function signature changes (Dart checks it on load). */
#define MOZHI_BERGAMOT_ABI_VERSION 1

/* One loaded translation direction (model + shortlist + vocabularies). */
typedef struct MozhiBergamotModel MozhiBergamotModel;

/* MOZHI_BERGAMOT_ABI_VERSION of the loaded library. */
MOZHI_BERGAMOT_EXPORT int32_t mozhi_bergamot_abi_version(void);

/* Engine version, e.g. "bergamot v0.6.0 (mozilla/translations 69455aca)".
 * Static storage: do not free. */
MOZHI_BERGAMOT_EXPORT const char* mozhi_bergamot_version(void);

/* Loads a model from uncompressed files.
 *
 *  model_path      *.intgemm.alphas.bin / *.intgemm8.bin (required)
 *  shortlist_path  lex.*.s2t.bin, or NULL/"" for none (slower)
 *  src_vocab_path  vocab.*.spm or srcvocab.*.spm (required)
 *  trg_vocab_path  trgvocab.*.spm, or NULL/"" when the vocabulary is shared
 *  extra_config    extra Marian/Bergamot YAML options (one "key: value" per
 *                  line) appended to the defaults, or NULL/"".
 *
 * The gemm precision is chosen from the model's file name ("alphas" ->
 * int8shiftAlphaAll, otherwise int8shiftAll) unless extra_config sets
 * gemm-precision. Returns NULL on failure. */
MOZHI_BERGAMOT_EXPORT MozhiBergamotModel* mozhi_bergamot_model_create(
    const char* model_path, const char* shortlist_path,
    const char* src_vocab_path, const char* trg_vocab_path,
    const char* extra_config);

/* Releases a model (NULL is ignored). The model must not be in use. */
MOZHI_BERGAMOT_EXPORT void mozhi_bergamot_model_destroy(
    MozhiBergamotModel* model);

/* Translates text with one model. html != 0 keeps HTML markup (tags are
 * removed before and re-inserted after translation). Long text is split
 * into paragraphs and sentences internally; whitespace between them is
 * preserved. Returns a malloc'd string or NULL on failure. */
MOZHI_BERGAMOT_EXPORT char* mozhi_bergamot_translate(MozhiBergamotModel* model,
                                                     const char* text,
                                                     int32_t html);

/* Translates source -> pivot with `first`, then pivot -> target with
 * `second` (e.g. es->en, en->de), without re-splitting in between. */
MOZHI_BERGAMOT_EXPORT char* mozhi_bergamot_translate_pivot(
    MozhiBergamotModel* first, MozhiBergamotModel* second, const char* text,
    int32_t html);

/* Frees a string returned by this library (NULL is ignored). */
MOZHI_BERGAMOT_EXPORT void mozhi_bergamot_free_string(char* text);

/* Message of the last failure on the calling thread, or NULL when the last
 * call on this thread succeeded. Valid until the next call on this thread. */
MOZHI_BERGAMOT_EXPORT const char* mozhi_bergamot_last_error(void);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* MOZHI_BERGAMOT_H_ */
