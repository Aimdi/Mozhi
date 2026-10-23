# llama_engine

On-device AI for Mozhi with **llama.cpp** (ggml CPU backend; no Google
services, nothing leaves the device): a catalogue of GGUF language models,
verified downloads and imports, and an engine that runs a model in a
background isolate and streams its answer. The app uses it as an
in-process `LlmClient` ("On this device"): Hy-MT2 1.8B translates, and an
assistant model (Gemma 4 E2B, or Qwen3 1.7B on smaller phones) powers the
AI extras.

## Usage

```dart
import 'package:llama_engine/llama_engine.dart';

if (!llamaPlatformSupported) return; // Android arm64-v8a / x86_64 only

final engine = createLlamaEngine(); // picks the CPU variant (see below)
final info = await engine.load(modelPath, contextSize: 4096); // mmap
print('${info.architecture} ${info.chatTemplateName} ${info.engine}');

final answer = StringBuffer();
await for (final piece in engine.generate(
  LlamaGenerateRequest(
    // e.g. one of Hy-MT2's translation prompts
    messages: [LlamaChatMessage(LlamaRole.user, prompt)],
    sampling: const LlamaSampling(), // Hy-MT2: 0.7 / top-k 20 / top-p 0.6
    maxTokens: 512,
    onFinish: (stats) => print('${stats.finishReason} '
        '${stats.tokensPerSecond.toStringAsFixed(1)} tokens/s'),
  ),
)) {
  answer.write(piece); // whole UTF-8 characters, as they come
}

await engine.cancel(); // stops running and waiting generations
await engine.unload(); // memory back to the system
```

Cancelling the stream's subscription cancels that generation (and only
that one); `jsonOutput: true` constrains the answer to one JSON object;
`stop` ends it before a string. A prompt that does not leave room for
`maxTokens` fails with `LlamaContextException` (with the prompt's token
count); `countTokens` measures one first.

## API

| Type | What |
| --- | --- |
| `LlamaEngine`, `createLlamaEngine`, `llamaPlatformSupported` | The engine: `load` (one model at a time, memory-mapped), `generate` (a stream of text pieces; one generation at a time, the next waits), `countTokens`, `cancel`, `unload`, `loadedModelPath`, `dispose`. On Android it is `IsolateLlamaEngine` (a long-lived background isolate); on the web a stub whose calls fail with `UnsupportedError` (conditional export: `dart:ffi` never reaches web builds) |
| `LlamaGenerateRequest`, `LlamaChatMessage`, `LlamaRole`, `LlamaSampling` | What to generate: a conversation (formatted with the model's chat template), sampling (temperature, top-k, top-p, min-p, repetition penalty over the last `repeatLastN` tokens, seed; `LlamaSampling.greedy`), `maxTokens`, `jsonOutput`, `stop`, `onFinish` |
| `LlamaGenerateStats`, `LlamaFinishReason` | Prompt and answer tokens, durations, tokens/s, and why it ended: `stop` (end of text or a stop string) or `length` (`maxTokens` or a full context: the answer may be cut short) |
| `LlamaModelInfo` | Architecture, name, training and loaded context, parameters, size, chat template (supported? which?), the engine and CPU variant |
| `LlamaEngineException`, `LlamaNotLoadedException`, `LlamaContextException`, `LlamaCancelledException` | Failures |

Model catalogue, downloads and imports: `LlamaModelCatalog`,
`LlamaModelManager` and friends (`lib/src/catalog.dart`,
`lib/src/model_manager.dart`, `assets/models.json`).

### Chat templates

`generate` and `countTokens` format the messages with the model's own
template: the ones llama.cpp knows (`llama_chat_apply_template`: ChatML,
`hunyuan-dense` for Hy-MT2, Gemma 1-3, Llama 3, ...) and two the shim
formats itself: **Gemma 4** (`<|turn>` ... `<turn|>`, with the empty
thought channel that turns thinking off) and **Qwen3** (ChatML plus the
empty `<think></think>` that turns thinking off). A model without a usable
template is reported by `LlamaModelInfo.chatTemplate == false` and cannot
chat. When the embedded template is unknown, the architecture decides
(`gemma4`, `qwen3`, `hunyuan-dense`).

Message contents are untrusted text (documents, web pages, OCR), so they
are never parsed for special tokens: the shim formats the template with a
random sentinel in place of each content (a template that trims contents
trims the sentinel's `\v` too), splits the result into the template's
text and the contents, and tokenizes only the template's text with
special tokens. The contents, and the template's text between its special
tokens, are plain text (`parse_special` off, and split after the first
character of any special token's text, so neither a control token such as
`<|im_end|>`, `<turn|>`, `<|endoftext|>`, `<eos>` nor a user-defined one
such as Gemma 4's `<|channel>` can come out of them). The BOS token is
added once, at the start. For ordinary text the tokens are the same as
for the formatted prompt as a whole. NUL characters are removed from
messages and stop strings before they reach the C API.

## Native library

`libmozhi_llama*.so` export only the C API in
[`native/src/mozhi_llama.h`](native/src/mozhi_llama.h) (`mozhi_llama_*`,
ABI version 2; version script `native/src/mozhi_llama.map`):

| Function | What |
| --- | --- |
| `abi_version`, `version`, `cpu_features` | Checks and diagnostics (`cpu_features`: the compiled architecture and what ggml finds at run time) |
| `model_load(path, n_threads, n_ctx, use_mmap)`, `model_free`, `model_info` | One handle = the weights + one context; `n_ctx` is capped at the training context (llama.cpp rounds it up to a multiple of 256); `model_info` returns JSON |
| `chat_format(handle, roles[], contents[], n, add_assistant)` | The prompt as text (display, diagnostics), or NULL + `last_error` when the model has no supported template; roles `system`, `user`, `assistant` only |
| `chat_tokenize(handle, roles[], contents[], n, add_assistant, tokens, n_max)` | The prompt's tokens (and their count) as `chat_generate_begin` uses them: template markers special, contents plain text (see Chat templates) |
| `chat_generate_begin(handle, roles[], contents[], n, add_assistant, params)`, `generate_next(handle, buf, size)`, `generate_end(handle)`, `generate_stats(handle, stats)` | A generation: `begin` clears the KV cache and checks the prompt fits (`MOZHI_LLAMA_E_CONTEXT` when it has more than `n_ctx - max_tokens` tokens); each `next` returns the next piece (> 0 bytes, never part of a UTF-8 character; invalid bytes become U+FFFD), 0 at the end, -1 on errors, -2 when cancelled; text that may start a stop string is held back until it is known not to |
| `generate_begin(handle, prompt, params)`, `tokenize_count(handle, text)` | The same for a raw prompt, whose special-token text is parsed everywhere: trusted text only (the CLI's `--raw`); the Dart engine never uses them for messages |
| `json_grammar` | llama.cpp's `grammars/json.gbnf` (embedded at configure time from the pinned checkout) for `params.grammar` |
| `cancel()`, `params.cancel_flag` | The global cancel (every generation running now) and a per-generation flag another thread sets; both are checked between tokens and, through ggml's abort callback, during prompt processing |
| `free_string`, `last_error` | Memory and errors (thread-local) |

Calls on one handle are serialised by its lock, except `model_free`, which
must not race another call on the same handle (the Dart engine makes all
calls from its isolate). No exception crosses the C API; a failed ggml
assertion or an exception that escapes anyway aborts with a message (the
shim sets ggml's abort callback and its own `std::terminate` handler, so
ggml never `fork()`s the app for a debugger's backtrace).

Sampling runs repetition penalty (the prompt's last tokens count too, as in
Hugging Face's `repetition_penalty`), top-k, top-p, min-p, temperature and
a random pick (greedy at temperature 0). With a grammar, the chain's pick
is checked against the grammar first and only a rejected pick re-samples
the grammar-filtered vocabulary. Logging is silent (the first error of a
call is kept for its message); nothing touches the network.

llama.cpp and ggml are linked statically, CPU backend only (no OpenMP,
BLAS, GPU, llamafile, KleidiAI, libcurl or OpenSSL; `GGML_CPU_REPACK` on
for Q4 weights), one shared library per CPU variant:

| ABI | Library | CPU |
| --- | --- | --- |
| arm64-v8a | `libmozhi_llama.so` | ARMv8.0-A (NEON): every arm64 phone |
| arm64-v8a | `libmozhi_llama_dotprod.so` | ARMv8.2-A + dotprod + fp16 (Cortex-A55/A75 and later) |
| arm64-v8a | `libmozhi_llama_i8mm.so` | ARMv8.6-A + dotprod + fp16 + i8mm (Cortex-A510/A710/X2 and later) |
| x86_64 | `libmozhi_llama.so` | SSE4.2 (emulators, Chromebooks) |

There is no armeabi-v7a build (a 1-2 GB model cannot be mapped into a
32-bit address space reliably). `createLlamaEngine` reads `/proc/cpuinfo`
(`ArmCpuFeatures`: a feature counts only if every core lists it, since
big.LITTLE cores can differ) and opens `_i8mm` with i8mm + dotprod + fp16,
`_dotprod` with dotprod + fp16, else the baseline; when the chosen library
fails to open or reports another ABI version, it falls back to the
baseline. A variant on a CPU without its instructions would crash
(SIGILL), which is why the check is strict. Only ggml's CPU backend
differs between the variants (as in ggml's own `GGML_CPU_ALL_VARIANTS`):
`native/CMakeLists.txt` compiles it once per variant from the sources and
settings of the baseline target with its own `-march`, and links each
variant library from the same llama and ggml-base archives; no cache
option is shared or changed. There is no `GGML_BACKEND_DL`: Android keeps
native libraries inside the APK, and ggml's backend loader scans
directories.

| Path | What |
| --- | --- |
| `native/CMakeLists.txt` | The libraries from the pinned sources (`-ffile-prefix-map`, `--gc-sections`, `--no-undefined`, version script, `-z max-page-size=16384` on Android); nothing is downloaded |
| `native/third_party/llama.cpp` | Submodule, tag v0.6.0 (`d81235049384534c167caea52b85a694f6103d14`), unmodified |
| `native/tool/mozhi_llama_cli.c` | Smoke test / benchmark: `mozhi_llama_cli MODEL [--json] [--max N] [--temp T] [--stop S] ... [PROMPT]` (prints the model, streams the answer, then prompt and generation speed) |
| `native/THIRD_PARTY_NOTICES.md` | llama.cpp, ggml, YaRN (MIT), Unicode data (Unicode License v3), libc++ |
| `android/build.gradle` | `externalNativeBuild` (NDK 28.2.13676358, CMake 3.22.1, arm64-v8a / x86_64, `c++_static`, 16 KB pages; targets `mozhi_llama`, `mozhi_llama_dotprod`, `mozhi_llama_i8mm`) |
| `tool/fetch_native_deps.sh` | Checks out the pinned submodule (shallow); `tool/fetch_native_deps.sh` at the repository root runs it |
| `tool/build_native_linux.sh` | Builds `build/native/linux/libmozhi_llama.so` (+ the CLI) for the tests |
| `tool/make_test_model.py` | Writes the tests' tiny models (below) |

## Building and testing

```sh
packages/llama_engine/tool/fetch_native_deps.sh   # once per checkout
packages/llama_engine/tool/build_native_linux.sh  # host library (a few minutes)
python3 packages/llama_engine/tool/make_test_model.py \
  --all packages/llama_engine/build/test_models    # needs numpy

# from packages/llama_engine (agents: the Very Good CLI test tool)
flutter test
```

The test models (about 3 MB each, deterministic, never committed) are
llama-architecture GGUFs with random weights and LLaMA's SentencePiece
vocabulary, written with llama.cpp's own gguf-py. Their weights follow a
small "script" so the tests can check exact output: after a ChatML or
Qwen3 prompt the model writes `abcdefghijklmnopqrstuvwxyz中` (中 as three
byte tokens) and ends, after a Gemma 4 prompt it counts digits forever,
and with the JSON grammar it answers `{}`. One file per chat template
(`llama-test-chatml.gguf`, `-qwen3`, `-gemma4`, `-hunyuan-dense`,
`-llama3`, `-none`). Two more borrow the vocabularies of real chat models,
whose markers are special tokens (`llama-test-qwen2-vocab.gguf`, about
9 MB, with Qwen3's template, and `-gemma4-vocab.gguf`, about 21 MB, with
Gemma 4's; random weights, no script), for the tests that special-token
text in a message stays plain text.
`test/src/engine/native_engine_test.dart` uses them for loading, model
info, chat formats, token counts, streaming and UTF-8 pieces, stop
strings, `maxTokens`, JSON output, context errors, cancellation (per
generation, `cancel()` and the global cancel from another isolate),
unload/reload and back-to-back generations; it is skipped without the
library or the models. `test/src/engine/isolate_engine_test.dart` checks
the isolate protocol with a fake native layer, and
`cpu_features_test.dart` the variant choice with real `/proc/cpuinfo`
samples.

`LLAMA_LIBRARY_PATH` overrides the library and `LLAMA_TEST_MODELS` the
models' directory. CI builds the host library (with ccache) and the test
models before the package tests, and the Android libraries in the job
*Build llama native (Android)*.

To try a real model on the host:

```sh
build/native/linux/mozhi_llama_cli Hy-MT2-1.8B-Q4_K_M.gguf --threads 4 \
  "Translate the following text into German. Note that you should only \
output the translated result without any additional explanation:

Good morning"
```

The arm64 variants can be checked on an x86_64 machine with a cross
compiler and QEMU, e.g.
`CMAKE_ARGS="-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64
-DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc
-DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++" tool/build_native_linux.sh
build/native/aarch64`, then `qemu-aarch64 -cpu max -L
/usr/aarch64-linux-gnu` running the CLI with each library (the `_i8mm`
one stops with SIGILL under `-cpu cortex-a53`, the baseline runs).
