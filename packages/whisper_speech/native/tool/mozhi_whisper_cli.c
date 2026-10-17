/*
 * Smoke test and benchmark for libmozhi_whisper (not shipped in the app).
 *
 *   mozhi_whisper_cli MODEL [WAV|--silence SECONDS] [LANGUAGE] [THREADS]
 *
 * WAV must be 16 kHz mono 16-bit PCM (e.g. third_party/whisper.cpp/samples/
 * jfk.wav, or `ffmpeg -i in.mp3 -ar 16000 -ac 1 -c:a pcm_s16le out.wav`).
 * LANGUAGE is a Whisper code or "auto" (default). Prints the detected
 * language, the text and the time taken.
 *
 * Copyright (c) 2026 Mozhi contributors. MIT License.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "../src/mozhi_whisper.h"

static double now_seconds(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

/* Reads the "data" chunk of a 16-bit PCM WAV file into floats. */
static float* read_wav(const char* path, int32_t* count) {
  FILE* file = fopen(path, "rb");
  if (file == NULL) return NULL;
  unsigned char header[12];
  if (fread(header, 1, 12, file) != 12 || memcmp(header, "RIFF", 4) != 0 ||
      memcmp(header + 8, "WAVE", 4) != 0) {
    fclose(file);
    return NULL;
  }
  unsigned char chunk[8];
  while (fread(chunk, 1, 8, file) == 8) {
    uint32_t size = (uint32_t)chunk[4] | ((uint32_t)chunk[5] << 8) |
                    ((uint32_t)chunk[6] << 16) | ((uint32_t)chunk[7] << 24);
    if (memcmp(chunk, "data", 4) != 0) {
      fseek(file, (long)(size + (size & 1)), SEEK_CUR);
      continue;
    }
    int32_t n = (int32_t)(size / 2);
    int16_t* pcm = malloc((size_t)n * sizeof(int16_t));
    float* samples = malloc((size_t)n * sizeof(float));
    if (pcm == NULL || samples == NULL ||
        fread(pcm, sizeof(int16_t), (size_t)n, file) != (size_t)n) {
      free(pcm);
      free(samples);
      fclose(file);
      return NULL;
    }
    for (int32_t i = 0; i < n; ++i) samples[i] = (float)pcm[i] / 32768.0f;
    free(pcm);
    fclose(file);
    *count = n;
    return samples;
  }
  fclose(file);
  return NULL;
}

int main(int argc, char** argv) {
  if (argc < 2) {
    fprintf(stderr,
            "usage: %s MODEL [WAV|--silence SECONDS] [LANGUAGE] [THREADS]\n",
            argv[0]);
    return 2;
  }
  int arg = 2;
  int32_t count = 0;
  float* samples = NULL;
  if (argc > arg && strcmp(argv[arg], "--silence") == 0 && argc > arg + 1) {
    count = (int32_t)(atof(argv[arg + 1]) * MOZHI_WHISPER_SAMPLE_RATE);
    samples = calloc((size_t)(count > 0 ? count : 1), sizeof(float));
    arg += 2;
  } else if (argc > arg) {
    samples = read_wav(argv[arg], &count);
    if (samples == NULL) {
      fprintf(stderr, "cannot read %s (16-bit PCM WAV expected)\n", argv[arg]);
      return 1;
    }
    arg += 1;
  } else {
    count = MOZHI_WHISPER_SAMPLE_RATE;  // 1 s of silence
    samples = calloc((size_t)count, sizeof(float));
  }
  const char* language = argc > arg ? argv[arg] : "auto";
  const int32_t threads = argc > arg + 1 ? atoi(argv[arg + 1]) : 0;

  printf("%s (ABI %d)\n", mozhi_whisper_version(), mozhi_whisper_abi_version());
  double start = now_seconds();
  MozhiWhisperModel* model = mozhi_whisper_model_load(argv[1], threads);
  if (model == NULL) {
    fprintf(stderr, "load failed: %s\n", mozhi_whisper_last_error());
    free(samples);
    return 1;
  }
  printf("loaded in %.2f s (multilingual: %d)\n", now_seconds() - start,
         mozhi_whisper_model_is_multilingual(model));

  char detected[MOZHI_WHISPER_LANGUAGE_SIZE];
  start = now_seconds();
  char* text = mozhi_whisper_transcribe(model, samples, count, language,
                                        threads, detected, sizeof detected);
  const double elapsed = now_seconds() - start;
  int status = 0;
  if (text == NULL) {
    fprintf(stderr, "transcribe failed: %s\n", mozhi_whisper_last_error());
    status = 1;
  } else {
    printf("%.2f s of audio in %.2f s, language \"%s\"\n",
           (double)count / MOZHI_WHISPER_SAMPLE_RATE, elapsed, detected);
    printf("text: \"%s\"\n", text);
    mozhi_whisper_free_string(text);
  }
  mozhi_whisper_model_free(model);
  free(samples);
  return status;
}
