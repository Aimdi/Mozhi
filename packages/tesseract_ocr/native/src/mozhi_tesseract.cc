// mozhi_tesseract - a minimal C API over the Tesseract OCR engine and
// Leptonica. See mozhi_tesseract.h for the contract.
//
// Copyright (c) 2026 Mozhi contributors. MIT License.

#include "mozhi_tesseract.h"

#include <algorithm>
#include <array>
#include <cmath>
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
#include <tesseract/resultiterator.h>

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

// The caller's pixels (see mozhi_tesseract_recognize for the formats),
// for sampling the colours of the text and its background.
struct Source {
  const uint8_t* pixels;
  int32_t width;
  int32_t height;
  int32_t bytes_per_pixel;
  int32_t bytes_per_line;
};

// What a layout pass reports besides the text (see
// mozhi_tesseract_recognize_layout).
struct LayoutRequest {
  Source source;
  bool words;
};

// The RGB colour of pixel (x, y) of `source`; premultiplied RGBA counts as
// composited over white, like for recognition.
inline void ReadRgb(const Source& source, int32_t x, int32_t y,
                    uint8_t rgb[3]) {
  const uint8_t* p = source.pixels +
                     static_cast<size_t>(y) * source.bytes_per_line +
                     static_cast<size_t>(x) * source.bytes_per_pixel;
  switch (source.bytes_per_pixel) {
    case 1:
      rgb[0] = rgb[1] = rgb[2] = p[0];
      break;
    case 3:
      rgb[0] = p[0];
      rgb[1] = p[1];
      rgb[2] = p[2];
      break;
    default: {  // 4: premultiplied RGBA over white.
      const uint32_t white = 255u - p[3];
      for (int c = 0; c < 3; ++c) {
        const uint32_t value = p[c] + white;
        rgb[c] = static_cast<uint8_t>(value > 255 ? 255 : value);
      }
      break;
    }
  }
}

constexpr double kPi = 3.14159265358979323846;

// Most pixels a paragraph's colours are sampled from (larger boxes are
// sampled on a grid).
constexpr int64_t kMaxColourSamples = 1 << 20;

// The median of a 256-bin histogram holding `count` values.
uint32_t Median(const std::array<uint32_t, 256>& histogram, uint64_t count) {
  uint64_t seen = 0;
  for (uint32_t value = 0; value < 256; ++value) {
    seen += histogram[value];
    if (seen * 2 >= count) return value;
  }
  return 255;
}

// The median colours (0xRRGGBB) of the background and of the text inside
// the box [left, right) x [top, bottom) of `source`, told apart by
// Tesseract's thresholded image `binary` (1 = ink); the larger share is
// the background. False when either is unknown.
bool SampleColours(const Source& source, PIX* binary, int left, int top,
                   int right, int bottom, uint32_t* background,
                   uint32_t* foreground) {
  if (binary == nullptr || pixGetDepth(binary) != 1) return false;
  left = std::max(left, 0);
  top = std::max(top, 0);
  right = std::min(right, static_cast<int>(source.width));
  bottom = std::min(bottom, static_cast<int>(source.height));
  if (right <= left || bottom <= top) return false;
  const int64_t area = static_cast<int64_t>(right - left) * (bottom - top);
  int step = 1;
  while (area / (static_cast<int64_t>(step) * step) > kMaxColourSamples) {
    ++step;
  }
  // The thresholded image may be scaled (GetThresholdedImageScaleFactor).
  const int64_t binary_width = pixGetWidth(binary);
  const int64_t binary_height = pixGetHeight(binary);
  const l_uint32* data = pixGetData(binary);
  const l_int32 wpl = pixGetWpl(binary);
  // [ink][channel][value]
  std::array<std::array<std::array<uint32_t, 256>, 3>, 2> histograms{};
  std::array<uint64_t, 2> counts{};
  uint8_t rgb[3];
  for (int y = top; y < bottom; y += step) {
    const int64_t by = y * binary_height / source.height;
    const l_uint32* line = data + by * wpl;
    for (int x = left; x < right; x += step) {
      const int64_t bx = x * binary_width / source.width;
      const int ink = GET_DATA_BIT(line, bx) ? 1 : 0;
      ReadRgb(source, x, y, rgb);
      for (int c = 0; c < 3; ++c) ++histograms[ink][c][rgb[c]];
      ++counts[ink];
    }
  }
  if (counts[0] == 0 || counts[1] == 0) return false;
  const int ground = counts[1] > counts[0] ? 1 : 0;
  auto colour = [&](int ink) {
    uint32_t value = 0;
    for (int c = 0; c < 3; ++c) {
      value = (value << 8) | Median(histograms[ink][c], counts[ink]);
    }
    return value;
  };
  *background = colour(ground);
  *foreground = colour(1 - ground);
  return true;
}

// Appends `text` as a JSON string.
void AppendJsonString(std::string* out, const char* text) {
  *out += '"';
  for (const unsigned char* p = reinterpret_cast<const unsigned char*>(text);
       *p != '\0'; ++p) {
    switch (*p) {
      case '"':
        *out += "\\\"";
        break;
      case '\\':
        *out += "\\\\";
        break;
      case '\n':
        *out += "\\n";
        break;
      case '\r':
        *out += "\\r";
        break;
      case '\t':
        *out += "\\t";
        break;
      default:
        if (*p < 0x20) {
          char escaped[8];
          std::snprintf(escaped, sizeof escaped, "\\u%04x", *p);
          *out += escaped;
        } else {
          *out += static_cast<char>(*p);
        }
    }
  }
  *out += '"';
}

void AppendInt(std::string* out, long value) { *out += std::to_string(value); }

// Appends `value` with one decimal, independent of the C locale.
void AppendTenths(std::string* out, double value) {
  const long tenths = std::lround(value * 10);
  if (tenths < 0) *out += '-';
  const long magnitude = tenths < 0 ? -tenths : tenths;
  AppendInt(out, magnitude / 10);
  *out += '.';
  AppendInt(out, magnitude % 10);
}

// Appends `"key": [l, t, r, b]` of the iterator's object at `level`.
void AppendBox(std::string* out, const tesseract::ResultIterator& it,
               tesseract::PageIteratorLevel level, int box[4]) {
  box[0] = box[1] = box[2] = box[3] = 0;
  it.BoundingBox(level, &box[0], &box[1], &box[2], &box[3]);
  *out += "\"box\":[";
  for (int i = 0; i < 4; ++i) {
    if (i > 0) *out += ',';
    AppendInt(out, box[i]);
  }
  *out += ']';
}

void AppendConfidence(std::string* out, const tesseract::ResultIterator& it,
                      tesseract::PageIteratorLevel level) {
  const float confidence = it.Confidence(level);
  *out += ",\"confidence\":";
  AppendInt(out, std::lround(std::clamp(confidence, 0.0f, 100.0f)));
}

// The text of the iterator's object at `level` without the trailing line
// breaks and spaces Tesseract adds.
std::string TextAt(const tesseract::ResultIterator& it,
                   tesseract::PageIteratorLevel level) {
  std::unique_ptr<char[]> text(it.GetUTF8Text(level));
  std::string value = text == nullptr ? "" : text.get();
  while (!value.empty() &&
         (value.back() == '\n' || value.back() == ' ' || value.back() == '\r')) {
    value.pop_back();
  }
  return value;
}

const char* AlignmentName(tesseract::ParagraphJustification justification) {
  switch (justification) {
    case tesseract::JUSTIFICATION_LEFT:
      return "left";
    case tesseract::JUSTIFICATION_CENTER:
      return "center";
    case tesseract::JUSTIFICATION_RIGHT:
      return "right";
    default:
      return "unknown";
  }
}

// The "blocks" array of mozhi_tesseract_recognize_layout for the current
// recognition result (see the header for the format).
std::string LayoutBlocks(tesseract::TessBaseAPI& api,
                         const LayoutRequest& request) {
  std::unique_ptr<tesseract::ResultIterator> it(api.GetIterator());
  if (it == nullptr) return "[]";
  const PixPtr binary(api.GetThresholdedImage());
  std::string out = "[";
  bool block_open = false, paragraph_open = false, line_open = false;
  bool first_block = true, first_paragraph = true, first_line = true;
  bool first_word = true;
  auto close_line = [&] {
    if (!line_open) return;
    if (request.words) out += ']';
    out += '}';
    line_open = false;
  };
  auto close_paragraph = [&] {
    close_line();
    if (!paragraph_open) return;
    out += "]}";
    paragraph_open = false;
  };
  auto close_block = [&] {
    close_paragraph();
    if (!block_open) return;
    out += "]}";
    block_open = false;
  };
  int box[4];
  it->Begin();
  do {
    if (it->Empty(tesseract::RIL_WORD)) continue;
    if (it->IsAtBeginningOf(tesseract::RIL_BLOCK) || !block_open) {
      close_block();
      if (!first_block) out += ',';
      first_block = false;
      out += '{';
      AppendBox(&out, *it, tesseract::RIL_BLOCK, box);
      AppendConfidence(&out, *it, tesseract::RIL_BLOCK);
      tesseract::Orientation orientation = tesseract::ORIENTATION_PAGE_UP;
      tesseract::WritingDirection direction =
          tesseract::WRITING_DIRECTION_LEFT_TO_RIGHT;
      tesseract::TextlineOrder order = tesseract::TEXTLINE_ORDER_TOP_TO_BOTTOM;
      float deskew = 0;
      it->Orientation(&orientation, &direction, &order, &deskew);
      out += ",\"orientation\":";
      AppendInt(&out, 90L * static_cast<int>(orientation));
      out += ",\"vertical\":";
      out += direction == tesseract::WRITING_DIRECTION_TOP_TO_BOTTOM
                 ? "true"
                 : "false";
      out += ",\"deskew\":";
      AppendTenths(&out, deskew * 180.0 / kPi);
      out += ",\"paragraphs\":[";
      block_open = true;
      first_paragraph = true;
    }
    if (it->IsAtBeginningOf(tesseract::RIL_PARA) || !paragraph_open) {
      close_paragraph();
      if (!first_paragraph) out += ',';
      first_paragraph = false;
      out += '{';
      AppendBox(&out, *it, tesseract::RIL_PARA, box);
      AppendConfidence(&out, *it, tesseract::RIL_PARA);
      out += ",\"ltr\":";
      out += it->ParagraphIsLtr() ? "true" : "false";
      tesseract::ParagraphJustification justification =
          tesseract::JUSTIFICATION_UNKNOWN;
      bool is_list_item = false, is_crown = false;
      int first_line_indent = 0;
      it->ParagraphInfo(&justification, &is_list_item, &is_crown,
                        &first_line_indent);
      out += ",\"align\":\"";
      out += AlignmentName(justification);
      out += '"';
      uint32_t background = 0, foreground = 0;
      if (SampleColours(request.source, binary.get(), box[0], box[1], box[2],
                        box[3], &background, &foreground)) {
        out += ",\"background\":";
        AppendInt(&out, background);
        out += ",\"foreground\":";
        AppendInt(&out, foreground);
      }
      out += ",\"lines\":[";
      paragraph_open = true;
      first_line = true;
    }
    if (it->IsAtBeginningOf(tesseract::RIL_TEXTLINE) || !line_open) {
      close_line();
      if (!first_line) out += ',';
      first_line = false;
      out += '{';
      AppendBox(&out, *it, tesseract::RIL_TEXTLINE, box);
      AppendConfidence(&out, *it, tesseract::RIL_TEXTLINE);
      int x1 = 0, y1 = 0, x2 = 0, y2 = 0;
      if (it->Baseline(tesseract::RIL_TEXTLINE, &x1, &y1, &x2, &y2)) {
        out += ",\"baseline\":[";
        AppendInt(&out, x1);
        out += ',';
        AppendInt(&out, y1);
        out += ',';
        AppendInt(&out, x2);
        out += ',';
        AppendInt(&out, y2);
        out += ']';
      }
      out += ",\"text\":";
      AppendJsonString(&out, TextAt(*it, tesseract::RIL_TEXTLINE).c_str());
      if (request.words) out += ",\"words\":[";
      line_open = true;
      first_word = true;
    }
    if (request.words) {
      if (!first_word) out += ',';
      first_word = false;
      out += '{';
      AppendBox(&out, *it, tesseract::RIL_WORD, box);
      AppendConfidence(&out, *it, tesseract::RIL_WORD);
      out += ",\"text\":";
      AppendJsonString(&out, TextAt(*it, tesseract::RIL_WORD).c_str());
      out += '}';
    }
  } while (it->Next(tesseract::RIL_WORD));
  close_block();
  out += ']';
  return out;
}

// One recognition of the current image with one thresholding method.
struct Pass {
  std::string text;
  int words = 0;
  int confidence = 0;  // mean word confidence, 0-100
  // Sum of the word confidences: more confidently read text scores higher.
  long score = 0;
  // The "blocks" JSON array when a layout was requested.
  std::string blocks;
};

// Runs Tesseract over `pix` with thresholding method `method` (0 Otsu,
// 2 Sauvola; Tesseract's "thresholding_method"), with the layout when
// `layout` is not NULL. Returns false and sets the error when recognition
// fails.
bool RunPass(tesseract::TessBaseAPI& api, PIX* pix, const char* method,
             const LayoutRequest* layout, Pass* pass) {
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
  pass->blocks = layout == nullptr ? "" : LayoutBlocks(api, *layout);
  api.Clear();
  return true;
}

// Global Otsu thresholding (Tesseract's default) reads clean scans and
// screenshots best, including light text on dark backgrounds, but loses
// whole regions of a photo with uneven lighting or a shadow. Sauvola's
// adaptive thresholding reads those, but fails on large dark or coloured
// areas. So Otsu runs first, and when it finds little confident text, a
// Sauvola pass too; the pass with the more confident text wins.
bool RecognizeBest(tesseract::TessBaseAPI& api, PIX* pix,
                   const LayoutRequest* layout, Pass* best) {
  if (!RunPass(api, pix, "0", layout, best)) return false;
  if (best->words >= kGoodPassWords &&
      best->confidence >= kGoodPassConfidence) {
    return true;
  }
  Pass sauvola;
  if (!RunPass(api, pix, "2", layout, &sauvola)) return false;
  if (sauvola.score > best->score) *best = std::move(sauvola);
  return true;
}

// Checks the arguments shared by the recognize functions; on failure sets
// the error and returns false.
bool CheckImage(const MozhiTesseract* engine, const uint8_t* pixels,
                int32_t width, int32_t height, int32_t bytes_per_pixel,
                int32_t bytes_per_line) {
  if (engine == nullptr || pixels == nullptr) {
    SetError("engine and pixels are required");
    return false;
  }
  if (width <= 0 || height <= 0 || width > kMaxSide || height > kMaxSide ||
      static_cast<int64_t>(width) * height > kMaxPixels) {
    SetError("invalid image size " + std::to_string(width) + "x" +
             std::to_string(height));
    return false;
  }
  if (bytes_per_pixel != 1 && bytes_per_pixel != 3 && bytes_per_pixel != 4) {
    SetError("unsupported bytes_per_pixel " + std::to_string(bytes_per_pixel));
    return false;
  }
  if (bytes_per_line < static_cast<int64_t>(width) * bytes_per_pixel) {
    SetError("bytes_per_line " + std::to_string(bytes_per_line) +
             " is shorter than a row");
    return false;
  }
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
  if (!CheckImage(engine, pixels, width, height, bytes_per_pixel,
                  bytes_per_line)) {
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
    if (!RecognizeBest(engine->api, pix.get(), nullptr, &pass)) return nullptr;
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

char* mozhi_tesseract_recognize_layout(MozhiTesseract* engine,
                                       const uint8_t* pixels, int32_t width,
                                       int32_t height, int32_t bytes_per_pixel,
                                       int32_t bytes_per_line, int32_t flags) {
  ClearError();
  if (!CheckImage(engine, pixels, width, height, bytes_per_pixel,
                  bytes_per_line)) {
    return nullptr;
  }
  try {
    const PixPtr pix(
        GrayPix(pixels, width, height, bytes_per_pixel, bytes_per_line));
    if (pix == nullptr) {
      SetError("out of memory");
      return nullptr;
    }
    const LayoutRequest layout{
        Source{pixels, width, height, bytes_per_pixel, bytes_per_line},
        (flags & MOZHI_TESSERACT_LAYOUT_WORDS) != 0};
    Pass pass;
    if (!RecognizeBest(engine->api, pix.get(), &layout, &pass)) return nullptr;
    std::string json = "{\"text\":";
    AppendJsonString(&json, pass.text.c_str());
    json += ",\"confidence\":";
    AppendInt(&json, pass.confidence);
    json += ",\"width\":";
    AppendInt(&json, width);
    json += ",\"height\":";
    AppendInt(&json, height);
    json += ",\"blocks\":";
    json += pass.blocks;
    json += '}';
    return CopyString(json.c_str());
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
