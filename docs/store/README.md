# Store listings and releases

How Mozhi gets onto Google Play and F-Droid, and the checklist for every
release. The listing text and images live in
[`fastlane/metadata/android`](../../fastlane/metadata/android), the layout
that both `fastlane supply` (Google Play) and F-Droid read.

- [Listing files](#listing-files)
- [Release checklist](#release-checklist)
- [Google Play](#google-play)
- [Play data safety answers](#play-data-safety-answers)
- [F-Droid](#f-droid)

---

## Listing files

```
fastlane/metadata/android/
  en-US/                      default; the other locales fall back to it
    title.txt                 "Mozhi Translate" (max 30)
    short_description.txt     max 80
    full_description.txt      max 4000, plain text
    changelogs/<versionCode>.txt   max 500
    images/icon.png           512 x 512, from assets/branding/icon-512.png
    images/phoneScreenshots/  01-…08-*.png, from assets/screenshots
  de-DE/ fr-FR/ es-ES/ it-IT/ pt-BR/
    title.txt short_description.txt full_description.txt changelogs/
```

- Locale folders use Google Play's codes (`de-DE`, `pt-BR`, …). F-Droid
  accepts them too.
- The descriptions are plain text with `•` bullets and capitalised section
  headings, so they look the same in both stores. Terms follow the app's ARB
  files (`lib/l10n/arb`): for example *Nuancen* / *Nuances* / *Matices* for
  Insights, *Vorlagen* / *Préréglages* / *Preajustes* for Presets.
  *Translate with Mozhi* stays in English because the Android
  text-selection label (`android/app/src/main/res/values/strings.xml`) is not
  translated yet; update the listings if it gets translated.
- The store title is *Mozhi Translate* (better for search); the launcher
  label is *Mozhi*.
- Only 8 screenshots are listed because Play accepts at most 8 per device
  type. Order: AI translation, alignment, refine, compare engines, word
  insights, check meaning, proofread, dark mode.

**Validate** after every change:

```sh
python3 fastlane/validate_metadata.py           # lengths, files, images
python3 fastlane/validate_metadata.py --strict  # also fail on Play-only image rules
```

It counts characters the way the stores do (Unicode code points, trimmed)
and checks that a changelog exists for the `versionCode` in `pubspec.yaml`.

---

## Release checklist

1. **Bump the version** in `pubspec.yaml`: `version: <name>+<code>`, e.g.
   `0.2.0+2`. `versionCode` must go up on every release that reaches a store,
   and a code can never be reused (Play rejects it; F-Droid ignores it).
2. **Version codes of split APKs.** `flutter build apk --split-per-abi` adds
   `1000 × ABI` to the code: `armeabi-v7a` = N+1000, `arm64-v8a` = N+2000,
   `x86_64` = N+4000. App bundles and universal APKs use N. Because of the
   offsets, keep N below 1000.
3. **Changelog.** Write `fastlane/metadata/android/en-US/changelogs/<N>.txt`
   (max 500 characters) and translate it for each locale. Copy it to the
   split codes so F-Droid finds a changelog whichever APK it builds:

   ```sh
   N=2
   for d in fastlane/metadata/android/*/changelogs; do
     [ -f "$d/$N.txt" ] || continue
     for off in 1000 2000 4000; do cp "$d/$N.txt" "$d/$((N + off)).txt"; done
   done
   ```

4. **Listing.** If features changed, update `full_description.txt` in every
   locale (README.md and docs/features.md are the source of truth) and,
   if the UI changed, the screenshots in `assets/screenshots` and their
   copies in `images/phoneScreenshots/`.
5. **Validate**: `python3 fastlane/validate_metadata.py`.
6. **Signing secrets** (GitHub > Settings > Secrets and variables >
   Actions). Without them CI signs with a throwaway debug key, and such APKs
   can never update a properly signed install:

   | Secret | Value |
   | --- | --- |
   | `ANDROID_KEYSTORE_BASE64` | `base64 -w0 release.jks` |
   | `ANDROID_KEYSTORE_PASSWORD` | keystore password |
   | `ANDROID_KEY_ALIAS` | key alias |
   | `ANDROID_KEY_PASSWORD` | key password (falls back to the keystore password) |

   Keep an offline backup of the keystore and its passwords; losing it means
   users must uninstall to update. Locally, `android/key.properties` or the
   `ANDROID_KEYSTORE_PATH`/… environment variables do the same (see
   `android/app/build.gradle.kts`).
7. **Tag and push**: `git tag v0.2.0 && git push origin v0.2.0`.
   `.github/workflows/release.yaml` builds the split and universal APKs and
   the web build and publishes a GitHub release with `SHA256SUMS.txt`. The
   workflow warns if it fell back to the debug key.
8. **Check the release**: `apksigner verify --print-certs app-arm64-v8a-production-release.apk`
   shows your certificate (not `CN=Android Debug`), install it over the
   previous release, and spot-check translate, AI provider, offline and the
   selection menu.
9. **Stores**: upload to Play (below). F-Droid picks up the new tag by itself
   once the app is in fdroiddata (its `UpdateCheckMode: Tags`).

---

## Google Play

**Build an app bundle.** Play requires an AAB; CI currently builds APKs only:

```sh
flutter build appbundle --release --flavor production -t lib/main_production.dart
# build/app/outputs/bundle/productionRelease/app-production-release.aab
```

Use Play App Signing: the keystore above becomes the *upload* key, and Google
holds the app signing key. APKs from GitHub are then signed differently from
Play installs, so users can't switch between the two without uninstalling.
(Uploading your own key as the app signing key avoids that.)

**Upload the listing and bundle** with fastlane (there is no `Fastfile`;
`supply` works on its own). Create a service account with release access in
the Play Console and keep its JSON key out of the repository:

```sh
fastlane supply --package_name io.github.aimdi.mozhi \
  --json_key play-service-account.json \
  --metadata_path fastlane/metadata/android \
  --aab build/app/outputs/bundle/productionRelease/app-production-release.aab \
  --track internal
```

The first upload of a new app must be done by hand in the Play Console.

**Before the first Play upload (open items):**

- [ ] **Screenshots are taller than 2:1.** The 412 × 915 images (1 : 2.22) are
      fine for F-Droid, but Play rejects screenshots whose long side is more
      than twice the short side. Either capture new ones at 2:1 or less (e.g.
      1080 × 2160 or 1080 × 1920), or pad the copies to 458 × 915 with their
      edge colour:

      ```sh
      for f in fastlane/metadata/android/en-US/images/phoneScreenshots/*.png; do
        bg=$(convert "$f" -format '%[pixel:p{0,457}]' info:)
        convert "$f" -background "$bg" -gravity center -extent 458x915 "$f"
      done
      ```
- [ ] **Feature graphic** (`images/featureGraphic.png`, 1024 × 500, no
      alpha) is required by Play and doesn't exist yet. F-Droid shows it too.
- [ ] Optional: `sevenInchScreenshots/` and `tenInchScreenshots/` showing
      the side-by-side layout (≥ 840 dp).
- [ ] **Generative AI policy.** Play's AI-Generated Content policy asks apps
      that generate content with AI to let users report or flag offensive
      output from inside the app. The app has no such action. Check whether
      the policy applies to translation and proofreading with models the user
      connects; if it does, add a *Report* action (it could open an e-mail
      or issue form; nothing may be sent automatically).
- [ ] Privacy policy URL: `https://aimdi.github.io/Mozhi/#privacy` or the
      rendered `docs/privacy.md` on GitHub.
- [ ] Content rating questionnaire: a translation utility; no user-to-user
      interaction, no purchases. The web page translator can show arbitrary
      web content, and AI output is not filtered by the app.
- [ ] App access: everything works without an account. Reviewers need no
      credentials (public Mozhi instances are built in; AI features need the
      reviewer's own key, so say that AI features are optional).
- [ ] Permissions: `INTERNET` and `RECORD_AUDIO` (dictation, only when the
      microphone button is pressed). The camera is used through the system
      camera app (`IMAGE_CAPTURE` intent), so there is no `CAMERA`
      permission. `PROCESS_TEXT`, `SEND` and the Quick Settings tile need no
      declarations.
- [ ] Ads: no. Target audience: not designed for children (13+ or 18+ is
      the safer choice because of unfiltered AI output).

---

## Play data safety answers

Derived from [docs/privacy.md](../privacy.md). Google counts data as
*collected* when it leaves the device through the app, including through
third-party libraries, even if the developer never receives it. Re-check these
answers whenever privacy.md changes.

**What leaves the device**

| Data | Goes to | Who decides |
| --- | --- | --- |
| Text to translate or proofread, translation options, glossary terms | The Mozhi instance, AI provider, DeepL API or LibreTranslate server selected | User picks and configures the service; nothing goes to the developer |
| Images (image translation) | The selected AI model or Mozhi instance (Google Lens) | User, per image; on-device OCR keeps it local |
| Web page URLs | The website (download), then page text to the engine | User |
| Text for read-aloud | The Mozhi instance (Google/Reverso TTS), or the OS TTS engine | User |
| Dictation audio | The operating system's speech recogniser, not the app | OS |
| ML Kit diagnostics: device and app info, API configuration (e.g. configured languages), performance metrics | Google | Automatic whenever ML Kit runs (Android builds with ML Kit) |

**Recommended answers (builds that include ML Kit, i.e. GitHub and Play):**

- *Does your app collect or share any of the required user data types?*
  **Yes**: ML Kit's metrics, and the user's text and images sent to the
  service the user chose.
- *Is all of the user data collected by your app encrypted in transit?*
  **No.** Public instances and cloud providers use HTTPS, but the app
  deliberately allows plain `http` to self-hosted servers and local models on
  the user's network. Answering "Yes" would be wrong.
- *Do you provide a way for users to request that their data is deleted?*
  **No** (no account and no developer server; on-device data is deleted with
  *Clear history*, *Reset usage*, deleting a provider, or uninstalling).
  Third-party services follow their own policies.
- **Data types**

  | Play category | Collected | Shared | Ephemeral | Required | Purpose |
  | --- | --- | --- | --- | --- | --- |
  | App activity > Other user-generated content (text to translate or proofread) | Yes | No ¹ | No ² | Optional ³ | App functionality |
  | Photos and videos > Photos (image translation) | Yes | No ¹ | No ² | Optional | App functionality |
  | App info and performance > Diagnostics (ML Kit) | Yes | No | No | Required ⁴ | Analytics |
  | Device or other IDs (ML Kit) | Check ⁵ | No | No | Required | Analytics |

  ¹ Play does not count a transfer as *sharing* when the user initiates it
  and expects the data to go to that service (the user adds and selects the
  instance or provider).
  ² The app can't promise how a third-party server keeps the data.
  ³ Users can stay on device (offline, local models, own server).
  ⁴ ML Kit can't be turned off while it is in the build; it runs only when
  the user uses offline translation or on-device text recognition, but Play
  asks about the app as shipped.
  ⁵ Copy ML Kit's own answers from Google's
  [ML Kit data disclosure](https://developers.google.com/ml-kit/android-data-disclosure)
  for exactly the ML Kit artifacts in the build (`translate`,
  `language-id`, `text-recognition` and the Chinese, Devanagari, Japanese
  and Korean models). That page says the SDKs collect device information,
  app information and performance metrics for diagnostics and usage
  analytics, encrypted in transit and not shared; at the time of writing the
  Translate row lists the configured source and target languages.
- Not collected: location, personal info, financial info, contacts,
  messages, audio (dictation goes to the OS recogniser), files and docs
  (document translation sends only the extracted text, counted above),
  calendar, health, web browsing history (URLs go only to the website the
  user opens), API keys (stored in secure storage and sent only to their
  provider as credentials).

A build **without ML Kit** (see F-Droid below) drops the two ML Kit rows.

Two points are judgement calls. Some developers of clients for user-chosen
servers answer "no data collected", arguing that the developer never receives
anything. The conservative answers above match Google's "leaves the device"
definition and avoid a policy strike; whichever you pick, keep privacy.md
and the listing consistent.

---

## F-Droid

F-Droid builds every app from source with only free software and reads the
same `fastlane/metadata/android` folder from the release tag. The listing,
icon, screenshots (the 2:1 limit doesn't apply) and changelogs are ready.
The **build is not**, because of Google ML Kit.

### Blockers

1. **Google ML Kit is proprietary.** `google_mlkit_translation`,
   `google_mlkit_language_id` (in `packages/mlkit_translator`) and
   `google_mlkit_text_recognition` (app) pull closed-source Google
   artifacts from Google's Maven repository: `com.google.mlkit:translate`,
   `language-id`, `text-recognition`, the four script models added in
   `android/app/build.gradle.kts`, and through them parts of Google Play
   services (`play-services-basement`, `play-services-tasks`) and Google's
   data transport used to upload ML Kit's metrics. F-Droid doesn't accept
   non-free libraries at all, so this is not something an anti-feature can
   cover: the F-Droid build must not contain ML Kit. (NonFreeDep is not the
   right label: it means *depends on another non-free app being installed*,
   while ML Kit is bundled in the APK.)

   **Suggested fix: a build without ML Kit.** A Gradle product flavor alone
   is not enough: Flutter registers every plugin in `pubspec.yaml`, whatever
   the flavor. What works for Flutter apps on F-Droid:

   - Keep every ML Kit import in one place on the Dart side (today:
     `lib/bootstrap.dart`, `lib/offline/view/offline_models_page.dart`,
     `lib/image_translate/data/text_recognition_service.dart`), behind small
     interfaces (`OfflineTranslator` already exists in
     translation_repository; add one for text recognition), with a stub
     implementation in a sibling file that reports "not available".
   - Hide **Offline languages** and **On-device text recognition** when the
     stub is in use (the image screen already handles *No image
     translation method available*).
   - Guard the four `com.google.mlkit:text-recognition-*` lines in
     `android/app/build.gradle.kts` behind a Gradle property, e.g.
     `if (!project.hasProperty("noMlkit"))`.
   - Add a script (e.g. `tool/fdroid_prepare.sh`) that the F-Droid recipe
     runs as `prebuild`: remove `google_mlkit_text_recognition` and
     `mlkit_translator` from `pubspec.yaml`, swap in the stub files, and
     build with `--android-project-arg=noMlkit=true` (Flutter passes it to Gradle as `-PnoMlkit=true`). Run it in CI too so the ML Kit-free build keeps
     compiling.
   - Optionally publish that build as a separate GitHub asset
     (`mozhi-…-foss.apk`) for people who don't want Google libraries.

   These changes are in `lib/`, `packages/`, `android/` and `pubspec.yaml`,
   outside this folder.

2. **Flutter's Play Core references.** Flutter's Android embedding contains
   `PlayStoreDeferredComponentManager`, which refers to
   `com.google.android.play.core`. The app doesn't use deferred
   components and doesn't depend on Play Core, but F-Droid's scanner has
   flagged such references in some Flutter apps. Run `fdroid scanner` on
   the APK built by the recipe; if it complains, the usual fix is
   `-dontwarn com.google.android.play.core.**` in `proguard-rules.pro` plus
   making sure no Play Core artifact ends up in the dependency tree
   (`./gradlew :app:dependencies`).

3. **Signatures.** F-Droid signs with its own key unless the build is
   reproducible and the recipe pins your certificate (`AllowedAPKSigningKeys`
   and `Binaries:`). With the same application ID (`io.github.aimdi.mozhi`),
   F-Droid, GitHub and Play installs can't update each other. Reproducible
   Flutter builds are possible but take work (pinned Flutter version, same
   build paths); decide before submitting.

Not blockers: Flutter itself (F-Droid builds it from its `flutter` srclib),
`flutter_secure_storage` (Tink, Apache 2.0), `dynamic_color` (Material
Components, Apache 2.0), `speech_to_text` and `flutter_tts` (they use the
system's recognition and TTS services; on devices without them the app falls
back or says so).

### Anti-features to declare

| Anti-feature | Declare? | Why |
| --- | --- | --- |
| **NonFreeNet** | **Yes** | The built-in public Mozhi instances relay to Google, DeepL, Reverso, Yandex, Bing and MyMemory; image translation through Mozhi uses Google Lens; read-aloud through Mozhi uses Google/Reverso; the AI presets (OpenAI, Anthropic, Gemini, …) and the DeepL API are non-free services. Free alternatives exist (self-hosted Mozhi with LibreTranslate, local models), but the defaults promote non-free services. |
| **UpstreamNonFree** | **Yes** | The upstream builds (GitHub releases, Play) contain ML Kit; only the F-Droid build is free. |
| Tracking | No, for the F-Droid build | Without ML Kit nothing reports usage. (Upstream builds with ML Kit would qualify.) |
| NonFreeDep | No | The app doesn't require any non-free app to be installed. |
| NonFreeAdd, Ads, TetheredNet, KnownVuln, NSFW, NoSourceSince, NonFreeAssets | No | No ads or add-ons, no service run by the developer, source and assets under MIT. |

### Draft fdroiddata recipe

For `metadata/io.github.aimdi.mozhi.yml` in
[fdroiddata](https://gitlab.com/fdroid/fdroiddata), once the ML Kit-free
build exists. The script name, Flutter version and commit are placeholders;
F-Droid's reviewers will adjust the details.

```yaml
Categories:
  - Translation & Dictionary   # F-Droid's category name may differ; check fdroiddata
License: MIT
AuthorName: Aimdi
SourceCode: https://github.com/Aimdi/Mozhi
IssueTracker: https://github.com/Aimdi/Mozhi/issues
Changelog: https://github.com/Aimdi/Mozhi/releases

AntiFeatures:
  NonFreeNet:
    en-US: Translates through Google, DeepL and other services via Mozhi instances, and through cloud AI providers you add.
  UpstreamNonFree:
    en-US: Upstream builds include Google ML Kit for offline translation; this build does not.

RepoType: git
Repo: https://github.com/Aimdi/Mozhi.git

Builds:
  - versionName: 0.1.0
    versionCode: 2001          # arm64-v8a; add entries for 1001 / 4001
    commit: v0.1.0
    output: build/app/outputs/flutter-apk/app-arm64-v8a-production-release.apk
    srclibs:
      - flutter@3.47.0         # match the version CI uses
    prebuild:
      - tool/fdroid_prepare.sh # strips ML Kit (to be written)
      - $$flutter$$/bin/flutter config --no-analytics
      - $$flutter$$/bin/flutter pub get
    build:
      - $$flutter$$/bin/flutter build apk --release --flavor production
        -t lib/main_production.dart --split-per-abi
        --target-platform android-arm64 --android-project-arg=noMlkit=true

AutoUpdateMode: Version
UpdateCheckMode: Tags ^v\d+\.\d+\.\d+$
UpdateCheckData: pubspec.yaml|version:\s.+\+(\d+)|.|version:\s(.+)\+
CurrentVersion: 0.1.0
CurrentVersionCode: 2001
```

F-Droid reads the changelog for the version code it builds, which is why
the release checklist copies `<N>.txt` to N+1000, N+2000 and N+4000.
