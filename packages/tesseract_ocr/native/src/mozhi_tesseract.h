/*
 * mozhi_tesseract - a minimal C API over the Tesseract OCR engine (LSTM
 * only) and Leptonica, for Dart FFI.
 *
 * Copyright (c) 2026 Mozhi contributors. MIT License (see ../../LICENSE).
 * Tesseract (third_party/tesseract) is Apache-2.0, Leptonica
 * (third_party/leptonica) BSD-2-Clause; see ../THIRD_PARTY_NOTICES.md.
 *
 * Contract:
 *  - All strings are NUL-terminated UTF-8.
 *  - Strings returned by mozhi_tesseract_recognize() and
 *    mozhi_tesseract_recognize_layout() are allocated with malloc() and
 *    must be released with mozhi_tesseract_free_string().
 *  - A handle must not be used by two threads at the same time; separate
 *    handles may be used on separate threads. Call the functions from a
 *    background thread/isolate: creating a handle loads the language data
 *    and recognition takes up to a few seconds.
 *  - Failures return NULL (or 0) and record a message that
 *    mozhi_tesseract_last_error() returns on the same thread. Engine errors
 *    are reported, never thrown across the API.
 *  - Nothing is read from or written to the network, and nothing but the
 *    language data files is read from disk. Tesseract's own log output is
 *    discarded.
 */
#ifndef MOZHI_TESSERACT_H_
#define MOZHI_TESSERACT_H_

#include <stdint.h>

#if defined(_WIN32)
#define MOZHI_TESSERACT_EXPORT __declspec(dllexport)
#else
#define MOZHI_TESSERACT_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Bumped when a function signature changes or a function is added (Dart
 * checks it on load). 2: mozhi_tesseract_recognize_layout(). */
#define MOZHI_TESSERACT_ABI_VERSION 2

/* Resolution recognition assumes (Tesseract needs one to size its
 * filters; photos carry none that is meaningful). */
#define MOZHI_TESSERACT_SOURCE_PPI 300

/* One Tesseract engine with its languages loaded. */
typedef struct MozhiTesseract MozhiTesseract;

/* MOZHI_TESSERACT_ABI_VERSION of the loaded library. */
MOZHI_TESSERACT_EXPORT int32_t mozhi_tesseract_abi_version(void);

/* Engine version, e.g. "tesseract 5.5.3, leptonica-1.87.0". Static
 * storage: do not free. */
MOZHI_TESSERACT_EXPORT const char* mozhi_tesseract_version(void);

/* Loads an engine for `languages`: Tesseract codes joined by '+', e.g.
 * "eng" or "deu+eng" (the first is the main language). Each language needs
 * `<datapath>/<code>.traineddata` (LSTM data, e.g. tessdata_fast). Page
 * segmentation is automatic (PSM_AUTO, no orientation detection).
 * Returns NULL on failure (a missing or unreadable file, an invalid code). */
MOZHI_TESSERACT_EXPORT MozhiTesseract* mozhi_tesseract_create(
    const char* datapath, const char* languages);

/* Releases an engine (NULL is ignored). It must not be in use. */
MOZHI_TESSERACT_EXPORT void mozhi_tesseract_destroy(MozhiTesseract* engine);

/* Recognizes the text in an image of `width` x `height` pixels, rows
 * `bytes_per_line` bytes apart (>= width * bytes_per_pixel), where
 * `bytes_per_pixel` is
 *   1  8-bit gray,
 *   3  RGB,
 *   4  RGBA with premultiplied alpha (dart:ui's ImageByteFormat.rawRgba;
 *      transparent pixels count as white).
 * Colour is converted to gray (Rec. 601 luma). Tesseract thresholds it
 * with Otsu's global method; when that finds fewer than 3 words or a mean
 * confidence below 70 (uneven lighting, a shadow across a photo), a second
 * pass uses Sauvola's adaptive method, and the pass with the more
 * confidently read text is returned. Lines are separated by "\n",
 * paragraphs by an empty line. Writes the mean word confidence (0-100) to
 * *mean_confidence when it is not NULL. Returns a malloc'd string ("" when
 * there is no text) or NULL on failure. */
MOZHI_TESSERACT_EXPORT char* mozhi_tesseract_recognize(
    MozhiTesseract* engine, const uint8_t* pixels, int32_t width,
    int32_t height, int32_t bytes_per_pixel, int32_t bytes_per_line,
    int32_t* mean_confidence);

/* mozhi_tesseract_recognize_layout() flags. */
/* Also report every word (text, box, confidence) of each line. */
#define MOZHI_TESSERACT_LAYOUT_WORDS 1

/* Like mozhi_tesseract_recognize() (same arguments, thresholding passes and
 * text), but returns the text together with where it is in the image, as
 * one malloc'd JSON object (UTF-8):
 *
 *   {"text": "...",            the text mozhi_tesseract_recognize() returns
 *    "confidence": 87,         mean word confidence, 0-100
 *    "width": 1200, "height": 800,   the image size (pixels)
 *    "blocks": [               text blocks in reading order
 *      {"box": [l, t, r, b], "confidence": 90,
 *       "orientation": 0,      0, 90, 180 or 270: clockwise rotation of the
 *                              text from upright, as layout analysis sees
 *                              it (no orientation detection: usually 0)
 *       "vertical": false,     top-to-bottom writing (vertical CJK)
 *       "deskew": -1.5,        degrees to rotate the block anti-clockwise
 *                              for it to be level (-45 to 45)
 *       "paragraphs": [
 *         {"box": [...], "confidence": 91,
 *          "ltr": true,        left-to-right script (false: Arabic, Hebrew)
 *          "align": "left",    left, center, right or unknown
 *          "background": 16777215, "foreground": 0,   0xRRGGBB, see below
 *          "lines": [
 *            {"box": [...], "confidence": 92,
 *             "baseline": [x1, y1, x2, y2],
 *             "text": "Opening hours",
 *             "words": [{"box": [...], "confidence": 95, "text": "..."}]}
 *          ]}
 *       ]}
 *    ]}
 *
 * Boxes are [left, top, right, bottom] in pixels of the image, from the
 * top-left corner of the first pixel to the bottom-right corner of the
 * last one (right and bottom exclusive). Lines are in reading order, also
 * for right-to-left scripts. "words" is present with
 * MOZHI_TESSERACT_LAYOUT_WORDS. "background" and "foreground" are the
 * median colours of the pixels inside the paragraph's box that Tesseract's
 * thresholding counted as background and as text (the larger share is the
 * background, so light text on a dark ground works too); they are left out
 * when unknown. Returns NULL on failure. */
MOZHI_TESSERACT_EXPORT char* mozhi_tesseract_recognize_layout(
    MozhiTesseract* engine, const uint8_t* pixels, int32_t width,
    int32_t height, int32_t bytes_per_pixel, int32_t bytes_per_line,
    int32_t flags);

/* Frees a string returned by this library (NULL is ignored). */
MOZHI_TESSERACT_EXPORT void mozhi_tesseract_free_string(char* text);

/* Message of the last failure on the calling thread, or NULL when the last
 * call on this thread succeeded. Valid until the next call on this thread. */
MOZHI_TESSERACT_EXPORT const char* mozhi_tesseract_last_error(void);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* MOZHI_TESSERACT_H_ */
