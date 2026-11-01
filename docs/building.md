# Building and reproducible builds

How to build exactly what CI and the release workflow build, how to pick
a variant, how to check an APK for Google code, and how to compare two
builds. For day-to-day development (flavors, tests, localisation) see
[Contributing](contributing.md). For publishing a release, see
[Releasing](release.md).

- [Pinned toolchain](#pinned-toolchain)
- [Sources](#sources)
- [Variants](#variants)
- [Build like the release workflow](#build-like-the-release-workflow)
- [Check an APK for Google code](#check-an-apk-for-google-code)
- [Check an APK for 16 KB pages](#check-an-apk-for-16-kb-pages)
- [Web build: self-hosted fonts and deferred languages](#web-build-self-hosted-fonts-and-deferred-languages)
- [Compare two builds](#compare-two-builds)
- [ccache and build paths](#ccache-and-build-paths)
- [Golden tests](#golden-tests)

## Pinned toolchain

The output depends on every item below. Use the same values to reproduce
a CI or release build.

| Tool | Version | Pinned in |
| --- | --- | --- |
| Flutter (stable), Dart | 3.47.7, Dart 3.13.5 | `FLUTTER_VERSION` in `.github/workflows/main.yaml` and `release.yaml` |
| JDK | Temurin 17 | `actions/setup-java` (`java-version: "17"`) in both workflows |
| Android NDK | 28.2.13676358 (Flutter 3.47's default) | `NDK_VERSION` in both workflows; `ndkVersion` in `packages/bergamot_translator/android/build.gradle`, `packages/tesseract_ocr/android/build.gradle`, `packages/whisper_speech/android/build.gradle` and `packages/llama_engine/android/build.gradle` |
| CMake (Android SDK package) | 3.22.1 | `CMAKE_VERSION` in both workflows; `externalNativeBuild.cmake.version` in the same `build.gradle` |
| Android Gradle Plugin | 9.4.1 | `android/settings.gradle.kts`; the plugin's `build.gradle` (`classpath`) |
| Kotlin | 2.4.21 | `android/settings.gradle.kts`; `kotlin-stdlib` in `android/app/build.gradle.kts` |
| Gradle | 9.6.0 | `android/gradle/wrapper/gradle-wrapper.properties` (Flutter writes `gradlew` during the build) |
| compileSdk / minSdk | 36 / 24 | Flutter's defaults (`flutter.compileSdkVersion`, `flutter.minSdkVersion`); the engine plugin sets the same explicitly |

CI runs on `ubuntu-latest`, which isn't pinned (GitHub moves it to
Ubuntu 26 from 19 October 2026). The host OS shouldn't change the output,
but record it when you compare builds.

Install the NDK and CMake the way CI does:

```sh
sdkmanager --install "ndk;28.2.13676358" "cmake;3.22.1"
```

CI and the release workflow run `tool/install_native_toolchain.sh` (with
`NDK_VERSION` and `CMAKE_VERSION` set), which does the same, installs
ccache, and retries the download up to three times because Google's
servers sometimes send a broken archive.

## Sources

```sh
git clone https://github.com/Aimdi/Mozhi.git && cd Mozhi
git checkout v0.1.0                       # the tag you want to reproduce
bash tool/fetch_native_deps.sh            # every on-device engine
flutter pub get --enforce-lockfile        # fails if pubspec.lock would change
```

- **Dart packages**: the committed root `pubspec.lock` pins every package
  the app uses, including the dependencies of the path packages in
  `packages/`. `--enforce-lockfile` refuses to build from anything else.
  The packages' own lock files are git-ignored, and the app build doesn't
  read them.
- **Native engines**: `tool/fetch_native_deps.sh` runs each engine
  package's own `tool/fetch_native_deps.sh`. The offline translation
  engine's one checks out the pinned
  submodules (`mozilla/translations`, PCRE2 and CLD2) and, inside
  `translations`, only the nested submodules the engine compiles. Everything is shallow, at
  the commits recorded in git. It then applies
  `packages/bergamot_translator/native/patches/`. Don't run
  `git submodule update --init --recursive`: that also fetches Mozilla's
  training tools. The text recognition engine's one
  (`packages/tesseract_ocr`) checks out Tesseract 5.5.3 and Leptonica
  1.87.0, without Tesseract's own test submodules; the offline voice
  input's one (`packages/whisper_speech`) checks out whisper.cpp v1.9.5,
  and the on-device AI's one (`packages/llama_engine`) llama.cpp v0.6.0;
  neither has submodules. The commits are listed in
  [Dependencies](dependencies.md#tables). Nothing is downloaded while
  CMake configures or builds.
- **Gradle dependencies** are resolved from Google's Maven and Maven
  Central at the versions the plugins declare. There is no Gradle lock or
  dependency verification file.

## On-device AI engine

`packages/llama_engine` builds llama.cpp v0.6.0 (CPU only) into one
library per CPU variant; Dart picks the fastest one the phone's CPU runs
from `/proc/cpuinfo` and falls back to the baseline:

| ABI | Libraries |
| --- | --- |
| arm64-v8a | `libmozhi_llama.so` (ARMv8.0-A), `libmozhi_llama_dotprod.so` (ARMv8.2-A + dotprod + fp16), `libmozhi_llama_i8mm.so` (ARMv8.6-A + dotprod + fp16 + i8mm) |
| x86_64 | `libmozhi_llama.so` (SSE4.2) |
| armeabi-v7a | none (64-bit only: on-device AI is unavailable there) |

The Gradle build lists the three targets for every ABI; on x86_64 the
variant names are empty static stand-ins, which are not packaged. CI checks
the APKs carry exactly these libraries, and the job *Build llama native
(Android)* builds them with the NDK directly (exports, dependencies,
16 KB alignment). On a Linux host:

```sh
packages/llama_engine/tool/build_native_linux.sh      # build/native/linux
python3 packages/llama_engine/tool/make_test_model.py \
  --all packages/llama_engine/build/test_models        # needs numpy
```

The package tests then run the real engine (CI's *Analyze and test* job
does both before the package tests); see
[`packages/llama_engine/README.md`](../packages/llama_engine/README.md).

## Variants

| Variant | Made by | Google code | Ships as |
| --- | --- | --- | --- |
| **Default** | the tree as committed | none (checked by `tool/check_no_google.sh`) | GitHub release APKs, the Play bundle (`.aab`), F-Droid |
| **Play** | `sh tool/play_prepare.sh` | Google ML Kit text recognition (closed source) not released; build it yourself if you want it |
| **F-Droid** | `sh tool/fdroid_prepare.sh` | none: the same app as the default | F-Droid's own build |

- **`play_prepare.sh`** adds `google_mlkit_text_recognition` to
  `pubspec.yaml` and copies the overlay in `tool/play/`. It also appends
  ML Kit's script models to `android/app/build.gradle.kts` and writes
  `noMlkit=false` to `android/gradle.properties`.
- **`fdroid_prepare.sh`** changes nothing about the app. For F-Droid's
  source scanner, it deletes the Play-only sources (`tool/play/`,
  `tool/play_prepare.sh`, `packages/mlkit_translator`). It refuses a tree
  that `play_prepare.sh` changed and checks that the Gradle exclusions are
  in place. F-Droid's recipe runs `fetch_native_deps.sh` and then this
  script in `prebuild`, with `submodules: false`.

Both scripts edit the working tree in place and are idempotent. Run them
on a scratch copy, never commit the result, and run `flutter pub get`
afterwards. Details: [Contributing, Build variants](contributing.md#build-variants).

## Build like the release workflow

These are the commands `.github/workflows/release.yaml` runs, with the same
flags. `--obfuscate`, `--split-debug-info` and `--split-per-abi` all change
the output, so a build without them can't match a release.

```sh
flutter gen-l10n

# One APK per ABI: build/app/outputs/flutter-apk/app-<abi>-production-release.apk
flutter build apk --release --flavor production -t lib/main_production.dart \
  --split-per-abi --obfuscate --split-debug-info=build/symbols/apk-split-per-abi

# Universal APK: build/app/outputs/flutter-apk/app-production-release.apk
flutter build apk --release --flavor production -t lib/main_production.dart \
  --obfuscate --split-debug-info=build/symbols/apk-universal

# App bundle: build/app/outputs/bundle/productionRelease/app-production-release.aab
flutter build appbundle --release --flavor production -t lib/main_production.dart \
  --obfuscate --split-debug-info=build/symbols/aab

# Web zip (no CDN; for the root of a web server), then its fallback fonts,
# the starter phrasebooks at models/phrasebooks/ (with their index.json)
# and the list of files the app shell keeps for offline use (last)
flutter build web --release -t lib/main_production.dart \
  --base-href / --no-web-resources-cdn
python3 tool/web_fallback_fonts.py build/web
python3 tool/mirror_models.py build/web/models --only phrasebook
python3 tool/web_shell_manifest.py build/web
```

The web zip carries the starter phrasebooks (29 packs, about 0.5 MB,
downloaded from their GitHub release and checked against the bundled
catalogue) because a browser can't fetch them from GitHub (no CORS
headers); the app shell leaves `models/` out. The offline languages,
dictionaries and text recognition data are too large for it: self-hosters
mirror them next to the app ([Mirror the on-device
models](self-hosting-mozhi.md#mirror-the-on-device-models)), and the web
app says so where a server doesn't host them.

CI on branches (`main.yaml`) builds the APKs **without** `--obfuscate`, so
its `mozhi-android` artifact differs from a release by design.

Signing comes from `ANDROID_KEYSTORE_PATH`, `ANDROID_KEYSTORE_PASSWORD`,
`ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD` (or `android/key.properties`).
Without them the build is signed with the debug key. The first build
compiles the engine for three ABIs: about 25-30 minutes on four cores
without a cache.

## Check an APK for Google code

```sh
sh tool/check_no_google.sh path/to/app.apk      # or an .aab
```

- **What it checks**: the script parses every `classes*.dex` and fails
  (exit 1) on any class under `com/google/mlkit`, `com/google/android/gms`,
  `com/google/firebase` or `com/google/android/datatransport`. It also
  fails on zip entries that look like ML Kit's native libraries or models.
  Exit 0 means clean, and exit 2 means the input isn't an APK or AAB.
- **Options**: `--defined-only` turns classes that are only referenced
  into warnings, `--dex-only` skips the zip entry check, and `--max N`
  limits the listing.
- **Requirements**: no Android SDK, only `python3`. Without it the script
  falls back to `unzip` and `grep`.
- **When it runs**: CI runs it on every default APK, and the release
  workflow also runs it on the app bundle. The Play variant fails it by
  design.

R8 can rename classes that have no keep rule, so also check the Gradle
classpath of the default build (from `android/`, after one `flutter build
apk`, which writes `gradlew`):

```sh
./gradlew :app:dependencies --configuration productionReleaseRuntimeClasspath |
  grep -E 'com\.google\.(mlkit|android\.gms|firebase|android\.datatransport)' ||
  echo "no Google artifacts"
```

## Check an APK for 16 KB pages

Android 15 and later run on some phones with 16 KB memory pages. There, a
native library only loads when its LOAD segments are aligned to 16 KB
and, stored uncompressed in the APK, it starts on a 16 KB boundary.
Otherwise the engine that needs it (offline translation, text
recognition, voice input) fails on those phones only.

```sh
python3 tool/check_page_size.py path/to/app.apk      # or an .aab, or a .so
```

- **What it checks**: every `lib/<abi>/*.so` of the 64-bit ABIs
  (arm64-v8a, x86_64): the on-device engines and also Flutter's and the
  plugins' libraries. More than 16 KB is fine (`libflutter.so` is aligned
  to 64 KB). 32-bit libraries are listed but never fail, since 16 KB
  phones are 64-bit. In an app bundle only the ELF alignment counts:
  bundletool and Google Play align the APKs they make.
- **Exit status**: 0 when everything passes, 1 when a library doesn't,
  2 when the input isn't an APK, bundle or library. Only `python3` is
  needed.
- **When it runs**: CI on every APK, the release workflow on the APKs and
  the bundle. The job *Build Bergamot native (Android)* also checks each
  engine right after linking.
- **Where the alignment comes from**: the engines link with
  `-Wl,-z,max-page-size=16384` (their `native/CMakeLists.txt`) and pass
  `ANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON`; NDK r28 aligns to 16 KB by
  default anyway, and the Android Gradle Plugin (8.5.1 and later) stores
  uncompressed libraries 16 KB aligned.

## Web build: self-hosted fonts and deferred languages

`flutter build web` alone makes a working build, but one that still
contacts Google: CanvasKit draws text with the bundled Roboto, and
downloads a Noto font from `fonts.gstatic.com` for every character Roboto
lacks (Chinese, Japanese, Korean, Indic and Arabic scripts, emoji,
symbols). That request tells Google the user's IP address and which
scripts they read. The release zip and the CI builds therefore run one
more step:

```sh
python3 tool/web_fallback_fonts.py build/web
```

- **What it does**: reads the font list from the web engine of the Flutter
  SDK that built the app (`bin/cache/flutter_web_sdk`: 725 files for
  Flutter 3.47.7, Roboto included), downloads them once into
  `build/web_fallback_fonts_cache`, and copies them to
  `build/web/fallback_fonts/` at the same paths as on `fonts.gstatic.com`.
  Then it turns on `mozhiSelfHostedFonts` in `build/web/flutter_bootstrap.js`
  (which sets the engine's `fontFallbackBaseUrl` to `fallback_fonts/`) and
  removes `https://fonts.gstatic.com` from the Content Security Policy in
  `build/web/index.html`.
- **Size**: 21.8 MB for Flutter 3.47.7 (the zip grows by about as much:
  the fonts are already compressed). The browser only fetches the fonts a
  page needs, so loading the app is not slower.
- **Checks**: every file must be a font of its type (magic bytes) and at
  most 8 MB. The cache is reused (`--cache DIR`); `--offline` uses only
  the cache and fails if a font is missing; `--list` prints the files.
  Exit status 1 means a font could not be fetched or is invalid, 2 a
  usage or build error.
- **Without it** (a plain local build), the bootstrap keeps Flutter's
  default and the fonts come from Google, as before; nothing breaks.
- **Tests**: `python3 tool/web_fallback_fonts_test.py` (no network).

The app's own texts are split as well (`use-deferred-loading` in
`l10n.yaml`): `main.dart.js` holds English only, and each other language is
a `main.dart.js_N.part.js` file the app fetches once, before its first frame
when it is the app's language (`preloadAppLocalizations`). In a build of
the development flavor this took `main.dart.js` from 7.9 MB to 5.0 MB
(1.92 MB to 1.45 MB gzipped). Serve the `*.part.js` files with the rest of
the build.

## Web build: the app shell

The web app keeps its own files in the browser so that it opens with no
network once it has been opened (**Settings > General > Keep the web app
for offline use**): `web/mozhi_sw.js`, a service worker, caches exactly the
files that `mozhi_sw_manifest.json` lists. The release zip and the CI
builds write that list as the last step:

```sh
python3 tool/web_shell_manifest.py build/web
```

- **What it does**: lists every file of the build with its size and
  SHA-256 in `build/web/mozhi_sw_manifest.json`, and stamps the list's
  version (the SHA-256 of the list) and the paths into
  `build/web/mozhi_sw.js`. A build with other files gets another version,
  which browsers install as an update in the background (**Update ready**,
  **Reload**). Running it again changes nothing.
- **Left out**: the worker and the list themselves, Flutter's deprecated
  `flutter_service_worker.js`, hidden files, source maps and `*.symbols`,
  and model files next to the app (`models/`, folders below `bergamot/`).
- **Kept when first used** (`"lazy": true`): the fallback fonts and the
  renderer files that no build in `_flutter.buildConfig` loads (`skwasm`
  without a WebAssembly build of the app, CanvasKit's `webparagraph`);
  about 34 MB are kept at the install, 38 MB more only as pages use them.
- **`index.html`** is hashed with its `<base href>` emptied, so editing it
  for a sub-path keeps the list valid. Any other change to the files
  needs the tool again: the worker refuses a file that doesn't match.
- **Without it** (a plain `flutter build web`), the worker never installs
  and the app works online only, as before. Debug runs never get it.
- **Tests**: `python3 tool/web_shell_manifest_test.py` (also checks with
  Node.js, when installed, that the worker reads what the tool writes);
  `e2e/tests/offline_shell.spec.js` in a browser.

## Compare two builds

1. Build both from the same commit, with the toolchain above, the same
   flags and the same ccache setting (next section).
2. **Copy the signature and verify.**
   [apksigcopier](https://github.com/obfusk/apksigcopier) copies the first
   APK's signature onto a copy of the second and checks that it verifies.
   It needs `apksigner` from the Android SDK build-tools. "Verifies" means
   the two APKs are identical apart from the signature:

   ```sh
   apksigcopier compare mozhi-v0.1.0-arm64-v8a.apk \
     build/app/outputs/flutter-apk/app-arm64-v8a-production-release.apk
   # the second APK unsigned instead:
   apksigcopier compare --unsigned mozhi-v0.1.0-arm64-v8a.apk unsigned.apk
   ```

3. **If they differ**, [diffoscope](https://diffoscope.org) shows where:

   ```sh
   diffoscope --html diff.html mozhi-v0.1.0-arm64-v8a.apk \
     build/app/outputs/flutter-apk/app-arm64-v8a-production-release.apk
   ```

**Expected to differ: the signature only.** That's the APK Signing Block
(v2/v3), plus `META-INF/*.SF`, `*.RSA` and `MANIFEST.MF` if the APK also
has a v1 (JAR) signature. With minSdk 24 the Android Gradle Plugin
normally leaves v1 out; `apksigner verify -v <apk>` shows which schemes
are present. Two builds signed with different keys, for example the debug
key without the signing secrets, always differ there. apksigcopier deals
with exactly that.

Anything else is a reproducibility bug. Usual causes:

- a different Flutter, NDK, CMake, JDK or AGP version;
- different flags;
- a tree changed by `play_prepare.sh` or `fdroid_prepare.sh`;
- a different build path (next section).

Not verified yet: no two builds (CI vs CI, or CI vs local) have been
compared byte for byte so far.

## ccache and build paths

CI compiles the engine through ccache. It sets `CMAKE_C_COMPILER_LAUNCHER`,
`CMAKE_CXX_COMPILER_LAUNCHER`, `CCACHE_DIR`,
`CCACHE_BASEDIR=$GITHUB_WORKSPACE`, `CCACHE_COMPRESS` and
`CCACHE_MAXSIZE`, and CMake reads the launchers from the environment. A
cache hit returns the object file the compiler would have produced for
the same input, so a warm or cold cache gives the same result. The
release jobs restore the cache from branch runs for that reason.

`CCACHE_BASEDIR` does change the output, though: ccache rewrites absolute
paths under the base directory into relative ones before it calls the
compiler, and that includes the paths `__FILE__` expands to. Marian uses
`__FILE__` in its error messages, and the Linux build of
`libmozhi_bergamot.so` contains about 200 such source paths. Checked with
ccache 4.9.1 and clang: `__FILE__` came out as `../src/a.c` with a base
directory and as the absolute path without one.

As a result:

- builds **with** ccache and `CCACHE_BASEDIR=<checkout root>`, like CI and
  the release workflow, embed relative paths and don't depend on where the
  checkout lives;
- builds **without** ccache, or without `CCACHE_BASEDIR`, embed absolute
  paths and match only builds made in the same directory.

To reproduce a release APK, build the engine like CI:

```sh
export CMAKE_C_COMPILER_LAUNCHER=ccache CMAKE_CXX_COMPILER_LAUNCHER=ccache
export CCACHE_BASEDIR="$PWD"        # the checkout root
```

A path-independent fix that doesn't rely on ccache would be
`-ffile-prefix-map=<source root>=.` in
`packages/bergamot_translator/native/CMakeLists.txt`. It isn't there yet.
F-Droid's build server, which builds without ccache in its own directory,
needs it before its APK can match the release.

## Golden tests

Screenshot (golden) tests in `test/goldens/` cover the translate screen
(empty, with a result, on a tablet, and split at the hinge of a
two-screen device), the translation options sheet, history, settings, and the onboarding privacy and
languages steps. They run on a 411 × 891 phone in light and dark (the
default Lights out look), and translate and settings also at 1280 × 800.
The PNGs are in
`test/goldens/images/`. The tests are tagged `golden` (declared in
`dart_test.yaml`), and CI runs them with the rest (`flutter test` on
`ubuntu-latest`).

`test/goldens/flutter_test_config.dart` applies to that directory only.
It:

- loads Roboto and Material Icons from the Flutter SDK
  (`$FLUTTER_ROOT/bin/cache/artifacts/material_fonts`) instead of the test
  font. If the fonts aren't there, the tests are skipped with a message
  (run `flutter precache`);
- hides the debug banner;
- accepts a screenshot when at most 0.5 % of its pixels differ from the
  golden, so small anti-aliasing differences between machines pass. Any
  difference is printed.

Characters that Roboto lacks, such as → and ✦, render as boxes. They look
the same on every machine.

After an intended UI change, regenerate the goldens and review the changed
PNGs in the diff:

```sh
flutter test --update-goldens test/goldens
# or: very_good test --no-optimization --update-goldens -- test/goldens
```

Then run `flutter test test/goldens` without the flag: it should pass. A
failed comparison writes its diff images to `test/goldens/failures/`;
don't commit them. To leave the goldens out of a run, use
`flutter test --exclude-tags golden`.
