# Contributing

Thanks for helping! This page covers the toolchain, building and running the
flavors, tests, code style, and localisation, including adding a new UI
language. For how the code is organised, read [Architecture](architecture.md)
first.

- [Toolchain](#toolchain)
- [Get the code running](#get-the-code-running)
- [Flavors](#flavors)
- [Building releases](#building-releases)
- [Build variants](#build-variants)
- [Tests and checks](#tests-and-checks)
- [Web end-to-end tests](#web-end-to-end-tests)
- [Code style](#code-style)
- [Localisation](#localisation)
- [Adding a UI language](#adding-a-ui-language)
- [Documentation](#documentation)
- [Pull requests](#pull-requests)

## Toolchain

- **Flutter 3.47** (stable; CI uses 3.47.7) with **Dart 3.13**.
- Android: JDK 17 and the Android SDK, plus the NDK `28.2.13676358` and
  CMake `3.22.1` from the SDK manager for the offline engine (Gradle
  installs them on first use if the licences are accepted). `ccache` is
  optional and makes rebuilds of the engine fast.
- Optional: [Very Good CLI](https://cli.vgv.dev) (`very_good test`).

## Get the code running

```sh
git clone https://github.com/Aimdi/Mozhi.git
cd Mozhi
flutter pub get                 # also generates lib/l10n/gen
for p in packages/*/; do (cd "$p" && flutter pub get); done
# Android only: the on-device engines' C++ sources (translation, text
# recognition, voice: pinned submodules, only what each engine needs;
# never `git submodule update --init --recursive`)
tool/fetch_native_deps.sh
flutter run --flavor development -t lib/main_development.dart
```

The first Android build compiles the offline engine (Mozilla's Bergamot,
`packages/bergamot_translator`) for every ABI, which takes 25-30 minutes on
four cores; later builds reuse it. To compile it through ccache, export
`CMAKE_C_COMPILER_LAUNCHER=ccache CMAKE_CXX_COMPILER_LAUNCHER=ccache` before
building (CMake reads them from the environment). Web builds and all tests
need neither the native sources nor the NDK.

The app needs no server of its own: by default it uses the public Mozhi
instances. For development against your own back ends, run Mozhi and Ollama
locally with the Compose file in [`deploy/`](../deploy/README.md).

## Flavors

| Flavor | Entry point | Android app id | Android name |
| --- | --- | --- | --- |
| development | `lib/main_development.dart` | `io.github.aimdi.mozhi.dev` | [DEV] Mozhi |
| staging | `lib/main_staging.dart` | `io.github.aimdi.mozhi.stg` | [STG] Mozhi |
| production | `lib/main_production.dart` | `io.github.aimdi.mozhi` | Mozhi |

The three install side by side on Android. Always pass both `--flavor` and
`-t`:

```sh
flutter run --flavor staging -t lib/main_staging.dart
flutter run -d chrome --profile --no-web-resources-cdn \
  -t lib/main_development.dart                       # web has no flavors
```

On the web, `web/index.html` sets a strict Content Security Policy (no
inline scripts, no scripts from other origins). Debug web runs inject an
inline debugger script and load CanvasKit from Google's CDN, so the policy
blocks them: run the web app in `--profile` or `--release` mode with
`--no-web-resources-cdn` (no hot reload), and debug UI on another target.
For a one-off debug session you can remove the
`Content-Security-Policy` meta tag locally; don't commit that.

## Building releases

```sh
# Android: one APK per ABI, plus a universal APK. The release workflow
# also passes --obfuscate --split-debug-info=build/symbols/<build> and keeps
# the symbols as a private workflow artifact (for `flutter symbolize`).
flutter build apk --release --flavor production -t lib/main_production.dart --split-per-abi
flutter build apk --release --flavor production -t lib/main_production.dart

# Web (for the root of a web server, like the CI and release builds; change
# --base-href for a sub-path, e.g. /mozhi/), then its fonts and the list of
# files the app shell keeps for offline use (docs/building.md)
flutter build web --release -t lib/main_production.dart \
  --base-href / --no-web-resources-cdn
python3 tool/web_fallback_fonts.py build/web
python3 tool/web_shell_manifest.py build/web
```

Release signing for Android, the CI artifacts and tagged releases are
described in the [README](../README.md).

## Build variants

There are two Android variants. Both translate offline with Mozilla's
open Firefox Translations models on the Bergamot engine
(`packages/bergamot_translator`, see [Offline engine](offline-engine.md));
they differ only in on-device text recognition (OCR) for camera and image
translation: Tesseract in the default build
(`packages/tesseract_ocr`, see [Text recognition](text-recognition.md)), ML
Kit in the Play variant.

| | Default | Play variant |
| --- | --- | --- |
| Google code (ML Kit, Play services, Firebase) | **none** | ML Kit text recognition |
| Offline translation | Bergamot | Bergamot |
| On-device OCR | Tesseract, language data downloaded on request | ML Kit |
| Made by | the source tree as committed | `tool/play_prepare.sh` |
| Used for | GitHub releases, F-Droid, the Play bundle | optional APK next to the releases |
| CI job | *Build Android APKs* (`mozhi-android`) | *Build Play variant (ML Kit)* (`mozhi-android-play`) |

**Default build.** `pubspec.yaml` has no ML Kit package,
`lib/platform/mlkit_bindings.dart` returns the Tesseract text recognizer
(`lib/platform/text_recognition.dart`; none on the web)
and `android/app/build.gradle.kts` excludes the groups `com.google.mlkit`,
`com.google.android.gms`, `com.google.firebase` and
`com.google.android.datatransport` from every configuration (property
`noMlkit`, default `true`), so a dependency that pulls them in fails the
release build. CI runs `tool/check_no_google.sh` on every APK (and, in the
release workflow, on the app bundle); it must pass.

**Play variant.** The ML Kit code lives in an overlay, `tool/play/`, which
mirrors the paths it is copied to and is excluded from the default
analysis (`analysis_options.yaml`):

```sh
tool/play_prepare.sh           # edits the working tree: use a scratch copy
flutter pub get
flutter build apk --release --flavor production -t lib/main_production.dart
```

The script (POSIX `sh` plus `python3`):

1. adds `google_mlkit_text_recognition` (pinned) to `pubspec.yaml`;
2. copies `tool/play/lib/platform/mlkit_bindings.dart` over the default
   bindings, adds `lib/image_translate/data/mlkit_text_recognition_service.dart`
   and the two matching tests;
3. appends the `// BEGIN mlkit` … `// END mlkit` block (ML Kit's Chinese,
   Devanagari, Japanese and Korean script models) to
   `android/app/build.gradle.kts` and writes `noMlkit=false` to
   `android/gradle.properties`;
4. checks the result (ML Kit may only be imported by the two overlay files).

ML Kit *translation* (`packages/mlkit_translator`) is not part of any
variant: the repository takes a single offline engine, and a second,
closed one would add ~30 MB per language for no gain over Bergamot. The
package is kept in the tree for reference; no build depends on it.

**F-Droid.** The default build is the F-Droid build. `tool/fdroid_prepare.sh`
changes nothing about the app: for F-Droid's source scanner it deletes the
Play-only sources (`tool/play/`, `tool/play_prepare.sh`,
`packages/mlkit_translator`), refuses a tree that `play_prepare.sh`
already changed, and checks that nothing refers to ML Kit and that the
Gradle exclusions are in place. The recipe's `prebuild` runs
`packages/bergamot_translator/tool/fetch_native_deps.sh` (with
`submodules: false`) and then `tool/fdroid_prepare.sh`; the old
`--android-project-arg=noMlkit=true` is accepted and changes nothing.

Both scripts are idempotent (a second run only checks) and exit with an
error when a pattern they rely on is missing, so a refactoring that moves
the ML Kit code breaks them loudly. `tool/variant_prepare_test.sh` tests
both on scratch copies (CI runs it in *Analyze and test*). Don't commit a
prepared tree.

**Keeping the variants working.** ML Kit may only be imported from the
overlay. Everything else gets the engines through the bindings
(`createTextRecognitionService()`, `mlKitIncluded`) or the interfaces
(`OfflineTranslator` in translation_repository, `TextRecognitionService`
in `lib/image_translate/data`); both bindings files keep the same public
API. The offline translator is created in `lib/platform/offline_engine.dart`
for every variant. Code that needs to know what the build has uses
`lib/core/on_device_ml.dart` (`mlKitIncluded`, `onDeviceMlSupported`; tests
flip `debugMlKitIncludedOverride` and `debugOfflineEngineIncludedOverride`).
The ML Kit notice appears on the licences page only in the Play variant.

To check the Play variant locally without touching your checkout:

```sh
tmp=$(mktemp -d)
git ls-files -z | xargs -0 cp --parents -t "$tmp"   # or git worktree add
(cd "$tmp" && sh tool/play_prepare.sh && flutter pub get && flutter analyze)
```

## Tests and checks

CI runs the following on every push and pull request; run them before you
open one:

```sh
# Formatting (the same file list as CI: generated code and build output excluded)
find lib test packages tool -name '*.dart' -not -path 'lib/l10n/gen/*' \
  -not -path '*/.dart_tool/*' -not -path '*/build/*' -print0 \
  | xargs -0 dart format --output=none --set-exit-if-changed

flutter analyze
dart run bloc_tools:bloc lint lib

# Packages: `dart test` for pure Dart ones, `flutter test` for Flutter ones
# (bergamot_translator, mlkit_translator). bergamot_translator's real-engine
# tests only run with BERGAMOT_TEST_MODELS=1 (see its README).
for p in packages/*/; do
  (cd "$p" && if grep -q 'sdk: flutter' pubspec.yaml; then flutter test; else dart test; fi)
done

# Build scripts: the variant scripts and the APK checker
sh tool/variant_prepare_test.sh
sh tool/check_no_google_test.sh

# App
flutter test --coverage
```

Two checks need the internet and run in CI's "Check model downloads"
job rather than with the tests:

```sh
# Every downloadable file (offline languages, voice models, text
# recognition data) is still served with the size the app expects.
python3 tool/check_model_downloads.py
# The public Mozhi servers built into the app: which still translate, with
# which engines (fails only when none translates with the default engine).
python3 tool/check_public_instances.py
```

CI's "Android emulator smoke test" job installs the x86_64 release APK on
an Android 14 emulator without Google APIs and uses it like a new user:
it opens Mozhi, accepts the first-run defaults, types a French sentence
and follows what the app offers, downloading French for offline use first
and else allowing the text to be sent once
(`tool/android_smoke.py <apk> <out-dir>`, with `adb` and a running
emulator or phone). It fails when Mozhi crashes or stops or the sentence
can't be typed; the job summary says whether and how it got translated,
the log lists the text on screen at each step and the screenshots are in
the job's `android-smoke` artifact.

Conventions:

- Cubits are tested with `bloc_test`; dependencies are mocked with
  `mocktail`.
- HTTP is never real in tests: use `MockClient` from
  `package:http/testing.dart`.
- Widget tests use the shared `pumpApp` helper in `test/helpers/`.
- Aim for full coverage of logic. Prompt builders are tested by asserting on
  the text they produce, parsers on real-world model output.

## Web end-to-end tests

`e2e/` holds a small [Playwright](https://playwright.dev) suite that drives
a release web build in Chromium. It covers start-up, the More tools menu,
the Settings, Quality modes, Usage, Dictionary and Documents routes
(several of them deferred, i.e. separate downloads), typing a translation
with an AI provider, a refinement chip, the meaning check, translate
links (`/translate?text=…&from=…&to=…` fills in the screen but sends no AI
request on its own), proofreading (applying and reverting edits, the
writing statistics), History (favorites, search, delete with Undo),
settings round trips (Save history off, the dark theme after a reload),
swapping languages and the recent language pairs, translation memory
("From your history") and friendly errors when the servers are
unreachable. CI runs it in the `Web end-to-end tests` job; on
failure the HTML report, screenshots, videos and traces are uploaded as the
`e2e-report` artifact.

Nothing real is contacted: `e2e/mock_server.py` (Python standard library
only) answers as a Mozhi instance (`/api/*`) and an OpenAI-compatible
provider (`/v1/*`) with deterministic replies (for example `[AI→French
(Français)] <text>` and `[refined] …`). The settings in `e2e/fixtures/` are
seeded into `localStorage` before the app starts.

Requirements: Node.js 18 or newer and Python 3.

```sh
# 1. Build the development flavor, served from /, with its fonts and the
#    app shell's list of files (offline_shell.spec.js)
flutter build web --release -t lib/main_development.dart \
  --no-web-resources-cdn --base-href / -o build/web-e2e
python3 tool/web_fallback_fonts.py build/web-e2e
python3 tool/web_shell_manifest.py build/web-e2e

# 2. Install Playwright and its Chromium (once)
cd e2e
npm ci
npx playwright install --with-deps chromium

# 3. Run (Playwright starts the web server and the mock server itself)
E2E_WEB_DIR=../build/web-e2e npx playwright test
npx playwright show-report        # after a failure: screenshots and traces
```

Environment variables: `E2E_WEB_DIR` (the build to serve, default
`../build/web`), `E2E_APP_PORT` (default 8080), `E2E_MOCK_PORT` (default
8787; the fixtures are rewritten to it) and `E2E_SERVICE_WORKERS` (`allow`
runs every spec with the app shell's service worker; by default only
`offline_shell.spec.js` allows it, since each test starts a fresh browser
profile where the worker would download the whole build again).
`E2E_MODELS_DIR` (`python3 fetch_models.py de <dir>`) enables the specs
that need real offline models. Outside CI, servers that already
listen on those ports are reused, so pick free ports if something else
uses them.

Writing tests:

- Import `test` from `./helpers`, not from `@playwright/test`: it fails a
  test whose page logs a Content Security Policy violation.

- Flutter web renders to a canvas. The app turns on its semantics tree at
  startup on the web (`ensureSemantics` in `lib/bootstrap.dart`); the specs
  wait for it (`waitForSemantics` in `e2e/tests/helpers.js`), then use role
  and label selectors (`getByRole('button', { name: 'More tools' })`), i.e.
  the widgets' semantic labels and localised (English) strings. Avoid
  coordinates.
- A read-only text, such as the translation, is not in the DOM: the
  `copiedTranslation` helper presses Copy and reads the clipboard. An
  editable field exposes its value only while focused.
- Type with `fillField` / `typeSource`: Flutter creates the DOM input
  only once the field has focus, so a plain `fill` right after a click can
  be lost.
- Flutter only builds semantics for what is on screen: scroll a long list
  with `scrollTo` before looking for an item further down.
- The theme is drawn, not styled: `meanLuminance` reads it from a
  screenshot. `takeMockDown` makes the mock server unreachable for one
  page (no-network tests).
- Wait for a label, a role or a polled value (`expect.poll`), not for a
  fixed time. The only fixed wait proves that no request is sent.
- New AI features need a deterministic answer in `llm_answer` in the mock
  server (matched on words in the prompt).

## Code style

- Lints come from `very_good_analysis` 11 and `bloc_lint`. Fix infos too, not
  just warnings.
- The code uses Dart 3.13 syntax, including primary constructors
  (`const new(...)`, `factory fromJson(...)`). Write normal Dart, then run
  `dart fix --apply <path>` and `dart format <path>`.
- **Import Material from `package:material_ui/material_ui.dart`**, never from
  `package:flutter/material.dart`. `go_router` and `dynamic_color` use
  `material_ui`, and mixing the two causes type mismatches.
- State: Cubits with `equatable` states and the Page/View split (`XPage`
  provides the Cubit, `XView` builds the UI).
- UI: Material 3, adaptive layouts (bottom navigation on phones, rail and side
  by side panes from 840 dp), 48 dp touch targets, semantic labels on icon
  buttons, correct in light and dark themes.
- Every user-facing string is localised (see below).
- No telemetry or analytics, ever. History stays on the device.
- Keep public package APIs stable; if a contract has to change, change it
  minimally and say so in the pull request.

## Localisation

All user-facing strings live in ARB files in `lib/l10n/arb/`; `app_en.arb` is
the template. The Dart code in `lib/l10n/gen/` is generated: never edit it by
hand. In widgets, use the `context.l10n` extension:

```dart
import 'package:mozhi/l10n/l10n.dart';

Text(context.l10n.translateSwapLanguages)
```

**Adding English strings.** Use the helper script, which updates
`app_en.arb` safely (it takes a lock, so parallel edits don't clobber each
other) and regenerates the code:

```sh
python3 tool/l10n_add.py '{"historyExportDone": "History exported"}'
```

Placeholders and ICU plurals take a value plus metadata:

```sh
python3 tool/l10n_add.py '{
  "historyCount": {
    "value": "{count, plural, =1{1 entry} other{{count} entries}}",
    "placeholders": {"count": {"type": "int"}}
  }
}'
```

Rules:

- Keys are lowerCamelCase and start with the feature: `translate…`,
  `history…`, `settings…`, `proofread…`, and `common…` for shared strings
  such as **Cancel**.
- The script never overwrites an existing key with a different text; it
  reports a conflict instead. Pick a new key in that case. Re-adding an
  identical key does nothing.
- Without the script, edit `app_en.arb` and run `flutter gen-l10n`.

## Adding a UI language

1. Create `lib/l10n/arb/app_<locale>.arb`, for example `app_de.arb`,
   `app_pt_BR.arb` or `app_zh_Hant.arb`:

   ```json
   {
     "@@locale": "de",
     "appTitle": "Mozhi",
     "navTranslate": "Übersetzen",
     "translateSwapLanguages": "Sprachen tauschen"
   }
   ```

   Translate the values of the keys in `app_en.arb`. The `@key` metadata
   entries are not needed in translations; keep placeholders such as
   `{language}` and the ICU plural structure exactly as in English.
2. Run `flutter gen-l10n` (or `flutter pub get`). The language is picked up
   automatically: `supportedLocales` is generated from the ARB files. Keys
   you haven't translated yet fall back to English, and the generator lists
   them as untranslated.
3. Translate the Android labels: copy
   `android/app/src/main/res/values/strings.xml` to
   `values-<locale>/strings.xml` (e.g. `values-de`, `values-pt-rBR`;
   Indonesian uses the legacy code `values-in`, not `values-id`) and
   translate every string in it: the text-selection actions, the Quick
   Settings tile, the launcher shortcuts and the home-screen widget. Keep the
   names, follow the length notes in the English file, and write apostrophes
   as `\'` (or use `’`). For example:

   ```xml
   <resources>
       <string name="translate_with_mozhi">Mit Mozhi übersetzen</string>
       <string name="translate_offline">Offline übersetzen</string>
       <!-- … every other string from values/strings.xml … -->
   </resources>
   ```

4. Optionally translate the store listing in
   `fastlane/metadata/android/<locale>/` (same files as `en-US`).
5. Check the app in that language, including a right-to-left check for
   Arabic, Hebrew, Persian or Urdu: use `EdgeInsetsDirectional` and
   `AlignmentDirectional` in layouts.

## Documentation

User and contributor documentation is Markdown in `docs/`; self-hosting files
are in `deploy/`. Keep instructions accurate to the current code and the
upstream projects (Mozhi, Ollama, ...), prefer short sections with working
commands, and use [Mermaid](https://mermaid.js.org) for diagrams. Validate
Compose changes with `docker compose -f deploy/docker-compose.yml config`.

## Pull requests

- Keep each pull request focused, with tests for new logic.
- Make sure the checks above pass and the app still runs on a phone-sized and
  a wide window.
- Describe what you changed and why, with screenshots for UI changes.
- By contributing you agree that your work is released under the project's
  [MIT licence](../LICENSE).
