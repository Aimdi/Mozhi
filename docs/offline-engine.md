# Offline engine: Mozilla Firefox Translations (Bergamot)

Status: **the app's offline engine in every build** (wave B), and since
wave 3 **in the web app too**, compiled to WebAssembly ([Web app](#web-app)).
Built and proven on Linux x86_64 (real models) and on ARM (aarch64 and
armv7 under qemu); the Android build runs on CI (no device run yet); the
web engine runs in Chromium here. Package:
[`packages/bergamot_translator`](../packages/bergamot_translator/).

It replaced Google ML Kit (proprietary, Google Play services adjacent,
missing from the F-Droid build) with Mozilla's open models, the ones
Firefox uses for its built-in translation. The default build now contains
no Google code at all; ML Kit survives only as on-device text recognition
in the optional Play variant ([build variants](contributing.md#build-variants)).
ML Kit's language identification is replaced by CLD2, compiled into the
same native library ([Language identification](#language-identification)).

## Decision

Use **Mozilla's own fork of bergamot-translator, which now lives in
[`mozilla/translations`](https://github.com/mozilla/translations) under
`inference/`** (bergamot v0.6.0 + its Marian fork), vendored as a pinned git
submodule, behind a ~800-line C API (`native/src/mozhi_bergamot.{h,cc}`)
called from Dart with `dart:ffi` in a background isolate.

| Candidate | License | Maintained | Runs Mozilla's current models | Android ARM | Verdict |
| --- | --- | --- | --- | --- | --- |
| [jerinphilip/slimt](https://github.com/jerinphilip/slimt) | **GPL-2.0-or-later** (`COPYRIGHT`: "either version 2 of the License, or (at your option) any later version") | last commit 2024-04-11 | No: `slimt/Model.cc` hard-codes `tiny`/`base` configurations; 72 of the 113 released directions are `base-memory`, 7 use split vocabularies | yes (ruy, gemmology) | **Rejected**: linking it into the APK makes the shipped app a GPL work; the app is MIT. |
| [browsermt/bergamot-translator](https://github.com/browsermt/bergamot-translator) | MPL-2.0 (Marian: MIT) | frozen: v0.4.5, last commit 2024-05-12 | yes | arm64 CI existed (`.github/workflows/arm.yml`, NDK r23b) | Superseded by Mozilla's fork below. |
| **mozilla/translations `inference/`** | **MPL-2.0** (`LICENSE`), Marian fork **MIT** (`inference/marian-fork/LICENSE.md`) | yes: Mozilla moved bergamot here in Oct 2024 ("Fork bergamot-translator into this repository", #867); pinned commit `69455aca` (2026-09-25) | yes, by definition: it is the engine Firefox runs these models with (as WebAssembly) and the one Mozilla evaluates them with | ARM path (ruy + simd_utils) inherited from browsermt; needed build fixes, all done in our CMake (see below) | **Chosen.** |
| [jesses2025smith/bergamot_translator](https://github.com/jesses2025smith/bergamot_translator) (Flutter plugin) | MPL-2.0 | one author, ~2 weeks of commits (2026-01) | via DavidVentura's fork | arm64 + x86_64 only: armeabi-v7a disabled ("missing NEON intrinsics … vcvtnq_s32_f32"), minSdk 28, a patch must be applied by hand | Not adopted: no catalog, downloads, verification or pivoting; reviewed for ideas only. |
| DavidVentura/bergamot-translator + marian-dev forks (used by the GPL-3.0 app offline-translator) | MPL-2.0 / MIT | yes | yes | arm64, armv7, x86, x86_64 | Read for ideas only; no code taken from the GPL app. Our armv7 rounding helper uses the same textbook technique as his MIT Marian fork. |

Why not just ML Kit-style "one binary per language"? Bergamot models are
plain files (model, lexical shortlist, SentencePiece vocabulary); the engine
is one ~6-10 MB native library for all languages.

## Architecture

```
BergamotTranslator (implements DetailedOfflineTranslator)  lib/src/bergamot_translator.dart
 ├─ ModelCatalog       assets/catalog.json (113 directions)  lib/src/catalog.dart
 ├─ ModelRouter        app codes -> Mozilla codes, direct    lib/src/model_router.dart
 │                     model or pivot through English
 ├─ BergamotModelManager  download, SHA-256, gunzip, atomic  lib/src/model_manager.dart
 │                     install under <root>/models/<pair>/<version>/
 ├─ TextChunker        paragraph/line/sentence pieces        lib/src/text_chunker.dart
 ├─ identifyLanguage() Cld2Decision over CLD2 + heuristic    lib/src/native_language_identifier.dart
 │   ├─ NativeLanguageIdentifier  IsolateLanguageIdentifier: lib/src/engine/ffi/
 │   │     Isolate.run per call -> mozhi_bergamot_detect -> CLD2
 │   └─ LanguageIdentifier  heuristic (scripts + function    lib/src/language_identifier.dart
 │         words): fallback and second opinion
 └─ BergamotBatchEngine  IsolateBergamotEngine: one long-   lib/src/engine/ffi/
      lived background isolate, requests queued on the UI side and sent
      one at a time -> NativeEngine (dart:ffi, LRU of 2-4 models)
        -> libmozhi_bergamot.so (C API) -> bergamot BlockingService -> Marian
```

* **Threading:** every translation call happens in one background isolate
  (`Isolate.spawn`, started lazily, restarted if it dies); the UI isolate
  only sends messages. The C API serialises them with a mutex (the
  engine and Marian's loggers are process-global), converts every engine
  error into a message (`marian::setThrowExceptionOnAbort`), never aborts.
  Language identification runs in its own short-lived isolate per call
  (`Isolate.run`) and takes no lock (CLD2 is stateless), so it never waits
  behind a long translation.
* **Long text:** pieces of at most 2000 characters, cut at blank lines, then
  line breaks, then sentence ends; the engine splits each piece into
  sentences itself (ssplit) and keeps whitespace, so paragraphs survive.
  The pieces go to the engine in batches of up to 6000 characters, one
  native call (`mozhi_bergamot_translate_ex`) per batch, so Bergamot
  batches their sentences together; see
  [Responsiveness](#responsiveness-alignment-and-memory).
  A sentence cache (2048 entries) makes re-translating edited text cheap.
* **Pivoting:** all Firefox models are xx->en or en->xx. es->de runs es->en
  then en->de inside the engine (`pivotMultiple`, no re-splitting).
  "Downloading Spanish" installs es-en and en-es; English needs no model.
* **Web:** the package imports on every platform; `dart:ffi` is behind a
  conditional import (`engine_factory.dart`). In a browser the same
  `BergamotTranslator` runs the WebAssembly build of the engine in a worker,
  with the models in the browser's private storage ([Web app](#web-app)).

## Responsiveness, alignment and memory

Added in wave 1 (`DetailedOfflineTranslator` in
`translation_repository`, `BergamotBatchEngine` here; both are separate
interfaces, so other `OfflineTranslator`/`BergamotEngine` implementations
keep compiling).

* **Batching.** `translate` sends the pieces of a text in one native call
  per 6000 characters (`maxBatchLength`, about Bergamot's mini-batch of
  1024 words). Typed text is therefore always one call; a long document
  is several, so it can be cancelled between them.
* **Abort.** `translate(..., abort:)` / `translateDetailed(..., abort:)`:
  once the future completes, the request stops before its next batch and
  throws `OfflineTranslationCancelledException`. The isolate engine keeps
  its queue on the UI side and sends one request at a time, so a request
  that is aborted while it waits never reaches the engine; one already in
  the native call finishes in the background (Bergamot cannot be
  interrupted), but its caller is released at once (2-41 ms in the
  real-model test). `TranslationRepository` passes an abort that completes
  when the caller cancels the translation stream
  (`offline/offline_requests.dart`), so text typed over a long input no
  longer queues stale work.
* **Preload.** `preload(source:, target:)` loads the installed models of
  a pair in the engine isolate ahead of the first translation (it never
  downloads or throws; false for `auto`, a missing model or an
  unsupported pair). The app should call it when the on-device engine is
  selected for an installed pair and when the input gains focus.
* **Alignment and confidence.** `translateDetailed` returns an
  `OfflineTranslation`: per sentence its source and target range, a
  score, and per translated word the source word it most likely comes
  from (Marian's soft alignment, summed over the word's tokens) with that
  probability. Offsets are UTF-16 code units, computed in C++. Words are
  SentencePiece tokens grouped at whitespace like Bergamot's quality
  estimator; in scripts written without spaces (Chinese, Japanese, Thai)
  every token is a word. `OfflineTranslation.alignedSpans()` turns them
  into the `AlignedSpan`s of `TranslationRepository.align`, which now works
  for the on-device engine (free, instant, any length, nothing sent).
* **Low confidence.** A sentence of at least 3 words whose score (the mean
  log-probability of its words) is below -0.4 is
  `OfflineSentence.isLowConfidence`. Measured with the de/es models:
  fluent translations score -0.05 to -0.3; text in another language than
  the source and garbled output -0.4 to -0.8; on hard-wrapped
  documentation it fires for ~3% of fragments (mostly genuinely odd
  ones). Caveat: Bergamot's lexical shortlist is the union for the whole
  batch, so a bad sentence scores lower inside a longer text (-0.72) than
  alone (-0.42); fluent ones barely change. Log-probabilities miss
  confident mistakes (literal idioms score like fluent text).
* **`skip-cost: false`.** Firefox decodes with `skip-cost: true`, which
  skips the softmax and leaves raw logits as word scores (+12 to +22,
  meaningless as confidence). The library now decodes with
  `skip-cost: false` so the scores are log-probabilities. With beam size 1
  the softmax only shifts each step's scores by a constant, so the
  translation stays the same except at near ties: 53 of 54 paragraphs
  identical (en->de and en->es, one heading changed), ~3% slower
  (2746 -> 2842 ms for 1374 words).
* **Memory budget** (`lib/platform/native_memory.dart`).
  * The engine keeps 2 models loaded on low-RAM devices
    (`isLowRamDevice`, under 3 GB, or a heap class of 128 MB or less
    without a RAM figure), 4 from 8 GB of RAM, 3 otherwise
    (`DeviceMemory.bergamotModelCacheSize`, from the `memoryInfo` method
    of `MainActivity.kt`'s `io.github.aimdi.mozhi/memory` channel, asked
    while the catalog loads).
  * On memory pressure (`didHaveMemoryPressure`, which Flutter raises from
    Android's `onTrimMemory`, including when the UI is hidden on Android
    14+) `BergamotTranslator.trimMemory()` unloads every model but those
    of the last translation; the next request reloads what it needs.
  * Whisper (`whisper_speech`): the model (75-150 MB) is unloaded after
    60 s without a transcription, when the app goes to the background and
    on memory pressure (`WhisperSpeech.unload`; a running transcription
    finishes first).

## Models and the catalog

`tool/offline_catalog.py` reads Mozilla's registry
(`https://storage.googleapis.com/moz-fx-translations-data--303e-prod-translations-data/db/models.json`)
and writes `packages/bergamot_translator/assets/catalog.json`.

* **Selection:** per direction the `"Release Android"` model (the mobile
  size Firefox for Android ships) if there is one, else `"Release"`.
  `"Release Desktop"` (larger), `"Nightly"` and unreleased (`null`) entries
  are skipped. Result: **113 directions**, 55 into English (incl. `hbs`
  Serbo-Croatian, used for hr/bs/sr sources) and 58 out of English: 54
  languages in both directions plus English, `az` only as a target.
  72 `base-memory` and 41 `tiny` models.
* **Checksums:** the registry only has the SHA-256 of the *uncompressed*
  model file, nothing for shortlists and vocabularies. The script therefore
  streams every file once and records size + SHA-256 of the download (gzip)
  and of the decompressed file, cross-checked against the registry's model
  hash and the server's MD5 (`x-goog-hash`). Registry paths contain a unique
  training-run id, so a URL's content never changes; results are cached
  (`packages/bergamot_translator/build/offline_catalog_cache.json`) and
  re-runs only download new models. A full run streams 2.55 GB (a few
  minutes here). Output is deterministic.
* **Why an asset, not a `const`:** one human-reviewable JSON (186 KB) that
  the generator owns, diffable in PRs, and replaceable later by a catalog
  fetched at run time (same parser, `ModelCatalog.parse`). It loads with
  `loadBundledCatalog()`; tests read the file directly.
* **Sizes:** 14-38 MB to download per direction (median 25 MB), 21-55 MB on
  disk (median 36 MB); e.g. en-de 25.7 MB download / 36.7 MB installed
  (model 31.6 MB, shortlist 4.3 MB, vocabulary 0.8 MB). A language (both
  directions) is ~50 MB to download, ~73 MB on disk. The whole catalog is
  2.55 GB.
* **Model license:** MPL-2.0 (Firefox Translations models); never bundled,
  downloaded on request.

Install flow (`BergamotModelManager`): stream to
`models/.downloads/<pair>/<version>/<file>.gz.part` while hashing ->
**reject unless size and SHA-256 match before decompressing** -> gunzip into
`models/.staging/...` while hashing -> reject unless the decompressed size
and SHA-256 match -> write `manifest.json` -> one `rename()` into
`models/<pair>/<version>/` (atomic; an older version is moved to
`.trash` and deleted). An interrupted download keeps its `.part` file and
resumes with an HTTP `Range` request (the existing bytes are re-hashed, so
the final check covers the whole file); a server that ignores `Range`
restarts it. The `http.Client` is injectable (tests use `MockClient`).
An import from files ([below](#import-models-without-the-app-downloading-them))
goes through the same checks, staging and rename, with no download step.

Before anything is written, the manager checks the free space (its
`freeSpace`, the app's `FreeSpace`: `StatFs` on Android): what is left to
download plus the decompressed files (the `.gz` parts stay until the model
is installed), plus a margin of 5 %, at least 50 MB
(`BergamotModelManager.requiredSpace`). Too little fails with a
`ModelInsufficientSpaceException` before any request, and the offline
languages screen says **Not enough free space for German: needs 120 MB,
40 MB free.** Hashing and decompressing run in background isolates
(`FileHashing`: a download's chunks are hashed in a long-lived isolate as
they arrive), so the app stays smooth.

## Import models without the app downloading them

A download makes the phone contact `storage.googleapis.com`, which
Google hosts. To avoid that, for example in **Offline only**, download
the files on another computer, copy them to the phone and import them.
The import contacts nothing, so it works in every privacy mode.

**Which files.** Each direction has three files (four for the few models
with split vocabularies): the model, the lexical shortlist and the
vocabulary, e.g. for German to English:

```
model.deen.intgemm.alphas.bin.gz
lex.50.50.deen.s2t.bin.gz
vocab.deen.spm.gz
```

A language needs both of its directions (German: de-en and en-de, six
files). Between two other languages Mozhi goes through English, so
Spanish to German needs Spanish and German. English needs nothing.

**Where to get them.** From Mozilla's bucket:

```
https://storage.googleapis.com/moz-fx-translations-data--303e-prod-translations-data/models/<source>-<target>/<version>/exported/<file>.gz
```

`<version>` is the training run in the catalog bundled with your app version
(`packages/bergamot_translator/assets/catalog.json`, the `url` of each file).
The easiest way: on **Settings > Translation engines > Offline languages**,
tap a language. **Files for German** lists its files with their sizes; copy
one link, or **Copy all links** and send them to the other computer. Use the
links of your app version: files of another model version don't match the
checksums and are rejected.

**Download them** in a browser, or with `wget -i links.txt` (one link
per line). Keep the names. Decompressing them (`gunzip`) is fine too:
both forms are accepted. A renamed copy (`vocab.deen (1).spm.gz`) is
recognised by its size and checksum.

**Copy them to the phone** over USB (file transfer mode), on an SD card
or from a network share: anywhere the Android file picker can open.

**Import them:** **Settings > Translation engines > Offline languages > Import
from files**, then select all the files at once. Every file is checked against
the SHA-256 bundled with the app, like a download. Every complete direction is
installed; nothing else changes. A summary follows, for example **Installed
German → English**, **Missing 1 file for English → German** (with the missing
file names), **2 files didn't match any model** or **A file for German →
English is damaged (checksum mismatch)**. Import the missing files later;
directions already installed are skipped. You can delete the copies
afterwards: the app keeps its own.

How it works (`BergamotModelManager.importFiles(files, catalog:)`): each
file is matched to a catalog file by name (`<name>.gz` as published,
`CatalogFileDownload.downloadName`, or `<name>` decompressed; case is
ignored), otherwise by size and SHA-256. A named file must match the
size and SHA-256 of the gzip file or of the decompressed file; a gzip
file is decompressed into staging and checked again, a decompressed one
is copied and checked again. Complete models go through the downloader's
staging and atomic install (replacing another version of the pair); an
install of the same model that is running finishes first. The result
lists per model: installed, already installed, incomplete (missing
files), checksum mismatch (the damaged files) or failed (the error), and
the files that matched nothing. The imported files are only read. On
Android `file_picker` copies the picked files into the app's cache; the
app deletes those copies after the import.

## Language identification

`BergamotTranslator.identifyLanguage` (the app's on-device detection, also
used to pick the source of an `auto` offline translation) runs **CLD2**
(Compact Language Detector 2), compiled into `libmozhi_bergamot.so` (and
into the web app's `bergamot-translator.wasm`), and falls back to the old
heuristic where the engine cannot run (a browser without what the web
engine needs, armv7 without VFPv4) or the library has no identifier.

| Candidate | License | Size / dependencies | Short text | Verdict |
| --- | --- | --- | --- | --- |
| **[CLD2](https://github.com/CLD2Owners/cld2)** (Google; Chrome's detector before CLD3) | Apache-2.0 | plain C++, no dependencies; "chrome" tables (83 languages) +1.8 MB, "full" tables (165) +6.5 MB per ABI; ~0.03 ms per sentence | declines (`un`) on a word or two, best-effort mode guesses | **Chosen**, chrome tables. Unmaintained since 2015 but finished, thread-safe, shipped by Chrome on ARM for years. |
| [CLD3](https://github.com/google/cld3) (Google, CLD2's successor) | Apache-2.0 | small neural network, but its feature definitions are protobuf messages: needs `protoc` at build time and protobuf linked (SentencePiece's bundled protobuf-lite has no generator) | designed for short text | Rejected: protobuf code generation in the CMake build for three ABIs and the F-Droid recipe is not worth it while CLD2 plus the decision below is good enough. |
| [fastText lid.176.ftz](https://fasttext.cc/docs/en/language-identification.html) (what Firefox uses now) | code MIT, **model CC-BY-SA-3.0** | 917 KB model + fastText C++ | good | Rejected: a CC-BY-SA model bundled in the MIT app (share-alike, attribution on every copy) is licence-awkward; downloading it would add a network step to detection. |
| keep the heuristic only | MIT | 0 | most short Latin-script text undetermined | Kept as fallback and second opinion. |

**Tables:** the chrome set covers every language of the offline catalog
except **Uyghur** (the heuristic still recognises its letters) and
detects about 30 more (`sw`, `la`, `cy`, ...). The full tables would add Uyghur
and ~80 rarer languages for +4.7 MB per ABI (x3 ABIs in the APK) and more
confusion between close languages on short text.

**Decision** (`Cld2Decision.choose`, on the first 4096 characters):

1. heuristic says `ug` (Uyghur letters) -> `ug`;
2. CLD2's normal answer when reliable -> it (any language; `iw` -> `he`,
   `jw` -> `jv`, `tw` -> `ak`, `sr-ME` -> `sr`; `zh-Hant` is kept: there are
   Traditional Chinese models);
3. a script only one language uses (Hangul, kana, Han without kana,
   Greek, Hebrew, Thai, Bengali, Gujarati, Kannada, Malayalam, Tamil,
   Telugu) -> the heuristic's answer (CLD2 guesses "中国" as Japanese);
4. CLD2's best-effort guess, when reliable and either the heuristic agrees
   or its score is at least 500 *and* the engine translates from that
   language (a guess of `zh-Hant` counts as `zh`: shared characters);
5. otherwise null: the app asks for the source language.

Hints (CLD2's `content_language_hint`) are supported by the C API but not
used: feeding it the heuristic's guesses made results worse (the heuristic
calls most Cyrillic text Russian).

**Measured** (Linux x86_64, `test/src/isolate_language_identifier_test.dart`
with the native library; 238 phrases of 1-6 words in the 55 offline
languages, `test/fixtures/language_id_phrases.tsv`, several ambiguous by
nature such as hr/bs/sr/sl or id/ms):

| | right | wrong | undetermined |
| --- | ---: | ---: | ---: |
| heuristic alone (before) | 32% | 10% | 58% |
| CLD2 normal answers alone | 51% | 5% | 44% |
| **the decision above** | **82%** | **10%** | **8%** |

Most mistakes are close languages (id/ms, cs/sk, da/no/sv, gl/pt/es,
nl/af) or greetings shared across languages ("Salut", "Adiós"); of the 28
short questions and requests 24 are right (wrong: "Waar is het
station?" English, "¿Dónde está la estación de tren?" Galician, "Unde
este gara?" Slovak, "Di mana stasiun kereta?" Malay). "Guten Morgen", "Hola, ¿cómo estás?",
"Добрый день", "こんにちは", "مرحبا" and "Bonjour tout le monde" are tested.

| Latency | |
| --- | --- |
| CLD2, both passes, one sentence | ~0.03 ms (`mozhi_bergamot_cli --detect`); 0.05 ms from Dart incl. opening the loaded library |
| CLD2, both passes, 4096 characters | 0.29 ms |
| `IsolateLanguageIdentifier.identify` (Isolate.run, JIT, loaded machine) | 0.75-1.2 ms per call |

**Code:** C API `mozhi_bergamot_detect` (fills a `MozhiBergamotDetection`:
CLD2's answer, top 3 languages with percent and score, reliability),
added to ABI 1 without changing other functions (Dart looks the symbol up
and falls back to the heuristic without it); Dart
`lib/src/native_language_identifier.dart` (results, `Cld2Decision`) and
`lib/src/engine/ffi/isolate_language_identifier.dart` (FFI, isolate).

## Native build

* Sources: three pinned submodules, `native/third_party/translations`
  (mozilla/translations @ `69455aca`), `native/third_party/pcre2`
  (PCRE2 10.47, for ssplit; built in-tree, JIT off) and
  `native/third_party/cld2` (CLD2 @ `b56fa78a`, 2015-08-20, the last
  commit; 118 MB checkout, mostly the unused full tables). **Do not** run
  `git submodule update --init --recursive` on `translations` (it also
  holds Mozilla's training pipeline: marian-dev, kenlm, emsdk, ...).
  `packages/bergamot_translator/tool/fetch_native_deps.sh` initialises only
  the 5 nested submodules the CPU engine needs (+ ruy's cpuinfo), shallow,
  and applies `native/patches/`.
* C API, ABI 2 (`native/src/mozhi_bergamot.h`; Dart refuses another ABI):
  ABI 1's calls are unchanged; ABI 2 adds `mozhi_bergamot_translate_ex`
  (a batch of texts, direct or pivot, flags for HTML, alignment and
  quality; returns JSON with `text` and, on request, `sentences` with
  ranges, scores and words). `mozhi_bergamot_cli --details MODEL SHORTLIST
  VOCAB < lines.txt` prints that JSON for a batch.
* `native/CMakeLists.txt` builds `libmozhi_bergamot.so` with nothing
  downloaded at configure or build time. What it has to work around (all
  without editing vendored files, except the one patch):
  * Marian's CMake runs `git submodule update --init --recursive` while
    configuring (it cloned 291 MB of training tools in a test): neutralised
    by pointing `GIT_DIR` at nothing during `add_subdirectory`.
  * Marian's `git_revision.h` rule depends on `<gitdir>/logs/HEAD`, resolved
    wrongly when mozilla/translations is a submodule: that single rule is
    replaced by a deterministic, git-free one (also better for
    reproducible builds).
  * No BLAS on Android: float GEMM uses ruy on every target
    (`USE_RUY_SGEMM`); int8 GEMM is intgemm on x86_64 (runtime AVX2/AVX-512
    dispatch) and ruy on ARM.
  * Marian's directory-scoped definitions and `-march` flags did not reach
    bergamot's own sources or the shim (on armv7 they then took the x86
    code path): forwarded to every target.
  * ARM: `simd_utils.h` uses `fesetround` without `<fenv.h>` (force-included).
  * armv7: AArch64-only NEON intrinsics (`vfmaq_n_f32`, `vcvtnq_s32_f32`,
    GCC's missing `vld1q_u8_x4`) and two clang-only incompatibilities of
    the old sse2neon (`float64x2_t`, `_mm_set_epi64(int64_t, int64_t)`) are
    handled by `native/src/armv7_neon_compat.h` (force-included); the target is
    `armv7-a + neon-vfpv4` (Cortex-A5/A7/A12/A15/A17 and ARMv8 cores in
    32-bit mode); Dart checks `/proc/cpuinfo` for `vfpv4` before loading.
  * armv7: Marian reads the float multiplier after an int8 matrix through a
    `float*` cast; for the 1x1 item `Wemb_QuantMultA` of `*.alphas.bin`
    models it is unaligned -> SIGBUS on 32-bit ARM. Fixed with `memcpy` in
    `native/patches/0001-marian-unaligned-quant-mult.patch`. Likewise the
    model header's 64-bit fields are read through unaligned `uint64_t*`
    casts; clang turns them into `ldrd`, which faults on 32-bit ARM:
    `0002-marian-unaligned-binary-header.patch`. Both should go upstream;
    CMake refuses to configure without them.
  * Marian and intgemm build with `-Werror`; `-Wno-error` is appended so a
    newer compiler's new warnings cannot break the build.
  * Android API 24 < 28 has no `iconv`: pathie gets
    `PATHIE_ASSUME_UTF8_ON_UNIX` (Android paths are UTF-8, iconv is never
    called).
  * Only `mozhi_bergamot_*` is exported (version script); libc++ is linked
    statically (`c++_static`), `-z max-page-size=16384` (16 KB pages).
  * CLD2 (static library `mozhi_cld2`, the 24 files of its
    `compile_libs.sh` with `debug_empty.cc`): its 2014 generated tables
    initialise `uint8` arrays with negative constants, an error since
    C++11 in GCC and clang, so it builds with `-Wno-narrowing` (as Chrome
    did) and `-w`. Its unaligned loads go through `memcpy` on every target
    we build (`port.h`).
  * Reproducible builds: `-ffile-prefix-map` maps the repository root to
    `.`, the build directory to `build` and the NDK to `ndk` for every
    target, so the ~190 `__FILE__` paths (Marian's messages, asserts) no
    longer embed the machine's checkout path; and Marian's generated
    `build_info.cpp` (every CMake cache variable: checkout, compiler,
    system library paths) is replaced by a fixed one. Byte-for-byte
    identical builds on two machines were not compared.
* Character signedness: `char` is unsigned on Linux/Android aarch64 and
  armv7 and signed on x86_64, so code that relies on a signed `char` can
  behave differently on phones. It was checked and is not a problem here,
  so the build sets no `-fsigned-char`: SentencePiece gives byte-for-byte
  the same tokens on x86_64 and aarch64 (all four test vocabularies, 27
  lines of accented and NFKC-sensitive text); CLD2 gives the same answers
  on x86_64, aarch64 and armv7 (238 phrases); translations of accented
  text agree across x86_64 and aarch64 except for word choice from the
  different int8 GEMM (intgemm vs ruy), with the same accented letters in
  the output; and an aarch64 build with `-fsigned-char` translates the same
  as the default one (see *What was verified*). Names losing their accent
  in English output ("Malaga", "Angel", "Sofia") is the es-en model's
  learned English spelling and happens on x86_64 just the same; the
  source reaches it intact (`▁José ▁vive ▁en ▁Málaga .`).
  `bergamot_integration_test.dart` checks that accented letters survive
  in both directions.
* Android (`android/build.gradle`): `externalNativeBuild` with
  `../native/CMakeLists.txt`, NDK pinned to `28.2.13676358` (= Flutter
  3.47's default), CMake 3.22.1, `abiFilters arm64-v8a, armeabi-v7a,
  x86_64`, minSdk 24, always `Release` (an -O0 engine is unusable even in
  debug builds), `targets "mozhi_bergamot"`.
* CI: job **"Build Bergamot native (Android)"** in
  `.github/workflows/main.yaml` builds the three ABIs with the pinned NDK
  and CMake exactly like Gradle does, checks exports, dependencies (no
  `libc++_shared.so`) and 16 KB alignment, and uploads
  `bergamot-android-native` (libraries and the benchmark CLI). It is the
  diagnostics job: it starts at once, builds every ABI even when one fails,
  runs ninja with `-k 0` so one run lists every compile error, and prints a
  per-ABI table (configure, build, number of errors) plus the distinct
  errors in the run summary; logs are uploaded as `bergamot-android-logs`.
  The APK jobs (*Build Android APKs*, *Build Play variant (ML Kit)*, the
  release jobs) compile the engine again through the plugin's Gradle
  `externalNativeBuild`, which stops at the first failing ABI; on failure
  they list the compiler errors of their log. All of them use ccache
  (`CMAKE_<LANG>_COMPILER_LAUNCHER` from the environment), restored from
  any earlier Android job. Expect ~10 minutes per ABI cold.
* Linux (tests): `packages/bergamot_translator/tool/build_native_linux.sh`
  -> `build/native/linux/libmozhi_bergamot.so` (~6 minutes on 4 cores).
  `native/tool/mozhi_bergamot_cli.c` (target `mozhi_bergamot_cli`) is a
  smoke-test/benchmark CLI, also usable on a device via `adb shell`;
  `--detect < lines.txt` prints CLD2's answer and guess for every line
  with the time it took.

## What was verified

On this sandbox (Intel Xeon 2.1 GHz, 4 cores, AVX-512; the engine uses one
thread), with the real models downloaded from Mozilla's bucket and verified
against the catalog:

| Check | Result |
| --- | --- |
| en->de "Hello, how are you?" | "Hallo, wie geht es dir?" |
| de->en "Wie geht es dir? Das Wetter ist heute schön." | "How are you? The weather is nice today." |
| es->en->de "Hola, ¿cómo estás? Me gusta mucho este libro." | "Hey, wie geht's? Dieses Buch gefällt mir sehr gut." |
| HTML `<p>Hello <b>world</b>, how are you?</p>` | `<p>Hallo <b>Welt</b>, wie geht es dir?</p>` |
| two paragraphs, auto source | paragraphs preserved |
| model create (lazy) | 66-70 ms |
| cold start: isolate + model load + first sentence | 240-290 ms (136 ms in-process) |
| 493 words en->de, warm | **500-630 ms (~780-980 words/s)** |
| 493 words en->es incl. loading that model | 650-790 ms |
| download + verify + install de-en, en-de, es-en, en-es (103 MB) | 31 s |
| aarch64 build (GCC 13 cross, ruy, NEON) under qemu-aarch64 | en->de "Hallo, wie geht es dir?"; es->en->de pivot as above |
| armv7 build (GCC 13 cross, NEON+VFPv4, compat header, patches) under qemu-arm | en->de "Hallo, wie geht es dir?"; es->en->de pivot as above |
| armv7 and aarch64 builds with **clang 18** (closest to the NDK's clang 19) under qemu | es->en->de pivot as above on both (this found the clang-only issues and patch 0002) |
| `libmozhi_bergamot.so` size, stripped | x86_64 10.4 MB (GCC); aarch64 8.5 MB, armv7 5.8 MB (clang, glibc, shared libstdc++; Android adds ~1 MB of static libc++) |
| `mozhi_bergamot_translate_ex`, aarch64 build (GCC 13 cross) under qemu | same alignments and UTF-16 offsets as x86_64 ("Málaga." <- "Málaga.", "Jose" <- "José") |
| accented text, x86_64 vs aarch64 (34 sentences, es/de/en, four directions) | 30 identical, 4 differ in word choice only; accented letters in the output equal (4/4, 4/4, 23/23, 20/20) |
| SentencePiece tokens, x86_64 vs aarch64 (four vocabularies, 27 lines) | identical |
| aarch64 built with `-fsigned-char` (all 308 compile units) vs the default unsigned `char`, same 34 sentences | byte-identical JSON (texts, alignments, scores) |
| abort of a waiting and a running request (real models) | both callers released in 2-41 ms; the engine keeps working |
| CLD2's cost in the library (x86_64, stripped) | +1.76 MiB: 10,685,432 -> 12,532,760 bytes (12,524,568 with the path changes below) |
| absolute paths in the library (`strings \| grep -c /home/`) | 200 -> 0 (`-ffile-prefix-map`, fixed Marian `build_info.cpp`) |

`flutter test` in the package: 225 tests pass, 14 of them with the real
models (skipped unless `BERGAMOT_TEST_MODELS=1`; they pass here,
including an `auto` translation of "Guten Morgen" identified by CLD2,
word alignment through a pivot, the low-confidence flag, abort, preload
and accented letters in both directions). The language identification
tests that need the native library run whenever it is built. The batch,
abort and detail paths are also covered with a fake engine, so they run
without models.

## Not verified (needs CI or a device)

* The NDK build itself (dl.google.com is blocked here): the CMake logic for
  Android is exercised only through GCC 13 and clang 18 cross-compilers for
  glibc + qemu (bionic- and NDK-specific parts: `ANDROID_ABI` branches,
  pathie/iconv, `liblog`, `c++_static`, 16 KB pages are untested). The CI
  job is the first real NDK build.
* The Gradle path (`android/build.gradle` inside a Flutter app build) and
  loading `libmozhi_bergamot.so` from an APK.
* Speed and memory on phones. Expect roughly 5-20x slower than this Xeon on
  mid-range ARM (one core, int8 ruy); memory is ~40 MB of weights per loaded
  direction plus Marian's 128 MB workspace setting (`workspace: 128`,
  Firefox's value; lower it via the C API's `extra_config` if needed).
* x86_64 Android (emulators) uses the same intgemm path as the Linux test.
* CLD2 inside the NDK build and on a device. Standalone, with the same
  sources and flags (armv7: NEON + VFPv4, Thumb, the force-included compat
  header), clang 18 builds it for armv7 and aarch64 and, under qemu, it
  gives byte-for-byte the same answers as on x86_64 for all 238 test
  phrases (both passes). Detection latency on phones is not measured
  (`mozhi_bergamot_cli --detect < lines.txt` on a device does).

## App integration (wave B, done)

1. `pubspec.yaml`: `bergamot_translator: {path: packages/bergamot_translator}`
   and `path_provider` (BSD-3-Clause, already resolved transitively). The
   default `pubspec.yaml` has no ML Kit package any more.
2. `lib/platform/offline_engine.dart` creates the engine for every variant
   (`dart.library.io`; the web gets `offline_engine_web.dart`, the
   WebAssembly engine, see [Web app](#web-app); `dart:ffi` is never
   compiled for the web). `createBergamotOfflineTranslator`:
   * `loadBundledCatalog()` and `getApplicationSupportDirectory()` in
     parallel; models go to `<support>/bergamot/models/<pair>/<version>/`
     (app-private, no backup: `allowBackup="false"` and
     `data_extraction_rules.xml`);
   * `isMeteredConnection`: `MeteredNetwork` (`lib/platform/metered_network.dart`)
     calls `isActiveNetworkMetered` on the privacy channel
     (`MainActivity.kt`: `ConnectivityManager.isActiveNetworkMetered()`,
     permission `ACCESS_NETWORK_STATE`). Unknown counts as metered;
   * downloads use `CurrentSessionClient`, i.e. the client of
     `NetworkSession.current`, so the proxy setting (e.g. Orbot) and the
     network policy apply to model downloads too;
   * `models.cleanUp()` runs unawaited (never blocks the first frame);
   * any failure (no catalog, no directory: e.g. a desktop test host) logs
     and returns an `UnavailableOfflineTranslator`.
   `bootstrap.dart` starts it before the stores open and passes it as
   `offline:` to `TranslationRepository` and as
   `AppDependencies.offlineTranslator`.
3. Offline languages screen (`lib/offline/`): `OfflineModelDetails`
   (`BergamotModelDetails` adapts the translator) adds per-language download
   and installed sizes (both directions), the total storage used, updates
   (`outdatedModels()`: an *Update* pill), download progress in percent, a
   "via English" note and where the models come from. English is shown as
   built in (no download, not counted). A Wi-Fi-only download on a metered
   network (`MeteredConnectionException`) opens *Download over mobile
   data?* with *Download anyway*; checksum, server (HTTP status), network
   (including the app's proxy/https rules), storage, engine and
   unsupported-language errors each have their own message and a *Retry*
   action. *Import from files* installs models copied to the phone
   (`OfflineModelImport`, see
   [above](#import-models-without-the-app-downloading-them)); tapping a
   language lists its files and download links. On a device whose CPU cannot run the engine (armv7 without
   VFPv4) the screen says so; in a browser without what the web engine
   needs it says what is missing.
4. Licences page (`lib/app/third_party_licenses.dart`): *Firefox
   Translations engine (Bergamot)* lists every component of
   `native/THIRD_PARTY_NOTICES.md` with its licence and where the MPL-2.0
   source is (a test keeps the two in sync), *Firefox Translations models*
   states the MPL-2.0 model licence. The ML Kit notice is only shown in the
   Play variant.
5. CI and releases build the engine (see *Native build* above) after
   `fetch_native_deps.sh`; the F-Droid recipe runs it in `prebuild` with
   `submodules: false`, then `tool/fdroid_prepare.sh`.

**Privacy note (for docs/privacy.md).** Model downloads go to
`storage.googleapis.com`: Mozilla's Firefox Translations bucket
(`moz-fx-translations-data--303e-prod-translations-data`) is hosted on
Google Cloud Storage, so Google, as the host, sees the device's IP address,
the time and which model files are fetched (i.e. which languages were
downloaded). Only static files are requested (HTTPS `GET`, optionally with
`Range` to resume); no text, identifiers or cookies are sent, and
downloads only happen when the user taps *Download* or *Update*. They go
through the app's proxy setting when one is set. Translation itself never
touches the network; models stay on the device and are verified against
the SHA-256 checksums bundled with the app.

## Web app

Wave 3: the web app translates on the device too, with the same engine,
models, catalog, routing (pivots through English), chunking, batching,
alignment, quality scores and CLD2 decision as the Android app. Only the
engine binary, the file storage and the download path differ.

```
BergamotTranslator (unchanged)            lib/src/bergamot_translator.dart
 ├─ OpfsModelManager    downloads through the app's  lib/src/engine/web/
 │                      http.Client; files kept in the browser's OPFS
 ├─ WorkerBergamotEngine  one request at a time,     lib/src/engine/web/
 │                      aborts dropped while waiting
 └─ WorkerLanguageIdentifier  CLD2                    lib/src/engine/web/
        │  postMessage (dart:js_interop only: js_bergamot_worker.dart)
        ▼
web/bergamot/worker.js  (committed, hand-written, no build step)
 ├─ bergamot-translator.{js,wasm}  Emscripten 3.1.8, built by
 │     tool/build_wasm.sh (gitignored; CI builds it)
 └─ navigator.storage.getDirectory()/bergamot/  models, downloads
```

`createWebBergamotTranslator` (`lib/src/engine/web/web_bergamot.dart`)
assembles it; the app's `lib/platform/offline_engine_web.dart` calls it after
`probeBergamotWorker`, and otherwise keeps an `UnavailableOfflineTranslator`
whose `webRequirement` the Offline languages page explains (old browser,
private window without site storage, plain `http`, a build without the
engine files). With the engine available everything that depends on
`OfflineTranslator.isAvailable` works as on Android: the engine list,
Offline only / Offline first, the fallback to the on-device engine, Detect
language with CLD2, onboarding's on-device choice.

### Build

`packages/bergamot_translator/tool/build_wasm.sh [output-dir]` (default
`web/bergamot/`, next to `worker.js`, so `flutter build web` copies it):

* sources: `fetch_native_deps.sh` (the pinned, shallow submodules of the
  native build) plus the two only the WebAssembly build compiles:
  marian-fork's `onnxjs` (float GEMM in WASM, MIT) and its Eigen (MPL-2.0,
  built with `EIGEN_MPL2_ONLY`). Upstream's `inference/scripts/build-wasm.py`
  is **not** used: it runs `git submodule update --init --recursive`
  (Mozilla's whole training pipeline);
* Emscripten at the version upstream pins (`EMSDK_VERSION = "3.1.8"` in
  `build-wasm.py`, read by the script; "the latest version of emsdk had
  errors building sentencepiece"), cloned at the commit of upstream's
  `inference/3rd_party/emsdk` submodule into `$MOZHI_CACHE_DIR/emsdk`
  (default `~/.cache/mozhi`, ~1.2 GB), never into the repository;
* `native/wasm/CMakeLists.txt`: upstream's inference CMake with
  `COMPILE_WASM` (single-threaded, `-msimd128 -mssse3`, no exception
  catching, `ALLOW_MEMORY_GROWTH`, `FILESYSTEM=0`, `IMPORTED_MEMORY` for
  mozIntGemm, no `eval`: `DYNAMIC_EXECUTION=0`), CLD2 with the same 24
  files and "chrome" tables as Android, and `native/wasm/src/
  mozhi_bergamot_wasm.cc`: **the native C API itself** (it compiles
  `native/src/mozhi_bergamot.cc` in its translation unit, so ABI 2's
  `translate_ex` JSON with alignment and quality scores and
  `mozhi_bergamot_detect` cannot drift) plus loading a model from memory
  (`mozhi_bergamot_buffer_create/data/destroy`,
  `mozhi_bergamot_model_create_from_buffers`, which also registers the
  languages: the WASM build splits sentences with the browser's
  `Intl.Segmenter`). Upstream's embind module is not built;
* upstream's import-gemm patch (`inference/wasm/patch-artifacts-import-
  gemm-module.sh`): Firefox's privileged `WebAssembly.mozIntGemm` when the
  page has it, else the int8 GEMM compiled into the module (every ordinary
  page, so "fallback" in practice); then the glue is wrapped in
  `function loadBergamot(Module) {...}` like upstream does;
* `native/wasm/patches/0001-wasm-text-processor-max-length-break.patch`:
  upstream's WASM `TextProcessor` never initialises `maxLengthBreak_` (the
  native one reads `max-length-break`), so long sentences were wrapped at
  whatever the heap held (0: never; 1: an endless loop). The patch reads
  the option like the native build. Send upstream.

Output: `bergamot-translator.wasm` 6.6 MB (3.0 MB gzipped),
`bergamot-translator.js` 41 KB. A cold build takes ~25 minutes on 2 cores
here (Marian is compiled with `-flto`). Bergamot ignores Marian's
`workspace` option (`TranslationModel` reserves 5 MB and grows on demand),
so there is nothing to lower there for browsers.

CI: job **Build Bergamot WASM** (`.github/workflows/main.yaml`, emsdk
cached by version and commit) uploads `bergamot-wasm`; **Build web** and
**Web end-to-end tests** put it into `web/bergamot/` before
`flutter build web`; the release workflow builds it from source again
(job `bergamot-wasm`) for the web zip. A web build without it still works:
the probe reports `engineFiles` and the app stays online-only. The
end-to-end spec `e2e/tests/offline_engine.spec.js` downloads the real
German pair (51 MB, fetched and checked by `e2e/fetch_models.py`, cached by
CI) from the page, cuts the model host off, translates, reloads and
translates again without a download, and translates an `auto` source
identified by CLD2; it is skipped without `$E2E_MODELS_DIR` or without the
engine in the build. `e2e/mock_server.py` also serves that directory as a
model mirror (`/models/`, with `Range`) for specs of a custom mirror.

### Worker protocol

`web/bergamot/worker.js` owns the WebAssembly instance, the loaded models
and the OPFS. Messages: page → worker `{id, op, ...}`, worker → page
`{id, ok: true, result}` or `{id, ok: false, error: {kind, message}}`
with `kind` one of `engine` (the instance is dropped and restarts with the
next request: C++ exceptions are not caught in this build, and an abort is
final), `storage` (quota, private windows), `checksum`, `missing`,
`unsupported`, `protocol`. Requests run strictly one after another; a
translation is one synchronous WASM call and cannot be interrupted, so the
Dart side keeps its own queue and sends one translation at a time (an
aborted request that still waits never reaches the worker; a running one
releases its caller at once, as on Android).

| op | arguments | result |
| --- | --- | --- |
| `probe` | | `{simd, opfs, syncAccess, decompression, digest, segmenter, engine, secure, persisted}` (does not start the engine; `engine`: a `HEAD` of the `.wasm`) |
| `configure` | `maxModels` (≥ 2, default 2), `idleSeconds` (default 300) | |
| `init` | | `{abi, version, gemm}` (`gemm`: `mozIntGemm` or `fallback`) |
| `translate` | `chain` (1 or 2 model specs: `key`, `source`, `target`, `model`, `shortlist`, `sourceVocab`, `targetVocab?`, OPFS paths), `texts`, `html`, `details` | the JSON string of `mozhi_bergamot_translate_ex` (alignment and quality with `details`) |
| `identify` | `text`, `hints?` | `{precise, bestEffort}`, each `{language, languages: [{code, percent, score}], textBytes, reliable}` |
| `preload` / `release` / `trim` / `dispose` | `chain` / `key` / – / – | |
| `list` | | installed models: `{directory, manifest, sizeBytes}` |
| `downloadOpen` / `downloadWrite` / `downloadClose` | `path`, `restart` / `path`, `at`, `bytes` / `path` | `{size}` |
| `fingerprint` | `path` (a file written with `downloadOpen`/`downloadWrite`: an imported file) | `{size, sha256}` |
| `install` | `part`, `target`, `size`, `sha256`, `uncompressedSize`, `uncompressedSha256`, `compressed?` (default `true`; `false`: an imported file decompressed already, checked against the decompressed size and SHA-256 and written as it is) | `{size}` |
| `commit` | `directory`, `manifest`, `downloads` | |
| `remove` / `cleanUp` / `usage` | `path` / – / – | `usage`: `{usage, quota, engineMemory}` |

Models: up to `maxModels` loaded, least recently used unloaded first,
before a new one loads. WebAssembly memory never shrinks (a pivot with two
models peaks around 350 MB), so after `idleSeconds` without a request the
worker drops the whole instance; the next request starts it again (~0.1 s:
the compiled module is kept) and reloads the models from the OPFS (~0.5 s
each).

### Storage and downloads

* **Where:** `navigator.storage.getDirectory()` → `bergamot/models/<pair>/
  <version>/` (decompressed files and `manifest.json`, written last: a
  model counts as installed only with it, and `cleanUp` removes versions
  without one) and `bergamot/.downloads/<pair>/<version>/<file>.gz.part`
  (kept when interrupted; the next download resumes with `Range`). Models
  are read straight into WASM memory through synchronous access handles
  (no extra copy).
* **Downloads** go through the app's `http.Client` (`CurrentSessionClient`:
  the session's network rules and its request log), not through the
  worker's `fetch`, in 1 MiB writes. Where the files come from is the
  model source in **Settings › Translation engines › Model source**
  (original publishers, **this web server**, the web default,
  `<base>/models/bergamot/<src>-<trg>/<version>/<name>.gz`, or a custom
  mirror; see [self-hosting](self-hosting-mozhi.md#mirror-the-on-device-models)),
  through the same `bergamotDownloadUrls` as Android.
* **Verification** in the worker: size and `crypto.subtle.digest('SHA-256')`
  of the gzip file against the catalog, then `DecompressionStream('gzip')`
  and the size and SHA-256 of the decompressed file, before anything is
  installed. A mismatch deletes the download (`ModelChecksumException`,
  naming the mirror).
* **Persistence:** with each download the app asks
  `navigator.storage.persist()` (Window only, so from Dart) until the browser
  agrees; without it the browser may evict the packs under storage
  pressure (Chrome decides by itself, Firefox asks the user). The download
  does not wait for the answer (Firefox's prompt may stay open), and a
  question still open is not asked again.
* **Older browsers:** `FileSystemSyncAccessHandle` methods that return
  promises (Safari 16, Chrome before 108) work like the current synchronous
  ones: the worker awaits every call (`e2e/unit/` tests both kinds).
* **Free space:** a download first compares what it needs (download and
  decompressed sizes plus the margin) with what the origin's quota leaves
  (`navigator.storage.estimate()`: `quota - usage`, when the browser has
  it) and is refused at once when it would not fit.
* **Mozilla's bucket and CORS** (checked 2026-10-22 with
  `curl -H 'Origin: …'`): `storage.googleapis.com/moz-fx-translations-data…`
  sends `Access-Control-Allow-Origin` only for `http://localhost[:port]`
  and `https://mozilla.github.io`; any other origin (a self-hosted web app,
  `http://127.0.0.1:8080`) gets no CORS header, so the browser refuses the
  download. Hence the web default "this web server" (a same-origin mirror,
  `tool/mirror_models.py`); "original publishers" only works for a web app
  served from `localhost`.
* **Import from files** (wave 7): a browser has no file paths
  (`OpfsModelManager.importFiles` throws `UnsupportedError`), so
  `OpfsModelManager.importSources(sources, catalog:)` takes the picked
  files' contents (`ModelImportSource`: name, length, a byte stream; the
  app's `PickedImportFile` from `file_picker`) with the rules of Android's
  `importFiles`: matched by name (published or decompressed, any case) or,
  renamed, by size and SHA-256; a file of no catalog size is never read.
  A candidate is written to `bergamot/.imports/<n>.part` in the worker's
  storage and hashed there (`fingerprint`); a complete model is installed
  with `install` (the published form verified and decompressed again, a
  decompressed one verified, `compressed: false`) and `commit` (other
  versions of the pair removed), like a download; `.imports/` is removed
  afterwards in any case. Nothing goes over the network. The page lists
  the files to download by hand per language, as on Android
  (`WebBergamotModelDetails`).
* "Wi-Fi only" uses `navigator.connection` (`type == 'cellular'` or
  `saveData`) where the browser has it; elsewhere the web app counts as not
  metered (it cannot tell).

### Browser support

What the probe requires (`BergamotWebRequirement`, reported in this order):
the engine files in the build, a secure context (`https` or localhost:
OPFS and `crypto.subtle` exist only there), the OPFS with synchronous access
handles in workers, WebAssembly SIMD, `DecompressionStream('gzip')` and
`Intl.Segmenter`. That is Chrome/Edge 102+, Firefox 125+ (not in private
windows, which have no OPFS), Safari 16.4+ (desktop and iOS). The CSP of
`web/index.html` already allows it (`worker-src 'self'`, `script-src
'self' 'wasm-unsafe-eval'`, `connect-src 'self'`); a server that sends its
own CSP header must allow the same for `bergamot/worker.js`. No
SharedArrayBuffer, so no COOP/COEP headers.

### Measured (Chromium 141 headless here, Xeon 2.1 GHz shared by six builds)

| Check | Result |
| --- | --- |
| probe, compile and start the engine | 80-630 ms (first compile of the 6.6 MB module, then cached) |
| German (de-en + en-de, 51.2 MB) from a same-origin mirror: download, verify, decompress, install | 5-6 s; 70.6 MB on disk (74 MB OPFS usage) |
| first translation after a reload (engine start + model load + "Hello, how are you? The weather is nice today.") | 1.1-1.9 s → "Hallo, wie geht es dir? Das Wetter ist heute schön." |
| model load + first sentence (engine running) | 530-740 ms |
| 492 words en->de, warm, with alignment and scores | 3.4-4.0 s: **120-150 words/s** (fallback int8 GEMM; native here: 780-980) |
| es->en->de pivot "Hola, ¿cómo estás? Me gusta mucho este libro." | "Hi, wie geht's dir? Ich mag dieses Buch wirklich." (400 ms) |
| HTML `<p>Hello <b>world</b>, how are you?</p>` | `<p>Hallo <b>Welt</b>, wie geht es dir?</p>` |
| alignment / quality JSON | same shape as the native library (UTF-16 offsets, `p`, scores) |
| CLD2 "Guten Morgen, wie geht es dir heute?" / "Bom dia" | `de` reliable / `un`, best effort `pt` (as native) |
| WASM memory after a pivot with two models and a 6000-character batch | 357 MB |

Not verified: Firefox and Safari (no browsers here), phones, memory limits
of mobile browsers, `mozIntGemm` (Firefox's privileged pages only).

## Follow-ups

* Web: a run on Firefox and Safari
  and on phones (memory: ~350 MB of WASM memory with a pivot), and
  multi-threading once the app can send COOP/COEP headers.
* Web: report the `dart2js` miscompilation found here upstream
  (dart-lang/sdk): a nullable local assigned in a `catch` and read by a
  closure afterwards keeps a stale value on the success path of an `async`
  method (`OfflineModelsCubit._attempt` documents the workaround). A
  standalone reproduction to file is in `tool/repro/dart2js_catch_closure/`.
* Upstream `0001-marian-unaligned-quant-mult.patch` and the ARM CMake fixes
  to mozilla/translations.
* Language identification: `OfflineTranslator.identifyLanguage` returns one
  code; ranked candidates with a confidence (CLD2 has the top 3) and
  hints from the user's own languages would let the app offer "German or
  Dutch?" instead of guessing or asking.
* Download cancellation; a shorter "translate as you type" debounce for
  the on-device engine (about 250 ms) and the `preload` call sites in the
  app (both in `TranslateCubit`).
* Show `OfflineSentence.isLowConfidence` in the output (e.g. a dotted
  underline and "The on-device engine is unsure about this sentence",
  with "Compare with another engine"); offer tap-to-highlight for offline
  results (`TranslateState.canAlign` is AI-only today).
* Optional: fetch a fresher catalog at run time (same schema), verify it
  (signature) before use.
* Measure on low-end devices; consider `tiny` models for armeabi-v7a.
