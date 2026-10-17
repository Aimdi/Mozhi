# Offline engine: Mozilla Firefox Translations (Bergamot)

Status: **the app's offline engine in every build** (wave B). Built and
proven on Linux x86_64 (real models) and on ARM (aarch64 and armv7 under
qemu); the Android build runs on CI (no device run yet). Package:
[`packages/bergamot_translator`](../packages/bergamot_translator/).

It replaced Google ML Kit (proprietary, Google Play services adjacent,
missing from the F-Droid build) with Mozilla's open models, the ones
Firefox uses for its built-in translation. The default build now contains
no Google code at all; ML Kit survives only as on-device text recognition
in the optional Play variant ([build variants](contributing.md#build-variants)).

## Decision

Use **Mozilla's own fork of bergamot-translator, which now lives in
[`mozilla/translations`](https://github.com/mozilla/translations) under
`inference/`** (bergamot v0.6.0 + its Marian fork), vendored as a pinned git
submodule, behind a ~250-line C API (`native/src/mozhi_bergamot.{h,cc}`)
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
BergamotTranslator (implements OfflineTranslator)          lib/src/bergamot_translator.dart
 ├─ ModelCatalog       assets/catalog.json (113 directions)  lib/src/catalog.dart
 ├─ ModelRouter        app codes -> Mozilla codes, direct    lib/src/model_router.dart
 │                     model or pivot through English
 ├─ BergamotModelManager  download, SHA-256, gunzip, atomic  lib/src/model_manager.dart
 │                     install under <root>/models/<pair>/<version>/
 ├─ TextChunker        paragraph/line/sentence pieces        lib/src/text_chunker.dart
 ├─ LanguageIdentifier heuristic identifyLanguage()          lib/src/language_identifier.dart
 └─ BergamotEngine     IsolateBergamotEngine: one long-lived lib/src/engine/ffi/
      background isolate -> NativeEngine (dart:ffi, LRU of 3 models)
        -> libmozhi_bergamot.so (C API) -> bergamot BlockingService -> Marian
```

* **Threading:** every native call happens in one background isolate
  (`Isolate.spawn`, started lazily, restarted if it dies); the UI isolate
  only sends messages. The C API serialises calls with a mutex (the
  engine and Marian's loggers are process-global), converts every engine
  error into a message (`marian::setThrowExceptionOnAbort`), never aborts.
* **Long text:** pieces of at most 2000 characters, cut at blank lines, then
  line breaks, then sentence ends; the engine splits each piece into
  sentences itself (ssplit) and keeps whitespace, so paragraphs survive.
  A sentence cache (2048 entries) makes re-translating edited text cheap.
* **Pivoting:** all Firefox models are xx->en or en->xx. es->de runs es->en
  then en->de inside the engine (`pivotMultiple`, no re-splitting).
  "Downloading Spanish" installs es-en and en-es; English needs no model.
* **Web:** the package imports on every platform; `dart:ffi` is behind a
  conditional import (`engine_factory.dart`), web gets a stub and
  `isAvailable == false`.

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

## Native build

* Sources: two pinned submodules, `native/third_party/translations`
  (mozilla/translations @ `69455aca`) and `native/third_party/pcre2`
  (PCRE2 10.47, for ssplit; built in-tree, JIT off). **Do not** run
  `git submodule update --init --recursive` on `translations` (it also
  holds Mozilla's training pipeline: marian-dev, kenlm, emsdk, ...).
  `packages/bergamot_translator/tool/fetch_native_deps.sh` initialises only
  the 5 nested submodules the CPU engine needs (+ ruy's cpuinfo), shallow,
  and applies `native/patches/`.
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
  smoke-test/benchmark CLI, also usable on a device via `adb shell`.

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

`flutter test` in the package: 137 tests pass, plus 6 real-model tests
(skipped unless `BERGAMOT_TEST_MODELS=1`; they pass here). Line coverage is
97% with them and 94% without (the difference is the FFI path).

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
* `identifyLanguage` is a heuristic (scripts + function words); Latin-script
  text of a few words is often undetermined (the app then asks for the
  source language).

## App integration (wave B, done)

1. `pubspec.yaml`: `bergamot_translator: {path: packages/bergamot_translator}`
   and `path_provider` (BSD-3-Clause, already resolved transitively). The
   default `pubspec.yaml` has no ML Kit package any more.
2. `lib/platform/offline_engine.dart` creates the engine for every variant
   (`dart.library.io`; the web gets `offline_engine_web.dart`, an
   `UnavailableOfflineTranslator`, so `dart:ffi` is never compiled for the
   web: `flutter build web` passes). `createBergamotOfflineTranslator`:
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
   action. On a device whose CPU cannot run the engine (armv7 without
   VFPv4) the screen says so; on the web it points to the Android app.
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

## Follow-ups

* Upstream `0001-marian-unaligned-quant-mult.patch` and the ARM CMake fixes
  to mozilla/translations.
* A real language identifier (e.g. CLD2, Apache-2.0, compiled into the same
  library).
* Cancellation of long translations (between pieces) and download
  cancellation; "translate as you type" debouncing in the app.
* Optional: fetch a fresher catalog at run time (same schema), verify it
  (signature) before use.
* Measure on low-end devices; consider `tiny` models for armeabi-v7a.
