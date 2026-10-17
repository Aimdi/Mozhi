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
