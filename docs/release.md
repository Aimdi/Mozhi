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

Open items as of 17 October 2026. No tag or GitHub release exists yet.

- [ ] **Signing secrets.** Add the four secrets ([Signing](#signing)).
      Without them every APK and the bundle are signed with a throwaway
      debug key, and such a release can never be updated by a properly
      signed one. Don't publish a debug-signed release.
- [ ] **Certificate fingerprint.** Publish the signing certificate's
      SHA-256 in the README section
      [Verify a release](../README.md#verify-a-release). It's a
      placeholder until the secrets exist.
- [ ] **Default branch.** The default branch is still
      `claude/magical-einstein-k02w13`, and no branch is protected. Create
      `main`, make it the default and protect it (require the CI checks,
      block force pushes). Signed `v*` tags are also worth requiring. See
      [the audit, §8](audit/2026-audit.md#8-default-branch).
      `license_check.yaml` only runs on `main`, and Dependabot opens its
      pull requests against the default branch.
- [ ] **Dependabot PRs #1, #2 and #5** need the owner's decision. Nothing
      has been merged:

  | PR | Change | Audit recommendation |
  | --- | --- | --- |
  | #1 | `actions/checkout` 4.4.0 → 7.0.1 | Merge |
  | #2 | `softprops/action-gh-release` 2.6.2 → 3.0.3 | Rebase it first (`@dependabot rebase`) and read the v3.0.0 notes, then merge |
  | #5 | `actions/download-artifact` 4.3.0 → 8.0.2 | Merge |

  `release.yaml` only runs on tags, so pull request CI never exercises #2
  and #5. Prove them with a [pre-release dry run](#checklist) (step 4)
  after merging. Details:
  [the audit, §7](audit/2026-audit.md#7-open-pull-requests).
- [ ] **Dependency metadata block.** The Android Gradle Plugin by default
      puts an encrypted dependency list, readable only by Google Play, into
      the signing block of every APK. `android/app/build.gradle.kts`
      doesn't turn it off. F-Droid and IzzyOnDroid ask for it to be
      removed:

  ```kotlin
  android {
      dependenciesInfo {
          includeInApk = false     // GitHub, F-Droid, IzzyOnDroid APKs
          includeInBundle = false  // optional: Play reads it from the bundle
      }
  }
  ```

- [ ] **A device test.** No build has run on a real phone yet (CI only
      builds). Install a release candidate on at least one arm64 and,
      ideally, one armeabi-v7a device. Check offline translation (download
      a language), the text-selection menu and image translation.

## What the release workflow does

`.github/workflows/release.yaml` runs on every pushed tag that starts with
`v`. Branch pushes only run CI (`main.yaml`).

| Job | Builds | Checks |
| --- | --- | --- |
| *Build Android APKs and app bundle* | the default (Google-free) build: one APK per ABI, a universal APK and the `.aab`, all obfuscated | `tool/check_no_google.sh` on every APK and the bundle; the universal APK has `libmozhi_bergamot.so` for all three ABIs and no `libc++_shared.so`; warns when the tag doesn't match the `pubspec.yaml` version |
| *Build Play variant APK (ML Kit)* | `tool/play_prepare.sh`, then a universal APK | none for Google code (it contains ML Kit by design) |
| *Build web* | the static web build, zipped | |
| *Publish GitHub release* | `SHA256SUMS.txt` over every file | publishes the release; it's marked as a **pre-release** when the tag contains `-` |

Release files, for tag `<tag>`:

| File | What |
| --- | --- |
| `mozhi-<tag>-arm64-v8a.apk`, `-armeabi-v7a.apk`, `-x86_64.apk` | default build, one ABI each |
| `mozhi-<tag>-universal.apk` | default build, all ABIs |
| `mozhi-<tag>-play-universal.apk` | Play variant (ML Kit text recognition) |
| `mozhi-<tag>.aab` | app bundle for Google Play (not installable) |
| `mozhi-<tag>-web.zip` | web build for the root of a web server |
| `SHA256SUMS.txt` | SHA-256 of all of the above |

The Dart debug symbols of the obfuscated builds are kept as private
workflow artifacts (`debug-symbols-android-<tag>` and
`debug-symbols-android-play-<tag>`, 90 days) for `flutter symbolize`. They
never reach the release. The release notes are GitHub's generated notes
plus a fixed description of the files.

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

     All of them must pass. `mozhi-v0.1.0-play-universal.apk` must
     *fail*: that confirms it is the ML Kit build its name says it is.
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

The same key signs the APKs, the Play variant and the bundle. Keep an
offline backup of the keystore and its passwords: losing them means users
must uninstall to update.

**The certificate fingerprint** identifies your builds. Read it from the
keystore or from a signed APK:

```sh
keytool -list -v -keystore release.jks -alias <alias> | grep 'SHA256:'
apksigner verify --print-certs mozhi-v0.1.0-universal.apk | grep 'SHA-256'
```

Publish it in the README under
[Verify a release](../README.md#verify-a-release). F-Droid
(`AllowedAPKSigningKeys`, for reproducible builds) and IzzyOnDroid want
the same value in lowercase hex without colons.

## Tracker scan (εxodus)

[εxodus Privacy](https://reports.exodus-privacy.eu.org) looks for known
tracker signatures in an APK. The default build must show **0 trackers**.

Before publishing, scan the APK locally with
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

Also scan the Play variant and note the result in the release notes.
ML Kit is closed source and sends diagnostics to Google, whether or not
εxodus lists it as a tracker.

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
