// mozhi_llama - a minimal C API over llama.cpp. See mozhi_llama.h for the
// contract.
//
// Copyright (c) 2026 Mozhi contributors. MIT License.

#include "mozhi_llama.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <mutex>
#include <new>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "ggml-cpu.h"
#include "ggml.h"
#include "llama.h"
#include "mozhi_llama_json.h"

#if defined(__ANDROID__)
#include <android/log.h>
#endif

#ifndef MOZHI_LLAMA_ENGINE_VERSION
#define MOZHI_LLAMA_ENGINE_VERSION "unknown"
#endif

#ifndef MOZHI_LLAMA_CPU
#define MOZHI_LLAMA_CPU "unknown"
#endif

namespace {

thread_local std::string tls_error;
thread_local bool tls_has_error = false;
// The last error llama.cpp or ggml logged on this thread (loading errors
// such as an unknown architecture), added to our own message.
thread_local std::string tls_log_error;

// Bumped by mozhi_llama_cancel(); a generation aborts when it changes.
std::atomic<uint64_t> g_cancel_generation{0};

std::once_flag g_setup_once;

void ClearError() {
  tls_has_error = false;
  tls_error.clear();
}

void SetError(std::string message) {
  tls_error = std::move(message);
  tls_has_error = true;
}

// `message`, plus what llama.cpp logged as the reason, if anything.
void SetErrorWithLog(const std::string& message) {
  if (tls_log_error.empty()) {
    SetError(message);
  } else {
    SetError(message + ": " + tls_log_error);
  }
}

std::string Trim(const std::string& text) {
  const char* whitespace = " \t\r\n";
  const size_t start = text.find_first_not_of(whitespace);
  if (start == std::string::npos) return std::string();
  const size_t end = text.find_last_not_of(whitespace);
  return text.substr(start, end - start + 1);
}

// llama.cpp and ggml log every model load (metadata, tensor and buffer
// sizes, system info) to stderr by default: nothing of that is needed, and
// it would end up in logcat. The first error since the call started is kept
// (on this thread, shortened) to explain a failure, e.g. "failed to open
// ...: No such file or directory"; errors never contain prompt or output
// text.
void SilentLog(ggml_log_level level, const char* text, void* /*user_data*/) {
  if (level != GGML_LOG_LEVEL_ERROR || text == nullptr ||
      !tls_log_error.empty()) {
    return;
  }
  std::string line = Trim(text);
  if (line.empty()) return;
  if (line.size() > 200) line = line.substr(0, 200) + "...";
  tls_log_error = std::move(line);
}

// A failed GGML_ASSERT cannot be recovered from (ggml calls abort()).
// ggml's default handler would first fork() the app to run gdb/lldb for a
// backtrace; write the message instead, so it shows up in crash reports.
void AbortMessage(const char* message) {
#if defined(__ANDROID__)
  __android_log_write(ANDROID_LOG_FATAL, "mozhi_llama", message);
#endif
  std::fprintf(stderr, "mozhi_llama: %s\n", message);
}

void Setup() {
  std::call_once(g_setup_once, [] {
    llama_log_set(SilentLog, nullptr);  // Also sets ggml's log callback.
    ggml_set_abort_callback(AbortMessage);
    llama_backend_init();
  });
}

int32_t DefaultThreads() {
  const unsigned cores = std::thread::hardware_concurrency();
  return static_cast<int32_t>(std::clamp<unsigned>(cores, 1, 4));
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

bool Contains(const std::string& text, const char* part) {
  return text.find(part) != std::string::npos;
}

double MillisecondsSince(std::chrono::steady_clock::time_point start) {
  return std::chrono::duration<double, std::milli>(
             std::chrono::steady_clock::now() - start)
      .count();
}

// --- UTF-8 -------------------------------------------------------------------

constexpr char kReplacement[] = "\xEF\xBF\xBD";  // U+FFFD

// Turns a byte stream (token pieces: a character can be split between
// tokens, and a model can produce invalid sequences) into valid UTF-8:
// complete, well-formed characters are passed on, invalid bytes become
// U+FFFD (one per maximal invalid subpart, as the Unicode standard
// recommends), and an incomplete character at the end is kept for the next
// bytes.
class Utf8Decoder {
 public:
  void Feed(const char* data, size_t size, std::string* out) {
    partial_.append(data, size);
    const auto* bytes = reinterpret_cast<const unsigned char*>(partial_.data());
    const size_t n = partial_.size();
    size_t i = 0;
    while (i < n) {
      const unsigned char c = bytes[i];
      if (c < 0x80) {
        out->push_back(static_cast<char>(c));
        ++i;
        continue;
      }
      size_t length = 0;
      unsigned char low = 0x80;
      unsigned char high = 0xBF;
      if (c >= 0xC2 && c <= 0xDF) {
        length = 2;
      } else if (c == 0xE0) {
        length = 3;
        low = 0xA0;
      } else if ((c >= 0xE1 && c <= 0xEC) || c == 0xEE || c == 0xEF) {
        length = 3;
      } else if (c == 0xED) {
        length = 3;
        high = 0x9F;  // No UTF-16 surrogates.
      } else if (c == 0xF0) {
        length = 4;
        low = 0x90;
      } else if (c >= 0xF1 && c <= 0xF3) {
        length = 4;
      } else if (c == 0xF4) {
        length = 4;
        high = 0x8F;  // Nothing above U+10FFFF.
      } else {
        out->append(kReplacement);
        ++i;
        continue;
      }
      size_t k = 1;
      bool invalid = false;
      for (; k < length && i + k < n; ++k) {
        const unsigned char next = bytes[i + k];
        const unsigned char min = k == 1 ? low : 0x80;
        const unsigned char max = k == 1 ? high : 0xBF;
        if (next < min || next > max) {
          invalid = true;
          break;
        }
      }
      if (invalid) {
        out->append(kReplacement);
        i += k;
        continue;
      }
      if (k < length) break;  // Incomplete so far: wait for more bytes.
      out->append(partial_, i, length);
      i += length;
    }
    partial_.erase(0, i);
  }

  // Ends the stream: an incomplete character becomes U+FFFD.
  void Flush(std::string* out) {
    if (!partial_.empty()) out->append(kReplacement);
    partial_.clear();
  }

  void Reset() { partial_.clear(); }

 private:
  std::string partial_;
};

// `text` with invalid UTF-8 replaced (metadata of a model file).
std::string ValidUtf8(const std::string& text) {
  Utf8Decoder decoder;
  std::string out;
  decoder.Feed(text.data(), text.size(), &out);
  decoder.Flush(&out);
  return out;
}

bool IsValidUtf8(const std::string& text) { return ValidUtf8(text) == text; }

std::string JsonString(const std::string& text) {
  std::string out = "\"";
  for (const char ch : ValidUtf8(text)) {
    const auto c = static_cast<unsigned char>(ch);
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
        if (c < 0x20) {
          char escaped[8];
          std::snprintf(escaped, sizeof(escaped), "\\u%04x", c);
          out += escaped;
        } else {
          out.push_back(ch);
        }
    }
  }
  out += "\"";
  return out;
}

// --- Chat templates ----------------------------------------------------------

enum class TemplateKind {
  kNone,
  kLlama,   // llama_chat_apply_template() with `template_text`.
  kGemma4,  // Gemma 4's <|turn> format (not in llama.cpp's built-ins).
  kQwen3,   // ChatML with thinking turned off.
};

struct ChatTemplate {
  TemplateKind kind = TemplateKind::kNone;
  std::string template_text;  // For kLlama: a template or a built-in name.
  std::string name;           // Reported in model_info(); may be empty.
};

int32_t ApplyLlamaTemplate(const std::string& tmpl,
                           const std::vector<llama_chat_message>& messages,
                           bool add_assistant, std::string* out) {
  const int32_t length =
      llama_chat_apply_template(tmpl.c_str(), messages.data(), messages.size(),
                                add_assistant, nullptr, 0);
  if (length < 0) return length;
  std::vector<char> buffer(static_cast<size_t>(length) + 1);
  llama_chat_apply_template(tmpl.c_str(), messages.data(), messages.size(),
                            add_assistant, buffer.data(),
                            static_cast<int32_t>(buffer.size()));
  out->assign(buffer.data(), static_cast<size_t>(length));
  return length;
}

// Gemma 4 (google/gemma-4-*-it chat_template.jinja, text only, thinking
// off): an optional system turn, then <|turn>{user|model}\n{content}<turn|>\n
// per message, and an empty thought channel after the answer's turn. The
// template's {{ bos_token }} is left out: tokenizing adds the BOS token.
std::string FormatGemma4(const std::vector<llama_chat_message>& messages,
                         bool add_assistant) {
  std::string out;
  size_t first = 0;
  if (!messages.empty() && std::strcmp(messages[0].role, "system") == 0) {
    out += "<|turn>system\n" + Trim(messages[0].content) + "<turn|>\n";
    first = 1;
  }
  for (size_t i = first; i < messages.size(); ++i) {
    const bool model = std::strcmp(messages[i].role, "assistant") == 0;
    out += "<|turn>";
    out += model ? "model" : messages[i].role;
    out += "\n" + Trim(messages[i].content) + "<turn|>\n";
  }
  if (add_assistant) out += "<|turn>model\n<|channel>thought\n<channel|>";
  return out;
}

int32_t FormatChat(const ChatTemplate& tmpl,
                   const std::vector<llama_chat_message>& messages,
                   bool add_assistant, std::string* out) {
  switch (tmpl.kind) {
    case TemplateKind::kNone:
      return -1;
    case TemplateKind::kGemma4:
      *out = FormatGemma4(messages, add_assistant);
      return static_cast<int32_t>(out->size());
    case TemplateKind::kQwen3: {
      // Qwen3's template with enable_thinking=false: the answer starts
      // after an empty think block (no slow, verbose reasoning first).
      const int32_t length =
          ApplyLlamaTemplate("chatml", messages, add_assistant, out);
      if (length < 0) return length;
      if (add_assistant) *out += "<think>\n\n</think>\n\n";
      return static_cast<int32_t>(out->size());
    }
    case TemplateKind::kLlama:
      return ApplyLlamaTemplate(tmpl.template_text, messages, add_assistant,
                                out);
  }
  return -1;
}

std::string ModelMeta(const llama_model* model, const char* key) {
  const int32_t length = llama_model_meta_val_str(model, key, nullptr, 0);
  if (length < 0) return std::string();
  std::vector<char> buffer(static_cast<size_t>(length) + 1);
  llama_model_meta_val_str(model, key, buffer.data(), buffer.size());
  return std::string(buffer.data(), static_cast<size_t>(length));
}

// The name of the built-in template that formats like `tmpl`, if any.
std::string BuiltinTemplateName(const std::string& tmpl) {
  const std::vector<llama_chat_message> probe = {
      {"system", "S"}, {"user", "U"}, {"assistant", "A"}, {"user", "V"}};
  std::string expected;
  if (ApplyLlamaTemplate(tmpl, probe, true, &expected) < 0) return "";
  const int32_t count = llama_chat_builtin_templates(nullptr, 0);
  std::vector<const char*> names(static_cast<size_t>(std::max(count, 0)));
  llama_chat_builtin_templates(names.data(), names.size());
  for (const char* name : names) {
    std::string formatted;
    if (ApplyLlamaTemplate(name, probe, true, &formatted) >= 0 &&
        formatted == expected) {
      return name;
    }
  }
  return "";
}

// How to format chats for `model`: its embedded template when llama.cpp (or
// this file) knows it, else the format of its architecture.
ChatTemplate ResolveChatTemplate(const llama_model* model) {
  ChatTemplate result;
  const char* embedded = llama_model_chat_template(model, nullptr);
  const std::string architecture = ModelMeta(model, "general.architecture");
  if (embedded != nullptr && *embedded != '\0') {
    const std::string tmpl(embedded);
    if (Contains(tmpl, "<|turn>") && Contains(tmpl, "<turn|>")) {
      result.kind = TemplateKind::kGemma4;
      result.name = "gemma4";
      return result;
    }
    const std::string name = BuiltinTemplateName(tmpl);
    std::string ignored;
    if (ApplyLlamaTemplate(tmpl, {{"user", "U"}}, true, &ignored) >= 0) {
      if (name == "chatml" && Contains(tmpl, "enable_thinking")) {
        result.kind = TemplateKind::kQwen3;
        result.name = "qwen3";
      } else {
        result.kind = TemplateKind::kLlama;
        result.template_text = tmpl;
        result.name = name;
      }
      return result;
    }
  }
  if (architecture == "gemma4") {
    result.kind = TemplateKind::kGemma4;
    result.name = "gemma4";
  } else if (architecture == "qwen3") {
    result.kind = TemplateKind::kQwen3;
    result.name = "qwen3";
  } else if (architecture == "hunyuan-dense") {
    result.kind = TemplateKind::kLlama;
    result.template_text = "hunyuan-dense";
    result.name = "hunyuan-dense";
  }
  return result;
}

// --- Generation --------------------------------------------------------------

struct Generation {
  bool active = false;
  bool prompt_done = false;
  bool finished = false;
  bool cancelled = false;
  int32_t finish_reason = MOZHI_LLAMA_FINISH_NONE;
  std::vector<llama_token> prompt;
  int32_t prompt_tokens = 0;
  int32_t max_tokens = 0;
  int32_t generated = 0;
  int32_t decoded = 0;                     // Tokens in the KV cache.
  llama_token pending = LLAMA_TOKEN_NULL;  // Sampled, not decoded yet.
  llama_sampler* chain = nullptr;
  llama_sampler* grammar = nullptr;
  std::vector<std::string> stops;
  Utf8Decoder decoder;
  std::string held;   // Could be the start of a stop string.
  std::string ready;  // To be returned by generate_next().
  uint64_t cancel_snapshot = 0;
  const volatile int32_t* cancel_flag = nullptr;
  std::chrono::steady_clock::time_point started;
  double prompt_ms = 0;
  double generate_ms = 0;

  void FreeSamplers() {
    if (chain != nullptr) llama_sampler_free(chain);
    if (grammar != nullptr) llama_sampler_free(grammar);
    chain = nullptr;
    grammar = nullptr;
  }
};

}  // namespace

struct MozhiLlamaModel {
  llama_model* model = nullptr;
  llama_context* context = nullptr;
  const llama_vocab* vocab = nullptr;
  int32_t n_ctx = 0;
  int32_t n_threads = 0;
  ChatTemplate chat_template;
  std::vector<llama_token_data> candidates;
  // The context's abort callback reads these from ggml's threads.
  std::atomic<bool> abort_armed{false};
  std::atomic<uint64_t> abort_snapshot{0};
  std::atomic<const volatile int32_t*> abort_flag{nullptr};
  Generation generation;
  // One call at a time: the context and the generation are not thread-safe.
  std::mutex mutex;
};

namespace {

bool FlagSet(const volatile int32_t* flag) {
  return flag != nullptr && __atomic_load_n(flag, __ATOMIC_RELAXED) != 0;
}

bool ShouldAbort(void* data) {
  const auto* handle = static_cast<const MozhiLlamaModel*>(data);
  if (!handle->abort_armed.load(std::memory_order_relaxed)) return false;
  return g_cancel_generation.load(std::memory_order_relaxed) !=
             handle->abort_snapshot.load(std::memory_order_relaxed) ||
         FlagSet(handle->abort_flag.load(std::memory_order_relaxed));
}

bool Cancelled(const Generation& generation) {
  return g_cancel_generation.load() != generation.cancel_snapshot ||
         FlagSet(generation.cancel_flag);
}

void EndGeneration(MozhiLlamaModel* handle) {
  Generation& generation = handle->generation;
  handle->abort_armed.store(false);
  handle->abort_flag.store(nullptr);
  generation.cancel_flag = nullptr;
  generation.FreeSamplers();
  generation.active = false;
  generation.prompt.clear();
  generation.prompt.shrink_to_fit();
  generation.stops.clear();
  generation.decoder.Reset();
  generation.held.clear();
  generation.ready.clear();
}

void Finish(Generation* generation, int32_t reason) {
  std::string tail;
  generation->decoder.Flush(&tail);
  generation->held += tail;
  generation->ready += generation->held;
  generation->held.clear();
  generation->finished = true;
  generation->finish_reason = reason;
}

// Adds decoded text: everything up to a stop string is released (and the
// generation ends there); text that could still become a stop string is
// held back.
void AppendText(Generation* generation, const std::string& text) {
  std::string& held = generation->held;
  held += text;
  size_t stop_at = std::string::npos;
  for (const std::string& stop : generation->stops) {
    const size_t at = held.find(stop);
    if (at < stop_at) stop_at = at;
  }
  if (stop_at != std::string::npos) {
    generation->ready.append(held, 0, stop_at);
    held.clear();
    generation->decoder.Reset();
    generation->finished = true;
    generation->finish_reason = MOZHI_LLAMA_FINISH_STOP;
    return;
  }
  size_t keep = 0;
  for (const std::string& stop : generation->stops) {
    const size_t longest = std::min(stop.size() - 1, held.size());
    for (size_t k = longest; k > keep; --k) {
      if (held.compare(held.size() - k, k, stop, 0, k) == 0) {
        keep = k;
        break;
      }
    }
  }
  generation->ready.append(held, 0, held.size() - keep);
  held.erase(0, held.size() - keep);
}

// Copies the start of the ready text to `buf`, whole characters only.
int32_t Emit(Generation* generation, char* buf, int32_t size) {
  std::string& ready = generation->ready;
  size_t n = std::min(ready.size(), static_cast<size_t>(size - 1));
  while (n > 0 && n < ready.size() &&
         (static_cast<unsigned char>(ready[n]) & 0xC0) == 0x80) {
    --n;
  }
  std::memcpy(buf, ready.data(), n);
  buf[n] = '\0';
  ready.erase(0, n);
  return static_cast<int32_t>(n);
}

// llama_decode() of `count` tokens; MOZHI_LLAMA_OK, _E_CANCELLED or _E_ERROR.
int32_t Decode(MozhiLlamaModel* handle, llama_token* tokens, int32_t count) {
  const int32_t status =
      llama_decode(handle->context, llama_batch_get_one(tokens, count));
  if (status == 0) {
    handle->generation.decoded += count;
    return MOZHI_LLAMA_OK;
  }
  if (Cancelled(handle->generation)) {
    handle->generation.cancelled = true;
    SetError("cancelled");
    return MOZHI_LLAMA_E_CANCELLED;
  }
  SetErrorWithLog("decoding failed (llama_decode: " + std::to_string(status) +
                  ")");
  return MOZHI_LLAMA_E_ERROR;
}

int32_t DecodePrompt(MozhiLlamaModel* handle) {
  Generation& generation = handle->generation;
  const auto start = std::chrono::steady_clock::now();
  const int32_t batch = std::max<int32_t>(
      1, static_cast<int32_t>(llama_n_batch(handle->context)));
  const auto total = static_cast<int32_t>(generation.prompt.size());
  for (int32_t i = 0; i < total; i += batch) {
    const int32_t status = Decode(handle, generation.prompt.data() + i,
                                  std::min(batch, total - i));
    if (status != MOZHI_LLAMA_OK) return status;
  }
  generation.prompt_ms = MillisecondsSince(start);
  generation.started = std::chrono::steady_clock::now();
  generation.prompt_done = true;
  return MOZHI_LLAMA_OK;
}

// Samples the next token from the last logits. Without a grammar this is
// the chain alone. With one, the chain's pick is checked against the
// grammar first (cheap: one token) and only when the grammar rejects it is
// the whole vocabulary filtered by the grammar and sampled again.
llama_token Sample(MozhiLlamaModel* handle) {
  Generation& generation = handle->generation;
  const float* logits = llama_get_logits_ith(handle->context, -1);
  if (logits == nullptr) throw std::runtime_error("no logits to sample from");
  const int32_t n_vocab = llama_vocab_n_tokens(handle->vocab);
  std::vector<llama_token_data>& candidates = handle->candidates;
  auto fill = [&] {
    candidates.resize(static_cast<size_t>(n_vocab));
    for (int32_t id = 0; id < n_vocab; ++id) {
      candidates[static_cast<size_t>(id)] = {id, logits[id], 0.0f};
    }
    return llama_token_data_array{candidates.data(), candidates.size(), -1,
                                  false};
  };
  llama_token_data_array array = fill();
  llama_sampler_apply(generation.chain, &array);
  llama_token token = array.data[array.selected].id;
  if (generation.grammar != nullptr) {
    llama_token_data single = {token, 1.0f, 0.0f};
    llama_token_data_array check = {&single, 1, -1, false};
    llama_sampler_apply(generation.grammar, &check);
    if (std::isinf(single.logit)) {
      array = fill();
      llama_sampler_apply(generation.grammar, &array);
      llama_sampler_apply(generation.chain, &array);
      token = array.data[array.selected].id;
    }
    llama_sampler_accept(generation.grammar, token);
  }
  llama_sampler_accept(generation.chain, token);
  return token;
}

std::string TokenPiece(const llama_vocab* vocab, llama_token token) {
  char small[64];
  int32_t length = llama_token_to_piece(vocab, token, small, sizeof(small), 0,
                                        /*special=*/false);
  if (length >= 0) return std::string(small, static_cast<size_t>(length));
  std::vector<char> large(static_cast<size_t>(-length));
  length = llama_token_to_piece(vocab, token, large.data(),
                                static_cast<int32_t>(large.size()), 0, false);
  return length > 0 ? std::string(large.data(), static_cast<size_t>(length))
                    : std::string();
}

llama_sampler* BuildChain(const MozhiLlamaModel* handle,
                          const MozhiLlamaParams& params) {
  llama_sampler_chain_params chain_params =
      llama_sampler_chain_default_params();
  chain_params.no_perf = true;
  llama_sampler* chain = llama_sampler_chain_init(chain_params);
  const int32_t n_vocab = llama_vocab_n_tokens(handle->vocab);
  const int32_t last_n =
      params.repeat_last_n < 0 ? handle->n_ctx : params.repeat_last_n;
  if (params.repeat_penalty > 0 && params.repeat_penalty != 1.0f &&
      last_n > 0) {
    llama_sampler_chain_add(
        chain, llama_sampler_init_penalties(n_vocab, last_n,
                                            params.repeat_penalty, 0.0f, 0.0f));
  }
  if (params.temperature <= 0) {
    llama_sampler_chain_add(chain, llama_sampler_init_greedy());
    return chain;
  }
  if (params.top_k > 0) {
    llama_sampler_chain_add(chain, llama_sampler_init_top_k(params.top_k));
  }
  if (params.top_p > 0 && params.top_p < 1) {
    llama_sampler_chain_add(chain, llama_sampler_init_top_p(params.top_p, 1));
  }
  if (params.min_p > 0) {
    llama_sampler_chain_add(chain, llama_sampler_init_min_p(params.min_p, 1));
  }
  llama_sampler_chain_add(chain, llama_sampler_init_temp(params.temperature));
  llama_sampler_chain_add(chain, llama_sampler_init_dist(params.seed));
  return chain;
}

std::string CpuFeatures() {
  std::string features;
  auto add = [&features](bool present, const char* name) {
    if (!present) return;
    features += features.empty() ? "" : " ";
    features += name;
  };
  add(ggml_cpu_has_neon(), "NEON");
  add(ggml_cpu_has_arm_fma(), "ARM_FMA");
  add(ggml_cpu_has_fp16_va(), "FP16_VA");
  add(ggml_cpu_has_dotprod(), "DOTPROD");
  add(ggml_cpu_has_matmul_int8(), "MATMUL_INT8");
  add(ggml_cpu_has_sve(), "SVE");
  add(ggml_cpu_has_sme(), "SME");
  add(ggml_cpu_has_sse3(), "SSE3");
  add(ggml_cpu_has_ssse3(), "SSSE3");
  add(ggml_cpu_has_avx(), "AVX");
  add(ggml_cpu_has_avx2(), "AVX2");
  add(ggml_cpu_has_f16c(), "F16C");
  add(ggml_cpu_has_fma(), "FMA");
  add(ggml_cpu_has_avx512(), "AVX512");
  return std::string(MOZHI_LLAMA_CPU) + ": " +
         (features.empty() ? std::string("none") : features);
}

}  // namespace

extern "C" {

int32_t mozhi_llama_abi_version(void) { return MOZHI_LLAMA_ABI_VERSION; }

const char* mozhi_llama_version(void) {
  static const std::string version =
      std::string("llama.cpp ") + MOZHI_LLAMA_ENGINE_VERSION + " (ggml " +
      ggml_version() + ", CPU " + MOZHI_LLAMA_CPU + ")";
  return version.c_str();
}

const char* mozhi_llama_cpu_features(void) {
  static const std::string features = CpuFeatures();
  return features.c_str();
}

const char* mozhi_llama_json_grammar(void) { return kJsonGrammar; }

MozhiLlamaModel* mozhi_llama_model_load(const char* path, int32_t n_threads,
                                        int32_t n_ctx, int32_t use_mmap) {
  ClearError();
  tls_log_error.clear();
  if (path == nullptr || *path == '\0') {
    SetError("path is required");
    return nullptr;
  }
  try {
    Setup();
    llama_model_params model_params = llama_model_default_params();
    model_params.n_gpu_layers = 0;  // Only the CPU backend is compiled in.
    model_params.load_mode =
        use_mmap != 0 ? LLAMA_LOAD_MODE_MMAP : LLAMA_LOAD_MODE_NONE;
    llama_model* model = llama_model_load_from_file(path, model_params);
    if (model == nullptr) {
      SetErrorWithLog(std::string("cannot load the model ") + path);
      return nullptr;
    }
    if (llama_model_has_encoder(model) || !llama_model_has_decoder(model)) {
      llama_model_free(model);
      SetError(
          "not a text generation model (encoder models are not "
          "supported)");
      return nullptr;
    }
    auto* handle = new (std::nothrow) MozhiLlamaModel();
    if (handle == nullptr) {
      llama_model_free(model);
      SetError("out of memory");
      return nullptr;
    }
    const int32_t trained = llama_model_n_ctx_train(model);
    int32_t context_size = n_ctx > 0 ? n_ctx : trained;
    if (trained > 0) context_size = std::min(context_size, trained);
    if (context_size <= 0) context_size = 4096;
    handle->n_threads = n_threads > 0 ? n_threads : DefaultThreads();

    llama_context_params context_params = llama_context_default_params();
    context_params.n_ctx = static_cast<uint32_t>(context_size);
    context_params.n_batch =
        static_cast<uint32_t>(std::min<int32_t>(context_size, 512));
    context_params.n_ubatch = context_params.n_batch;
    context_params.n_seq_max = 1;
    context_params.n_threads = handle->n_threads;
    context_params.n_threads_batch = handle->n_threads;
    context_params.no_perf = true;
    context_params.embeddings = false;
    context_params.abort_callback = ShouldAbort;
    context_params.abort_callback_data = handle;
    llama_context* context = llama_init_from_model(model, context_params);
    if (context == nullptr) {
      llama_model_free(model);
      delete handle;
      SetErrorWithLog("cannot create a context of " +
                      std::to_string(context_size) + " tokens");
      return nullptr;
    }
    handle->model = model;
    handle->context = context;
    handle->vocab = llama_model_get_vocab(model);
    handle->n_ctx = static_cast<int32_t>(llama_n_ctx(context));
    handle->chat_template = ResolveChatTemplate(model);
    return handle;
  } catch (const std::bad_alloc&) {
    SetError("out of memory");
  } catch (const std::exception& error) {
    SetError(error.what());
  } catch (...) {
    SetError("unknown engine error");
  }
  return nullptr;
}

void mozhi_llama_model_free(MozhiLlamaModel* handle) {
  ClearError();
  if (handle == nullptr) return;
  {
    std::lock_guard<std::mutex> lock(handle->mutex);
    EndGeneration(handle);
    llama_free(handle->context);
    llama_model_free(handle->model);
    handle->context = nullptr;
    handle->model = nullptr;
  }
  delete handle;
}

char* mozhi_llama_model_info(MozhiLlamaModel* handle) {
  ClearError();
  if (handle == nullptr) {
    SetError("model is required");
    return nullptr;
  }
  try {
    std::lock_guard<std::mutex> lock(handle->mutex);
    const llama_model* model = handle->model;
    char description[256] = {0};
    llama_model_desc(model, description, sizeof(description));
    const ChatTemplate& tmpl = handle->chat_template;
    std::string json = "{";
    json += "\"architecture\":" +
            JsonString(ModelMeta(model, "general.architecture"));
    json += ",\"name\":" + JsonString(ModelMeta(model, "general.name"));
    json += ",\"description\":" + JsonString(description);
    json +=
        ",\"n_ctx_train\":" + std::to_string(llama_model_n_ctx_train(model));
    json += ",\"n_ctx\":" + std::to_string(handle->n_ctx);
    json += ",\"n_params\":" + std::to_string(llama_model_n_params(model));
    json += ",\"size\":" + std::to_string(llama_model_size(model));
    json +=
        ",\"n_vocab\":" + std::to_string(llama_vocab_n_tokens(handle->vocab));
    json += ",\"n_layer\":" + std::to_string(llama_model_n_layer(model));
    json += ",\"n_embd\":" + std::to_string(llama_model_n_embd(model));
    json += ",\"chat_template\":";
    json += tmpl.kind == TemplateKind::kNone ? "false" : "true";
    json += ",\"chat_template_name\":";
    json += tmpl.name.empty() ? "null" : JsonString(tmpl.name);
    json += "}";
    return CopyString(json);
  } catch (const std::bad_alloc&) {
    SetError("out of memory");
  } catch (const std::exception& error) {
    SetError(error.what());
  } catch (...) {
    SetError("unknown engine error");
  }
  return nullptr;
}

char* mozhi_llama_chat_format(MozhiLlamaModel* handle, const char* const* roles,
                              const char* const* contents, int32_t n,
                              int32_t add_assistant) {
  ClearError();
  if (handle == nullptr || n < 0 ||
      (n > 0 && (roles == nullptr || contents == nullptr))) {
    SetError("model and messages are required");
    return nullptr;
  }
  try {
    std::vector<llama_chat_message> messages;
    messages.reserve(static_cast<size_t>(n));
    for (int32_t i = 0; i < n; ++i) {
      if (roles[i] == nullptr || contents[i] == nullptr) {
        SetError("message " + std::to_string(i) + " has no role or content");
        return nullptr;
      }
      messages.push_back({roles[i], contents[i]});
    }
    std::lock_guard<std::mutex> lock(handle->mutex);
    if (handle->chat_template.kind == TemplateKind::kNone) {
      SetError("the model has no supported chat template");
      return nullptr;
    }
    std::string prompt;
    if (FormatChat(handle->chat_template, messages, add_assistant != 0,
                   &prompt) < 0) {
      SetError("the model's chat template cannot be applied");
      return nullptr;
    }
    return CopyString(prompt);
  } catch (const std::bad_alloc&) {
    SetError("out of memory");
  } catch (const std::exception& error) {
    SetError(error.what());
  } catch (...) {
    SetError("unknown engine error");
  }
  return nullptr;
}

int32_t mozhi_llama_tokenize_count(MozhiLlamaModel* handle, const char* text) {
  ClearError();
  if (handle == nullptr || text == nullptr) {
    SetError("model and text are required");
    return -1;
  }
  const size_t length = std::strlen(text);
  if (length > static_cast<size_t>(INT32_MAX)) {
    SetError("text too long");
    return -1;
  }
  const int32_t count =
      llama_tokenize(handle->vocab, text, static_cast<int32_t>(length), nullptr,
                     0, /*add_special=*/true, /*parse_special=*/true);
  if (count == INT32_MIN) {
    SetError("text too long");
    return -1;
  }
  return count < 0 ? -count : count;
}

int32_t mozhi_llama_generate_begin(MozhiLlamaModel* handle, const char* prompt,
                                   const MozhiLlamaParams* params) {
  ClearError();
  tls_log_error.clear();
  if (handle == nullptr || prompt == nullptr || params == nullptr) {
    SetError("model, prompt and parameters are required");
    return MOZHI_LLAMA_E_ERROR;
  }
  if (params->n_stop < 0 || (params->n_stop > 0 && params->stop == nullptr)) {
    SetError("invalid stop strings");
    return MOZHI_LLAMA_E_ERROR;
  }
  // Read before anything else: a cancel from now on aborts this generation.
  const uint64_t snapshot = g_cancel_generation.load();
  try {
    std::lock_guard<std::mutex> lock(handle->mutex);
    Generation& generation = handle->generation;
    if (generation.active) {
      SetError("a generation is already running");
      return MOZHI_LLAMA_E_ERROR;
    }
    std::vector<std::string> stops;
    for (int32_t i = 0; i < params->n_stop; ++i) {
      if (params->stop[i] == nullptr || *params->stop[i] == '\0') continue;
      std::string stop(params->stop[i]);
      if (!IsValidUtf8(stop)) {
        SetError("a stop string is not valid UTF-8");
        return MOZHI_LLAMA_E_ERROR;
      }
      stops.push_back(std::move(stop));
    }

    const size_t length = std::strlen(prompt);
    if (length == 0 || length > static_cast<size_t>(INT32_MAX)) {
      SetError(length == 0 ? "the prompt is empty" : "the prompt is too long");
      return length == 0 ? MOZHI_LLAMA_E_ERROR : MOZHI_LLAMA_E_CONTEXT;
    }
    const auto text_length = static_cast<int32_t>(length);
    const int32_t needed = llama_tokenize(handle->vocab, prompt, text_length,
                                          nullptr, 0, true, true);
    if (needed == INT32_MIN) {
      SetError("the prompt is too long");
      return MOZHI_LLAMA_E_CONTEXT;
    }
    int32_t count = -needed;
    if (count <= 0) {
      SetError("the prompt cannot be tokenized");
      return MOZHI_LLAMA_E_ERROR;
    }
    const int32_t limit = params->max_tokens > 0
                              ? handle->n_ctx - params->max_tokens
                              : handle->n_ctx - 1;
    if (count > limit) {
      SetError("the prompt has " + std::to_string(count) +
               " tokens; the context holds " + std::to_string(limit) +
               " with room for the answer");
      return MOZHI_LLAMA_E_CONTEXT;
    }
    std::vector<llama_token> tokens(static_cast<size_t>(count));
    count = llama_tokenize(handle->vocab, prompt, text_length, tokens.data(),
                           count, true, true);
    if (count <= 0) {
      SetError("the prompt cannot be tokenized");
      return MOZHI_LLAMA_E_ERROR;
    }
    tokens.resize(static_cast<size_t>(count));

    llama_sampler* grammar = nullptr;
    if (params->grammar != nullptr && *params->grammar != '\0') {
      grammar =
          llama_sampler_init_grammar(handle->vocab, params->grammar, "root");
      if (grammar == nullptr) {
        SetErrorWithLog("invalid grammar");
        return MOZHI_LLAMA_E_ERROR;
      }
    }
    llama_sampler* chain = BuildChain(handle, *params);
    // The repetition penalty counts the end of the prompt too (as in
    // Hugging Face's repetition_penalty and llama-server).
    for (const llama_token token : tokens) llama_sampler_accept(chain, token);

    llama_memory_clear(llama_get_memory(handle->context), false);
    generation = Generation();
    generation.active = true;
    generation.prompt = std::move(tokens);
    generation.prompt_tokens = count;
    generation.max_tokens =
        params->max_tokens > 0 ? params->max_tokens : handle->n_ctx - count;
    generation.chain = chain;
    generation.grammar = grammar;
    generation.stops = std::move(stops);
    generation.cancel_snapshot = snapshot;
    generation.cancel_flag = params->cancel_flag;
    handle->abort_snapshot.store(snapshot);
    handle->abort_flag.store(params->cancel_flag);
    handle->abort_armed.store(true);
    return MOZHI_LLAMA_OK;
  } catch (const std::bad_alloc&) {
    SetError("out of memory");
  } catch (const std::exception& error) {
    SetError(error.what());
  } catch (...) {
    SetError("unknown engine error");
  }
  return MOZHI_LLAMA_E_ERROR;
}

int32_t mozhi_llama_generate_next(MozhiLlamaModel* handle, char* buf,
                                  int32_t size) {
  ClearError();
  tls_log_error.clear();
  if (handle == nullptr || buf == nullptr ||
      size < MOZHI_LLAMA_MIN_PIECE_SIZE) {
    SetError("model and a buffer of at least 8 bytes are required");
    return MOZHI_LLAMA_E_ERROR;
  }
  buf[0] = '\0';
  try {
    std::lock_guard<std::mutex> lock(handle->mutex);
    Generation& generation = handle->generation;
    if (!generation.active) {
      SetError("no generation is running");
      return MOZHI_LLAMA_E_ERROR;
    }
    for (;;) {
      if (!generation.ready.empty()) return Emit(&generation, buf, size);
      if (generation.finished) return 0;
      if (generation.cancelled || Cancelled(generation)) {
        generation.cancelled = true;
        SetError("cancelled");
        return MOZHI_LLAMA_E_CANCELLED;
      }
      if (!generation.prompt_done) {
        const int32_t status = DecodePrompt(handle);
        if (status != MOZHI_LLAMA_OK) return status;
      } else if (generation.pending != LLAMA_TOKEN_NULL) {
        llama_token token = generation.pending;
        generation.pending = LLAMA_TOKEN_NULL;
        const int32_t status = Decode(handle, &token, 1);
        if (status != MOZHI_LLAMA_OK) return status;
      }
      const llama_token token = Sample(handle);
      ++generation.generated;
      if (llama_vocab_is_eog(handle->vocab, token)) {
        Finish(&generation, MOZHI_LLAMA_FINISH_STOP);
      } else {
        const std::string piece = TokenPiece(handle->vocab, token);
        std::string text;
        generation.decoder.Feed(piece.data(), piece.size(), &text);
        AppendText(&generation, text);
        if (!generation.finished &&
            (generation.generated >= generation.max_tokens ||
             generation.decoded >= handle->n_ctx)) {
          Finish(&generation, MOZHI_LLAMA_FINISH_LENGTH);
        }
        if (!generation.finished) generation.pending = token;
      }
      if (generation.finished) {
        generation.generate_ms = MillisecondsSince(generation.started);
      }
    }
  } catch (const std::bad_alloc&) {
    SetError("out of memory");
  } catch (const std::exception& error) {
    SetError(error.what());
  } catch (...) {
    SetError("unknown engine error");
  }
  return MOZHI_LLAMA_E_ERROR;
}

void mozhi_llama_generate_end(MozhiLlamaModel* handle) {
  ClearError();
  if (handle == nullptr) return;
  std::lock_guard<std::mutex> lock(handle->mutex);
  Generation& generation = handle->generation;
  if (generation.active && generation.prompt_done && !generation.finished) {
    generation.generate_ms = MillisecondsSince(generation.started);
  }
  EndGeneration(handle);
}

int32_t mozhi_llama_generate_stats(MozhiLlamaModel* handle,
                                   MozhiLlamaStats* stats) {
  ClearError();
  if (handle == nullptr || stats == nullptr) {
    SetError("model and stats are required");
    return MOZHI_LLAMA_E_ERROR;
  }
  std::lock_guard<std::mutex> lock(handle->mutex);
  const Generation& generation = handle->generation;
  stats->prompt_tokens = generation.prompt_tokens;
  stats->generated_tokens = generation.generated;
  stats->finish_reason = generation.finish_reason;
  stats->reserved = 0;
  stats->prompt_ms = generation.prompt_ms;
  stats->generate_ms = generation.generate_ms;
  return MOZHI_LLAMA_OK;
}

void mozhi_llama_cancel(void) { g_cancel_generation.fetch_add(1); }

void mozhi_llama_free_string(char* text) { std::free(text); }

const char* mozhi_llama_last_error(void) {
  return tls_has_error ? tls_error.c_str() : nullptr;
}

}  // extern "C"
