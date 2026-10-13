# Contributing

Thanks for helping! This page covers the toolchain, building and running the
flavors, tests, code style, and localisation, including adding a new UI
language. For how the code is organised, read [Architecture](architecture.md)
first.

- [Toolchain](#toolchain)
- [Get the code running](#get-the-code-running)
- [Flavors](#flavors)
- [Building releases](#building-releases)
- [Tests and checks](#tests-and-checks)
- [Code style](#code-style)
- [Localisation](#localisation)
- [Adding a UI language](#adding-a-ui-language)
- [Documentation](#documentation)
- [Pull requests](#pull-requests)

## Toolchain

- **Flutter 3.47** (stable; CI uses 3.47.7) with **Dart 3.13**.
- Android: JDK 17 and the Android SDK.
- iOS and macOS: Xcode on a Mac.
- Windows: Visual Studio with the "Desktop development with C++" workload.
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

The three install side by side on Android. iOS and macOS have matching
`development`, `staging` and `production` schemes. Always pass both
`--flavor` and `-t`:

```sh
flutter run --flavor staging -t lib/main_staging.dart
flutter run -d chrome -t lib/main_development.dart   # web has no flavors
```

## Building releases

```sh
# Android: one APK per ABI, plus a universal APK
flutter build apk --release --flavor production -t lib/main_production.dart --split-per-abi
flutter build apk --release --flavor production -t lib/main_production.dart

# Web (served from /Mozhi/; change --base-href for another path)
flutter build web --release -t lib/main_production.dart --base-href /Mozhi/

# Desktop
flutter build macos --release --flavor production -t lib/main_production.dart
flutter build windows --release -t lib/main_production.dart
```

Release signing for Android, the CI artifacts and tagged releases are
described in the [README](../README.md).

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
3. Add the locale to `CFBundleLocalizations` in `ios/Runner/Info.plist` so iOS
   offers it.
4. Translate the Android text-selection label: create
   `android/app/src/main/res/values-<locale>/strings.xml` (e.g. `values-de`,
   `values-pt-rBR`) with

   ```xml
   <resources>
       <string name="translate_with_mozhi">Mit Mozhi übersetzen</string>
   </resources>
   ```

5. Optionally translate the store listing in
   `fastlane/metadata/android/<locale>/` (same files as `en-US`).
6. Check the app in that language, including a right-to-left check for
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
