# Privacy plan: progress

## Phase 0: audit (done, 2026-10-17)

- Audited baseline `2c33476` (the plan's starting point) without changing
  any behaviour. Report: [2026-audit.md](2026-audit.md).
- Added `tool/check_no_google.sh`, a dex-level check that an APK or AAB
  has no classes from ML Kit, Play services, Firebase or data transport,
  and its test `tool/check_no_google_test.sh` (22 cases on synthetic
  APKs).
- Main findings for the next phases:
  - Translations fail over silently across 11 public Mozhi operators.
  - When the saved engine is unavailable, the app silently switches
    engine. The fallback can be a cloud AI, and quick translate then
    sends the text at once.
  - Detection for translation-only cloud AI engines sends the text to
    Mozhi as well.
  - Mozhi text-to-speech puts the text in the URL (`GET /api/tts`).
    Translation itself is a POST.
  - Image translation uploads the photo to Mozhi Lens as soon as it is
    picked.
  - Public instances are labelled "Self-hosted".
  - History is stored unencrypted and moves with device-to-device
    transfer.
  - Missing: incognito, `FLAG_SECURE`, opting out of keyboard learning,
    the sensitive-clipboard flag, a proxy setting, consent before
    sending, and "delete all data".
  - CI: `license_check` never runs because `main` doesn't exist. Merge
    Dependabot PRs #1, #2 and #5. Rebase #2 first (it is 16 commits
    behind), then test #2 and #5 with a pre-release tag.
- Not verified, because no Android SDK was available and Google Maven was
  blocked: ML Kit's transitive Play services, data transport and Firebase
  artifacts in the normal build. Check them with `tool/check_no_google.sh`
  on a release APK.

## Phase 1: privacy architecture (done, 2026-10-17)

Feature commits: `bebecb6`, `5c6981d`, `52f6a95`, `5fd09ef` and `f85055b`,
plus `f1e3d86` (translations) and `fd345ad` (e2e). The `wip:` commits
between `532f529` and `f25a707` hold parts of the same work; each feature
commit message describes the finished change.

- **Model** (`bebecb6`):
  - `DataDestination` (on device, self-hosted, public instance, cloud
    provider) and `PrivacyMode` (Offline only, Offline first, Online), in
    `packages/translation_repository/lib/src/models/data_destination.dart`;
  - `ConsentRequiredException`;
  - the settings for consents, approved language pairs, incognito, screen
    blocking and the HTTP proxy.

  New installs start in Offline first. Settings saved before privacy
  modes existed load as Online.
- **Routing**:
  - every request is checked against the privacy mode as its own
    destination: language detection, the AI model for extras, and Reverso
    after Google for speech;
  - a consent prompt (once, or always for a language pair) comes before
    anything is sent, and nothing moves to another back end by itself;
  - when the selected engine is gone, only the on-device engine may take
    its place;
  - a destination chip names who received the text (findings 2, 3 and
    4).
- **Storage** (`5c6981d`, `5fd09ef`):
  - the history is encrypted (AES-256-GCM, key in secure storage) and
    migrated from plaintext;
  - incognito, `FLAG_SECURE`, sensitive copies and **Delete all local
    data**;
  - backups and device transfers exclude all app data (finding 9);
  - per-app language through `localeConfig`.
- **Network** (`52f6a95`):
  - one HTTP client for every back end, with a generic User-Agent and no
    cookies or referrers;
  - an optional HTTP CONNECT proxy (Orbot);
  - plain `http` to public hosts is refused, and so are `.onion`/`.i2p`
    without a proxy;
  - **Listen** uses the device voice first, and Mozhi TTS (text in the
    URL) only with consent (finding 5).
- **Clean-up** (`f85055b`):
  - sensitive clipboard for every copy, and no keyboard learning in
    incognito (never for API keys and URLs);
  - provider headers and instance credentials move to secure storage
    (migrated);
  - the OpenRouter attribution headers are gone;
  - Android platform networking refuses cleartext, and the web build sends
    no referrer;
  - web page fetches go through the proxy too;
  - **Delete all local data** also clears in-memory copies and the offline
    models.
- `f1e3d86`: 166 new strings in all 18 translated locales.

## Phase 2: instances and LibreTranslate (done, 2026-10-17)

The code landed in `532f529` and `5dea866`; `52f6a95` is the feature
commit.

- A bundled snapshot of Mozhi's public instance list
  (`packages/mozhi_api/lib/src/mozhi_public_instance.dart`) with country,
  host, Cloudflare, Tor and I2P addresses. Nothing is fetched at run time.
- **Settings > Mozhi instances** no longer pings every instance on open
  (finding 8). Checks happen only on request (*Check instances*, *Test*),
  with latency badges and Cloudflare/Tor/I2P labels. Tor and I2P addresses
  are offered only with a proxy.
- Failover only reaches instances the privacy settings allow
  (`MozhiPool.run(allow: …)`), and the consent prompt says that the text
  may go on to the next servers in the list. Public instances are labelled
  *Public server*, not *Self-hosted* (finding 7).
- LibreTranslate and DeepL clients (`packages/mt_api`):
  - the key travels only in the request body;
  - blank text is never sent;
  - every request can be cancelled;
  - new request-level tests.

## Phase 3: Bergamot offline engine (done on CI, 2026-10-17)

- `aec30e7`: `packages/bergamot_translator`.
  - Mozilla's bergamot-translator from `mozilla/translations` (MPL-2.0),
    pinned as a submodule, behind a small C API, called over `dart:ffi` in
    a background isolate.
  - English pivoting, SHA-256-verified downloads with atomic installs,
    and a catalogue of 113 directions.
- `9c0cba1`: the app's offline engine in every build.
  - The default build has no Google code: Gradle excludes ML Kit, Play
    services, Firebase and data transport, and CI runs
    `tool/check_no_google.sh` on every APK and the AAB.
  - ML Kit OCR moves to the optional Play variant (`tool/play_prepare.sh`).
- CI fixes: `b9f9bde` and `f2e13fc` (faiss SSE intrinsics on Android
  x86_64), `483cfcb` (allow `libandroid.so`), `b88cb9d` (build every ABI
  even when one is clean), `c42e30a` (here-strings instead of
  `printf | grep -q` under `pipefail`).
- **CI run 39032433094** (commit `fd345ad`) was green on all six jobs:
  - *Build Bergamot native (Android)* built arm64-v8a, armeabi-v7a and
    x86_64 and passed the export, dependency and 16 KB alignment checks;
  - *Build Android APKs* passed `tool/check_no_google.sh` on every APK and
    found the engine for all three ABIs in the universal APK;
  - the Play variant, web and e2e jobs (24 tests) passed too.

- `6cff411`: CLD2 language identification in the engine (`detect` in the
  C API), so Detect language works offline; the native build is
  reproducible (`-ffile-prefix-map`, fixed build info).

## Phase 4: UI/UX (mostly done, 2026-10-17)

- `2a9c517`: a calm translate screen. Only the languages, the input and
  the translation show by default; **More** opens the other tools. The
  language picker marks detected and downloaded (offline) languages, and
  the consent prompt offers the offline download or **Translate on this
  device** when the engine supports the pair. **Switch instance** picks
  another Mozhi instance for one translation.
- `8b61507`: setup in three steps after the welcome (privacy mode, your
  languages with offline downloads, an optional online service). The AI
  step moved to **Settings > AI providers**. Settings are ordered Privacy,
  Offline languages, Online engines, AI providers (marked Advanced),
  Appearance, Read aloud, About. History has language-pair and destination
  filters.
- `4ddac64`, `27d794c`: "Always into French" on the consent button for a
  detected source, and the history header never cuts the language pair.
- Accessibility: widget tests at 200 % text on a 360 dp phone check
  onboarding, settings and the history filters for overflow, tap-target
  size, labels and (settings) text contrast.
- All 18 languages are complete; 60 unused strings were removed.

## Phase 6: release and build documentation (done, 2026-10-17)

- New pages:
  - [docs/release.md](../release.md): the release workflow, checklist,
    signing secrets by name, certificate fingerprint, pre-release dry run,
    εxodus scan and dependency updates;
  - [docs/building.md](../building.md): the pinned toolchain, sources,
    variants, the Google-code check, and comparing builds;
  - [docs/dependencies.md](../dependencies.md): every direct and native
    dependency with version, licence and purpose, generated by the new
    `tool/list_dependencies.py`.
- The README has a *Verify a release* section; the certificate
  fingerprint is a placeholder.
- `.github/dependabot.yaml`: weekly instead of daily. It now covers pub in
  every package and Gradle (`android/`,
  `packages/bergamot_translator/android/`), and groups minor and patch
  updates per ecosystem.
- Findings:
  - `CCACHE_BASEDIR` turns the engine's embedded `__FILE__` paths into
    relative ones (checked with ccache 4.9.1). Without it the library
    embeds absolute build paths, so reproducing a release needs the same
    ccache setting or `-ffile-prefix-map`.
    (Since `6cff411` the build passes `-ffile-prefix-map`.)
  - zlib (linked) and faiss (compiled) were missing from
    `native/THIRD_PARTY_NOTICES.md` (added since).
  - The APKs kept AGP's dependency metadata block (turned off in
    `4b3cd6c`).

## Open items

- **No real device yet.** Only CI builds exist. The engine ran on Linux
  x86_64 and under qemu (aarch64, armv7), never on a phone.
- **Not done**: Tesseract (on-device OCR for the default build) and offline
  voice input.
- **Phase 4 leftovers**: golden tests and foldable layouts.
- **Dependabot PRs #1, #2 and #5** are waiting for the owner's decision.
  #2 and #5 need a pre-release tag to be exercised
  ([release.md](../release.md#before-the-first-release)).
- **Default branch.** Create `main` from the current tip, make it the
  default and protect it. Until then `license_check.yaml` never runs, and
  Dependabot targets the `claude/*` branch.
- **Releases**:
  - the signing secrets and the published certificate fingerprint;
  - a byte-for-byte comparison of two builds;
  - an εxodus scan of a default APK. CI artifacts couldn't be downloaded
    from this session, so none of these was run.
