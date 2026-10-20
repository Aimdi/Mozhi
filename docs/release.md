# Releasing

How a Mozhi release is cut, what the release workflow builds, and the
checks every release must pass before it's announced. Store work (listing
text, screenshots, the Play upload, the F-Droid recipe and anti-features)
is in [Store listings and releases](store/README.md). How to reproduce or
compare builds is in [Building](building.md).

- [Before the first release](#before-the-first-release)
- [What the release workflow does](#what-the-release-workflow-does)
- [Checklist](#checklist)
- [Signing](#signing)
- [Tracker scan (εxodus)](#tracker-scan-εxodus)
- [Dependency updates](#dependency-updates)

## Before the first release

Status as of 18 October 2026.

- [x] **Signing secrets.** The four secrets ([Signing](#signing)) are set
      (18 October 2026). A release tag (no `-`) now fails without them
      instead of publishing a debug-signed release, which a properly
      signed one could never update.
- [x] **Certificate fingerprint.** Published in the README section
      [Verify a release](../README.md#verify-a-release) and kept in
      `tool/release-certificate.sha256`, which `tool/check_signing.py`
      compares every signed APK and bundle with (CI and release).
- [x] **Default branch.** `main` is the default branch and is
      protected. Signed `v*` tags are also worth requiring. See
      [the audit, §8](audit/2026-audit.md#8-default-branch).
- [x] **GitHub Actions updates** (Dependabot PRs #1, #2, #5 and their
      successors #6 to #10): every action is on its Node 24 release since
      `e2a438a`, pinned by the commit of its release tag. `release.yaml`
      only runs on tags, so the new `action-gh-release` (v3) and
      `download-artifact` (v8) are first exercised by the
      [pre-release dry run](#checklist) (step 4).
- [x] **Gradle and Kotlin** (Dependabot #11): Gradle 9.5.1 and Kotlin
      2.4.21. Flutter warns that support for Gradle 9.0 ends soon. Gradle
      9.6 and later need the Android Gradle Plugin 9: AGP 8.12 uses a
      Gradle internal API that 9.6 removed (`InternalProblems`), so 9.8.1
      from #11 fails to apply the Android plugin.
- [ ] **Android Gradle Plugin 9** (Dependabot #12) is open: Flutter warns
      that support for AGP 8.12 ends soon, but AGP 9 is a migration
      (built-in Kotlin); `record` stays on 6.x until then (see
      `pubspec.yaml`).
- [x] **Dependency metadata block**: turned off in
      `android/app/build.gradle.kts` (`dependenciesInfo`).
- [ ] **A device test.** CI only builds; so far one release candidate
      (`v0.1.0-rc.1`) ran on a phone, where voice input, image translation
      and "Detect language" failed (fixed in #16). Install each release
      candidate on at least one arm64 and, ideally, one armeabi-v7a device.
      Check offline translation (download a language), both text-selection
      actions ("Translate with Mozhi" and "Translate offline"), text
      recognition in a photo (download one language's data) and offline
      voice input (download the Fast model, dictate a sentence). Then the
      Android integration:
      - long-press the app icon: the shortcuts Clipboard, Dictionary,
        Proofread and Conversation open the right screen, also while the
        app is already open;
      - with themed icons on (Android 13+), the icon is monochrome;
      - **Settings > Apps > Mozhi > Language** lists the app's languages
        and switches the app without restarting it;
      - status and navigation bar icons are dark in the light theme and
        light in the dark one, on the tabs and on full-screen pages, with
        gesture and three-button navigation;
      - a Mozhi instance or Ollama on the LAN over `http://` works, a
        public `http://` server is refused.

## What the release workflow does

`.github/workflows/release.yaml` runs on every pushed tag that starts with
`v`. Branch pushes only run CI (`main.yaml`).

| Job | Builds | Checks |
| --- | --- | --- |
| *Build Android APKs and app bundle* | the default (Google-free) build: one APK per ABI, a universal APK and the `.aab`, all obfuscated | `tool/check_no_google.sh` on every APK and the bundle; `tool/check_signing.py` (the release certificate; a release tag fails without the signing secrets); the universal APK has the three engines (`libmozhi_bergamot.so`, `libmozhi_tesseract.so`, `libmozhi_whisper.so`) for all three ABIs and no `libc++_shared.so`; `tool/check_page_size.py`: every 64-bit native library loads on 16 KB page phones ([Building](building.md#check-an-apk-for-16-kb-pages)); warns when the tag doesn't match the `pubspec.yaml` version |
| *Build web* | the static web build, zipped | |
| *Publish GitHub release* | `SHA256SUMS.txt` over every file | publishes the release; it's marked as a **pre-release** when the tag contains `-` |

Release files, for tag `<tag>`:

| File | What |
| --- | --- |
| `mozhi-<tag>-arm64-v8a.apk`, `-armeabi-v7a.apk`, `-x86_64.apk` | default build, one ABI each |
| `mozhi-<tag>-universal.apk` | default build, all ABIs |
| `mozhi-<tag>.aab` | app bundle for Google Play (not installable) |
| `mozhi-<tag>-web.zip` | web build for the root of a web server |
| `SHA256SUMS.txt` | SHA-256 of all of the above |

The Dart debug symbols of the obfuscated builds are kept as a private
workflow artifact (`debug-symbols-android-<tag>`, 90 days) for
`flutter symbolize`. They never reach the release. The release notes are
GitHub's generated notes plus a fixed description of the files.

## Checklist

1. **Version and changelog.**
   - Bump `version: <name>+<code>` in `pubspec.yaml`. Keep the code below
     1000, because split APKs add 1000, 2000 and 4000 to it.
   - Write `fastlane/metadata/android/en-US/changelogs/<code>.txt` (at
     most 500 characters) and the translated ones.
   - Copy them to `<code+1000>`, `<code+2000>` and `<code+4000>`
     ([store README, step 3](store/README.md#release-checklist)).
   - Validate: `python3 fastlane/validate_metadata.py --strict`.
2. **Dependencies.**
   - Run `python3 tool/list_dependencies.py --check`; run it with
     `--write` if it reports changes, and review the diff.
   - The default build must gain nothing proprietary: every new licence
     has to be in [the summary](dependencies.md#licence-summary).
3. **CI is green on the commit you tag.** That means every job of `ci`.
   *Build Android APKs* must pass `tool/check_no_google.sh`, and
   *Build Bergamot native (Android)* must build all three ABIs.
4. **Pre-release dry run.** Do this before the first release and after
   any change to `release.yaml` or its actions (#2 and #5 above):

   ```sh
   git tag v0.1.0-rc.1 && git push origin v0.1.0-rc.1
   ```

   - The release is published as a pre-release. "Check version" warns
     that `v0.1.0-rc.1` doesn't match `0.1.0`, which is expected.
   - F-Droid would ignore such tags: the
     [draft recipe](store/README.md#draft-fdroiddata-recipe) only matches
     `^v\d+\.\d+\.\d+$`.
   - Check the files ([step 6](#checklist)), then delete the pre-release
     and its tag: `gh release delete v0.1.0-rc.1 --cleanup-tag --yes`.
5. **Tag the release**: `git tag -s v0.1.0 -m "Mozhi 0.1.0" && git push
   origin v0.1.0` (`-a` instead of `-s` if you don't sign tags).
6. **Verify what was published.** Download every file of the release into
   an empty folder:

   ```sh
   sha256sum -c SHA256SUMS.txt
   for apk in mozhi-v0.1.0-*.apk; do
     apksigner verify --print-certs "$apk" | grep 'SHA-256'
   done
   keytool -printcert -jarfile mozhi-v0.1.0.aab | grep 'SHA256'
   ```

   - Every certificate SHA-256 must be the one in the README, and none may
     be `CN=Android Debug`.
   - Run `tool/check_no_google.sh` from a checkout on every default-build
     file:

     ```sh
     for f in mozhi-v0.1.0-arm64-v8a.apk mozhi-v0.1.0-armeabi-v7a.apk \
       mozhi-v0.1.0-x86_64.apk mozhi-v0.1.0-universal.apk mozhi-v0.1.0.aab; do
       sh tool/check_no_google.sh "$f" || echo "FAIL: $f"
     done
     ```

     All of them must pass.
   - The [εxodus scan](#tracker-scan-εxodus) of the universal default APK
     must report **0 trackers**.
   - Install the APK over the previous release on a phone and spot-check
     it ([store README, step 8](store/README.md#release-checklist)).
7. **Stores.**
   - **F-Droid** builds the new tag by itself once the app is in
     fdroiddata, and reads the listing and changelogs from
     `fastlane/metadata/android` at that tag.
   - **IzzyOnDroid** uses the APK attached to the GitHub release and the
     same metadata. Its inclusion hasn't been requested yet.
   - **Google Play** gets the `.aab`: see
     [Google Play](store/README.md#google-play).

## Signing

The workflows read four repository secrets (**Settings > Secrets and
variables > Actions**). Only their names belong in the repository. Never
paste a value into an issue, a log or a commit.

| Secret | Holds |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | the release keystore, base64-encoded |
| `ANDROID_KEYSTORE_PASSWORD` | the keystore password |
| `ANDROID_KEY_ALIAS` | the key alias |
| `ANDROID_KEY_PASSWORD` | the key password |

The same key signs the APKs and the bundle. Keep an
offline backup of the keystore and its passwords: losing them means users
must uninstall to update.

Before building, both workflows run `tool/check_keystore.py`: it fails in
seconds, naming the secret to fix, when the password doesn't open the
keystore, the alias names no key in it, or (for a PKCS12 keystore, which
has one password) the key password differs. Surrounding spaces and line
breaks in the secrets are ignored.

**The certificate fingerprint** identifies your builds. Read it from the
keystore or from a signed APK:

```sh
keytool -list -v -keystore release.jks -alias <alias> | grep 'SHA256:'
apksigner verify --print-certs mozhi-v0.1.0-universal.apk | grep 'SHA-256'
```

It's published in the README under
[Verify a release](../README.md#verify-a-release) and kept in
`tool/release-certificate.sha256` (lowercase hex without colons, the form
F-Droid's `AllowedAPKSigningKeys` and IzzyOnDroid want), which
`tool/check_signing.py` compares every signed build with. If the key ever
changes, update both.

## Tracker scan (εxodus)

[εxodus Privacy](https://reports.exodus-privacy.eu.org) looks for known
tracker signatures in an APK. The default build must show **0 trackers**.

CI does this on every build: `tool/check_trackers.py` matches every class
of each default APK against the code signatures in εxodus' public tracker
list (the release workflow too, and the step fails when one matches). It
only warns when the list can't be fetched; `tool/check_no_google.sh` is
the hard check for Google code.

For the official report, scan the APK locally with
[exodus-standalone](https://github.com/Exodus-Privacy/exodus-standalone)
(Docker):

```sh
docker run -v "$PWD":/app --rm -i exodusprivacy/exodus-standalone \
  /app/mozhi-v0.1.0-universal.apk
```

It prints a report and exits with the number of trackers it found, so 0
means none. Add `-j` for JSON. Once the app is on F-Droid, IzzyOnDroid or
Play, the public εxodus site can analyse it by its package name,
`io.github.aimdi.mozhi`. Link that report from the release notes.

## Dependency updates

`.github/dependabot.yaml` checks every week:

- GitHub Actions;
- pub: the app and every package under `packages/`;
- Gradle: `android/` and `packages/bergamot_translator/android/`.

Minor and patch updates come as one grouped pull request per ecosystem,
and each major update comes on its own. The offline engine's submodules
are updated by hand: after a bump, re-run `fetch_native_deps.sh` (the
patches must still apply) and the native CI job.

When reviewing:

- **Actions** are pinned by commit SHA with the version as a comment.
  Dependabot updates both. Updates to actions that only `release.yaml`
  uses need the pre-release dry run.
- **Gradle**: keep the Android Gradle Plugin the same in
  `android/settings.gradle.kts` and the engine's `build.gradle`. Keep
  Gradle, AGP and Kotlin within the range Flutter 3.47 supports
  (`flutter build apk` warns about versions it will soon drop). The NDK
  and CMake versions aren't Gradle dependencies: bump them by hand in
  both workflows and the engine's `build.gradle`.
- **pub**: run `python3 tool/list_dependencies.py --write` on the branch
  and check the licences.
