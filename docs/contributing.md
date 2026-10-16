# Contributing

Thanks for helping! This page covers the toolchain, building and running the
flavors, tests, code style, and localisation, including adding a new UI
language. For how the code is organised, read [Architecture](architecture.md)
first.

- [Toolchain](#toolchain)
- [Get the code running](#get-the-code-running)
- [Flavors](#flavors)
- [Building releases](#building-releases)
- [F-Droid variant (no ML Kit)](#f-droid-variant-no-ml-kit)
- [Tests and checks](#tests-and-checks)
- [Web end-to-end tests](#web-end-to-end-tests)
- [Code style](#code-style)
- [Localisation](#localisation)
- [Adding a UI language](#adding-a-ui-language)
- [Documentation](#documentation)
- [Pull requests](#pull-requests)

## Toolchain

- **Flutter 3.47** (stable; CI uses 3.47.7) with **Dart 3.13**.
- Android: JDK 17 and the Android SDK.
- Optional: [Very Good CLI](https://cli.vgv.dev) (`very_good test`).

## Get the code running

```sh
git clone https://github.com/Aimdi/Mozhi.git
cd Mozhi
flutter pub get                 # also generates lib/l10n/gen
for p in packages/*/; do (cd "$p" && flutter pub get); done
flutter run --flavor development -t lib/main_development.dart
```

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
# --base-href for a sub-path, e.g. /mozhi/)
flutter build web --release -t lib/main_production.dart \
  --base-href / --no-web-resources-cdn
```

Release signing for Android, the CI artifacts and tagged releases are
described in the [README](../README.md).

## F-Droid variant (no ML Kit)

Offline translation, language identification and on-device text
recognition use Google ML Kit, which is closed source. F-Droid only accepts
free software, so the F-Droid build is the same app without ML Kit. It is
made from the normal source tree by one script:

```sh
tool/fdroid_prepare.sh        # edits the working tree: use a scratch copy
flutter pub get
flutter build apk --release --flavor production -t lib/main_production.dart \
  --android-project-arg=noMlkit=true
```

The script (POSIX `sh` plus `python3`):

1. removes `google_mlkit_text_recognition` and `mlkit_translator` from
   `pubspec.yaml` (Flutter registers every plugin listed there, whatever the
   flavor, so a Gradle flavor alone cannot drop them);
2. copies `lib/platform/mlkit_bindings_stub.dart` over
   `lib/platform/mlkit_bindings.dart`;
3. deletes the files that import ML Kit:
   `lib/image_translate/data/mlkit_text_recognition_service.dart`,
   `packages/mlkit_translator` and their tests;
4. deletes the `// BEGIN mlkit` … `// END mlkit` block (the
   `com.google.mlkit:text-recognition-*` script models) from
   `android/app/build.gradle.kts` and writes `noMlkit=true` to
   `android/gradle.properties`; with that property Gradle also excludes the
   whole `com.google.mlkit` group, so a stray ML Kit dependency fails the
   build instead of ending up in the APK;
5. checks that nothing in `pubspec.yaml`, `lib/`, `test/`, `packages/` or
   the Gradle build still refers to ML Kit.

It is idempotent (a second run only checks) and exits with an error when a
pattern it edits is missing, so a refactoring that moves the ML Kit code
breaks it loudly. Don't commit the prepared tree.

**Keeping the variant working.** ML Kit may only be imported from
`lib/platform/mlkit_bindings.dart`,
`lib/image_translate/data/mlkit_text_recognition_service.dart` and
`packages/mlkit_translator`. Everything else gets the engines through the
bindings (`createOfflineTranslator()`, `createTextRecognitionService()`) or
the interfaces (`OfflineTranslator` in translation_repository,
`TextRecognitionService` in `lib/image_translate/data`). The stub keeps the
same public API and returns `UnavailableOfflineTranslator` and
`UnavailableTextRecognitionService`. Code that needs to know whether ML Kit
is there uses `lib/core/on_device_ml.dart` (`mlKitIncluded`,
`onDeviceMlSupported`; tests flip `debugMlKitIncludedOverride`). Without ML
Kit the app shows *Offline languages* in Settings as disabled with an
explanation, the offline engine is not offered, the on-device text
recognition method is hidden on the image screen and the ML Kit notice is
left out of the licenses page.

The CI job *Build F-Droid variant (no ML Kit)* (`.github/workflows/main.yaml`)
runs the script on its checkout, analyzes, builds the universal production
APK and fails if the APK contains `com/google/mlkit` classes or ML Kit
native libraries, or if the Gradle runtime classpath has a
`com.google.mlkit` artifact. Its APK is uploaded as `mozhi-android-fdroid`.
To check the variant locally without touching your checkout:

```sh
tmp=$(mktemp -d)
git ls-files -z | xargs -0 cp --parents -t "$tmp"   # or git worktree add
(cd "$tmp" && sh tool/fdroid_prepare.sh && flutter pub get &&
  bash .github/scripts/packages.sh get && flutter analyze)
```

## Tests and checks

CI runs the following on every push and pull request; run them before you
open one:

```sh
# Formatting (the same file list as CI: generated code and build output excluded)
find lib test packages -name '*.dart' -not -path 'lib/l10n/gen/*' \
  -not -path '*/.dart_tool/*' -not -path '*/build/*' -print0 \
  | xargs -0 dart format --output=none --set-exit-if-changed

flutter analyze
dart run bloc_tools:bloc lint lib

# Packages: `dart test` for pure Dart ones, `flutter test` for Flutter ones
# (mlkit_translator)
for p in packages/*/; do
  (cd "$p" && if grep -q 'sdk: flutter' pubspec.yaml; then flutter test; else dart test; fi)
done

# App
flutter test --coverage
```

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
writing statistics), History (favourites, search, delete with Undo),
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
# 1. Build the development flavor, served from /
flutter build web --release -t lib/main_development.dart \
  --no-web-resources-cdn --base-href / -o build/web-e2e

# 2. Install Playwright and its Chromium (once)
cd e2e
npm ci
npx playwright install --with-deps chromium

# 3. Run (Playwright starts the web server and the mock server itself)
E2E_WEB_DIR=../build/web-e2e npx playwright test
npx playwright show-report        # after a failure: screenshots and traces
```

Environment variables: `E2E_WEB_DIR` (the build to serve, default
`../build/web`), `E2E_APP_PORT` (default 8080) and `E2E_MOCK_PORT` (default
8787; the fixtures are rewritten to it). Outside CI, servers that already
listen on those ports are reused, so pick free ports if something else
uses them.

Writing tests:

- Import `test` from `./helpers`, not from `@playwright/test`: it fails a
  test whose page logs a Content Security Policy violation.

- Flutter web renders to a canvas. The specs turn on its semantics tree
  (`enableSemantics` in `e2e/tests/helpers.js`), then use role and label
  selectors (`getByRole('button', { name: 'More tools' })`), i.e. the
  widgets' semantic labels and localised (English) strings. Avoid
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
3. Translate the Android text-selection label: create
   `android/app/src/main/res/values-<locale>/strings.xml` (e.g. `values-de`,
   `values-pt-rBR`) with

   ```xml
   <resources>
       <string name="translate_with_mozhi">Mit Mozhi übersetzen</string>
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
