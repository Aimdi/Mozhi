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
| Android NDK | 28.2.13676358 (Flutter 3.47's default) | `NDK_VERSION` in both workflows; `ndkVersion` in `packages/bergamot_translator/android/build.gradle`, `packages/tesseract_ocr/android/build.gradle` and `packages/whisper_speech/android/build.gradle` |
| CMake (Android SDK package) | 3.22.1 | `CMAKE_VERSION` in both workflows; `externalNativeBuild.cmake.version` in the same `build.gradle` |
| Android Gradle Plugin | 8.12.0 | `android/settings.gradle.kts`; the plugin's `build.gradle` (`classpath`) |
| Kotlin | 2.4.21 | `android/settings.gradle.kts`; `kotlin-stdlib` in `android/app/build.gradle.kts` |
| Gradle | 9.5.1 | `android/gradle/wrapper/gradle-wrapper.properties` (Flutter writes `gradlew` during the build) |
| compileSdk / minSdk | 36 / 24 | Flutter's defaults (`flutter.compileSdkVersion`, `flutter.minSdkVersion`); the engine plugin sets the same explicitly |

CI runs on `ubuntu-latest`, which isn't pinned (GitHub moves it to
Ubuntu 26 from 19 October 2026). The host OS shouldn't change the output,
but record it when you compare builds.

Install the NDK and CMake the way CI does:

```sh
sdkmanager --install "ndk;28.2.13676358" "cmake;3.22.1"
```

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
  which has no submodules. The commits are listed in
  [Dependencies](dependencies.md#tables). Nothing is downloaded while
  CMake configures or builds.
- **Gradle dependencies** are resolved from Google's Maven and Maven
  Central at the versions the plugins declare. There is no Gradle lock or
  dependency verification file.

## Variants

| Variant | Made by | Google code | Ships as |
| --- | --- | --- | --- |
| **Default** | the tree as committed | none (checked by `tool/check_no_google.sh`) | GitHub release APKs, the Play bundle (`.aab`), F-Droid |
| **Play** | `sh tool/play_prepare.sh` | Google ML Kit text recognition (closed source) | `mozhi-<tag>-play-universal.apk` next to the release |
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

# Web zip (no CDN; for the root of a web server)
flutter build web --release -t lib/main_production.dart \
  --base-href / --no-web-resources-cdn
```

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
two-screen device), history, settings, and the onboarding privacy and
languages steps. They run on a 411 × 891 phone in light and dark, and
translate and settings also at 1280 × 800. The PNGs are in
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
