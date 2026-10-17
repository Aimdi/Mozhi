/*
 * mozhi_bergamot_cli - translates stdin with libmozhi_bergamot and prints
 * timings to stderr. For smoke tests and benchmarks (on a device:
 * `adb push` the binary, the library and a model, then run it in
 * `adb shell`). Not shipped in the app.
 *
 *   mozhi_bergamot_cli MODEL SHORTLIST VOCAB [TRG_VOCAB] < input.txt
 *   mozhi_bergamot_cli --pivot M1 S1 V1 M2 S2 V2 < input.txt
 *   mozhi_bergamot_cli --detect < lines.txt   (language of each line, CLD2)
 *
 * Copyright (c) 2026 Mozhi contributors. MIT License.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "../src/mozhi_bergamot.h"

static double now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

static char* read_all(FILE* in) {
  size_t size = 0, capacity = 1 << 16;
  char* buffer = malloc(capacity);
  size_t n;
  while (buffer && (n = fread(buffer + size, 1, capacity - size - 1, in)) > 0) {
    size += n;
    if (capacity - size < 2) {
      capacity *= 2;
      buffer = realloc(buffer, capacity);
    }
  }
  if (buffer) buffer[size] = '\0';
  return buffer;
}

static MozhiBergamotModel* load(const char* model, const char* shortlist,
                                const char* vocab, const char* trg_vocab) {
  double start = now_ms();
  MozhiBergamotModel* handle =
      mozhi_bergamot_model_create(model, shortlist, vocab, trg_vocab, NULL);
  if (handle == NULL) {
    fprintf(stderr, "load failed: %s\n", mozhi_bergamot_last_error());
    exit(1);
  }
  fprintf(stderr, "load %s: %.0f ms\n", model, now_ms() - start);
  return handle;
}

static void print_detection(const char* mode,
                            const MozhiBergamotDetection* detection) {
  printf("\t%s %s%s", mode, detection->language,
         detection->reliable ? "" : "?");
  for (int i = 0; i < 3; i++) {
    const MozhiBergamotLanguage* language = &detection->languages[i];
    if (strcmp(language->code, "un") == 0) break;
    printf(" %s:%d%%/%d", language->code, (int)language->percent,
           (int)language->score);
  }
}

/* Identifies the language of every line of stdin: CLD2's answer, then its
 * best-effort guess ("?" = not reliable; code:percent/score), and the time
 * per line. */
static int detect_lines(void) {
  char line[16384];
  double total = 0;
  int lines = 0;
  while (fgets(line, sizeof line, stdin) != NULL) {
    size_t length = strlen(line);
    while (length > 0 && (line[length - 1] == '\n' || line[length - 1] == '\r')) {
      line[--length] = '\0';
    }
    MozhiBergamotDetection precise, guess;
    double start = now_ms();
    if (!mozhi_bergamot_detect(line, (int32_t)length, NULL, 0, &precise) ||
        !mozhi_bergamot_detect(line, (int32_t)length, NULL,
                               MOZHI_BERGAMOT_DETECT_BEST_EFFORT, &guess)) {
      fprintf(stderr, "detect failed: %s\n", mozhi_bergamot_last_error());
      return 1;
    }
    double elapsed = now_ms() - start;
    total += elapsed;
    lines++;
    printf("%s", line);
    print_detection("cld2", &precise);
    print_detection("guess", &guess);
    printf("\t%.3f ms\n", elapsed);
  }
  if (lines > 0) {
    fprintf(stderr, "%d lines, %.3f ms per line (both passes)\n", lines,
            total / lines);
  }
  return 0;
}

int main(int argc, char** argv) {
  if (argc == 2 && strcmp(argv[1], "--detect") == 0) return detect_lines();
  int pivot = argc == 8 && strcmp(argv[1], "--pivot") == 0;
  if (!pivot && argc != 4 && argc != 5) {
    fprintf(stderr,
            "usage: %s MODEL SHORTLIST VOCAB [TRG_VOCAB] < input\n"
            "       %s --pivot M1 S1 V1 M2 S2 V2 < input\n"
            "       %s --detect < lines\n",
            argv[0], argv[0], argv[0]);
    return 2;
  }
  fprintf(stderr, "%s (ABI %d)\n", mozhi_bergamot_version(),
          mozhi_bergamot_abi_version());
  char* input = read_all(stdin);
  if (input == NULL) return 1;

  MozhiBergamotModel* first =
      pivot ? load(argv[2], argv[3], argv[4], NULL)
            : load(argv[1], argv[2], argv[3], argc == 5 ? argv[4] : NULL);
  MozhiBergamotModel* second = pivot ? load(argv[5], argv[6], argv[7], NULL)
                                     : NULL;

  for (int run = 0; run < 2; run++) {
    double start = now_ms();
    char* output = pivot ? mozhi_bergamot_translate_pivot(first, second, input, 0)
                         : mozhi_bergamot_translate(first, input, 0);
    if (output == NULL) {
      fprintf(stderr, "translate failed: %s\n", mozhi_bergamot_last_error());
      return 1;
    }
    /* Run 0 includes lazy graph initialisation; run 1 hits the cache. */
    fprintf(stderr, "translate (run %d): %.0f ms\n", run, now_ms() - start);
    if (run == 0) printf("%s\n", output);
    mozhi_bergamot_free_string(output);
  }
  mozhi_bergamot_model_destroy(second);
  mozhi_bergamot_model_destroy(first);
  free(input);
  return 0;
}
