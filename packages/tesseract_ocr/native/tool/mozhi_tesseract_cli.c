/*
 * mozhi_tesseract_cli - recognizes the text in a binary PGM (gray) or PPM
 * (RGB) image with libmozhi_tesseract, prints it to stdout and the timings
 * and mean confidence to stderr. For smoke tests and benchmarks (on a
 * device: `adb push` the binary, the library, a traineddata file and an
 * image, then run it in `adb shell`). Not shipped in the app.
 *
 *   mozhi_tesseract_cli [--layout] TESSDATA_DIR LANGUAGES IMAGE.pgm|IMAGE.ppm
 *   e.g. mozhi_tesseract_cli tessdata deu+eng sign.ppm
 *
 * --layout prints the JSON of mozhi_tesseract_recognize_layout() (with
 * words) instead of the text.
 *
 * Convert a photo first, e.g. `convert photo.jpg -resize 2500x2500\> p.ppm`.
 *
 * Copyright (c) 2026 Mozhi contributors. MIT License.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "../src/mozhi_tesseract.h"

static double now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

/* Skips whitespace and '#' comments in a PNM header. */
static void skip_space(FILE* in) {
  int c;
  while ((c = fgetc(in)) != EOF) {
    if (c == '#') {
      while ((c = fgetc(in)) != EOF && c != '\n') {
      }
    } else if (c != ' ' && c != '\t' && c != '\n' && c != '\r') {
      ungetc(c, in);
      return;
    }
  }
}

/* Reads a binary P5 (gray) or P6 (RGB) image with maxval 255. */
static unsigned char* read_pnm(const char* path, int* width, int* height,
                               int* channels) {
  FILE* in = fopen(path, "rb");
  if (in == NULL) {
    fprintf(stderr, "cannot open %s\n", path);
    return NULL;
  }
  char magic[3] = {0};
  int maxval = 0;
  unsigned char* pixels = NULL;
  if (fread(magic, 1, 2, in) != 2 || magic[0] != 'P' ||
      (magic[1] != '5' && magic[1] != '6')) {
    fprintf(stderr, "%s is not a binary PGM/PPM file (P5/P6)\n", path);
    goto done;
  }
  *channels = magic[1] == '5' ? 1 : 3;
  skip_space(in);
  if (fscanf(in, "%d", width) != 1) goto bad;
  skip_space(in);
  if (fscanf(in, "%d", height) != 1) goto bad;
  skip_space(in);
  if (fscanf(in, "%d", &maxval) != 1 || maxval != 255) goto bad;
  fgetc(in); /* the single whitespace before the pixels */
  if (*width <= 0 || *height <= 0 || *width > 16384 || *height > 16384) {
    goto bad;
  }
  size_t size = (size_t)*width * (size_t)*height * (size_t)*channels;
  pixels = malloc(size);
  if (pixels == NULL || fread(pixels, 1, size, in) != size) {
    free(pixels);
    pixels = NULL;
    goto bad;
  }
  goto done;
bad:
  fprintf(stderr, "%s: unsupported or truncated PNM (8-bit P5/P6 only)\n",
          path);
done:
  fclose(in);
  return pixels;
}

int main(int argc, char** argv) {
  int layout = argc == 5 && strcmp(argv[1], "--layout") == 0;
  if (layout) {
    argv++;
    argc--;
  }
  if (argc != 4) {
    fprintf(stderr,
            "usage: %s [--layout] TESSDATA_DIR LANGUAGES IMAGE.pgm|IMAGE.ppm\n"
            "%s\n",
            argv[0], mozhi_tesseract_version());
    return 2;
  }
  int width = 0, height = 0, channels = 0;
  unsigned char* pixels = read_pnm(argv[3], &width, &height, &channels);
  if (pixels == NULL) return 1;

  double start = now_ms();
  MozhiTesseract* engine = mozhi_tesseract_create(argv[1], argv[2]);
  if (engine == NULL) {
    fprintf(stderr, "load failed: %s\n", mozhi_tesseract_last_error());
    free(pixels);
    return 1;
  }
  double loaded = now_ms();
  int32_t confidence = 0;
  char* text =
      layout ? mozhi_tesseract_recognize_layout(engine, pixels, width, height,
                                                channels, width * channels,
                                                MOZHI_TESSERACT_LAYOUT_WORDS)
             : mozhi_tesseract_recognize(engine, pixels, width, height,
                                         channels, width * channels,
                                         &confidence);
  double done = now_ms();
  free(pixels);
  if (text == NULL) {
    fprintf(stderr, "recognize failed: %s\n", mozhi_tesseract_last_error());
    mozhi_tesseract_destroy(engine);
    return 1;
  }
  fputs(text, stdout);
  fprintf(stderr, "%s\nload %s: %.0f ms, recognize %dx%d: %.0f ms, "
          "mean confidence %d%s\n",
          mozhi_tesseract_version(), argv[2], loaded - start, width, height,
          done - loaded, (int)confidence, layout ? " (see the JSON)" : "");
  mozhi_tesseract_free_string(text);
  mozhi_tesseract_destroy(engine);
  return 0;
}
