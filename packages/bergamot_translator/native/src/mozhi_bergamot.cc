// mozhi_bergamot - a minimal C API over Mozilla's Firefox Translations
// (Bergamot) inference engine and the CLD2 language identifier. See
// mozhi_bergamot.h for the contract.
//
// Copyright (c) 2026 Mozhi contributors. MIT License.

#include "mozhi_bergamot.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <memory>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#include "compact_lang_det.h"  // CLD2 (third_party/cld2/public)
#include "encodings.h"
#include "common/logging.h"
#include "translator/parser.h"
#include "translator/response.h"
#include "translator/response_options.h"
#include "translator/service.h"
#include "translator/translation_model.h"

#ifndef MOZHI_BERGAMOT_ENGINE_VERSION
#define MOZHI_BERGAMOT_ENGINE_VERSION "unknown"
#endif

namespace {

using marian::bergamot::AnnotatedText;
using marian::bergamot::BlockingService;
using marian::bergamot::ByteRange;
using marian::bergamot::Response;
using marian::bergamot::ResponseOptions;
using marian::bergamot::TranslationModel;

// Number of translated sentences kept per process (keyed by model and
// sentence), so re-translating edited text only translates what changed.
constexpr size_t kCacheSize = 2048;

// Defaults used by Firefox and by Mozilla's evaluation of these models
// (mozilla/translations pipeline/eval/translators.py), except skip-cost:
// Firefox skips the softmax (skip-cost: true), which leaves raw logits as
// word scores. The quality scores (MOZHI_BERGAMOT_TRANSLATE_QUALITY) need
// log-probabilities. With beam-size 1 the softmax only shifts every step's
// scores by a constant, so the translation stays the same except for rare
// near ties (53 of 54 paragraphs identical en->de/en->es), ~3% slower.
constexpr const char* kDefaultConfig =
    "beam-size: 1\n"
    "normalize: 1.0\n"
    "word-penalty: 0\n"
    "max-length-break: 128\n"
    "mini-batch-words: 1024\n"
    "workspace: 128\n"
    "max-length-factor: 2.0\n"
    "skip-cost: false\n"
    "cpu-threads: 0\n"
    "quiet: true\n"
    "quiet-translation: true\n"
    "alignment: soft\n";

thread_local std::string tls_error;
thread_local bool tls_has_error = false;

// Guards g_service, g_live_models and every engine call: BlockingService and
// TranslationModel are not thread-safe, and Marian's loggers are global
// (only one service may exist at a time).
// g_service is deliberately a raw pointer: a static destructor would run at
// process exit after Marian's own statics (spdlog's registry) are gone.
std::mutex g_mutex;
BlockingService* g_service = nullptr;
size_t g_live_models = 0;

void ClearError() {
  tls_has_error = false;
  tls_error.clear();
}

void SetError(std::string message) {
  tls_error = std::move(message);
  tls_has_error = true;
}

bool IsBlank(const char* value) { return value == nullptr || *value == '\0'; }

// A single-quoted YAML scalar (quotes are doubled).
std::string YamlQuote(const std::string& value) {
  std::string quoted = "'";
  for (char c : value) {
    if (c == '\'') quoted += '\'';
    quoted += c;
  }
  quoted += '\'';
  return quoted;
}

// The service is created with the first model and destroyed with the last
// one, which also releases Marian's global loggers. Requires g_mutex.
BlockingService& Service() {
  if (g_service == nullptr) {
    BlockingService::Config config;
    config.cacheSize = kCacheSize;
    config.logger.level = "off";
    g_service = new BlockingService(config);
  }
  return *g_service;
}

char* CopyString(const std::string& value) {
  char* copy = static_cast<char*>(std::malloc(value.size() + 1));
  if (copy == nullptr) {
    SetError("out of memory");
    return nullptr;
  }
  std::memcpy(copy, value.data(), value.size());
  copy[value.size()] = '\0';
  return copy;
}

std::string BuildConfig(const char* model_path, const char* shortlist_path,
                        const char* src_vocab_path, const char* trg_vocab_path,
                        const char* extra_config) {
  const std::string model(model_path);
  const std::string extra = IsBlank(extra_config) ? "" : extra_config;
  const std::string src_vocab = YamlQuote(src_vocab_path);
  const std::string trg_vocab =
      IsBlank(trg_vocab_path) ? src_vocab : YamlQuote(trg_vocab_path);

  std::string config = kDefaultConfig;
  config += "models:\n  - " + YamlQuote(model) + "\n";
  config += "vocabs:\n  - " + src_vocab + "\n  - " + trg_vocab + "\n";
  if (!IsBlank(shortlist_path)) {
    // [path, check]: binary shortlists are not re-validated on load.
    config += "shortlist:\n  - " + YamlQuote(shortlist_path) + "\n  - false\n";
  }
  if (extra.find("gemm-precision") == std::string::npos) {
    const bool alphas = model.find("alphas") != std::string::npos;
    config += alphas ? "gemm-precision: int8shiftAlphaAll\n"
                     : "gemm-precision: int8shiftAll\n";
  }
  if (!extra.empty()) {
    config += extra;
    if (extra.back() != '\n') config += '\n';
  }
  return config;
}

// Copies a CLD2 language code ("un" for none) into a fixed-size field.
void CopyCode(CLD2::Language language, char* out, size_t size) {
  const char* code = CLD2::LanguageCode(language);
  std::snprintf(out, size, "%s", code == nullptr ? "un" : code);
}

// --- mozhi_bergamot_translate_ex() -------------------------------------------

// ASCII whitespace, independent of the locale (the tokens' bytes may be
// UTF-8 continuation bytes, which are never whitespace).
bool IsSpace(char c) {
  return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' ||
         c == '\v';
}

// The UTF-16 offset of every byte offset of UTF-8 `text` (size() + 1
// entries; the bytes of a character map to its start). Malformed bytes
// count as one character each.
std::vector<uint32_t> Utf16Offsets(const std::string& text) {
  std::vector<uint32_t> offsets(text.size() + 1);
  uint32_t units = 0;
  size_t i = 0;
  while (i < text.size()) {
    const auto lead = static_cast<unsigned char>(text[i]);
    size_t length = 1;
    if (lead >= 0xF0 && lead < 0xF8) {
      length = 4;
    } else if (lead >= 0xE0 && lead < 0xF0) {
      length = 3;
    } else if (lead >= 0xC0 && lead < 0xE0) {
      length = 2;
    }
    length = std::min(length, text.size() - i);
    for (size_t k = 0; k < length; ++k) offsets[i + k] = units;
    units += length == 4 ? 2 : 1;  // 4 bytes: a surrogate pair
    i += length;
  }
  offsets[text.size()] = units;
  return offsets;
}

// Tokens [begin, end) of one sentence of an AnnotatedText.
struct TokenSpan {
  size_t begin;
  size_t end;
};

// The words of sentence `s` of `text`: its subword tokens grouped like
// Bergamot's quality estimator groups them (a token that starts with
// whitespace starts a word; quality_estimator.cpp mapWords), without the
// empty end-of-sentence token. A sentence without whitespace in a script
// written without spaces (Chinese, Japanese, Thai: 3-byte UTF-8) gives one
// word per token instead of one for the whole sentence.
std::vector<TokenSpan> Words(const AnnotatedText& text, size_t s) {
  std::vector<TokenSpan> words;
  size_t tokens = text.numWords(s);
  if (tokens > 0 && text.wordAsByteRange(s, tokens - 1).size() == 0) {
    --tokens;  // end of sentence
  }
  if (tokens == 0) return words;
  const ByteRange sentence = text.sentenceAsByteRange(s);
  bool spaced = false;
  bool unspacedScript = false;
  for (size_t b = sentence.begin; b < sentence.end; ++b) {
    const auto byte = static_cast<unsigned char>(text.text[b]);
    if (IsSpace(text.text[b])) spaced = true;
    if (byte >= 0xE0 && byte < 0xF0) unspacedScript = true;
  }
  if (!spaced && unspacedScript) {
    for (size_t t = 0; t < tokens; ++t) words.push_back({t, t + 1});
    return words;
  }
  size_t begin = 0;
  for (size_t t = 1; t < tokens; ++t) {
    const ByteRange range = text.wordAsByteRange(s, t);
    if (range.size() > 0 && IsSpace(text.text[range.begin])) {
      words.push_back({begin, t});
      begin = t;
    }
  }
  words.push_back({begin, tokens});
  return words;
}

// The bytes of `word` (in sentence `s` of `text`) without the whitespace
// around it.
ByteRange WordBytes(const AnnotatedText& text, size_t s, TokenSpan word) {
  size_t begin = text.wordAsByteRange(s, word.begin).begin;
  size_t end = text.wordAsByteRange(s, word.end - 1).end;
  while (begin < end && IsSpace(text.text[begin])) ++begin;
  while (end > begin && IsSpace(text.text[end - 1])) --end;
  return ByteRange{begin, end};
}

void AppendJsonString(std::string& out, const std::string& value) {
  out += '"';
  for (const char c : value) {
    switch (c) {
      case '"':
        out += "\\\"";
        break;
      case '\\':
        out += "\\\\";
        break;
      case '\n':
        out += "\\n";
        break;
      case '\r':
        out += "\\r";
        break;
      case '\t':
        out += "\\t";
        break;
      default:
        if (static_cast<unsigned char>(c) < 0x20) {
          char escaped[8];
          std::snprintf(escaped, sizeof(escaped), "\\u%04x",
                        static_cast<unsigned>(static_cast<unsigned char>(c)));
          out += escaped;
        } else {
          out += c;
        }
    }
  }
  out += '"';
}

// A JSON number with 4 significant digits, or null. %g never writes a
// comma, so one can only be a locale's decimal separator (bionic always
// writes '.'; glibc follows LC_NUMERIC).
void AppendNumber(std::string& out, float value) {
  if (!std::isfinite(value)) {
    out += "null";
    return;
  }
  char buffer[32];
  const int length = std::snprintf(buffer, sizeof(buffer), "%.4g",
                                   static_cast<double>(value));
  if (length <= 0 || static_cast<size_t>(length) >= sizeof(buffer)) {
    out += "null";
    return;
  }
  for (int i = 0; i < length; ++i) {
    if (buffer[i] == ',') buffer[i] = '.';
  }
  out.append(buffer, static_cast<size_t>(length));
}

void AppendRange(std::string& out, const std::vector<uint32_t>& utf16,
                 ByteRange range) {
  out += '[';
  out += std::to_string(utf16[range.begin]);
  out += ',';
  out += std::to_string(utf16[range.end]);
  out += ']';
}

// The quality score of the quality estimator's word that holds token
// `begin` (the same word as ours, except in unspaced scripts, where its
// word is the whole sentence), or NaN.
float WordScore(const Response::SentenceQualityScore* scores, size_t begin) {
  if (scores == nullptr) return NAN;
  const size_t count =
      std::min(scores->wordRanges.size(), scores->wordScores.size());
  for (size_t i = 0; i < count; ++i) {
    const auto& range = scores->wordRanges[i];
    if (range.begin <= begin && begin < range.end) {
      return scores->wordScores[i];
    }
  }
  return NAN;
}

// The "words" of sentence `s` of `response` (see mozhi_bergamot.h).
void AppendWords(std::string& json, const Response& response, size_t s,
                 const std::vector<uint32_t>& source16,
                 const std::vector<uint32_t>& target16, bool alignment,
                 const Response::SentenceQualityScore* scores, bool quality) {
  // P[t][s] = p(source token s | target token t), one row per target token.
  const marian::bergamot::Alignment* matrix = nullptr;
  if (alignment && s < response.alignments.size() &&
      response.alignments[s].size() == response.target.numWords(s)) {
    matrix = &response.alignments[s];
  }
  std::vector<TokenSpan> sources;
  std::vector<ByteRange> sourceBytes;
  if (matrix != nullptr) {
    for (const TokenSpan& word : Words(response.source, s)) {
      const ByteRange bytes = WordBytes(response.source, s, word);
      if (bytes.size() == 0) continue;
      sources.push_back(word);
      sourceBytes.push_back(bytes);
    }
  }
  json += ",\"words\":[";
  bool first = true;
  std::vector<float> mass(sources.size());
  for (const TokenSpan& word : Words(response.target, s)) {
    const ByteRange bytes = WordBytes(response.target, s, word);
    if (bytes.size() == 0) continue;
    if (!first) json += ',';
    first = false;
    json += "{\"target\":";
    AppendRange(json, target16, bytes);
    if (quality) {
      json += ",\"score\":";
      AppendNumber(json, WordScore(scores, word.begin));
    }
    if (!sources.empty()) {
      // The source word with the most alignment mass, averaged over the
      // word's tokens.
      std::fill(mass.begin(), mass.end(), 0.0f);
      for (size_t t = word.begin; t < word.end; ++t) {
        const std::vector<float>& row = (*matrix)[t];
        for (size_t w = 0; w < sources.size(); ++w) {
          for (size_t k = sources[w].begin; k < sources[w].end && k < row.size();
               ++k) {
            mass[w] += row[k];
          }
        }
      }
      const size_t best = static_cast<size_t>(
          std::max_element(mass.begin(), mass.end()) - mass.begin());
      json += ",\"source\":";
      AppendRange(json, source16, sourceBytes[best]);
      json += ",\"p\":";
      AppendNumber(json, std::min(1.0f, mass[best] / static_cast<float>(
                                                         word.end - word.begin)));
    }
    json += '}';
  }
  json += ']';
}

// One element of the mozhi_bergamot_translate_ex() array.
void AppendResponse(std::string& json, const Response& response,
                    bool alignment, bool quality) {
  json += "{\"text\":";
  AppendJsonString(json, response.target.text);
  if (alignment || quality) {
    const std::vector<uint32_t> source16 = Utf16Offsets(response.source.text);
    const std::vector<uint32_t> target16 = Utf16Offsets(response.target.text);
    const size_t sentences = std::min(response.source.numSentences(),
                                      response.target.numSentences());
    json += ",\"sentences\":[";
    for (size_t s = 0; s < sentences; ++s) {
      if (s > 0) json += ',';
      json += "{\"source\":";
      AppendRange(json, source16, response.source.sentenceAsByteRange(s));
      json += ",\"target\":";
      AppendRange(json, target16, response.target.sentenceAsByteRange(s));
      const Response::SentenceQualityScore* scores =
          quality && s < response.qualityScores.size()
              ? &response.qualityScores[s]
              : nullptr;
      if (quality) {
        json += ",\"score\":";
        AppendNumber(json, scores == nullptr ? NAN : scores->sentenceScore);
      }
      AppendWords(json, response, s, source16, target16, alignment, scores,
                  quality);
      json += '}';
    }
    json += ']';
  }
  json += '}';
}

// Runs `body` under the engine lock and converts every exception into the
// thread's last error.
template <typename T, typename Body>
T Guarded(T on_error, Body body) {
  ClearError();
  try {
    std::lock_guard<std::mutex> lock(g_mutex);
    marian::setThrowExceptionOnAbort(true);
    return body();
  } catch (const std::exception& error) {
    SetError(error.what());
  } catch (...) {
    SetError("unknown engine error");
  }
  return on_error;
}

}  // namespace

struct MozhiBergamotModel {
  std::shared_ptr<TranslationModel> model;
};

extern "C" {

int32_t mozhi_bergamot_abi_version(void) { return MOZHI_BERGAMOT_ABI_VERSION; }

const char* mozhi_bergamot_version(void) {
  return "bergamot " MOZHI_BERGAMOT_ENGINE_VERSION;
}

MozhiBergamotModel* mozhi_bergamot_model_create(const char* model_path,
                                                const char* shortlist_path,
                                                const char* src_vocab_path,
                                                const char* trg_vocab_path,
                                                const char* extra_config) {
  if (IsBlank(model_path) || IsBlank(src_vocab_path)) {
    SetError("model_path and src_vocab_path are required");
    return nullptr;
  }
  const std::string config = BuildConfig(model_path, shortlist_path,
                                         src_vocab_path, trg_vocab_path,
                                         extra_config);
  return Guarded<MozhiBergamotModel*>(nullptr, [&]() -> MozhiBergamotModel* {
    auto options = marian::bergamot::parseOptionsFromString(
        config, /*validate=*/false);
    Service();  // Marian's loggers must exist before a model is built.
    auto handle = std::make_unique<MozhiBergamotModel>();
    handle->model =
        std::make_shared<TranslationModel>(options, /*replicas=*/1);
    ++g_live_models;
    return handle.release();
  });
}

void mozhi_bergamot_model_destroy(MozhiBergamotModel* model) {
  if (model == nullptr) return;
  Guarded<int>(0, [&]() {
    model->model.reset();
    delete model;
    if (g_live_models > 0 && --g_live_models == 0) {
      delete g_service;
      g_service = nullptr;
    }
    return 0;
  });
}

char* mozhi_bergamot_translate(MozhiBergamotModel* model, const char* text,
                               int32_t html) {
  if (model == nullptr || text == nullptr) {
    SetError("model and text are required");
    return nullptr;
  }
  return Guarded<char*>(nullptr, [&]() -> char* {
    ResponseOptions options;
    options.HTML = html != 0;
    std::vector<Response> responses = Service().translateMultiple(
        model->model, std::vector<std::string>{std::string(text)}, {options});
    return CopyString(responses.at(0).target.text);
  });
}

char* mozhi_bergamot_translate_pivot(MozhiBergamotModel* first,
                                     MozhiBergamotModel* second,
                                     const char* text, int32_t html) {
  if (first == nullptr || second == nullptr || text == nullptr) {
    SetError("first, second and text are required");
    return nullptr;
  }
  return Guarded<char*>(nullptr, [&]() -> char* {
    ResponseOptions options;
    options.HTML = html != 0;
    std::vector<Response> responses = Service().pivotMultiple(
        first->model, second->model, std::vector<std::string>{std::string(text)},
        {options});
    return CopyString(responses.at(0).target.text);
  });
}

char* mozhi_bergamot_translate_ex(MozhiBergamotModel* first,
                                  MozhiBergamotModel* second,
                                  const char* const* texts, int32_t count,
                                  int32_t flags) {
  if (first == nullptr || count < 0 || (count > 0 && texts == nullptr)) {
    SetError("first, texts and a count >= 0 are required");
    return nullptr;
  }
  for (int32_t i = 0; i < count; ++i) {
    if (texts[i] == nullptr) {
      SetError("texts must not contain NULL");
      return nullptr;
    }
  }
  return Guarded<char*>(nullptr, [&]() -> char* {
    const bool alignment = (flags & MOZHI_BERGAMOT_TRANSLATE_ALIGNMENT) != 0;
    const bool quality = (flags & MOZHI_BERGAMOT_TRANSLATE_QUALITY) != 0;
    ResponseOptions options;
    options.HTML = (flags & MOZHI_BERGAMOT_TRANSLATE_HTML) != 0;
    options.alignment = alignment;
    options.qualityScores = quality;
    std::vector<std::string> sources(texts, texts + count);
    const std::vector<ResponseOptions> all(sources.size(), options);
    std::vector<Response> responses;
    if (!sources.empty()) {
      responses = second == nullptr
                      ? Service().translateMultiple(first->model,
                                                    std::move(sources), all)
                      : Service().pivotMultiple(first->model, second->model,
                                                std::move(sources), all);
    }
    std::string json = "[";
    for (size_t i = 0; i < responses.size(); ++i) {
      if (i > 0) json += ',';
      AppendResponse(json, responses[i], alignment, quality);
    }
    json += ']';
    return CopyString(json);
  });
}

void mozhi_bergamot_free_string(char* text) { std::free(text); }

const char* mozhi_bergamot_last_error(void) {
  return tls_has_error ? tls_error.c_str() : nullptr;
}

int32_t mozhi_bergamot_detect(const char* text, int32_t length,
                              const char* hints, int32_t flags,
                              MozhiBergamotDetection* out) {
  ClearError();
  if (text == nullptr || out == nullptr) {
    SetError("text and out are required");
    return 0;
  }
  // CLD2 is stateless (constant tables, per-call scratch), so no engine
  // lock: identification never waits for a translation.
  try {
    const size_t size =
        length < 0 ? std::strlen(text) : static_cast<size_t>(length);
    // CLD2 takes an int length; callers send a sample, not whole books.
    const int scanned = static_cast<int>(std::min<size_t>(size, 1 << 30));
    // A padded copy: some of CLD2's word hashing reads whole 32-bit words,
    // up to three bytes past the last letter.
    std::string buffer(text, static_cast<size_t>(scanned));
    buffer.append(4, '\0');

    CLD2::CLDHints cld_hints = {IsBlank(hints) ? nullptr : hints, nullptr,
                                CLD2::UNKNOWN_ENCODING,
                                CLD2::UNKNOWN_LANGUAGE};
    const int cld_flags = (flags & MOZHI_BERGAMOT_DETECT_BEST_EFFORT) != 0
                              ? CLD2::kCLDFlagBestEffort
                              : 0;
    CLD2::Language languages[3];
    int percents[3];
    double scores[3];
    int text_bytes = 0;
    bool reliable = false;
    int valid_prefix_bytes = 0;
    const CLD2::Language summary = CLD2::ExtDetectLanguageSummaryCheckUTF8(
        buffer.data(), scanned,
        /*is_plain_text=*/(flags & MOZHI_BERGAMOT_DETECT_HTML) == 0,
        &cld_hints, cld_flags, languages, percents, scores,
        /*resultchunkvector=*/nullptr, &text_bytes, &reliable,
        &valid_prefix_bytes);

    *out = MozhiBergamotDetection{};
    CopyCode(summary, out->language, sizeof(out->language));
    for (int i = 0; i < 3; ++i) {
      CopyCode(languages[i], out->languages[i].code,
               sizeof(out->languages[i].code));
      out->languages[i].percent = percents[i];
      out->languages[i].score = static_cast<int32_t>(scores[i]);
    }
    out->text_bytes = text_bytes;
    out->reliable = reliable ? 1 : 0;
    return 1;
  } catch (const std::exception& error) {
    SetError(error.what());
  } catch (...) {
    SetError("unknown language identification error");
  }
  return 0;
}

}  // extern "C"
