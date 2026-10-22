# whisper_speech

Offline, on-device speech recognition for Mozhi with **OpenAI's Whisper**
models on **whisper.cpp** (ggml CPU backend; no Google services, nothing
leaves the device). The app records 16 kHz mono PCM and hands the samples
to this package; it does not record audio itself.

User documentation: [`docs/voice-input.md`](../../docs/voice-input.md).

## Usage

```dart
import 'package:whisper_speech/whisper_speech.dart';

final whisper = WhisperSpeech(
  catalog: await loadBundledWhisperCatalog(),
  root: appPrivateDirectory, // models go to <root>/models/<id>/
);

// Only when the user asked for it (Wi-Fi/metered rules are the app's job):
await whisper.download(whisper.catalog.model('tiny')!); // size, SHA-1, SHA-256 checked
// ...or without any network request:
await whisper.importFiles([File('/sdcard/Download/ggml-tiny.bin')]);

final buffer = Pcm16Buffer.window(); // 30 s of 16 kHz mono PCM16 at most
microphoneChunks.listen(buffer.add); // little-endian PCM16 bytes
final result = await whisper.transcribe(
  buffer.toFloat32List(),
  language: 'de', // or 'auto'; app codes such as 'pt-BR' or 'jv' work too
); // in a background isolate
print('${result.text} (${result.language})');

await whisper.cancel(); // aborts a running transcription

// Voice activity detection (Silero VAD; `whisper.vadModel` is downloaded
// or imported like a speech model). In its own isolate, chunk by chunk:
await whisper.resetSpeechDetection(); // a new recording
final frames = await whisper.detectSpeech(pcm16ToFloat32(chunk));
print(frames.probabilities); // one 0..1 per 512 samples (32 ms)
```

`isAvailable` is false on the web and on CPUs the library is not built for;
`transcribe` throws `WhisperModelMissingException` without an installed
model.

## API

| Type | What |
| --- | --- |
| `WhisperSpeech` | Facade: `isAvailable`, `installedModels()`, `isReady()`, `modelFor()`, `transcribe()`, `cancel()`, `unload()`, `download()`, `delete()`, `importFiles()`, `cleanUp()`, `dispose()`; with `idleUnloadAfter` the model (75-150 MB) is unloaded once no transcription ran for that long (the app uses 60 s and also unloads in the background and on memory pressure). Voice activity detection: `vadModel`, `installedVad()`, `isVadReady()`, `detectSpeech()`, `resetSpeechDetection()` |
| `WhisperModelCatalog`, `WhisperCatalogModel`, `loadBundledWhisperCatalog` | `assets/models.json`: `tiny` (Fast) and `base` (Better) with URL, exact size, SHA-1 and SHA-256, and the Silero VAD model (`vad`, the entry with `"kind": "vad"`) |
| `WhisperModelManager` | Download with `Range` resume (from the catalog's URL or a mirror), size + SHA-1 + SHA-256 verification, atomic install (staging + rename), delete, `importFiles` (by name or, for renamed copies, by size), `cleanUp` |
| `WhisperEngine`, `createWhisperEngine`, `whisperPlatformSupported` | The native engine in a long-lived background isolate (`IsolateWhisperEngine`); a stub on the web (conditional export: `dart:ffi` never reaches web builds) |
| `WhisperVadEngine`, `createWhisperVadEngine`, `WhisperVadFrames` | Silero VAD in a second isolate (`IsolateWhisperVadEngine`), so it keeps up with the microphone while a phrase is transcribed; it keeps one stream's state (LSTM and leftover samples) between calls |
| `WhisperTranscription` | `text` and the Whisper code of the language it was transcribed in |
| `whisperLanguages`, `whisperLanguageFor`, `languageForWhisper` | The 99 languages of tiny/base; app/BCP-47 codes to Whisper codes (`zh-TW` -> `zh`, `jv` -> `jw`, `fil` -> `tl`, `nb` -> `no`) and back |
| `pcm16ToFloat32`, `Pcm16Buffer`, `Pcm16Decoder`, `rmsDbfs` | PCM16 LE bytes to samples (chunks may split a sample), capped buffer, chunk-by-chunk decoder, loudness in dBFS |

## Models

`assets/models.json` lists the multilingual F16 models published by
whisper.cpp on Hugging Face
(`https://huggingface.co/ggerganov/whisper.cpp/resolve/main/<file>`):

| id | File | Bytes | SHA-1 |
| --- | --- | --- | --- |
| `tiny` | `ggml-tiny.bin` | 77,691,713 | `bd577a113a864445d4c299885e0cb97d4ba92b5f` |
| `base` | `ggml-base.bin` | 147,951,465 | `465707469ff3a37a2b9b8d8f89f2f99de7299dac` |
| `silero-vad` (`kind: vad`) | `ggml-silero-v6.2.0.bin` | 885,098 | `470e5d9d094ddba2f0a512cecc3732a252188abd` |

The VAD model is Silero VAD v6.2.0 (MIT) converted by whisper.cpp, served
from `https://huggingface.co/ggml-org/whisper-vad/resolve/main/` (the same
host as the speech models, so a model mirror serves it as
`<mirror>/whisper/ggml-silero-v6.2.0.bin`). Its size and checksums are those
of the copy whisper.cpp v1.9.5 ships for its tests
(`models/for-tests-silero-v6.2.0-ggml.bin`, the real model; a test compares
them), which matches the 864.35 KiB of whisper.cpp's README; CI compares
size and SHA-256 with Hugging Face (`tool/check_model_downloads.py` reads
every `models` entry).

The SHA-1s are the ones in whisper.cpp v1.9.5's `models/README.md` (a test
compares them). Quantized variants (`ggml-tiny-q5_1.bin`,
`ggml-base-q5_1.bin`, `-q8_0`; 2-3x smaller) run on the existing library
(ggml has NEON kernels for them) but are not listed yet: their exact sizes
and SHA-1s must be taken from Hugging Face first (the README lists none). Hugging Face could not be reached when the catalogue was
written; the byte sizes were checked against the layout
`convert-pt-to-ggml.py` writes (the tensors of tiny and base differ by
exactly the 70,259,752 bytes these sizes differ by). If a download ever
fails with a size mismatch, compare with the file sizes on Hugging Face.

## Native library

`libmozhi_whisper.so` exports only the C API in
[`native/src/mozhi_whisper.h`](native/src/mozhi_whisper.h) (`mozhi_whisper_*`:
ABI/version (2), model load/free, transcribe, cancel, free_string,
last_error, and voice activity detection: `vad_load`, `vad_free`,
`vad_frame_size`, `vad_process` (streaming: probabilities of the windows a
chunk completes, state kept between calls) and `vad_reset`; version script
`native/src/mozhi_whisper.map`). A file that is not a Silero model is
refused before whisper.cpp reads it. Decoding: greedy with
Whisper's temperature fallback, no timestamps, no context, non-speech
tokens suppressed, never translating. whisper.cpp and ggml are linked
statically, CPU backend only (no OpenMP, BLAS, GPU, Core ML, OpenVINO or
KleidiAI), with one portable baseline per ABI:

| ABI | CPU baseline |
| --- | --- |
| arm64-v8a | ARMv8.0-A (no dotprod/i8mm/FP16 arithmetic: ggml can only pick those at run time with one library per variant) |
| armeabi-v7a | NEON + VFPv4 (Dart checks `/proc/cpuinfo` first) |
| x86_64 | SSE4.2 (no AVX/F16C/FMA: emulators, Chromebooks) |

| Path | What |
| --- | --- |
| `native/CMakeLists.txt` | One shared library from the pinned sources; nothing is downloaded |
| `native/third_party/whisper.cpp` | Submodule, tag v1.9.5 (`d1be6fde11ac6e0407606b4e42fe72d34add8037`), unmodified |
| `native/tool/mozhi_whisper_cli.c` | Smoke test / benchmark: `mozhi_whisper_cli MODEL [WAV\|--silence S] [LANG] [THREADS]`, or `mozhi_whisper_cli --vad VAD_MODEL WAV [CHUNK]` (prints where speech is) |
| `native/THIRD_PARTY_NOTICES.md` | whisper.cpp, ggml, YaRN (MIT), libc++; the models (MIT, OpenAI) |
| `android/build.gradle` | `externalNativeBuild` (NDK 28.2.13676358, CMake 3.22.1, arm64-v8a / armeabi-v7a / x86_64, `c++_static`, 16 KB pages) |
| `tool/fetch_native_deps.sh` | Checks out the pinned submodule (shallow); `tool/fetch_native_deps.sh` at the repository root runs it |
| `tool/build_native_linux.sh` | Builds `build/native/linux/libmozhi_whisper.so` (+ the CLI) for the tests |

## Building and testing

```sh
packages/whisper_speech/tool/fetch_native_deps.sh   # once per checkout
packages/whisper_speech/tool/build_native_linux.sh  # host library (~40 s)

# from packages/whisper_speech (agents: the Very Good CLI test tool)
flutter test
```

Without the host library the real-engine tests
(`test/src/isolate_engine_test.dart`, `test/src/vad_engine_test.dart`) are
skipped. They use whisper.cpp's empty-weight test models
(`native/third_party/whisper.cpp/models/for-tests-*.bin`), which load and
run like real ones but recognise nothing: load, silence, language errors,
the background isolate and cancellation. The Silero test model is the real
one: the VAD tests check that it hears the phrases of `samples/jfk.wav` and
the pauses between them, however the stream is cut. To try a real model:

```sh
build/native/linux/mozhi_whisper_cli ggml-tiny.bin \
  native/third_party/whisper.cpp/samples/jfk.wav en
build/native/linux/mozhi_whisper_cli --vad \
  native/third_party/whisper.cpp/models/for-tests-silero-v6.2.0-ggml.bin \
  native/third_party/whisper.cpp/samples/jfk.wav
```

On the x86-64 baseline, the detector takes about 0.6 ms per 32 ms window
(11 s of audio in 0.2 s, one thread).

`WHISPER_LIBRARY_PATH` overrides the library path.
