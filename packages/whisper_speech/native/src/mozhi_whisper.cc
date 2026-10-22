// mozhi_whisper - a minimal C API over whisper.cpp. See mozhi_whisper.h for
// the contract.
//
// Copyright (c) 2026 Mozhi contributors. MIT License.

#include "mozhi_whisper.h"

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <fstream>
#include <mutex>
#include <new>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "ggml.h"
#include "whisper.h"

#if defined(__ANDROID__)
#include <android/log.h>
#endif

#ifndef MOZHI_WHISPER_ENGINE_VERSION
#define MOZHI_WHISPER_ENGINE_VERSION "unknown"
#endif

namespace {

thread_local std::string tls_error;
thread_local bool tls_has_error = false;

// Bumped by mozhi_whisper_cancel(); a transcription aborts when it changes.
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

// whisper.cpp and ggml log every model load and transcription (timings,
// system info, buffer sizes) to stderr by default: nothing of that is
// needed, and it would end up in logcat.
void SilentLog(ggml_log_level /*level*/, const char* /*text*/,
               void* /*user_data*/) {}

// A failed GGML_ASSERT cannot be recovered from (ggml calls abort()).
// ggml's default handler would first fork() the app to run gdb/lldb for a
// backtrace; write the message instead, so it shows up in crash reports.
void AbortMessage(const char* message) {
#if defined(__ANDROID__)
  __android_log_write(ANDROID_LOG_FATAL, "mozhi_whisper", message);
#endif
  std::fprintf(stderr, "mozhi_whisper: %s\n", message);
}

void Setup() {
  std::call_once(g_setup_once, [] {
    whisper_log_set(SilentLog, nullptr);  // Also sets ggml's log callback.
    ggml_set_abort_callback(AbortMessage);
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

bool IsAuto(const char* language) {
  return language == nullptr || *language == '\0' ||
         std::strcmp(language, "auto") == 0;
}

std::string Trim(const std::string& text) {
  const char* whitespace = " \t\r\n";
  const size_t start = text.find_first_not_of(whitespace);
  if (start == std::string::npos) return std::string();
  const size_t end = text.find_last_not_of(whitespace);
  return text.substr(start, end - start + 1);
}

struct AbortState {
  uint64_t generation;
};

bool ShouldAbort(void* data) {
  const auto* state = static_cast<const AbortState*>(data);
  return g_cancel_generation.load(std::memory_order_relaxed) !=
         state->generation;
}

// The window a Silero VAD model file declares (whisper.cpp's format, see
// models/convert-silero-vad-to-ggml.py: magic, type, version, window,
// context, ...), or 0 when the file is no Silero model. Checked before
// whisper.cpp reads the file, which trusts the header (a Whisper model's
// would make it allocate and read nonsense).
int32_t SileroWindow(const char* path) {
  std::ifstream file(path, std::ios::binary);
  uint32_t magic = 0;
  int32_t type_length = 0;
  if (!file.read(reinterpret_cast<char*>(&magic), sizeof(magic)) ||
      magic != 0x67676d6c ||
      !file.read(reinterpret_cast<char*>(&type_length), sizeof(type_length)) ||
      type_length < 6 || type_length > 64) {
    return 0;
  }
  std::string type(static_cast<size_t>(type_length), '\0');
  if (!file.read(&type[0], type_length) || type.compare(0, 6, "silero") != 0) {
    return 0;
  }
  int32_t version[3] = {0, 0, 0};
  int32_t window = 0;
  if (!file.read(reinterpret_cast<char*>(version), sizeof(version)) ||
      !file.read(reinterpret_cast<char*>(&window), sizeof(window)) ||
      window < 64 || window > 8192) {
    return 0;
  }
  return window;
}

}  // namespace

struct MozhiWhisperVad {
  whisper_vad_context* context = nullptr;
  int32_t window = 0;
  // Samples of the stream that do not fill a window yet.
  std::vector<float> pending;
  std::mutex mutex;
};

struct MozhiWhisperModel {
  whisper_context* context = nullptr;
  int32_t n_threads = 0;
  // whisper_full() uses the context's single state: one call at a time.
  std::mutex mutex;
};

extern "C" {

int32_t mozhi_whisper_abi_version(void) { return MOZHI_WHISPER_ABI_VERSION; }

const char* mozhi_whisper_version(void) {
  static const std::string version = std::string("whisper.cpp ") +
                                     MOZHI_WHISPER_ENGINE_VERSION + " (ggml " +
                                     ggml_version() + ", CPU)";
  return version.c_str();
}

MozhiWhisperModel* mozhi_whisper_model_load(const char* path,
                                            int32_t n_threads) {
  ClearError();
  if (path == nullptr || *path == '\0') {
    SetError("path is required");
    return nullptr;
  }
  try {
    Setup();
    whisper_context_params params = whisper_context_default_params();
    params.use_gpu = false;  // Only the CPU backend is compiled in.
    whisper_context* context =
        whisper_init_from_file_with_params(path, params);
    if (context == nullptr) {
      SetError(std::string("cannot load the model ") + path);
      return nullptr;
    }
    auto* model = new (std::nothrow) MozhiWhisperModel();
    if (model == nullptr) {
      whisper_free(context);
      SetError("out of memory");
      return nullptr;
    }
    model->context = context;
    model->n_threads = n_threads > 0 ? n_threads : DefaultThreads();
    return model;
  } catch (const std::exception& error) {
    SetError(error.what());
  } catch (...) {
    SetError("unknown engine error");
  }
  return nullptr;
}

void mozhi_whisper_model_free(MozhiWhisperModel* model) {
  ClearError();
  if (model == nullptr) return;
  {
    std::lock_guard<std::mutex> lock(model->mutex);
    whisper_free(model->context);
    model->context = nullptr;
  }
  delete model;
}

int32_t mozhi_whisper_model_is_multilingual(MozhiWhisperModel* model) {
  ClearError();
  if (model == nullptr) {
    SetError("model is required");
    return 0;
  }
  return whisper_is_multilingual(model->context) != 0 ? 1 : 0;
}

char* mozhi_whisper_transcribe(MozhiWhisperModel* model, const float* samples,
                               int32_t n_samples, const char* language,
                               int32_t n_threads, char* detected_language,
                               int32_t detected_language_size) {
  ClearError();
  if (detected_language != nullptr && detected_language_size > 0) {
    detected_language[0] = '\0';
  }
  if (model == nullptr || (samples == nullptr && n_samples > 0) ||
      n_samples < 0) {
    SetError("model and samples are required");
    return nullptr;
  }
  // Read before anything else: a cancel from now on aborts this call.
  AbortState abort_state{g_cancel_generation.load()};
  try {
    std::lock_guard<std::mutex> lock(model->mutex);
    whisper_context* context = model->context;

    const bool multilingual = whisper_is_multilingual(context) != 0;
    const bool detect = IsAuto(language);
    if (!detect) {
      const int id = whisper_lang_id(language);
      // Models know the first n_vocab - 51765 - 1 languages (99 for every
      // model but large-v3, which adds Cantonese); English-only ones one.
      const int known =
          multilingual ? whisper_model_n_vocab(context) - 51765 - 1 : 1;
      if (id < 0 || id >= known) {
        SetError(std::string("language not supported by this model: ") +
                 language);
        return nullptr;
      }
    }

    whisper_full_params params =
        whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.n_threads = n_threads > 0 ? n_threads : model->n_threads;
    params.translate = false;
    params.no_context = true;
    params.no_timestamps = true;
    params.single_segment = false;
    params.print_special = false;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;
    params.token_timestamps = false;
    params.suppress_blank = true;
    params.suppress_nst = true;
    params.detect_language = false;  // true would only detect, not transcribe.
    params.language = multilingual ? (detect ? "auto" : language) : "en";
    params.abort_callback = ShouldAbort;
    params.abort_callback_user_data = &abort_state;

    const int status = n_samples == 0
                           ? 0
                           : whisper_full(context, params, samples, n_samples);
    if (ShouldAbort(&abort_state)) {
      SetError("cancelled");
      return nullptr;
    }
    if (status != 0) {
      SetError("transcription failed (whisper_full: " +
               std::to_string(status) + ")");
      return nullptr;
    }

    std::string text;
    const int segments = n_samples == 0 ? 0 : whisper_full_n_segments(context);
    for (int i = 0; i < segments; ++i) {
      const char* segment = whisper_full_get_segment_text(context, i);
      if (segment != nullptr) text += segment;
    }

    if (detected_language != nullptr && detected_language_size > 0) {
      const char* code = nullptr;
      if (!multilingual) {
        code = "en";
      } else if (!detect) {
        code = language;
      } else if (n_samples > 0) {
        const int id = whisper_full_lang_id(context);
        code = id >= 0 ? whisper_lang_str(id) : nullptr;
      }
      std::snprintf(detected_language,
                    static_cast<size_t>(detected_language_size), "%s",
                    code == nullptr ? "" : code);
    }
    return CopyString(Trim(text));
  } catch (const std::bad_alloc&) {
    SetError("out of memory");
  } catch (const std::exception& error) {
    SetError(error.what());
  } catch (...) {
    SetError("unknown engine error");
  }
  return nullptr;
}

void mozhi_whisper_cancel(void) {
  g_cancel_generation.fetch_add(1);
}

void mozhi_whisper_free_string(char* text) { std::free(text); }

MozhiWhisperVad* mozhi_whisper_vad_load(const char* path, int32_t n_threads) {
  ClearError();
  if (path == nullptr || *path == '\0') {
    SetError("path is required");
    return nullptr;
  }
  try {
    Setup();
    const int32_t window = SileroWindow(path);
    if (window == 0) {
      SetError(std::string("not a Silero VAD model: ") + path);
      return nullptr;
    }
    whisper_vad_context_params params = whisper_vad_default_context_params();
    params.n_threads = n_threads > 0 ? n_threads : 1;
    params.use_gpu = false;  // Only the CPU backend is compiled in.
    whisper_vad_context* context =
        whisper_vad_init_from_file_with_params(path, params);
    if (context == nullptr) {
      SetError(std::string("cannot load the VAD model ") + path);
      return nullptr;
    }
    auto* vad = new (std::nothrow) MozhiWhisperVad();
    if (vad == nullptr) {
      whisper_vad_free(context);
      SetError("out of memory");
      return nullptr;
    }
    vad->context = context;
    vad->window = window;
    // The LSTM state is not cleared when the model is loaded.
    whisper_vad_reset_state(context);
    return vad;
  } catch (const std::bad_alloc&) {
    SetError("out of memory");
  } catch (const std::exception& error) {
    SetError(error.what());
  } catch (...) {
    SetError("unknown engine error");
  }
  return nullptr;
}

void mozhi_whisper_vad_free(MozhiWhisperVad* vad) {
  ClearError();
  if (vad == nullptr) return;
  {
    std::lock_guard<std::mutex> lock(vad->mutex);
    whisper_vad_free(vad->context);
    vad->context = nullptr;
  }
  delete vad;
}

int32_t mozhi_whisper_vad_frame_size(MozhiWhisperVad* vad) {
  ClearError();
  if (vad == nullptr) {
    SetError("detector is required");
    return 0;
  }
  return vad->window;
}

int32_t mozhi_whisper_vad_process(MozhiWhisperVad* vad, const float* samples,
                                  int32_t n_samples, float* probs,
                                  int32_t max_probs) {
  ClearError();
  if (vad == nullptr || n_samples < 0 || max_probs < 0 ||
      (samples == nullptr && n_samples > 0) ||
      (probs == nullptr && max_probs > 0)) {
    SetError("detector, samples and probabilities are required");
    return -1;
  }
  try {
    std::lock_guard<std::mutex> lock(vad->mutex);
    std::vector<float>& pending = vad->pending;
    pending.insert(pending.end(), samples, samples + n_samples);
    const size_t window = static_cast<size_t>(vad->window);
    const int32_t frames = static_cast<int32_t>(
        std::min<size_t>(pending.size() / window,
                         static_cast<size_t>(max_probs)));
    if (frames == 0) return 0;
    const size_t used = static_cast<size_t>(frames) * window;
    // Keeps the LSTM state between calls ("for streaming").
    if (!whisper_vad_detect_speech_no_reset(vad->context, pending.data(),
                                            static_cast<int>(used))) {
      SetError("voice activity detection failed");
      return -1;
    }
    const int32_t written =
        std::min<int32_t>(whisper_vad_n_probs(vad->context), frames);
    const float* computed = whisper_vad_probs(vad->context);
    std::copy(computed, computed + written, probs);
    pending.erase(pending.begin(),
                  pending.begin() + static_cast<std::ptrdiff_t>(used));
    return written;
  } catch (const std::bad_alloc&) {
    SetError("out of memory");
  } catch (const std::exception& error) {
    SetError(error.what());
  } catch (...) {
    SetError("unknown engine error");
  }
  return -1;
}

void mozhi_whisper_vad_reset(MozhiWhisperVad* vad) {
  ClearError();
  if (vad == nullptr) return;
  std::lock_guard<std::mutex> lock(vad->mutex);
  vad->pending.clear();
  whisper_vad_reset_state(vad->context);
}

const char* mozhi_whisper_last_error(void) {
  return tls_has_error ? tls_error.c_str() : nullptr;
}

}  // extern "C"
