// mozhi_bergamot - a minimal C API over Mozilla's Firefox Translations
// (Bergamot) inference engine and the CLD2 language identifier. See
// mozhi_bergamot.h for the contract.
//
// Copyright (c) 2026 Mozhi contributors. MIT License.

#include "mozhi_bergamot.h"

#include <algorithm>
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

using marian::bergamot::BlockingService;
using marian::bergamot::Response;
using marian::bergamot::ResponseOptions;
using marian::bergamot::TranslationModel;

// Number of translated sentences kept per process (keyed by model and
// sentence), so re-translating edited text only translates what changed.
constexpr size_t kCacheSize = 2048;

// Defaults used by Firefox and by Mozilla's evaluation of these models
// (mozilla/translations pipeline/eval/translators.py).
constexpr const char* kDefaultConfig =
    "beam-size: 1\n"
    "normalize: 1.0\n"
    "word-penalty: 0\n"
    "max-length-break: 128\n"
    "mini-batch-words: 1024\n"
    "workspace: 128\n"
    "max-length-factor: 2.0\n"
    "skip-cost: true\n"
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
