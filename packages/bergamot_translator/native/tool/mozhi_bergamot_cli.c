/*
 * mozhi_bergamot_cli - translates stdin with libmozhi_bergamot and prints
 * timings to stderr. For smoke tests and benchmarks (on a device:
 * `adb push` the binary, the library and a model, then run it in
 * `adb shell`). Not shipped in the app.
 *
 *   mozhi_bergamot_cli MODEL SHORTLIST VOCAB [TRG_VOCAB] < input.txt
 *   mozhi_bergamot_cli --pivot M1 S1 V1 M2 S2 V2 < input.txt
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

int main(int argc, char** argv) {
  int pivot = argc == 8 && strcmp(argv[1], "--pivot") == 0;
  if (!pivot && argc != 4 && argc != 5) {
    fprintf(stderr,
            "usage: %s MODEL SHORTLIST VOCAB [TRG_VOCAB] < input\n"
            "       %s --pivot M1 S1 V1 M2 S2 V2 < input\n",
            argv[0], argv[0]);
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
