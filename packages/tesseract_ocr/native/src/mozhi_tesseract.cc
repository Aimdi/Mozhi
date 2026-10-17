// mozhi_tesseract - a minimal C API over the Tesseract OCR engine and
// Leptonica. See mozhi_tesseract.h for the contract.
//
// Copyright (c) 2026 Mozhi contributors. MIT License.

#include "mozhi_tesseract.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <utility>
#include <vector>

#include <allheaders.h>  // Leptonica
#include <tesseract/baseapi.h>
#include <tesseract/publictypes.h>

namespace {

// Largest side and pixel count accepted (Leptonica refuses far larger
// images; the app decodes photos to at most 2500 px on the long side).
constexpr int32_t kMaxSide = 16384;
constexpr int64_t kMaxPixels = 100000000;

// Most languages a handle may load ("deu+eng+fra").
constexpr int kMaxLanguages = 8;

// A first (global Otsu) pass is kept when it finds at least this many
// words with at least this mean confidence; otherwise a second pass with
// Sauvola's adaptive thresholding runs (see RecognizeBest).
constexpr int kGoodPassWords = 3;
constexpr int kGoodPassConfidence = 70;

thread_local std::string tls_error;
thread_local bool tls_has_error = false;

void ClearError() {
  tls_has_error = false;
  tls_error.clear();
}

void SetError(std::string message) {
  tls_error = std::move(message);
  tls_has_error = true;
}

bool IsBlank(const char* value) { return value == nullptr || *value == '\0'; }

// A Tesseract language code as tessdata names its files: three lower-case
// letters, optionally "_" and a three- or four-letter variant ("chi_sim",
// "srp_latn"). Anything else (paths, "..", Tesseract's "~" exclusions) is
// refused, so a code can only name a file directly in the datapath.
bool IsLanguageCode(const std::string& code) {
  auto lower = [](char c) { return c >= 'a' && c <= 'z'; };
  if (code.size() < 3 || !lower(code[0]) || !lower(code[1]) ||
      !lower(code[2])) {
    return false;
  }
  if (code.size() == 3) return true;
  if (code[3] != '_' || code.size() < 7 || code.size() > 8) return false;
  for (size_t i = 4; i < code.size(); ++i) {
    if (!lower(code[i])) return false;
  }
  return true;
}

// Checks `languages` ("deu+eng") and that every file is readable in
// `datapath`; on failure sets the error and returns false.
bool CheckLanguages(const std::string& datapath, const std::string& languages) {
  std::vector<std::string> codes;
  size_t start = 0;
  while (start <= languages.size()) {
    size_t end = languages.find('+', start);
    if (end == std::string::npos) end = languages.size();
    codes.push_back(languages.substr(start, end - start));
    start = end + 1;
  }
  if (codes.size() > static_cast<size_t>(kMaxLanguages)) {
    SetError("more than " + std::to_string(kMaxLanguages) + " languages");
    return false;
  }
  for (const std::string& code : codes) {
    if (!IsLanguageCode(code)) {
      SetError("invalid language code \"" + code + "\" in \"" + languages +
               "\"");
      return false;
    }
  }
  for (const std::string& code : codes) {
    const std::string path = datapath + "/" + code + ".traineddata";
    std::FILE* file = std::fopen(path.c_str(), "rb");
    if (file == nullptr) {
      SetError("no language data for \"" + code + "\" (" + path + ")");
      return false;
    }
    std::fclose(file);
  }
  return true;
}

// Silences Leptonica's error messages (stderr), once per process. Errors
// are reported through return values instead.
void QuietLeptonica() {
  static std::once_flag once;
  std::call_once(once, [] { setMsgSeverity(L_SEVERITY_NONE); });
}

char* CopyString(const char* value) {
  const size_t length = std::strlen(value);
  char* copy = static_cast<char*>(std::malloc(length + 1));
  if (copy == nullptr) {
    SetError("out of memory");
    return nullptr;
  }
  std::memcpy(copy, value, length + 1);
  return copy;
}

// Rec. 601 luma in 8 bits (weights sum to 256).
inline uint8_t Luma(uint32_t r, uint32_t g, uint32_t b) {
  return static_cast<uint8_t>((77 * r + 150 * g + 29 * b) >> 8);
}

struct PixDeleter {
  void operator()(PIX* pix) const { pixDestroy(&pix); }
};
using PixPtr = std::unique_ptr<PIX, PixDeleter>;

// An 8-bit gray Pix of the image (see mozhi_tesseract_recognize for the
// formats); NULL when Leptonica cannot allocate it.
PIX* GrayPix(const uint8_t* pixels, int32_t width, int32_t height,
             int32_t bytes_per_pixel, int32_t bytes_per_line) {
  PIX* pix = pixCreate(width, height, 8);
  if (pix == nullptr) return nullptr;
  l_uint32* data = pixGetData(pix);
  const l_int32 wpl = pixGetWpl(pix);
  for (int32_t y = 0; y < height; ++y) {
    const uint8_t* row = pixels + static_cast<size_t>(y) * bytes_per_line;
    l_uint32* line = data + static_cast<size_t>(y) * wpl;
    switch (bytes_per_pixel) {
      case 1:
        for (int32_t x = 0; x < width; ++x) SET_DATA_BYTE(line, x, row[x]);
        break;
      case 3:
        for (int32_t x = 0; x < width; ++x) {
          const uint8_t* p = row + 3 * x;
          SET_DATA_BYTE(line, x, Luma(p[0], p[1], p[2]));
        }
        break;
      default:  // 4: premultiplied RGBA over white.
        for (int32_t x = 0; x < width; ++x) {
          const uint8_t* p = row + 4 * x;
          const uint32_t value = Luma(p[0], p[1], p[2]) + (255u - p[3]);
          SET_DATA_BYTE(line, x, value > 255 ? 255 : value);
        }
        break;
    }
  }
  return pix;
}

// One recognition of the current image with one thresholding method.
struct Pass {
  std::string text;
  int words = 0;
  int confidence = 0;  // mean word confidence, 0-100
  // Sum of the word confidences: more confidently read text scores higher.
  long score = 0;
};

// Runs Tesseract over `pix` with thresholding method `method` (0 Otsu,
// 2 Sauvola; Tesseract's "thresholding_method"). Returns false and sets
// the error when recognition fails.
bool RunPass(tesseract::TessBaseAPI& api, PIX* pix, const char* method,
             Pass* pass) {
  api.SetVariable("thresholding_method", method);
  // Tesseract keeps its own reference to the image.
  api.SetImage(pix);
  api.SetSourceResolution(MOZHI_TESSERACT_SOURCE_PPI);
  if (api.Recognize(nullptr) != 0) {
    api.Clear();
    SetError("recognition failed");
    return false;
  }
  std::unique_ptr<char[]> text(api.GetUTF8Text());
  std::unique_ptr<int[]> confidences(api.AllWordConfidences());
  pass->text = text == nullptr ? "" : text.get();
  pass->words = 0;
  pass->score = 0;
  for (int i = 0; confidences != nullptr && confidences[i] >= 0; ++i) {
    ++pass->words;
    pass->score += confidences[i];
  }
  pass->confidence =
      pass->words == 0 ? 0 : static_cast<int>(pass->score / pass->words);
  api.Clear();
  return true;
}

// Global Otsu thresholding (Tesseract's default) reads clean scans and
// screenshots best, including light text on dark backgrounds, but loses
// whole regions of a photo with uneven lighting or a shadow. Sauvola's
// adaptive thresholding reads those, but fails on large dark or coloured
// areas. So Otsu runs first, and when it finds little confident text, a
// Sauvola pass too; the pass with the more confident text wins.
bool RecognizeBest(tesseract::TessBaseAPI& api, PIX* pix, Pass* best) {
  if (!RunPass(api, pix, "0", best)) return false;
  if (best->words >= kGoodPassWords &&
      best->confidence >= kGoodPassConfidence) {
    return true;
  }
  Pass sauvola;
  if (!RunPass(api, pix, "2", &sauvola)) return false;
  if (sauvola.score > best->score) *best = std::move(sauvola);
  return true;
}

}  // namespace

struct MozhiTesseract {
  tesseract::TessBaseAPI api;
};

extern "C" {

int32_t mozhi_tesseract_abi_version(void) { return MOZHI_TESSERACT_ABI_VERSION; }

const char* mozhi_tesseract_version(void) {
  static std::once_flag once;
  static std::string version;
  std::call_once(once, [] {
    version = std::string("tesseract ") + tesseract::TessBaseAPI::Version();
    char* leptonica = getLeptonicaVersion();
    if (leptonica != nullptr) {
      version += ", ";
      version += leptonica;
      lept_free(leptonica);
    }
  });
  return version.c_str();
}

MozhiTesseract* mozhi_tesseract_create(const char* datapath,
                                       const char* languages) {
  ClearError();
  if (IsBlank(datapath) || IsBlank(languages)) {
    SetError("datapath and languages are required");
    return nullptr;
  }
  std::string directory(datapath);
  while (directory.size() > 1 && directory.back() == '/') directory.pop_back();
  const std::string codes(languages);
  if (!CheckLanguages(directory, codes)) return nullptr;
  QuietLeptonica();
  try {
    auto engine = std::make_unique<MozhiTesseract>();
#if !defined(_WIN32)
    // Tesseract logs warnings and progress to stderr (tprintf); nobody
    // reads it, and failures are reported through the return values.
    engine->api.SetVariable("debug_file", "/dev/null");
#endif
    if (engine->api.Init(directory.c_str(), codes.c_str(),
                         tesseract::OEM_LSTM_ONLY) != 0) {
      SetError("cannot load the language data for \"" + codes + "\" from " +
               directory);
      return nullptr;
    }
    engine->api.SetPageSegMode(tesseract::PSM_AUTO);
    return engine.release();
  } catch (const std::bad_alloc&) {
    SetError("out of memory");
  } catch (const std::exception& error) {
    SetError(std::string("cannot create the engine: ") + error.what());
  } catch (...) {
    SetError("cannot create the engine");
  }
  return nullptr;
}

void mozhi_tesseract_destroy(MozhiTesseract* engine) {
  ClearError();
  delete engine;
}

char* mozhi_tesseract_recognize(MozhiTesseract* engine, const uint8_t* pixels,
                                int32_t width, int32_t height,
                                int32_t bytes_per_pixel,
                                int32_t bytes_per_line,
                                int32_t* mean_confidence) {
  ClearError();
  if (mean_confidence != nullptr) *mean_confidence = 0;
  if (engine == nullptr || pixels == nullptr) {
    SetError("engine and pixels are required");
    return nullptr;
  }
  if (width <= 0 || height <= 0 || width > kMaxSide || height > kMaxSide ||
      static_cast<int64_t>(width) * height > kMaxPixels) {
    SetError("invalid image size " + std::to_string(width) + "x" +
             std::to_string(height));
    return nullptr;
  }
  if (bytes_per_pixel != 1 && bytes_per_pixel != 3 && bytes_per_pixel != 4) {
    SetError("unsupported bytes_per_pixel " + std::to_string(bytes_per_pixel));
    return nullptr;
  }
  if (bytes_per_line < static_cast<int64_t>(width) * bytes_per_pixel) {
    SetError("bytes_per_line " + std::to_string(bytes_per_line) +
             " is shorter than a row");
    return nullptr;
  }
  try {
    const PixPtr pix(
        GrayPix(pixels, width, height, bytes_per_pixel, bytes_per_line));
    if (pix == nullptr) {
      SetError("out of memory");
      return nullptr;
    }
    Pass pass;
    if (!RecognizeBest(engine->api, pix.get(), &pass)) return nullptr;
    if (mean_confidence != nullptr) *mean_confidence = pass.confidence;
    return CopyString(pass.text.c_str());
  } catch (const std::bad_alloc&) {
    SetError("out of memory");
  } catch (const std::exception& error) {
    SetError(std::string("recognition failed: ") + error.what());
  } catch (...) {
    SetError("recognition failed");
  }
  engine->api.Clear();
  return nullptr;
}

void mozhi_tesseract_free_string(char* text) { std::free(text); }

const char* mozhi_tesseract_last_error(void) {
  return tls_has_error ? tls_error.c_str() : nullptr;
}

}  // extern "C"
