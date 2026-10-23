/*
 * Smoke test and benchmark for libmozhi_llama (not shipped in the app).
 *
 *   mozhi_llama_cli MODEL [options] [PROMPT]
 *
 * Loads MODEL (a GGUF file), prints what the library and the model report,
 * formats PROMPT as one user message with the model's chat template and
 * streams the answer to stdout, then prints the prompt and generation
 * speed to stderr. Without PROMPT only the information is printed.
 *
 * Options:
 *   --system TEXT    a system message before the prompt
 *   --raw            use PROMPT as it is (no chat template; special-token
 *                    text in it is parsed)
 *   --json           JSON output (the built-in grammar)
 *   --max N          tokens to generate at most (default 256)
 *   --ctx N          context size (default 4096, capped at the model's)
 *   --threads N      threads (default: min(4, cores))
 *   --temp T         temperature (default 0.7; 0: greedy)
 *   --top-k N --top-p P --min-p P --repeat-penalty R --repeat-last-n N
 *   --seed S         sampling seed (default random)
 *   --stop TEXT      stop string (repeatable, up to 8)
 *   --no-mmap        read the file into memory instead of mapping it
 *
 * Copyright (c) 2026 Mozhi contributors. MIT License.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "../src/mozhi_llama.h"

static double now_seconds(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static int fail(const char* what) {
  const char* error = mozhi_llama_last_error();
  fprintf(stderr, "%s: %s\n", what, error != NULL ? error : "unknown error");
  return 1;
}

static int usage(const char* program) {
  fprintf(stderr,
          "usage: %s MODEL [--system TEXT] [--raw] [--json] [--max N] "
          "[--ctx N] [--threads N] [--temp T] [--top-k N] [--top-p P] "
          "[--min-p P] [--repeat-penalty R] [--repeat-last-n N] [--seed S] "
          "[--stop TEXT]... [--no-mmap] [PROMPT]\n",
          program);
  return 2;
}

int main(int argc, char** argv) {
  if (argc < 2) return usage(argv[0]);
  const char* model_path = argv[1];
  const char* prompt_text = NULL;
  const char* system_text = NULL;
  const char* stops[8];
  int32_t n_stop = 0;
  int raw = 0;
  int json = 0;
  int32_t n_ctx = 4096;
  int32_t threads = 0;
  int32_t use_mmap = 1;
  MozhiLlamaParams params;
  memset(&params, 0, sizeof(params));
  params.temperature = 0.7f;
  params.top_k = 20;
  params.top_p = 0.6f;
  params.min_p = 0.0f;
  params.repeat_penalty = 1.05f;
  params.repeat_last_n = 64;
  params.seed = MOZHI_LLAMA_RANDOM_SEED;
  params.max_tokens = 256;

  for (int i = 2; i < argc; ++i) {
    const char* arg = argv[i];
    const int has_value = i + 1 < argc;
    if (strcmp(arg, "--raw") == 0) {
      raw = 1;
    } else if (strcmp(arg, "--json") == 0) {
      json = 1;
    } else if (strcmp(arg, "--no-mmap") == 0) {
      use_mmap = 0;
    } else if (strcmp(arg, "--system") == 0 && has_value) {
      system_text = argv[++i];
    } else if (strcmp(arg, "--max") == 0 && has_value) {
      params.max_tokens = atoi(argv[++i]);
    } else if (strcmp(arg, "--ctx") == 0 && has_value) {
      n_ctx = atoi(argv[++i]);
    } else if (strcmp(arg, "--threads") == 0 && has_value) {
      threads = atoi(argv[++i]);
    } else if (strcmp(arg, "--temp") == 0 && has_value) {
      params.temperature = (float)atof(argv[++i]);
    } else if (strcmp(arg, "--top-k") == 0 && has_value) {
      params.top_k = atoi(argv[++i]);
    } else if (strcmp(arg, "--top-p") == 0 && has_value) {
      params.top_p = (float)atof(argv[++i]);
    } else if (strcmp(arg, "--min-p") == 0 && has_value) {
      params.min_p = (float)atof(argv[++i]);
    } else if (strcmp(arg, "--repeat-penalty") == 0 && has_value) {
      params.repeat_penalty = (float)atof(argv[++i]);
    } else if (strcmp(arg, "--repeat-last-n") == 0 && has_value) {
      params.repeat_last_n = atoi(argv[++i]);
    } else if (strcmp(arg, "--seed") == 0 && has_value) {
      params.seed = (uint32_t)strtoul(argv[++i], NULL, 10);
    } else if (strcmp(arg, "--stop") == 0 && has_value) {
      if (n_stop == 8) return usage(argv[0]);
      stops[n_stop++] = argv[++i];
    } else if (strncmp(arg, "--", 2) == 0 || prompt_text != NULL) {
      return usage(argv[0]);
    } else {
      prompt_text = arg;
    }
  }

  printf("engine: %s\ncpu: %s\n", mozhi_llama_version(),
         mozhi_llama_cpu_features());
  double start = now_seconds();
  MozhiLlamaModel* model =
      mozhi_llama_model_load(model_path, threads, n_ctx, use_mmap);
  if (model == NULL) return fail("load");
  char* info = mozhi_llama_model_info(model);
  if (info == NULL) return fail("info");
  printf("model: %s\nloaded in %.2f s\n", info, now_seconds() - start);
  mozhi_llama_free_string(info);
  if (prompt_text == NULL) {
    mozhi_llama_model_free(model);
    return 0;
  }

  if (json) params.grammar = mozhi_llama_json_grammar();
  params.stop = stops;
  params.n_stop = n_stop;

  int32_t begun;
  if (raw) {
    begun = mozhi_llama_generate_begin(model, prompt_text, &params);
  } else {
    /* The messages are tokenized with their text kept plain text. */
    const char* roles[2];
    const char* contents[2];
    int32_t n = 0;
    if (system_text != NULL) {
      roles[n] = "system";
      contents[n++] = system_text;
    }
    roles[n] = "user";
    contents[n++] = prompt_text;
    begun = mozhi_llama_chat_generate_begin(model, roles, contents, n, 1,
                                            &params);
  }
  if (begun != MOZHI_LLAMA_OK) return fail("generate");
  char piece[256];
  int32_t status;
  while ((status = mozhi_llama_generate_next(model, piece, sizeof(piece))) >
         0) {
    fputs(piece, stdout);
    fflush(stdout);
  }
  putchar('\n');
  if (status < 0) {
    fail(status == MOZHI_LLAMA_E_CANCELLED ? "cancelled" : "generate");
  }
  MozhiLlamaStats stats;
  mozhi_llama_generate_stats(model, &stats);
  mozhi_llama_generate_end(model);
  fprintf(stderr,
          "prompt: %d tokens in %.2f s (%.1f tokens/s)\n"
          "answer: %d tokens in %.2f s (%.1f tokens/s), finish %s\n",
          stats.prompt_tokens, stats.prompt_ms / 1000.0,
          stats.prompt_ms > 0 ? stats.prompt_tokens * 1000.0 / stats.prompt_ms
                              : 0.0,
          stats.generated_tokens, stats.generate_ms / 1000.0,
          stats.generate_ms > 0
              ? stats.generated_tokens * 1000.0 / stats.generate_ms
              : 0.0,
          stats.finish_reason == MOZHI_LLAMA_FINISH_STOP     ? "stop"
          : stats.finish_reason == MOZHI_LLAMA_FINISH_LENGTH ? "length"
                                                             : "none");
  mozhi_llama_model_free(model);
  return status < 0 ? 1 : 0;
}
