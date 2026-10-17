/*
 * mozhi_bergamot - a minimal C API over Mozilla's Firefox Translations
 * (Bergamot) inference engine and the CLD2 language identifier, for Dart
 * FFI.
 *
 * Copyright (c) 2026 Mozhi contributors. MIT License (see ../../LICENSE).
 * The engine itself (third_party/translations/inference) is MPL-2.0, CLD2
 * (third_party/cld2) Apache-2.0; see ../THIRD_PARTY_NOTICES.md.
 *
 * Contract:
 *  - All strings are NUL-terminated UTF-8 (mozhi_bergamot_detect() also
 *    takes a byte length).
 *  - Strings returned by mozhi_bergamot_translate*() are allocated with
 *    malloc() and must be released with mozhi_bergamot_free_string().
 *  - Every function is thread-safe. The engine is not re-entrant, so calls
 *    are serialised by an internal lock (one translation at a time per
 *    process); call them from a background thread/isolate. Language
 *    identification (mozhi_bergamot_detect) does not use that lock.
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

/* --- Language identification (CLD2) ---------------------------------------
 *
 * Compact Language Detector 2 (Apache-2.0, third_party/cld2), compiled in
 * with its 83-language "Chrome" tables. Needs no model files and does not
 * take the engine lock: it never waits for a translation and may run on
 * any thread at the same time as one. Added after ABI 1 without changing
 * any other function: callers look the symbol up before using it. */

/* mozhi_bergamot_detect() flags. */
/* Guess on short or ambiguous text instead of answering "un" (CLD2's
 * kCLDFlagBestEffort). Best-effort guesses are often wrong on a word or
 * two; callers should require a higher score for them. */
#define MOZHI_BERGAMOT_DETECT_BEST_EFFORT 1
/* The text is HTML: tags, comments and entities are skipped. */
#define MOZHI_BERGAMOT_DETECT_HTML 2

/* One language mozhi_bergamot_detect() found. */
typedef struct MozhiBergamotLanguage {
  /* CLD2's code, NUL-terminated: ISO 639-1 where there is one ("en",
   * "de"), CLD2's legacy codes "iw" (Hebrew), "jw" (Javanese), "tw" (Twi),
   * plus "zh-Hant" (Traditional Chinese), "sr-ME", "xx-<Script>" (a
   * script, no language) and "un" (unknown; unused slots). */
  char code[16];
  /* Share of the scored text in this language, 0-100. */
  int32_t percent;
  /* CLD2's normalized score: the language's score per KB of its text.
   * Around 1000-2000 for ordinary text, low for atypical or ambiguous
   * text; 0 for unused slots. */
  int32_t score;
} MozhiBergamotLanguage;

/* Result of mozhi_bergamot_detect(). */
typedef struct MozhiBergamotDetection {
  /* CLD2's answer for the whole text (same codes as above): usually
   * languages[0], the second one when the first is English boilerplate
   * around another language, "un" when CLD2 cannot tell. */
  char language[16];
  /* The top three languages by share of the text, best first. */
  MozhiBergamotLanguage languages[3];
  /* Bytes of letters CLD2 scored (digits, punctuation, markup and repeated
   * words do not count). */
  int32_t text_bytes;
  /* CLD2's is_reliable: 1 when the top language clearly won. */
  int32_t reliable;
} MozhiBergamotDetection;

/* Identifies the language of `length` bytes of UTF-8 `text` (length < 0:
 * NUL-terminated). `hints` biases the result towards some languages
 * (comma-separated codes, e.g. "de,en"; NULL or "" for none). `flags` is a
 * combination of MOZHI_BERGAMOT_DETECT_*. Invalid UTF-8 or text without
 * letters gives "un", not an error.
 *
 * Returns 1 and fills *out, or 0 (and sets the last error) when `text` or
 * `out` is NULL. */
MOZHI_BERGAMOT_EXPORT int32_t mozhi_bergamot_detect(
    const char* text, int32_t length, const char* hints, int32_t flags,
    MozhiBergamotDetection* out);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* MOZHI_BERGAMOT_H_ */
