/*
 * mozhi_llama - a minimal C API over llama.cpp (large language models in
 * GGUF files on the ggml CPU backend), for Dart FFI.
 *
 * Copyright (c) 2026 Mozhi contributors. MIT License (see ../../LICENSE).
 * llama.cpp and ggml (third_party/llama.cpp) are MIT; see
 * ../THIRD_PARTY_NOTICES.md.
 *
 * Contract:
 *  - All strings are NUL-terminated UTF-8, so a string ends at its first
 *    U+0000: callers remove NUL characters from text first (the Dart
 *    bindings do). Text this library returns is always valid UTF-8
 *    (invalid bytes from a model become U+FFFD).
 *  - Strings returned by mozhi_llama_model_info() and
 *    mozhi_llama_chat_format() are allocated with malloc() and must be
 *    released with mozhi_llama_free_string().
 *  - Threads: every function may be called from any thread, and calls on
 *    the same handle are serialised by a lock in the handle - except
 *    mozhi_llama_model_free(), which frees that lock with the handle: no
 *    other call on the handle may run or start once it is called (the
 *    caller serialises them; the Dart engine makes every call from one
 *    isolate). A model handle (the weights plus one context) runs one
 *    generation at a time: a generate_begin fails while another generation
 *    of that handle has not ended. Call the generate functions from a
 *    background thread/isolate: prompt processing takes seconds.
 *  - Message contents are untrusted text (documents, web pages, OCR):
 *    mozhi_llama_chat_tokenize() and mozhi_llama_chat_generate_begin()
 *    tokenize them as plain text, so text that looks like a special token
 *    ("<|im_end|>", "<turn|>", "<|endoftext|>", "<eos>", a user-defined
 *    token such as Gemma 4's "<|channel>") never becomes one; only the chat
 *    template's own markers are special tokens. mozhi_llama_generate_begin()
 *    and mozhi_llama_tokenize_count() take a raw prompt whose special-token
 *    text is parsed wherever it is: for trusted text only.
 *  - Failures return NULL, -1 or another negative MOZHI_LLAMA_E_* code and
 *    record a message that mozhi_llama_last_error() returns on the same
 *    thread. Engine errors are reported, never thrown across the API. (A
 *    failed internal assertion of ggml, or an exception that escapes
 *    anyway, still aborts the process, after writing a message to stderr /
 *    logcat; ggml's fork() of the process for a debugger's backtrace is
 *    never used.)
 *  - Nothing is logged by llama.cpp or ggml and nothing touches the
 *    network: the only input is the model file and the text passed in.
 *  - No state is kept between generations: the KV cache is cleared when a
 *    generation begins.
 */
#ifndef MOZHI_LLAMA_H_
#define MOZHI_LLAMA_H_

#include <stdint.h>

#if defined(_WIN32)
#define MOZHI_LLAMA_EXPORT __declspec(dllexport)
#else
#define MOZHI_LLAMA_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Bumped when a function signature or struct changes or functions are added
 * (Dart checks it on load). */
#define MOZHI_LLAMA_ABI_VERSION 2

/* Return codes. */
#define MOZHI_LLAMA_OK 0
/* Failure: see mozhi_llama_last_error(). */
#define MOZHI_LLAMA_E_ERROR (-1)
/* Stopped by mozhi_llama_cancel(). */
#define MOZHI_LLAMA_E_CANCELLED (-2)
/* The prompt does not fit: it has more than n_ctx - max_tokens tokens. */
#define MOZHI_LLAMA_E_CONTEXT (-3)

/* Why a generation ended (MozhiLlamaStats.finish_reason). */
#define MOZHI_LLAMA_FINISH_NONE 0   /* still running, or cancelled/failed */
#define MOZHI_LLAMA_FINISH_STOP 1   /* end of text or a stop string */
#define MOZHI_LLAMA_FINISH_LENGTH 2 /* max_tokens, or the context is full */

/* MozhiLlamaParams.seed for a random seed. */
#define MOZHI_LLAMA_RANDOM_SEED 0xFFFFFFFFu

/* Smallest buffer mozhi_llama_generate_next() accepts. */
#define MOZHI_LLAMA_MIN_PIECE_SIZE 8

/* One loaded model (a GGUF file, memory-mapped) with one context. */
typedef struct MozhiLlamaModel MozhiLlamaModel;

/* How to generate (mozhi_llama_generate_begin()). Sampling runs in this
 * order: repetition penalty, top-k, top-p, min-p, temperature, then a
 * random pick (greedy when temperature <= 0). */
typedef struct MozhiLlamaParams {
  float temperature;     /* <= 0: greedy (always the most likely token) */
  int32_t top_k;         /* <= 0: off */
  float top_p;           /* >= 1: off */
  float min_p;           /* <= 0: off */
  float repeat_penalty;  /* 1: off; applies to the last repeat_last_n tokens
                            of the prompt and the output */
  int32_t repeat_last_n; /* 0: off, -1: the whole context */
  uint32_t seed;         /* MOZHI_LLAMA_RANDOM_SEED: random */
  int32_t max_tokens;    /* tokens to generate at most; <= 0: until the
                            context is full */
  /* GBNF grammar the output must follow (root rule "root"), e.g.
   * mozhi_llama_json_grammar(); NULL or "" for free text. */
  const char* grammar;
  /* Generation ends before any of these strings (not included in the
   * output). NULL entries and empty strings are ignored. */
  const char* const* stop;
  int32_t n_stop;
  /* Optional (NULL: none): cancels this generation alone, like
   * mozhi_llama_cancel(), once another thread sets *cancel_flag to non-zero.
   * Must stay valid until mozhi_llama_generate_end(). */
  const volatile int32_t* cancel_flag;
} MozhiLlamaParams;

/* About the last generation of a handle (mozhi_llama_generate_stats()). */
typedef struct MozhiLlamaStats {
  int32_t prompt_tokens;
  int32_t generated_tokens;
  int32_t finish_reason; /* MOZHI_LLAMA_FINISH_* */
  int32_t reserved;
  double prompt_ms;   /* processing the prompt */
  double generate_ms; /* generating the output (after the prompt) */
} MozhiLlamaStats;

/* MOZHI_LLAMA_ABI_VERSION of the loaded library. */
MOZHI_LLAMA_EXPORT int32_t mozhi_llama_abi_version(void);

/* Engine version, e.g. "llama.cpp 0.6.0 (ggml 0.26.0, CPU armv8-a)". Static
 * storage: do not free. */
MOZHI_LLAMA_EXPORT const char* mozhi_llama_version(void);

/* What this library's CPU backend uses, for diagnostics: the architecture
 * it was compiled for and the features ggml found at run time, e.g.
 * "armv8.2-a+dotprod+fp16: NEON ARM_FMA FP16_VA DOTPROD". Static storage. */
MOZHI_LLAMA_EXPORT const char* mozhi_llama_cpu_features(void);

/* llama.cpp's grammars/json.gbnf: any JSON object. Static storage. */
MOZHI_LLAMA_EXPORT const char* mozhi_llama_json_grammar(void);

/* Loads a GGUF model for the CPU and creates its context.
 *  - n_threads <= 0: min(4, number of cores).
 *  - n_ctx: context size in tokens, capped at the model's training context;
 *    <= 0 uses the training context.
 *  - use_mmap: 1 maps the file (pages are read on demand and can be
 *    dropped by the system), 0 reads it into memory.
 * Returns NULL on failure (missing or invalid file, unsupported
 * architecture, out of memory). */
MOZHI_LLAMA_EXPORT MozhiLlamaModel* mozhi_llama_model_load(const char* path,
                                                           int32_t n_threads,
                                                           int32_t n_ctx,
                                                           int32_t use_mmap);

/* Releases a model and its context (NULL is ignored), ending a generation
 * that has not ended. Not to be called while another call on the same
 * handle runs or may start (see Threads above): that would use freed
 * memory. */
MOZHI_LLAMA_EXPORT void mozhi_llama_model_free(MozhiLlamaModel* model);

/* About the model, as a JSON object (malloc'd):
 *   architecture, name, description (strings), n_ctx_train, n_ctx (this
 *   context), n_params, size (bytes of the weights), n_vocab, n_layer,
 *   n_embd (numbers), chat_template (true when mozhi_llama_chat_format()
 *   works), chat_template_name (string or null: "chatml", "gemma4",
 *   "hunyuan-dense", "qwen3", ...).
 * NULL on failure. */
MOZHI_LLAMA_EXPORT char* mozhi_llama_model_info(MozhiLlamaModel* model);

/* Formats a conversation with the model's chat template: `n` messages,
 * roles "system", "user" or "assistant" (others fail). With add_assistant 1
 * the prompt ends where the model's answer starts. Templates llama.cpp
 * knows are applied by llama_chat_apply_template(); Gemma 4's is formatted
 * here, and Qwen3's gets thinking turned off (an empty <think></think>).
 * Returns the prompt (malloc'd) or NULL when the model has no supported
 * template. The text is for display and diagnostics: generate with
 * mozhi_llama_chat_generate_begin(), which keeps the contents plain text
 * (mozhi_llama_generate_begin() would parse special-token text in them). */
MOZHI_LLAMA_EXPORT char* mozhi_llama_chat_format(MozhiLlamaModel* model,
                                                 const char* const* roles,
                                                 const char* const* contents,
                                                 int32_t n,
                                                 int32_t add_assistant);

/* Tokenizes a conversation as mozhi_llama_chat_generate_begin() does (the
 * arguments of mozhi_llama_chat_format()): the model's BOS token if it
 * has one, the special tokens of the chat template's own text, and the
 * message contents as plain text - text in them that looks like a special
 * token (also a user-defined one) is split into ordinary tokens. Writes
 * the first n_tokens_max token ids to `tokens` (NULL with n_tokens_max 0
 * just counts) and returns the number of tokens, which may be larger than
 * n_tokens_max, or -1 on failure. */
MOZHI_LLAMA_EXPORT int32_t mozhi_llama_chat_tokenize(
    MozhiLlamaModel* model, const char* const* roles,
    const char* const* contents, int32_t n, int32_t add_assistant,
    int32_t* tokens, int32_t n_tokens_max);

/* Number of tokens of `text` as a raw prompt of mozhi_llama_generate_begin()
 * (with the model's BOS token; special-token text anywhere in it becomes
 * special tokens), or -1 on failure. For trusted text only; count a
 * conversation with mozhi_llama_chat_tokenize(). */
MOZHI_LLAMA_EXPORT int32_t mozhi_llama_tokenize_count(MozhiLlamaModel* model,
                                                      const char* text);

/* Starts a generation that answers a conversation (the arguments of
 * mozhi_llama_chat_format()), tokenized as mozhi_llama_chat_tokenize()
 * does: the message contents stay plain text. Clears the KV cache,
 * tokenizes the prompt and prepares sampling; the prompt is processed by
 * the first mozhi_llama_generate_next(). Returns MOZHI_LLAMA_OK,
 * MOZHI_LLAMA_E_CONTEXT when the prompt is longer than n_ctx - max_tokens
 * tokens (or than n_ctx - 1 without max_tokens), or MOZHI_LLAMA_E_ERROR
 * (no supported chat template, invalid grammar, a generation is running,
 * ...). End every successful begin with mozhi_llama_generate_end(). */
MOZHI_LLAMA_EXPORT int32_t mozhi_llama_chat_generate_begin(
    MozhiLlamaModel* model, const char* const* roles,
    const char* const* contents, int32_t n, int32_t add_assistant,
    const MozhiLlamaParams* params);

/* Like mozhi_llama_chat_generate_begin(), from a raw prompt: special-token
 * text anywhere in it becomes special tokens, so it must not contain
 * untrusted text (e.g. a developer's prompt in the CLI's --raw mode). */
MOZHI_LLAMA_EXPORT int32_t mozhi_llama_generate_begin(
    MozhiLlamaModel* model, const char* prompt, const MozhiLlamaParams* params);

/* Generates until the next piece of text is ready and writes it to `buf`
 * (NUL-terminated, at most size - 1 bytes; size >=
 * MOZHI_LLAMA_MIN_PIECE_SIZE). A piece is one or more whole UTF-8
 * characters, never part of one; text that could start a stop string is
 * held back until it is known not to. Returns the piece's length in bytes
 * (> 0), 0 when the generation has ended (end of text, a stop string,
 * max_tokens or a full context), MOZHI_LLAMA_E_CANCELLED after
 * mozhi_llama_cancel() or MOZHI_LLAMA_E_ERROR. */
MOZHI_LLAMA_EXPORT int32_t mozhi_llama_generate_next(MozhiLlamaModel* model,
                                                     char* buf, int32_t size);

/* Ends the generation (frees its sampler; NULL or no generation is
 * ignored). */
MOZHI_LLAMA_EXPORT void mozhi_llama_generate_end(MozhiLlamaModel* model);

/* Copies the statistics of the handle's current or last generation to
 * `stats`. Returns MOZHI_LLAMA_OK or MOZHI_LLAMA_E_ERROR. */
MOZHI_LLAMA_EXPORT int32_t mozhi_llama_generate_stats(MozhiLlamaModel* model,
                                                      MozhiLlamaStats* stats);

/* Aborts every generation running now, on any thread: prompt processing
 * stops as soon as ggml checks (between graph computations, typically
 * within a few milliseconds), and the next mozhi_llama_generate_next()
 * returns MOZHI_LLAMA_E_CANCELLED. Generations begun later are not
 * affected. (MozhiLlamaParams.cancel_flag cancels one generation.) */
MOZHI_LLAMA_EXPORT void mozhi_llama_cancel(void);

/* Frees a string returned by this library (NULL is ignored). */
MOZHI_LLAMA_EXPORT void mozhi_llama_free_string(char* text);

/* Message of the last failure on the calling thread, or NULL when the last
 * call on this thread succeeded. Valid until the next call on this thread. */
MOZHI_LLAMA_EXPORT const char* mozhi_llama_last_error(void);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* MOZHI_LLAMA_H_ */
