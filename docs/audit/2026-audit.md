# Mozhi privacy audit, Phase 0 (October 2026)

Phase 0 of the privacy-first improvement plan: a read-only audit. Nothing in
the app was changed. The only new files are this report,
[progress.md](progress.md), `tool/check_no_google.sh` and its test
`tool/check_no_google_test.sh`.

## Scope, baseline and method

- **Baseline:** commit `2c33476` ("docs: Android and web only") on
  `claude/magical-einstein-k02w13`, the tip of the branch when the plan
  started. Every `path:line` below refers to that commit. To read a file at
  that commit, run `git show 2c33476:<path>`.
- **Concurrent work, not audited:** while this audit ran, commit `bebecb6`
  ("feat(privacy): data destination model, privacy modes and privacy
  settings") landed. Phase 1 work also started in the working tree
  (`packages/bergamot_translator`, `.gitmodules`, `pubspec.yaml`, and edits
  to `mozhi_api_client.dart`). Where `bebecb6` adds a field that this
  report lists as missing, the report says so. Those fields exist in the
  model only and change no behaviour.
- **Toolchain checked:** Flutter 3.47.7 (stable, framework `abaf9c5237`),
  Dart 3.13.5. Runtime dependencies were resolved with
  `flutter pub deps --json`. Licences were read from
  `~/.pub-cache/hosted/pub.dev/<pkg>-<ver>/LICENSE`.
- **Limits:**
  - There is no Android SDK, so Gradle could not run. The Android
    dependencies come from each plugin's `android/build.gradle(.kts)` and
    `AndroidManifest.xml` in the pub cache.
  - `dl.google.com` (Google Maven) is blocked from this session, so
    ML Kit's own POMs could not be read. Transitive Google artifacts of
    ML Kit are therefore stated from its published dependency graph and
    marked **unverified**.
  - The F-Droid classpath is the exception. It is verified through the
    annotations of CI run 38895165428, the `2c33476` push, all jobs green
    (see §1.5).

## Key findings

1. **Text reaches public servers run by strangers by default.** The
   default settings list 11 public Mozhi instances
   (`packages/translation_repository/lib/src/models/mozhi_instance.dart:32-88`;
   `lib/settings/models/app_settings.dart:45`). They span India, Germany,
   the USA, Ukraine, Finland and Russia. The default engine is
   `mozhi:google` (`lib/translate/cubit/translate_cubit.dart:151`), and
   instant translate is on (`app_settings.dart:52`, 600 ms debounce,
   `translate_cubit.dart:93`).
2. **Silent failover across operators.** When a translation fails on an
   instance with any status except 400/413/414/431 (5xx, 429, 403, 404,
   3xx, network errors, or DeepL's empty-200), the same text is re-sent to
   the next instance. The chain can cover all 11 operators, and nobody is
   asked (`packages/translation_repository/lib/src/repository/mozhi_pool.dart:103-137`
   and `193-199`; `packages/mozhi_api/lib/src/mozhi_api_exception.dart:16-27`).
   Only timeouts are excluded, for requests that carry text
   (`failOverOnTimeout: false`).
3. **The engine is silently swapped, and the swap can land on a cloud
   AI.**
   - When the saved engine is missing or its languages fail to load, the
     translate screen falls back to the current engine, then
     `mozhi:google`, then `engines.first`
     (`translate_cubit.dart:696-723`, `729-750`).
   - The quick-translate sheet does the same
     (`lib/quick_translate/cubit/quick_translate_cubit.dart:349-362`).
   - When every Mozhi instance is unreachable, `getEngines` returns only
     the AI, machine-translation and offline engines
     (`packages/translation_repository/lib/src/translation_repository.dart:262-267`).
     The offline engine is listed last, so `engines.first` becomes the
     first configured provider, which can be a cloud AI.
   - The quick-translate sheet (text selected in another app) translates
     immediately (`quick_translate_cubit.dart:67-112`). So text selected in
     another app can go to a cloud AI provider without the user choosing
     it.
   - The translate screen also auto-sends external text with a non-AI
     engine such as DeepL (`translate_cubit.dart:887-891`, `436-445`).
   - No notice is shown. The repository itself never falls back across
     engine kinds (`translation_repository.dart:751-764`).
4. **Language detection sends text to a second back end.** With a
   translation-only (MT-profile) cloud AI model and an "auto" source, the
   text goes to Mozhi `google` for language detection whenever on-device
   identification is unavailable or inconclusive
   (`translation_repository.dart:911-916`, `962-987`, `1704-1719`). In the
   F-Droid build there is no on-device identification, so this always
   happens.
5. **User text appears in URLs.**
   - Mozhi text-to-speech is `GET /api/tts?engine=…&lang=…&text=…`
     (`packages/mozhi_api/lib/src/mozhi_api_client.dart:256-271`).
     **Listen** uses Mozhi first by default
     (`lib/speech/speech_service.dart:84-97`, `440-461`;
     `preferDeviceVoice` defaults to false at line 199), in chunks of 200
     characters (`lib/speech/speech_chunker.dart:1-11`). It fails over
     across instances, then from Google to Reverso
     (`translation_repository.dart:1721-1748`). Reverse proxies on public
     instances usually log query strings.
   - **Translation itself uses a POST form (confirmed)**
     (`mozhi_api_client.dart:349-377`). The plan's assumption of
     "`GET /api/translate` with the text in the URL" is wrong for
     translation and right for TTS.
   - In the web build, translate links put the text in the page URL
     (`https://host/?text=…`), and that URL reaches the web host
     (`lib/app/view/app.dart:76-79`).
6. **Image translation uploads the photo as soon as it is picked**
   (`lib/image_translate/cubit/image_translate_cubit.dart:15`, `164-176`).
   The default method prefers Mozhi Lens (a public instance, then Google)
   over on-device OCR, even when the selected engine is the offline one
   (`lib/image_translate/models/image_translate_method.dart:81-97`).
7. **The privacy badge is misleading.** Every Mozhi engine is labelled
   **Self-hosted**, including engines on public instances
   (`lib/translate/widgets/engine_selector.dart:350-380`).
8. **Network requests at startup and while browsing settings.**
   - Each launch, including the first one during onboarding, loads the
     engine and language lists from the active instance. A stored list is
     served at once and then refreshed in the background (on a fresh
     install, that instance is `mozhi.aryak.me`)
     (`lib/app/view/app.dart:74`; `translation_repository.dart:413-470`).
   - Opening **Settings > Mozhi instances** pings all 11 instances
     (`lib/settings/view/instances_page.dart:69`).
   - There are no update checks, analytics or CDN requests on Android.
9. **Stored data is not encrypted.**
   - History is plain JSON in `SharedPreferencesAsync` (DataStore on
     Android, `localStorage` on the web) under `history.v1`. It is **not
     encrypted** (`lib/history/data/history_repository.dart:80`;
     `lib/core/key_value_store.dart:18-33`).
   - It moves to a new phone with Android 12+ device-to-device transfer
     (`android/app/src/main/res/xml/data_extraction_rules.xml:24-27`).
   - Custom provider headers (`ai_provider_config.dart:198`) and Mozhi
     basic-auth credentials inside instance URLs are stored in the same
     plain settings JSON. API keys are the exception: they live in
     `flutter_secure_storage`.
10. **Missing privacy controls (baseline):** incognito, `FLAG_SECURE`,
    sensitive-clipboard flag, opting out of keyboard learning (IME),
    "delete all data", proxy support, cloud consent. Cleartext is allowed
    for every host (`AndroidManifest.xml:34`;
    `network_security_config.xml:17`). The only warnings for `http://` to
    a public host appear when the server is added. The network security
    config comment mentions an "app-level http guard"
    (`network_security_config.xml:12-15`), but no such guard exists.
11. **Google code in the build.**
    - ML Kit is proprietary and ships in the main build: Dart wrappers
      `google_mlkit_*` (MIT) with native `com.google.mlkit:*`.
    - Unverified, from ML Kit's published POMs: ML Kit pulls
      `com.google.android.gms:play-services-{base,basement,tasks}`,
      `com.google.android.datatransport:transport-{api,backend-cct,runtime}`
      (Firelog telemetry) and `com.google.firebase:firebase-{components,encoders,encoders-json}`.
    - No other plugin pulls Play services, Firebase or data transport.
    - The F-Droid variant removes ML Kit. CI shows no Google artifacts in
      its runtime classpath.
    - Two smaller items remain in both builds. image_picker declares a
      disabled `com.google.android.gms.metadata.ModuleDependencies`
      service (manifest only). speech_to_text targets the Google app for
      language details (an intent, not a library).
12. **CI and repository hygiene.**
    - `license_check.yaml` never runs, because it triggers on `main`,
      which doesn't exist.
    - All actions on Node 20 raise deprecation warnings. The three open
      Dependabot PRs fix part of that; merge them (§7).
    - The default branch is an unprotected `claude/*` branch (§8).

---

## 1. Dependencies

### 1.1 App (`pubspec.yaml`), direct dependencies

Resolved versions come from `pubspec.lock` (lock line in brackets).
Licences come from the pub cache.

| Package | Constraint (pubspec.yaml) | Resolved (pubspec.lock) | Licence | Notes |
| --- | --- | --- | --- | --- |
| audioplayers | ^6.8.1 (:11) | 6.8.1 (:52); android 5.3.0 (:60) | MIT | Plays Mozhi TTS MP3s. Android: androidx core-ktx, Kotlin coroutines. |
| bloc | ^9.2.1 (:12) | 9.2.1 | MIT | |
| dynamic_color | ^2.1.0 (:13) | 2.1.0 (:268) | Apache-2.0 | Android: `com.google.android.material:material:1.7.0` (open source, Apache-2.0). |
| equatable | ^3.0.0 (:14) | 3.0.0 | MIT | |
| file_picker | ^13.1.0 (:15) | 13.1.0 (:316); android_file_picker 2.1.0 (:20) | MIT | Android: androidx only. |
| flutter_bloc | ^9.1.1 (:18) | 9.1.1 | MIT | |
| flutter_secure_storage | ^11.2.0 (:21) | 11.2.0 (:422) | BSD-3-Clause | Android: `com.google.crypto.tink:tink-android:1.23.0` (open source, Apache-2.0; not a tracker). |
| flutter_tts | ^4.2.5 (:22) | 4.2.5 (:475) | MIT | System TTS engine (often Google TTS; voices marked "network" are online). |
| go_router | ^18.0.2 (:23) | 18.0.2 (:504) | BSD-3-Clause | |
| **google_mlkit_text_recognition** | ^0.17.1 (:24) | 0.17.1 (:528) | MIT (wrapper) | **Proprietary native SDK** `com.google.mlkit:text-recognition:16.0.1` (ML Kit Terms). Removed in F-Droid. |
| http | ^1.6.0 (:25) | 1.6.0 (:552) | BSD-3-Clause | All Dart HTTP traffic (dart:io `HttpClient` on Android). |
| image_picker | ^1.2.4 (:26) | 1.2.4 (:576); android 0.8.13+25 (:584) | Apache-2.0 | Android: androidx. Manifest declares a disabled `com.google.android.gms.metadata.ModuleDependencies` service (photo-picker backport hint, §1.4). |
| intl | ^0.20.2 (:27) | 0.20.3 (:640) | BSD-3-Clause | |
| llm_api | path (:28-29) | 0.1.0+1 | MIT (repo) | |
| material_ui | ^1.1.1 (:30) | **1.6.0** (:775) | BSD-3-Clause | Decoupled Material library. Defines the default page transitions (§9). |
| mlkit_translator | path (:31-32) | 0.1.0+1 | MIT (repo) | Pulls google_mlkit_translation and google_mlkit_language_id. Removed in F-Droid. |
| mozhi_api | path (:33-34) | 0.1.0+1 | MIT (repo) | |
| package_info_plus | ^10.2.2 (:35) | 10.2.2 (:868) | BSD-3-Clause | Local only. |
| share_plus | ^13.3.1 (:36) | 13.3.1 (:1028) | BSD-3-Clause | Android: androidx and coroutines. Adds a FileProvider and a non-exported receiver. |
| shared_preferences | ^2.5.6 (:37) | 2.5.6 (:1044); android 2.4.28 (:1052) | BSD-3-Clause | Android: androidx DataStore. Holds settings and history (§4). |
| speech_to_text | ^7.5.0 (:38) | 7.5.0 (:1161) | BSD-3-Clause | System `SpeechRecognizer`. No Gradle dependencies. Sets package `com.google.android.googlequicksearchbox` for language details (`SpeechToTextPlugin.kt:398`). |
| translation_repository | path (:39-40) | 0.1.0+1 | MIT (repo) | Pulls mt_api. |
| url_launcher | ^6.3.3 (:41) | 6.3.3 (:1264); android 6.3.33 (:1272) | BSD-3-Clause | Android: androidx core and browser. The app opens links in an external app (`lib/settings/view/widgets/link_launcher.dart:12`). |
| flutter, flutter_localizations | sdk | Flutter 3.47.7 | BSD-3-Clause | |

Dev dependencies (not shipped): bloc_lint 0.4.3, bloc_test 10.0.0,
bloc_tools 0.1.0-dev.25, mocktail 1.0.5, very_good_analysis 11.0.0
(`pubspec.yaml:43-50`). The lock requires Dart `>=3.13.0` and Flutter
`>=3.47.0` (`pubspec.lock:1440-1442`).

### 1.2 Packages (`packages/*/pubspec.yaml`)

Lock files: only the root `pubspec.lock` is committed. Each package's lock
is git-ignored (for example `packages/llm_api/.gitignore:7`), and the
local copies resolve the same versions except for dev tooling (analyzer 14.5.0
and test 1.33.0 instead of 13.3.0 / 1.31.1).

| Package | Runtime dependencies (resolved) | Dev | Flags |
| --- | --- | --- | --- |
| `mozhi_api` | http 1.6.0, http_parser 4.1.2, meta 1.19.0 | mocktail, test, very_good_analysis | none |
| `llm_api` | http 1.6.0, meta 1.19.0 | same | none |
| `mt_api` | http 1.6.0, meta 1.19.0 | same | none |
| `translation_repository` | collection 1.19.1, llm_api, mozhi_api, mt_api, meta | same | none |
| `mlkit_translator` | **google_mlkit_language_id 0.15.1**, **google_mlkit_translation 0.15.1** (`packages/mlkit_translator/pubspec.yaml:13-14`), translation_repository | flutter_test, mocktail, very_good_analysis | **ML Kit (proprietary)** |
| `mozhi_cli` | args 2.7.0, cli_completion 0.6.0, mason_logger 0.3.6, llm_api, mozhi_api, translation_repository (its lock has equatable 2.1.0) | build_runner 2.16.2, build_verify, build_version, mocktail, test | none. Config file is 0600 in a 0700 directory (`packages/mozhi_cli/lib/src/config/config_store.dart:10-17`). |

The app does not depend on `mozhi_cli`. It reaches `mt_api` through
`translation_repository`.

### 1.3 Licences of the runtime closure (129 packages)

| Licence | Count | Packages |
| --- | ---: | --- |
| BSD-3-Clause | 84 (+4 Flutter SDK) | most of the Dart team, flutter.dev and plus plugins, go_router, http, intl, material_ui, jni, … |
| MIT | 29 (+5 in this repo) | bloc family, audioplayers family, file_picker family, flutter_tts, **google_mlkit_commons/language_id/text_recognition/translation**, provider, uuid, xml, yaml, … |
| Apache-2.0 | 6 | clock, dynamic_color, image_picker (and its android/ios packages), material_color_utilities |
| MPL-2.0 | 1 | `dbus` 0.8.0 (pulled by `file_picker_linux`; Linux only, not in the Android or web build) |

None is GPL, and none lacks a licence. `license_check.yaml:25` allows only
MIT, BSD-3-Clause, BSD-2-Clause and Apache-2.0, so `dbus` (MPL-2.0) would
probably fail that check if it ever ran (§12).

The **ML Kit native SDKs are proprietary**: Google ML Kit Terms of Service,
with usage metrics sent to Google. The MIT licence covers only the Dart
wrappers. The app shows the terms in its licence page
(`lib/app/third_party_licenses.dart:44-68`).

### 1.4 Native Android dependencies of the plugins (pub cache Gradle files)

| Plugin (version) | Gradle file:line | `implementation` artifacts | Google / proprietary? |
| --- | --- | --- | --- |
| android_file_picker 2.1.0 | `android/build.gradle.kts:91-94` | androidx core, core-ktx, annotation, lifecycle-runtime | no |
| audioplayers_android 5.3.0 | `android/build.gradle:72-75` | androidx core-ktx 1.9.0, Kotlin stdlib, kotlinx-coroutines | no |
| dynamic_color 2.1.0 | `android/build.gradle.kts:53-56` | `com.google.android.material:material:1.7.0` | Google, open source (Apache-2.0). Not a tracker. Not flagged. |
| flutter_plugin_android_lifecycle 2.0.35 | `android/build.gradle.kts:48` | androidx annotation | no |
| flutter_secure_storage 11.2.0 | `android/build.gradle:68-69` | `com.google.crypto.tink:tink-android:1.23.0` | Google, open source (Apache-2.0). Not flagged. |
| flutter_tts 4.2.5 | `android/build.gradle:58-60` | Kotlin stdlib | no |
| **google_mlkit_commons 0.13.0** | `android/build.gradle:49` | **`com.google.mlkit:vision-common:17.3.0`** | **proprietary** |
| **google_mlkit_language_id 0.15.1** | `android/build.gradle:48` | **`com.google.mlkit:language-id:17.0.6`** | **proprietary** |
| **google_mlkit_text_recognition 0.17.1** | `android/build.gradle:49-53` | **`com.google.mlkit:text-recognition:16.0.1`**; Chinese, Devanagari, Japanese and Korean as `compileOnly` | **proprietary** |
| **google_mlkit_translation 0.15.1** | `android/build.gradle:50` | **`com.google.mlkit:translate:17.0.3`** | **proprietary** |
| image_picker_android 0.8.13+25 | `android/build.gradle.kts:50-53` | androidx core, annotation, exifinterface, activity | no code. Manifest has a disabled GMS `ModuleDependencies` service (`src/main/AndroidManifest.xml:15-24`). |
| jni 1.1.0 / jni_flutter 1.0.4+1 | `android/build.gradle` | none | no (used by path_provider_android) |
| package_info_plus 10.2.2 | `android/build.gradle.kts` | none | no |
| path_provider_android 2.3.1 | (no Gradle file; Dart over jni) | none | no |
| share_plus 13.3.1 | `android/build.gradle.kts:67-69` | androidx core-ktx, annotation, kotlinx-coroutines-android | no |
| shared_preferences_android 2.4.28 | `android/build.gradle.kts:62-64` | androidx datastore, datastore-preferences, preference | no |
| speech_to_text 7.5.0 | `android/build.gradle:1-40` | none | no library. Intent to `com.google.android.googlequicksearchbox` (`SpeechToTextPlugin.kt:395-399`; used below API 33 or without the microphone permission). |
| url_launcher_android 6.3.33 | `android/build.gradle.kts:75-77` | androidx core, annotation, browser | no |

The app module itself adds `kotlin-stdlib:2.3.21`
(`android/app/build.gradle.kts:139-141`). Unless the build is `noMlkit`,
it also adds the four ML Kit script models,
`com.google.mlkit:text-recognition-{chinese,devanagari,japanese,korean}:16.0.1`
(`android/app/build.gradle.kts:154-163`).

**Transitive Google artifacts of ML Kit** (unverified: Gradle could not
run and Google Maven was unreachable). ML Kit's published POMs depend on
`com.google.mlkit:common`, `com.google.android.gms:play-services-base`,
`-basement` and `-tasks`, `com.google.android.datatransport:transport-api`,
`-backend-cct` and `-runtime`, and `com.google.firebase:firebase-components`,
`-encoders` and `-encoders-json`. Their merged manifests normally add:

- `MlKitInitProvider`, a content provider that runs at process start;
- `MlKitComponentDiscoveryService`;
- data transport's `JobInfoSchedulerService` and
  `AlarmManagerSchedulerBroadcastReceiver`.

To confirm, run
`./gradlew :app:dependencies --configuration productionReleaseRuntimeClasspath`
and inspect the merged manifest
(`build/app/intermediates/merged_manifests/productionRelease/`) on a
machine with the Android SDK, or run `tool/check_no_google.sh` on the
normal release APK.

The Flutter embedding refers to Play Core for deferred components. The
classes are not bundled: `-dontwarn com.google.android.play.core.**`
(`android/app/proguard-rules.pro:15-16`).

### 1.5 F-Droid classpath (verified through CI)

The job "Build F-Droid variant (no ML Kit)" prints `::warning::Google
artifact in the classpath: …` for every `com.google.android.gms`,
`com.google.android.datatransport`, `com.google.firebase` or
`com.google.android.play` artifact in `productionReleaseRuntimeClasspath`
(`.github/workflows/main.yaml:259-275`). In run 38895165428 (commit
`2c33476`), the job's annotations contain only the Node 20 and setup-java
deprecation warnings. There is no Google artifact warning and no
"gradlew missing" warning. Flutter injects the Gradle wrapper during
`flutter build apk`
(`flutter_tools/lib/src/android/gradle_utils.dart:239,257`), so the check
did run. The F-Droid runtime classpath was therefore free of Play
services, data transport, Firebase and Play Core at the baseline.

## 2. Android build (`android/`)

| Item | Value | Where |
| --- | --- | --- |
| namespace / applicationId | `io.github.aimdi.mozhi` | `android/app/build.gradle.kts:47,57` |
| compileSdk | `flutter.compileSdkVersion` = **36** | `build.gradle.kts:48`; Flutter 3.47.7 `packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt:23` |
| minSdk | `flutter.minSdkVersion` = **24** | `build.gradle.kts:58`; `FlutterExtension.kt:26` |
| targetSdk | `flutter.targetSdkVersion` = **36** | `build.gradle.kts:59`; `FlutterExtension.kt:34` |
| NDK | `flutter.ndkVersion` = 28.2.13676358 | `build.gradle.kts:49`; `FlutterExtension.kt:42` |
| Java / JVM target | 17 / 17 | `build.gradle.kts:51-54,115-119` |
| AGP | **8.12.0** | `android/settings.gradle.kts:21` |
| Kotlin (KGP) | 2.3.21 (stdlib 2.3.21 at `build.gradle.kts:140`) | `settings.gradle.kts:22` |
| Gradle | **9.0.0** (`-all`) | `android/gradle/wrapper/gradle-wrapper.properties:5` |
| Flutter support range | Gradle: error below 8.14.0, warning below 9.1.0. AGP: error below 8.11.1, warning below 9.0.1. KGP: error below 2.2.20, warning below 2.3.20. So **AGP 8.12.0 and Gradle 9.0.0 both get Flutter's "will soon be unsupported" warning**. KGP is fine. | `DependencyVersionChecker.kt:94-109,217-293` |
| Flavors | dimension `default`: `production` (no suffix, "Mozhi"), `staging` (`.stg`, "[STG] Mozhi"), `development` (`.dev`, "[DEV] Mozhi") | `build.gradle.kts:77-94` |
| Signing | Release keystore from CI environment variables (`ANDROID_KEYSTORE_PATH` and friends), else `android/key.properties`. Otherwise, **release builds are silently signed with the debug key**. | `build.gradle.kts:10-44,66-75,96-102` |
| R8 | `isMinifyEnabled = true`, `proguard-android-optimize.txt` plus `proguard-rules.pro`. No `isShrinkResources`. The keep rules cover all of `io.flutter.**` and `io.github.aimdi.mozhi.**`, plus `-keepattributes *Annotation*, Signature, …`. | `build.gradle.kts:103-107`; `proguard-rules.pro:5-19` |
| ML Kit block | `noMlkit` Gradle property, which excludes the `com.google.mlkit` group from every configuration (`:125-137`). Inside `// BEGIN mlkit` … `// END mlkit` (`:143-164`): the four bundled script models (`:154-163`), which `tool/fdroid_prepare.sh` deletes. | `build.gradle.kts:125-164` |
| gradle.properties | `-Xmx8G`; `android.useAndroidX=true`; **`android.enableJetifier=true`** (probably unneeded: no plugin uses support libraries; it slows builds) | `android/gradle.properties:1-3` |
| Release obfuscation | `--obfuscate --split-debug-info` in `release.yaml:83-109`; symbols are kept as a private artifact (`:128-134`) | |

## 3. `AndroidManifest.xml` (`android/app/src/main/AndroidManifest.xml`)

**Permissions**

- `INTERNET` (`:3`).
- `RECORD_AUDIO` (`:11`), with `android.hardware.microphone`
  `required="false"` (`:14`).
- Deliberately not declared: `CAMERA` (the system camera app handles
  capture), `BLUETOOTH_CONNECT` (`:4-10`), and `QUERY_ALL_PACKAGES`.
- The `debug` and `profile` manifests add only `INTERNET`
  (`src/debug/AndroidManifest.xml:6`, `src/profile/AndroidManifest.xml:6`).
- Plugins declare no permissions. ML Kit and data transport normally merge
  in `ACCESS_NETWORK_STATE` and `INTERNET` (unverified).

**Application attributes**

| Attribute | Value | Line |
| --- | --- | --- |
| `allowBackup` | `false` | `:30` |
| `fullBackupContent` | `@xml/backup_rules` | `:31` |
| `dataExtractionRules` | `@xml/data_extraction_rules` | `:32` |
| `enableOnBackInvokedCallback` | `true` (predictive back) | `:33` |
| `usesCleartextTraffic` | **`true`** | `:34` |
| `networkSecurityConfig` | `@xml/network_security_config` | `:35` |
| `localeConfig` | **absent**, and there is no `res/xml/locales_config.xml` or `generateLocaleConfig` | n/a |

**Backup and transfer rules**

- `res/xml/backup_rules.xml:8-12` (Android 11 and lower; inert with
  `allowBackup=false`) excludes `sharedpref/FlutterSecureStorage.xml`,
  `sharedpref/FlutterSecureKeyStorage.xml` and `file/datastore`.
- `res/xml/data_extraction_rules.xml`:
  - `<cloud-backup disableIfNoEncryptionCapabilities="true">` excludes
    both secure-storage files and `file/datastore` (`:16-20`).
  - `<device-transfer>` excludes **only** the two secure-storage files
    (`:24-27`). **Settings, history, glossaries, presets and usage
    counters (all in `datastore/`) are copied to a new phone during
    device-to-device transfer.**

**Network security config** (`res/xml/network_security_config.xml`)

- `<base-config cleartextTrafficPermitted="true">` trusts system CAs only
  (`:17-21`).
- `<debug-overrides>` adds user CAs (`:22-27`).
- Its comment (`:12-15`) correctly notes that Dart's `HttpClient` ignores
  this file. It then calls "the app-level http guard" the real control for
  Dart traffic, but no such guard exists (§6).

**Components and intent filters**

| Component | Exported | Filters / notes | Lines |
| --- | --- | --- | --- |
| `.MainActivity` | **yes** | `singleTop`; `taskAffinity=""` (counters task hijacking); `MAIN`/`LAUNCHER`; `SEND` `text/plain`; `PROCESS_TEXT` `text/plain` ("Translate with Mozhi"); `VIEW` `mozhi://` with hosts translate, image, conversation, proofread, documents, web, dictionary (`BROWSABLE`); `flutter_deeplinking_enabled`; static shortcuts | `:36-96` (filters at `:62-95`) |
| `.TranslateClipboardActivity` (activity-alias) | no | Target of `TRANSLATE_CLIPBOARD` from the tile, widget and shortcut. MainActivity honours the action only through this alias (`MainActivity.kt:254-259`). | `:108-119` |
| `.TranslateTileService` | yes, protected by `BIND_QUICK_SETTINGS_TILE` | `QS_TILE` | `:122-131` |
| `.MozhiWidgetProvider` | no | `APPWIDGET_UPDATE`; no periodic updates (`res/xml/mozhi_widget_info.xml:17`) | `:137-147` |
| `<queries>` | n/a | `VIEW https`, `PROCESS_TEXT`, `SEND`, `RecognitionService`, `TTS_SERVICE`, `IMAGE_CAPTURE` | `:156-185` |
| From plugins | no | image_picker FileProvider and the disabled GMS `ModuleDependencies` service; share_plus FileProvider and `SharePlusPendingIntent` receiver; url_launcher `WebViewActivity`. All `exported="false"`. | plugin manifests (§1.4) |

PendingIntents in the tile and widget use `FLAG_IMMUTABLE`
(`TranslateTileService.kt:42-46`, `MozhiWidgetProvider.kt:93-98`). On a
locked device, the tile asks for unlock first (`unlockAndRun`,
`TranslateTileService.kt:31`).

Deep links: any app or web page can open
`mozhi://translate?text=…&from=…&to=…`
(`MainActivity.kt:326-338`; `lib/app/router.dart:194-203`). With a
non-AI engine, that text is translated and saved to history straight
away (`translate_cubit.dart:851-872,887-891`). The text belongs to the
attacker, so the privacy impact is low, but the history fills with
foreign entries. `mozhi://web?url=…` only fills in the address
(`router.dart:274-287`).

## 4. Storage

| Data | Class / key | Store | Encrypted | Leaves the device? | Retention |
| --- | --- | --- | --- | --- | --- |
| Settings (instances incl. URL user-info credentials, providers incl. **custom headers**, options, languages, recent pairs, extra targets) | `SettingsRepository`, `settings.v1` (`lib/settings/data/settings_repository.dart:27`); provider JSON incl. headers (`packages/translation_repository/lib/src/models/ai_provider_config.dart:189-204`) | `PreferencesStore` → `SharedPreferencesAsync` (Android: `files/datastore/`; web: `localStorage`) (`lib/core/key_value_store.dart:18-33`) | **no** | Device-to-device transfer: **yes** | until changed |
| API keys | `apikey.<providerId>` (`settings_repository.dart:30`) | `flutter_secure_storage` (`SecureStore`, `key_value_store.dart:36-51`); options at `lib/bootstrap.dart:135-145`. Web: `sessionStorage`. Falls back to memory when unavailable (`bootstrap.dart:147-151`; `lib/app/fallback_key_value_store.dart`). | yes (AndroidKeyStore-wrapped) | no (excluded from backup and transfer) | deleted with the provider (`settings_repository.dart:91-102`) |
| History and favourites | `HistoryRepository`, `history.v1` (`lib/history/data/history_repository.dart:80`), ≤ 1000 entries, ≤ 1 M chars, 20 k chars per text (`:69-78`) | preferences | **no: plain JSON** | transfer: **yes**; export to clipboard or share as JSON (`lib/settings/view/widgets/history_data_actions.dart:70-80`) | `HistoryRetention` forever/day/week/month, **default forever** (`lib/settings/models/app_settings.dart:10-21,60`); pruned on load/add and hourly (`lib/history/view/widgets/history_retention_listener.dart:26`); favourites always kept; `saveHistory` toggle (`app_settings.dart:54`) |
| Translation memory | `lib/history/data/translation_memory.dart`, searches history | memory | n/a | no | follows history |
| Presets, glossaries | `presets.v1` (`lib/presets/data/presets_repository.dart:21`), `glossaries.v1` (`lib/presets/data/glossary_repository.dart:21`) | preferences | no | transfer: yes | until deleted |
| Usage counters | `usage.v1` (`lib/usage/data/usage_tracker.dart:30`), 13 months | preferences | no | transfer: yes | 13 months |
| Speech settings | `speech.preferDevice`, `speech.settings` (`lib/speech/speech_service.dart:149,152`); `voice.preferOnDevice` (`lib/voice/speech_input_service.dart:76`) | preferences | no | transfer: yes | |
| Offline download setting | `offline.wifiOnly` (`lib/offline/cubit/offline_models_cubit.dart:24`) | preferences | no | | |
| Mozhi engine and language lists (metadata cache) | `translation_repository.metadata.v1.*` (`packages/translation_repository/lib/src/cache/persisted_metadata.dart:40`) | preferences (`lib/core/key_value_metadata_store.dart`) | no | transfer: yes (only instance URLs and lists) | `metadataMaxAge` |
| Translation cache | `TranslationCache`: 200 entries, 24 h TTL (`packages/translation_repository/lib/src/cache/translation_cache.dart:45-48`) | memory only | n/a | no | process lifetime |
| TTS audio cache | 20 clips (`speech_service.dart:142`) | memory only | n/a | no | process lifetime |
| Offline models | ML Kit model manager (`packages/mlkit_translator/lib/src/mlkit_offline_translator.dart:89-93`), ~30 MB per language | ML Kit's private app storage | no (not user data) | downloaded from Google; Wi-Fi only by default (`:89`) | until deleted in Offline settings |

Confirmed: **history is not encrypted**. Nothing on the device is
encrypted except the API keys. The only automatic deletion is the history
retention, which is off by default (forever).

## 5. Network call sites

Every request uses `package:http`. On Android that is dart:io
`HttpClient`, which:

- sends `User-Agent: Dart/3.13 (dart:io)` unless the code overrides it;
- sends no cookies (there is no cookie jar) and no `Referer`;
- ignores the system proxy and `network_security_config.xml`.

In the web build, the browser makes the requests: it adds `Origin` and
`Referer` (strict-origin-when-cross-origin, so the web app's origin) and
sends cookies only where CORS credentials allow.

| # | Call site | Host | Method / path | What is sent | User text in URL? | Headers / notes | Timeout |
| --- | --- | --- | --- | --- | --- | --- | --- |
| M1 | `MozhiApiClient.getEngines` (`packages/mozhi_api/lib/src/mozhi_api_client.dart:192-206`) | active Mozhi instance (failover) | GET `/api/engines` | nothing | no | Basic auth from URL user-info, same origin only (`:403-406`) | 30 s (`:57`) |
| M2 | `getSourceLanguages`/`getTargetLanguages` (`:208-214,338-347`) | same | GET `/api/{source,target}_languages?engine=` | engine id | no | | 30 s |
| M3 | `translate`/`translateWithEngines` → `_postTranslate` (`:216-252,349-377`), via `MozhiPool.run(failOverOnTimeout: false)` (`translation_repository.dart:795-825`) | instance, then the upstream engine (Google, DeepL, …) | **POST** `/api/translate`, form `engine, from, to, text` | text, languages | **no (body)** | POST redirects are followed manually (≤ 3, never https→http, `:47-52,459-470`). **Fails over across instances** (§6.2). | 30 s |
| M4 | `textToSpeech` (`:256-271`), via `TranslationRepository.textToSpeech` (`translation_repository.dart:1721-1748`) and `SpeechService._fetch` (`lib/speech/speech_service.dart:650-666`) | instance, then Google or Reverso TTS | **GET** `/api/tts?engine=&lang=&text=` | text (≤ 200 chars per chunk) | **YES** | Instance failover, then Google→Reverso fallback. The exception URI is stripped (`mozhi_api_exception.dart:29-44`; `mozhi_pool.dart:244-285`), but server logs are not. | 30 s |
| M5 | `translateImage` (`:275-303`), via `translation_repository.dart:1755-1823` | instance, then Google Lens | POST `/api/image`, multipart PNG | image (re-encoded, no EXIF: `lib/image_translate/data/image_encoder.dart`) | no | fails over (not after a timeout) | 30 s |
| M6 | `getVersion`/`ping` (`:306-316`), via `pingInstance` (`translation_repository.dart:1826-1827`) | each instance | GET `/api/version` | nothing | no | **Opening Settings > Mozhi instances pings every instance** (`lib/settings/view/instances_page.dart:63-69`). Also: onboarding "find fastest" (button, `lib/onboarding/cubit/onboarding_cubit.dart:88-102`, 6 s timeout at `:39`) and add/test instance (`lib/settings/view/widgets/add_instance_dialog.dart:141`). | 30 s / 6 s |
| L1 | `OpenAiCompatibleClient.streamChat` (`packages/llm_api/lib/src/providers/openai_compatible_client.dart:25-60`) | provider base URL (`api.openai.com`, OpenRouter, LAN servers, …) | POST `{base}/chat/completions` (SSE) | prompt with text, options (context, glossary, instructions), recent source languages for short text, preceding chunk text; images for vision | no, but any query string of the base URL is kept (`http_llm_client.dart:55-65`) | `Authorization: Bearer` (`:75-77`); custom headers (`http_llm_client.dart:93-95`). On a 400, retries once without `response_format`/`reasoning_effort` (same provider). **Redirects are never followed** (`:75-92`). | 120 s to headers and between chunks (`llm_client.dart:71`) |
| L2 | `listModels` (`openai_compatible_client.dart:65`, `anthropic_client.dart:127-129`, `gemini_client.dart:52-54`, `ollama_client.dart:81`), via `translation_repository.dart:1831-1835` | provider | GET `models`, `models?limit=1000`, `models?pageSize=1000`, `api/tags` | nothing | no | key header; only on **Browse models** or the onboarding test | 120 s / 90 s (onboarding test, `onboarding_cubit.dart:40`) |
| L3 | `AnthropicClient.streamChat` (`anthropic_client.dart:70-130`) | `api.anthropic.com` or a custom URL | POST `{base}/messages` (SSE) | as L1 | no | `x-api-key`, `anthropic-version`, **`anthropic-dangerous-direct-browser-access: true` on every platform** (`:151-156`). Beta `server-side-fallback-2026-07-01` for 4 models on api.anthropic.com (`:37-46`): Anthropic may answer with another Claude model (same provider). Retries on 400 (`:106-124`). | 120 s |
| L4 | `GeminiClient.streamChat` (`gemini_client.dart:33-45`) | `generativelanguage.googleapis.com` or custom | POST `models/{m}:streamGenerateContent?alt=sse` | as L1 | no | `x-goog-api-key` (header, not `?key=`) (`:77`) | 120 s |
| L5 | `OllamaClient.streamChat` (`ollama_client.dart:62-70`) | usually LAN | POST `api/chat` (NDJSON) | as L1 | no | optional `Authorization: Bearer` (`:92-95`) | 120 s |
| D1 | `DeeplClient.translate` (`packages/mt_api/lib/src/deepl/deepl_client.dart:71-130`) | `api-free.deepl.com` (`:fx` keys) / `api.deepl.com` / custom (`:38-55`) | POST `/v2/translate` (JSON, ≤ 50 texts per request) | texts, languages, formality, context, glossary id | no | `Authorization: DeepL-Auth-Key` (`:313-315`); no redirects (`mt_transport.dart:67-75`) | 30 s (`deepl_client.dart:26`) |
| D2 | `DeeplClient.languages`/`usage` (`:160-176`) | same | GET `/v2/languages?type=`, `/v2/usage` | nothing | no | | 30 s |
| D3 | `LibreTranslateClient.translate`/`translateBatch` (`packages/mt_api/lib/src/libre/libre_translate_client.dart:145-208`) | user's server (default suggestion `libretranslate.com`, `:42`) | POST `/translate` (JSON `q, source, target, format, alternatives, api_key`) (`:245-261`) | text, `api_key` in the **body** | no | | 30 s (`:27`) |
| D4 | `LibreTranslateClient.detect`, `languages`, `settings` (`:210-241`) | same | POST `/detect` `{q, api_key}`; GET `/languages`; GET `/frontend/settings` | text (detect) | no | | 30 s |
| W1 | `WebPageFetcher.fetch` (`lib/web_translate/data/web_page_fetcher.dart:164-258`) | any website the user enters | GET page URL | the URL, IP | the URL is the page's own | **Desktop Chrome User-Agent** (`:145-148,263`), `Accept-Language: en;q=0.8,*;q=0.5` (`:265`). Manual redirects (≤ 5); public→private redirects blocked (`:217-219`). 2 MiB cap. Never automatic from links (`lib/app/router.dart:172-177,274-287`). | 25 s (`:134`) |
| O1 | ML Kit model download (`mlkit_offline_translator.dart:89-93`) | Google | ML Kit internal | language code, device info (Google's SDK) | n/a | user action, Wi-Fi only by default; `translate` never downloads (`:29-31`) | n/a |
| O2 | ML Kit telemetry (data transport / Firelog) | Google (`firebaselogging*.googleapis.com`, per ML Kit terms) | SDK internal | API usage and performance metrics | n/a | **cannot be disabled from the app**; unverified here | n/a |
| O3 | System speech recognition (`speech_to_text`) | Google or OEM recogniser | OS | microphone audio | n/a | on-device only with **Prefer on-device**, **default off** (`speech_input_service.dart:91,277-278`) | |
| O4 | System TTS (`flutter_tts`) | OS engine (online voices possible) | OS | text | n/a | used when **Use device voice** is on, a device voice is chosen, or Mozhi fails | |
| O5 | `url_launcher` (`lib/settings/view/widgets/link_launcher.dart:12`) | browser | | | | user taps only | |

**Requests on startup**

- `TranslateCubit.loadEngines()` starts at once (`lib/app/view/app.dart:74`).
  It calls `getEngines` (`translation_repository.dart:250-268`), which
  serves the stored lists and **revalidates them in the background on
  every launch** (`:434-456`). That means GET `/api/engines`, then the
  source and target languages of the selected engine, on the active
  instance.
- This also happens on the very first launch, during onboarding, before
  the user has chosen anything. With the default instance list, that is
  `https://mozhi.aryak.me`.
- There are no font, CDN, favicon or update-check requests on Android. A
  scan of the hard-coded URLs in `lib/` finds only documentation links,
  provider default base URLs and `about_page.dart` source links.

**Web build only**

- CanvasKit is served from the build (`--no-web-resources-cdn`,
  `.github/workflows/main.yaml:320-323`, `release.yaml:156-159`).
- Fallback Noto fonts are loaded on demand from `fonts.gstatic.com`, which
  the CSP allows (`web/index.html:28`).
- No other third-party resources are loaded (`web/index.html`).

## 6. Privacy features: present and missing

| Feature | Status at `2c33476` | Evidence |
| --- | --- | --- |
| Incognito / don't-save mode | **missing** (`saveHistory` is a global toggle only). `bebecb6` adds an `incognito` field, unwired. | `app_settings.dart:54` |
| `FLAG_SECURE` | **missing** (no `FLAG_SECURE` anywhere). `bebecb6` adds a `secureScreen` field, unwired. | `MainActivity.kt` |
| Sensitive clipboard flag (`ClipDescription.EXTRA_IS_SENSITIVE`) | **missing**. Copies use `Clipboard.setData`, including the full history JSON. | `lib/translate/widgets/output_card.dart:41`; `history_data_actions.dart:75` |
| IME personalised learning off | **missing**: no `enableIMEPersonalizedLearning: false`. API key fields use `visiblePassword`, `autocorrect: false` and `enableSuggestions: false`. | `lib/settings/view/provider_editor_page.dart:721-724`; `lib/onboarding/widgets/provider_form.dart:104-107` |
| Clipboard read without a tap | **none.** Dart reads the clipboard only from paste buttons (`input_card.dart:205`, `proofread_input_card.dart:39`, `web_url_field.dart:26`, `import_text_dialog.dart:59`, `history_data_actions.dart:126`, `document_file_service.dart:129`) and from the "Translate clipboard" action (`lib/app/shared_text_handler.dart:32-37,138`). That action comes only from the tile, widget or shortcut through the non-exported alias, after the window gains focus. | `MainActivity.kt:172-178,211-222,254-259` |
| Delete all data | **missing.** Available: Clear history (`history_repository.dart:186`), Reset usage, deleting a provider and its key, deleting offline models. Nothing wipes settings, presets, glossaries, metadata and keys in one step. | |
| History retention / auto-delete | present, **default forever** | `app_settings.dart:10-21,60` |
| Proxy (HTTP, SOCKS, Tor) | **missing.** dart:io ignores the system proxy and there is no `findProxy`. `bebecb6` adds an `httpProxy` field, unwired. | grep: no `findProxy`/`HttpOverrides` |
| Cleartext policy | Allowed to **any** host (`AndroidManifest.xml:34`, NSC `:17`). Dart ignores the NSC anyway. Warnings appear only when an `http://` server outside the LAN is added (`lib/settings/view/widgets/insecure_http_warning.dart:7-12`; `add_instance_dialog.dart:148-154,226`; `provider_editor_page.dart:246,694`; `onboarding_cubit.dart:215`). There is no runtime guard, and existing `http://` public entries are not flagged. `MozhiApiClient.normalizeBaseUrl` infers `http://` for LAN, CGNAT, `.onion` and `.i2p` hosts (`mozhi_api_client.dart:130-188`). | |
| Cloud-AI consent | **missing.** No prompt before text first goes to a cloud provider or a public instance. `bebecb6` adds `consentedProviders` and a consent exception, unwired. | |
| Where-the-text-goes indicator | `PrivacyBadge`: Local / Self-hosted / Cloud. **Mislabels public Mozhi instances as Self-hosted.** No per-request host is shown. | `lib/translate/widgets/engine_selector.dart:350-380` |
| Telemetry, analytics, crash reporting | none in app code. Logs: bloc state *types* only, in debug (`lib/bootstrap.dart:22-54`); errors go to `dart:developer` `log`. ML Kit telemetry is the exception (O2). | |
| Text from other apps | Capped at 5000 characters (`translate_cubit.dart:130`). Never starts an AI request unless **Instant translate with AI** is on (`:887-891`), **except quick translate**, which always translates at once. | `quick_translate_cubit.dart:67-112` |
| Image metadata | stripped by re-encoding | `lib/image_translate/data/image_encoder.dart` |
| Web page fetch to the local network | public→private redirects blocked | `web_page_fetcher.dart:217-219,308-321` |

### 6.1 Silent failover and engine swaps

The repository does **not** fall back from offline or Mozhi to an AI
provider. `_translateUncached` dispatches on `engine.kind` with no
cross-kind fallback (`translation_repository.dart:751-764`). An offline
failure surfaces as `OfflineModelMissingException`/`ArgumentError`
(`repository/offline_engine.dart:67-120`). The silent paths are these:

| Path | What happens | Where |
| --- | --- | --- |
| Mozhi instance failover | The same text (translate, image, TTS, detection) is re-sent to the next of the 11 default operators on any retryable error: everything except 400/413/414/431 and Mozhi's input errors. Timeouts are excluded for content requests. | `mozhi_pool.dart:93-137,189-237`; `mozhi_api_exception.dart:13-27` |
| App-level engine substitution | Saved engine → current → `mozhi:google` → **`engines.first`** (can be a cloud AI). Applied on startup and on every engine-list reload, with no message. Quick translate then sends at once. | `translate_cubit.dart:696-750,314-446`; `quick_translate_cubit.dart:349-362,67-112`; `translation_repository.dart:262-267` |
| Detection for translation-only AI engines | On-device ID, then Mozhi `google` (a second back end), unless the engine is local | `translation_repository.dart:956-987,1704-1719` |
| TTS | Mozhi Google on every instance, then Mozhi **Reverso** (a different upstream third party), then the device engine | `translation_repository.dart:1721-1748`; `speech_service.dart:84-97` |
| AI extras on Mozhi or offline results | Sent to the "assist" AI engine: the configured one, else **the first AI provider** (`translate_cubit.dart:751-762`). The user asks for them, but once Insights or Alignment is opened, they reload for every later non-instant translation. | `lib/translate/widgets/output_card.dart:166-191` |
| Within one provider | Anthropic server-side model fallback (`anthropic_client.dart:37-46`); OpenAI-compatible retry without options (`openai_compatible_client.dart:44-50`); Anthropic retries on 400 | |

### 6.2 What the F-Droid variant removes

`tool/fdroid_prepare.sh`, run twice by CI (`main.yaml:212-216`):

1. Removes `google_mlkit_text_recognition` and the `mlkit_translator`
   path dependency from `pubspec.yaml` (`fdroid_prepare.sh:80-103`).
2. Copies `lib/platform/mlkit_bindings_stub.dart` over
   `mlkit_bindings.dart` (`:105-110`), giving `mlKitIncluded = false` and
   `UnavailableOfflineTranslator`.
3. Deletes `lib/image_translate/data/mlkit_text_recognition_service.dart`,
   its test, `test/platform/mlkit_bindings_test.dart` and
   `packages/mlkit_translator` (`:62-68,112-117`).
4. Deletes the `// BEGIN mlkit` Gradle block and sets `noMlkit=true`,
   which excludes the `com.google.mlkit` group (`:119-136`).
5. Checks with grep for leftovers (`:138-173`).

The CI job then checks four things (`main.yaml:218-276`):

- `pubspec.lock` has no `mlkit`;
- the dex files contain no `Lcom/google/mlkit/` bytes;
- the APK has no entries named mlkit, translate_jni, language_id or
  text_recognition;
- the Gradle classpath has no `com.google.mlkit`.

Only that last classpath check covers gms, datatransport, firebase and play, and those
findings are **warnings only**.

The variant does **not** remove image_picker's disabled GMS manifest
service, Material Components, Tink or the Flutter embedding's Play Core
references. None of these is a Play-services library.

Consequences of the F-Droid variant:

- no offline translation;
- no on-device language identification (so detection for MT-profile
  engines always goes to Mozhi, §6.1);
- no on-device OCR (image translation needs Mozhi Lens or AI vision).

`tool/check_no_google.sh` makes gms, Firebase and data transport classes
fatal at the dex level (§10).

## 7. Open pull requests

All three are from Dependabot and target `claude/magical-einstein-k02w13`.
Each touches only `uses:` lines with no new inputs.

| PR | Change | Our usage | Compatibility | Recommendation |
| --- | --- | --- | --- | --- |
| **#1** actions/checkout 4.4.0 → 7.0.1 (`3d3c42e`) | 7 `uses:` lines: `main.yaml:33,94,196,305,350`; `release.yaml:27,141` | No inputs. Events: `push`, `pull_request`, `workflow_dispatch` and tag pushes. | v5 moved to Node 24. v6 stores `persist-credentials` in a separate file (we never push). v7 blocks fork checkout only for `pull_request_target`/`workflow_run`, which we don't use. CI on the PR head passed all 5 jobs (16 Oct). Merge base is `2c33476`; the branch is 1 commit behind, and `bebecb6` doesn't touch workflows. | **Merge.** It also clears the "Node.js 20 is deprecated" annotation for checkout. |
| **#2** softprops/action-gh-release 2.6.2 → 3.0.3 (`efb3536`) | `release.yaml:206` | `name`, `generate_release_notes`, `prerelease`, `body`, `files`, `fail_on_unmatched_files` | The visible notes (3.0.1–3.0.3) cover maintenance, Node 24 and upload fixes; the 3.0.0 notes are truncated in the PR and couldn't be fetched from this session. The inputs we use are long-standing. The branch is **16 commits behind** (merge base `52fb449`; its CI still ran the removed Pages and Windows jobs). `release.yaml` runs only on tags, so PR CI never exercises it. | **Merge after `@dependabot rebase`.** Then cut a throw-away pre-release tag (for example `v0.1.0-rc.1`; `prerelease` is set for tags with `-`) to prove the publish job. Read the v3.0.0 notes for removed inputs first. |
| **#5** actions/download-artifact 4.3.0 → 8.0.2 (`9000827`) | `release.yaml:186` | `pattern: release-*`, `path: dist`, `merge-multiple: true`; the artifacts come from `upload-artifact@v4.6.2` | v5–v8 keep `pattern`, `path` and `merge-multiple` and read v4 artifacts (same backend). v8 fails on a digest mismatch (good) and skips unzipping content that isn't a zip (our uploads are zips). v8 is ESM, which is transparent to callers. The branch is 1 commit behind. Tag-only, so PR CI doesn't exercise it. | **Merge**, and validate with the same pre-release tag as #2. |

Follow-ups (not open as PRs; Dependabot's limit of 5 open PRs probably
holds them back): `actions/upload-artifact@v4.6.2` (Node 20 warning),
`actions/setup-java@v4.9.1` ("v4 is deprecated", per the CI annotations),
`actions/setup-node@v4.4.0`. This audit did not check whether
`subosito/flutter-action@v2.23.0` has a newer release.

## 8. Default branch

The default branch is `claude/magical-einstein-k02w13`, and **no branch is
protected** (GitHub API: `default_branch`, `branches[].protected = false`).
Recommendations (not done):

1. Create `main` from the current tip and make it the default branch.
   Dependabot PRs then target it. `.github/dependabot.yaml` has no
   `target-branch`.
2. Protect `main`: require PRs, require the status checks "Analyze and
   test", "Build Android APKs", "Build F-Droid variant (no ML Kit)",
   "Build web" and "Web end-to-end tests", block force pushes and
   deletion, and preferably require linear history and signed tags for
   `v*`.
3. Once `main` exists, `license_check.yaml` (which listens only to
   `main`, `license_check.yaml:7-19`) starts running. Add `MPL-2.0` to
   its allow-list, or exclude `dbus` (Linux only).
4. Keep `claude/*` branches as short-lived feature branches.

## 9. Plan assumptions: verified or corrected

| # | Assumption | Verdict | Evidence |
| --- | --- | --- | --- |
| 1 | Flutter 3.47 / Dart 3.13 | **VERIFIED.** Flutter 3.47.7, Dart 3.13.5 locally; CI pins 3.47.7 (`main.yaml:21`, `release.yaml:16`); `pubspec.yaml:6-8` has `sdk: ^3.13.0` and `flutter: ^3.47.0`. | |
| 2 | Flavors development/staging/production with ids `io.github.aimdi.mozhi[.stg\|.dev]` | **VERIFIED** | `android/app/build.gradle.kts:77-94`; entry points `lib/main_{development,staging,production}.dart` |
| 3 | Packages mozhi_api, llm_api, translation_repository, mt_api, mlkit_translator, mozhi_cli | **VERIFIED.** All six exist. The app depends directly on four; mt_api comes through translation_repository, and mozhi_cli is standalone. CLAUDE.md's layout section is stale: it doesn't list mt_api, mozhi_cli, or the `dictionary/`, `quick_translate/`, `usage/` and `web_translate/` features. | `pubspec.yaml:28-40`; `packages/*/pubspec.yaml` |
| 4 | Offline = ML Kit | **VERIFIED.** `MlKitOfflineTranslator` (translation and language ID) plus ML Kit OCR. The F-Droid build has no offline engine. (A `packages/bergamot_translator` started appearing in the working tree during this audit; it is not part of the baseline.) | `lib/platform/mlkit_bindings.dart:13-22`; `mlkit_bindings_stub.dart` |
| 5 | Mozhi `/api/translate` is GET with the text in the URL | **CORRECTED.** The app POSTs `application/x-www-form-urlencoded` (`mozhi_api_client.dart:28-33,349-377`). The text **is** in the URL for **`GET /api/tts`** (`:256-271`), which the default Listen path uses. | |
| 6 | LibreTranslate API shape | **VERIFIED.** POST `/translate` JSON `{q (string or list), source ('auto'), target, format, alternatives, api_key}`; POST `/detect`; GET `/languages`; GET `/frontend/settings`; errors as `{"error": …}` (400/403/429/500). | `libre_translate_client.dart:8-21,145-261` |
| 7 | Edge-to-edge (SystemChrome / SafeArea, deprecated `statusBarColor`?) | **VERIFIED: no deprecated calls.** No `SystemChrome`, `SystemUiOverlayStyle`, `statusBarColor` or `systemNavigationBarColor` in `lib/` or `android/`, and no `windowOptOutEdgeToEdgeEnforcement`. targetSdk 36 enforces edge-to-edge. `SafeArea` appears in 14 places (for example `app_shell.dart:107`, `onboarding_page.dart:109`, `proofread_page.dart:149`). **UNVERIFIABLE** here: whether every screen pads correctly on a device (no emulator). | grep over `lib/`, `android/` |
| 8 | Predictive back (PopScope vs WillPopScope; `PredictiveBackPageTransitionsBuilder` in theme?) | **VERIFIED, partly CORRECTED.** No `WillPopScope`. `PopScope` + `onPopInvokedWithResult` at `lib/onboarding/view/onboarding_page.dart:87-89` and `lib/quick_translate/view/quick_translate_sheet.dart:292-294`. The manifest opts in (`:33`). `lib/app/theme.dart` sets no `pageTransitionsTheme`, but **material_ui 1.6.0 already defaults Android to `PredictiveBackPageTransitionsBuilder`** (`material_ui-1.6.0/lib/src/page_transitions_theme.dart:780-787`), so nothing needs adding. Pin `material_ui >= 1.6` if this matters, since the constraint is `^1.1.1`. | |
| 9 | Per-app language (`localeConfig`) | **VERIFIED missing.** No `android:localeConfig`, `locales_config.xml` or `generateLocaleConfig`, although 19 ARB locales ship (`lib/l10n/arb/app_{ar,de,en,es,fr,hi,id,it,ja,ko,nl,pl,pt,ru,ta,tr,uk,vi,zh}.arb`). | |
| 10 | Material 3 Expressive not used | **VERIFIED.** `useMaterial3: true` (`lib/app/theme.dart:300`). No Expressive components or motion scheme; material_ui 1.6.0 has none (no `ButtonGroup`, `LoadingIndicator`, `FloatingToolbar` or `MotionScheme`). | |

## 10. `tool/check_no_google.sh`

```text
tool/check_no_google.sh [--defined-only] [--dex-only] [--max N] <app.apk|app.aab>
```

- **How it works.**
  - POSIX `sh` wrapper around `python3 -I`. It needs no Android SDK and
    no `unzip`.
  - It opens the APK or AAB as a zip and parses the header, `string_ids`,
    `type_ids` and `class_defs` of every `classes*.dex`
    (`base/dex/classes*.dex` in bundles; DEX 035–041, including 041
    containers).
  - It reports each type descriptor under `Lcom/google/mlkit/`,
    `Lcom/google/android/gms/`, `Lcom/google/firebase/` and
    `Lcom/google/android/datatransport/`, marked as *defined* or
    *referenced only*.
  - String constants such as `"com.google.android.gms"` are ignored,
    because they aren't type descriptors.
- **Exit status.**
  - `1` if any match is found (with `--defined-only`, references alone
    become warnings), or if zip entries look like ML Kit native libraries
    or models (same regex as CI; `--dex-only` skips this).
  - `2` for usage errors, a file that isn't a zip, or an archive with no
    dex.
  - Mentions of these packages in `AndroidManifest.xml` (for example
    image_picker's GMS `ModuleDependencies`) are warnings only.
  - Under GitHub Actions it also prints an `::error::` annotation.
- **Fallbacks.**
  - Without `python3`, it unzips the dex files and greps their bytes.
  - It does the same byte scan for a dex it can't parse.
- **Limitation.** R8 can rename classes that have no keep rule. ML Kit,
  Play services and Firebase keep the names their manifest entries, JNI
  and reflection need, so a contaminated build still shows many matches.
  Keep the Gradle classpath check too.
- **Tests.** `sh tool/check_no_google_test.sh` builds synthetic dex files
  and APKs with python3 and runs 22 cases (clean, ML Kit in
  `classes2.dex`, references only, `--defined-only`, Firebase and data
  transport, `--max`, manifest warning, native library, `--dex-only`,
  byte-scan fallback, AAB, DEX 041, error cases, the GitHub annotation,
  and the no-python3 fallback). All pass under dash and `bash --posix`.
  The script was also checked against real dex files assembled with smali
  2.5.2 (dex 035 and 039): defined, referenced-only and array types were
  reported correctly, and a string constant was not.
- **CI alignment (suggested, not applied).** In
  `.github/workflows/main.yaml:239-258`, the two grep checks could become
  `sh tool/check_no_google.sh "$apk" || failed=1`. That makes Play
  services, Firebase and data transport classes fatal at the dex level
  (today they are only Gradle-classpath warnings) and adds a class list to
  the log. Keep the Gradle step. Running
  `sh tool/check_no_google_test.sh` in "Analyze and test" would cover the
  script itself.

## 11. Smaller observations

- `instantTranslate` defaults to on for Mozhi engines, so text is sent
  while it is typed (debounced) to a public instance by default
  (`app_settings.dart:52`; `translate_cubit.dart:930-945`).
- Opening the history export copies the entire history as JSON to the
  clipboard, which clipboard managers and keyboards can read
  (`history_data_actions.dart:70-80`).
- Mozhi basic-auth credentials stay in the instance URL in the settings
  JSON (`mozhi_api_client.dart:62-69,111-129`). They are not moved to
  secure storage.
- `AiProviderConfig.isLocalHost` treats `.ts.net`, `.corp`, `.home`,
  `.private` and every dotless name as local
  (`ai_provider_config.dart:249-276`). This drives the "Local" badge, the
  insecure-http warnings and the reduced chunking.
- `docs/privacy.md` is mostly accurate. It does not mention the
  cross-operator failover for translations, the engine substitution, the
  detection-via-Mozhi path, the TTS text-in-URL, or that history moves
  with device-to-device transfer *unencrypted*.

## 12. CI notes

- `license_check.yaml` triggers only on `main`, so it never runs
  (`:7-19`). The licence allow-list excludes MPL-2.0 (`dbus`).
- The Node 20 deprecation annotations on every job come from
  `actions/checkout@v4.4.0`, `actions/setup-java@v4.9.1` and
  `actions/upload-artifact@v4.6.2` (run 38895165428). The "ubuntu-latest
  becomes Ubuntu 26 from 19 Oct 2026" notice applies too.
- The F-Droid Gradle dependency check depends on Flutter injecting
  `android/gradlew`, which is git-ignored (`android/.gitignore`). It does,
  during `flutter build apk`.
