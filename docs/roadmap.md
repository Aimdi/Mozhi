# Roadmap: the best translator that stays private

Mozhi should be the translator you'd pick even if privacy weren't a reason,
and the only sensible pick when it is. This page collects the October 2026
brainstorm (competitor research, on-device technology, a hands-on UX review
and a code audit) and turns it into an ordered plan. Shipped items move to
the [changelog](../CHANGELOG.md).

## Principles

1. **Private by construction.** Text goes only where the user sends it:
   on-device first, then the user's own servers, then a cloud provider they
   chose and confirmed. No account, no telemetry, no paywall, no Google code
   in the default build.
2. **Quality through choice.** Many engines, AI extras and comparison are
   Mozhi's strength. The app should help pick the best result, not make the
   user pick the engine.
3. **Instant and everywhere.** Results appear as fast as the engine allows,
   the layout holds still, and Mozhi is one tap away in any app.
4. **Trustworthy.** The app checks what engines return, says when a result
   is doubtful, and shows exactly what left the device.

## Where Mozhi stands

Mozhi already matches or beats every mainstream app on text-side AI
features: compare engines, refine chips, alternatives, word insights,
explain, meaning check and Kagi-style options. It also leads on privacy
controls: privacy modes, per-destination consent, Tor and proxy support,
incognito, encrypted history. The big apps meanwhile moved to LLMs and
speech (Gemini Live Translate, DeepL Voice and Clarify, Apple's on-device
Live Translation). Kagi Translate became an $8/month subscription with an
account. Privacy Guides users still lack a good mobile translator. The
gaps that matter:

- **Feel:** perceived latency, layout jumps on desktop, buried features,
  inconsistent patterns between tabs, sparse History and Settings.
- **Trust:** output is never checked; engines that return the input
  unchanged, drop placeholders or answer instead of translating are shown
  as if they were right.
- **Offline everywhere:** no offline engine in the web app, no on-device
  AI, dictionary data only from AI (the first and last closed in wave 3).
- **Reach:** no image or file share target, quick translate opens the full
  app, no camera overlay, no continuous transcription (all but a live
  camera overlay closed in waves 1 to 3).
- **Continuity:** no encrypted backup or sync, favorites aren't a
  phrasebook, no learning tools (all closed in wave 4).

## Done: waves 1 to 4

Wave 1 (trust, speed and transparency), wave 2 (feel like the best app),
wave 3 (offline everywhere) and wave 4 (continuity and learning) are
built; the
[changelog](../CHANGELOG.md) lists what changed (Unreleased). Wave 3
brought offline translation to the web app (Bergamot and CLD2 as
WebAssembly in a worker, models in the browser's private storage), a model
source setting with self-hosted mirrors, the translation drawn over photos,
speech detection with phrase-by-phrase voice input and a Transcribe screen,
Wiktionary dictionaries that work without AI or a network, and the privacy
follow-ups: the personal data shield for every AI extra, glossaries for
Mozhi and LibreTranslate (and saved glossaries that finally apply),
labelled online voices, and a proxy connection timeout that covers HTTPS.
A security review of the new code led to stricter redirects (a Mozhi
instance can't move your text to another server; downloads never follow a
redirect into your network or around your proxy), whole-word glossary
matching and better personal data detection.

Wave 4 brought continuity and learning without an account or a server:
an encrypted backup file (Argon2id and AES-256-GCM) that every feature
plugs its data into, with deletion records so merges don't bring deleted
entries back; end-to-end-encrypted sync through the user's own WebDAV
folder, merged per entry; phone-to-phone transfer of data and offline
models over the local network (QR code, X25519, a six-digit number on both
phones); a phrasebook of named collections with Wikivoyage starter
phrasebooks; FSRS flashcards with speaking practice on Whisper and Anki
export; and a shared conversation that guests follow in their own
language from their phone's browser. A security review of the new code
led to transfers that restore only what was offered, merges that never
add a translation server and keep API keys with their own server, limits
on what guests can make the host's engine do, and stricter limits on
backup files.

Carried over to later waves:

- **Delight:** word highlighting while Listen plays (it needs progress
  events from the read-aloud engines) and a mini dictionary when you tap a
  word in the translation.
- **Store presence:** fresh screenshots, an accurate store text in all
  listing languages, F-Droid per-ABI builds and changelogs.
- **Web app offline, the rest of it:** an app-shell service worker so a
  self-hosted web app opens with no network at all; **Import from files**
  for language packs and dictionaries in a browser; checks in Firefox,
  Safari and phone browsers (only Chromium was tested); Transcribe and the
  screen wake lock in a real browser.
- **Photos:** the overlay along tilted text lines (baselines, deskew),
  scene text (PP-OCR), and the overlay in the Play variant's ML Kit text
  recognition.
- **Voice:** Conversation picking the speaker from the spoken language and
  ending a turn at a real pause instead of after 3 seconds; long
  transcripts are cut at History's 20,000 characters.
- **Dictionaries:** WikDict translations and Tatoeba example sentences;
  resuming interrupted downloads; the first pack release (the workflow is
  ready: its sizes and the kaikki.org URL pattern are checked on the first
  run); glosses in the pack's own language for non-English packs.
- **Mirrors:** the manual download lists still show the publishers' links;
  `tool/check_model_downloads.py --mirror`; the nginx example in the docs is
  untested.
- **Privacy follow-ups:** the "kept on this device" note for photo and
  document translations; the personal data shield can't apply to speech
  (documented); Tailscale `.ts.net` names count as private (no proxy),
  which also covers public Funnel addresses.
- **Engineering:** report the dart2js miscompile found in wave 3 (a
  nullable local assigned in `catch`, captured by a closure, read stale on
  the success path) to the Dart SDK; a connection given up during the TLS
  handshake through the proxy stays open until the server closes it;
  Documents' own placeholder tokens are still limited to four digits.
- **Backup and sync:** Unicode normalisation of passphrases (a passphrase
  typed with another keyboard's composed characters doesn't match); the
  web app's Argon2id uses lighter settings (19 MiB, 2 passes) than
  Android's (64 MiB, 3); sync not yet tried against real Nextcloud,
  ownCloud, Synology and rclone servers; presets and glossaries saved
  before wave 4 have no change time, so two devices that already differ
  keep their own copy until one is edited; devices with different
  **Delete history automatically** settings keep re-uploading what the
  other drops; a sync merge racing a local edit is undone locally until
  the next sync.
- **Phone to phone:** check the LAN address choice on real Android 11+
  phones and hotspots, and the local-network permission of newer Android
  versions; an in-app QR scanner (the camera app opens the link today);
  encryption off the UI isolate; offline language packs are sent
  decompressed; a device flooding connections from many addresses can
  still delay pairing.
- **Phrasebook and practice:** the Wikivoyage parser was built on
  fixtures (check the first release run); **Add to phrasebook** for
  Transcribe segments; number words of more than one word ("twenty one")
  in speaking practice; FSRS weights fitted to the user's own reviews.
- **Settings merge:** a preset that names a deleted AI provider could pick
  up a merged provider with the same id.
- **Not done on purpose:** measuring instance speed automatically during
  setup. It contacts every listed volunteer server, so it stays a button
  ("Find the fastest server").

## Wave 5: offline AI

- **On-device AI:** an in-repo `llama_engine` package (llama.cpp, MIT)
  exposed as an on-device AI provider, so every AI feature (refine,
  alternatives, insights, dictionary, proofread, meaning check) works
  without a network.
  - Translation: Hy-MT2-1.8B (Apache-2.0, 33 languages).
  - General extras: Gemma 4 E2B/E4B (Apache-2.0).
  - Only on devices with enough memory, after the memory budget from
    Wave 1.
- **Faster CPU kernels:** dotprod and i8mm variants for ggml (also used by
  Whisper).

## Later, or with owner sign-off

- **Live camera viewfinder** with freeze-frame overlay. It needs the
  `camera` package or an in-repo CameraX plugin, plus the CAMERA permission.
- **PDF, DOCX, ODT, EPUB and PPTX documents.** ZIP and XML parsing or
  pdfium (Apache-2.0), probably new dependencies.
- **Tap-to-Translate bubble,** screen translate (MediaProjection or the
  Assist API) and opt-in translation of incoming notifications with the
  offline engine only.
- **Bundled neural text-to-speech for degoogled phones.** Piper and
  espeak-ng are GPL-3.0, so this needs a licence-clean voice stack. Until
  then, point users to SherpaTTS on F-Droid.
- **Handwriting input,** an app lock, and translating other apps'
  audio as live captions.

## What we won't do

- Google's on-device AI (Gemini Nano, ML Kit GenAI, LiteRT-LM): it is
  Google code and breaks the promise of the default build.
- Models with non-commercial or regional licences: NLLB-200, Tiny Aya,
  HY-MT1.5 (excludes the EU, UK and South Korea). Gemma-terms models such
  as TranslateGemma are opt-in downloads only.
- Phone-call translation (third-party Android apps can't get call audio)
  and voice cloning.
- Anything that sends text, metadata or analytics somewhere the user didn't
  choose.

## Guardrails for every change

- Default build: `tool/check_no_google.sh` must pass, and new native
  library and asset names must avoid `language_id` and `text_recognition`.
- Licences: code under MIT, BSD, Apache-2.0 or MPL-2.0; GPL code doesn't
  ship. Model licences are checked separately and shown in the app.
- Every new outgoing request appears in Network activity and respects the
  privacy mode and per-destination consent.
