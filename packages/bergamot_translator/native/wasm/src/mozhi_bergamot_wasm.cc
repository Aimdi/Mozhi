// mozhi_bergamot for WebAssembly: the C API of ../../src/mozhi_bergamot.h
// (ABI 2: translate_ex with alignment and quality scores, CLD2 language
// identification), compiled into bergamot-translator.wasm for the web app's
// worker (web/bergamot/worker.js), plus what a browser needs instead of
// file paths: models are loaded from memory.
//
// The browser has no file system the engine could read, so a model comes
// from four buffers the worker fills with the bytes of the files it keeps in
// the Origin Private File System:
//
//   buffer = mozhi_bergamot_buffer_create(size, alignment);
//   HEAPU8.set(bytes, mozhi_bergamot_buffer_data(buffer));
//   model = mozhi_bergamot_model_create_from_buffers(model_buffer,
//       shortlist_buffer, vocab_buffer, NULL, "en", "de", extra_config, 1);
//
// Everything else (translate_ex, detect, model_destroy, free_string, ...)
// is the native library's code, compiled in this translation unit so that
// the two builds cannot drift apart.
//
// Copyright (c) 2026 Mozhi contributors. MIT License.

#include "../../src/mozhi_bergamot.cc"

#include <cstddef>

#include "translator/definitions.h"

static_assert(sizeof(MozhiBergamotLanguage) == 24,
              "worker.js reads MozhiBergamotLanguage at fixed offsets");
static_assert(offsetof(MozhiBergamotDetection, languages) == 16,
              "worker.js reads MozhiBergamotDetection at fixed offsets");
static_assert(offsetof(MozhiBergamotDetection, text_bytes) == 88,
              "worker.js reads MozhiBergamotDetection at fixed offsets");
static_assert(offsetof(MozhiBergamotDetection, reliable) == 92,
              "worker.js reads MozhiBergamotDetection at fixed offsets");
static_assert(sizeof(MozhiBergamotDetection) == 96,
              "worker.js allocates 96 bytes for MozhiBergamotDetection");

namespace {

using marian::bergamot::AlignedMemory;
using marian::bergamot::MemoryBundle;

// The configuration of a model loaded from memory: the native defaults
// (kDefaultConfig) without file paths, the gemm precision of the model's
// format, then `extra_config` (which may override any of them; the worker
// lowers `workspace` for browsers).
std::string MemoryConfig(bool alphas, const char* extra_config) {
  const std::string extra = IsBlank(extra_config) ? "" : extra_config;
  std::string config = kDefaultConfig;
  if (extra.find("gemm-precision") == std::string::npos) {
    config += alphas ? "gemm-precision: int8shiftAlphaAll\n"
                     : "gemm-precision: int8shiftAll\n";
  }
  if (!extra.empty()) {
    config += extra;
    if (extra.back() != '\n') config += '\n';
  }
  return config;
}

// Takes the AlignedMemory out of a buffer handle (which is deleted).
AlignedMemory Take(void* buffer) {
  auto* memory = static_cast<AlignedMemory*>(buffer);
  AlignedMemory taken(std::move(*memory));
  delete memory;
  return taken;
}

}  // namespace

extern "C" {

/* Allocates `size` bytes aligned to `alignment` (a power of two: 256 for a
 * model, 64 for shortlists and vocabularies) for
 * mozhi_bergamot_model_create_from_buffers(). Returns a handle, or NULL
 * when out of memory. */
MOZHI_BERGAMOT_EXPORT void* mozhi_bergamot_buffer_create(int32_t size,
                                                         int32_t alignment) {
  ClearError();
  if (size <= 0 || alignment <= 0 || (alignment & (alignment - 1)) != 0) {
    SetError("size must be positive and alignment a power of two");
    return nullptr;
  }
  auto* memory = new AlignedMemory(static_cast<size_t>(size),
                                   static_cast<size_t>(alignment));
  if (memory->begin() == nullptr) {
    delete memory;
    SetError("out of memory");
    return nullptr;
  }
  return memory;
}

/* The first byte of a buffer, for the caller to write `size` bytes to. */
MOZHI_BERGAMOT_EXPORT char* mozhi_bergamot_buffer_data(void* buffer) {
  return buffer == nullptr ? nullptr
                           : static_cast<AlignedMemory*>(buffer)->begin();
}

/* Frees a buffer that was not given to a model (NULL is ignored). */
MOZHI_BERGAMOT_EXPORT void mozhi_bergamot_buffer_destroy(void* buffer) {
  delete static_cast<AlignedMemory*>(buffer);
}

/* mozhi_bergamot_model_create() for memory: `model` (256-byte aligned),
 * `shortlist` and `src_vocab` are required, `trg_vocab` is NULL when the
 * vocabulary is shared. The model takes the buffers (even when it fails:
 * do not use or destroy them afterwards). `source` and `target` are the
 * languages' BCP-47 codes: the engine splits sentences with the browser's
 * Intl.Segmenter for `source` and joins words as `target` writes them.
 * `alphas` != 0 for *.alphas.bin models (int8shiftAlphaAll). */
MOZHI_BERGAMOT_EXPORT MozhiBergamotModel*
mozhi_bergamot_model_create_from_buffers(void* model, void* shortlist,
                                         void* src_vocab, void* trg_vocab,
                                         const char* source,
                                         const char* target,
                                         const char* extra_config,
                                         int32_t alphas) {
  if (model == nullptr || shortlist == nullptr || src_vocab == nullptr ||
      IsBlank(source) || IsBlank(target)) {
    for (void* buffer : {model, shortlist, src_vocab, trg_vocab}) {
      mozhi_bergamot_buffer_destroy(buffer);
    }
    SetError("model, shortlist, src_vocab, source and target are required");
    return nullptr;
  }
  MemoryBundle bundle;
  bundle.models.emplace_back(Take(model));
  bundle.shortlist = Take(shortlist);
  auto source_vocab = std::make_shared<AlignedMemory>(Take(src_vocab));
  bundle.vocabs.push_back(source_vocab);
  bundle.vocabs.push_back(
      trg_vocab == nullptr ? source_vocab
                           : std::make_shared<AlignedMemory>(Take(trg_vocab)));
  const std::string config = MemoryConfig(alphas != 0, extra_config);
  const std::string source_language(source);
  const std::string target_language(target);
  return Guarded<MozhiBergamotModel*>(nullptr, [&]() -> MozhiBergamotModel* {
    auto options = marian::bergamot::parseOptionsFromString(
        config, /*validate=*/false);
    Service();  // Marian's loggers must exist before a model is built.
    auto handle = std::make_unique<MozhiBergamotModel>();
    handle->model = std::make_shared<TranslationModel>(
        options, std::move(bundle), /*replicas=*/1);
    handle->model->registerSourceLanguage(source_language);
    handle->model->registerTargetLanguage(target_language);
    ++g_live_models;
    return handle.release();
  });
}

}  // extern "C"
