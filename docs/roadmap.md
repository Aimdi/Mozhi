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
  AI, dictionary data only from AI (closed in waves 3 and 5; on-device AI
  is Android-only so far).
- **Reach:** no image or file share target, quick translate opens the full
  app, no camera overlay, no continuous transcription, no office
  documents or PDF, no way to translate other apps' screens or sound
  (closed in waves 1 to 3, 6 and 7).
- **Continuity:** no encrypted backup or sync, favorites aren't a
  phrasebook, no learning tools (all closed in wave 4).

## Done: waves 1 to 8

Wave 1 (trust, speed and transparency), wave 2 (feel like the best app),
wave 3 (offline everywhere), wave 4 (continuity and learning), wave 5
(offline AI), wave 6 (translate everything, anywhere), wave 7 (live and
in place) and wave 8 (works everywhere, the first time) are built; the [changelog](../CHANGELOG.md) lists what changed
(0.1.0-rc.3 for wave 5, 0.1.0-rc.4 for wave 6, 0.1.0-rc.5 for wave 7 and
0.1.0-rc.6 for wave 8).
Wave 3
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

Wave 5 brought every AI feature to the phone itself: llama.cpp in a new
`llama_engine` package, built three times for older and newer ARM
processors and picked at run time, runs Hy-MT2 1.8B for translation and
Gemma 4 E2B or Qwen3 1.7B for the extras, as an "On this device" AI
provider that works in Offline only with no consent and no network. The
models are downloaded only when asked (or imported, or received from
another phone), pinned to a commit and checked against checksums built
into the app; each one says whether it fits the phone's memory, and
translating as you type pauses on-device AI when the phone is hot or in
battery saver. Whisper got the same run-time CPU variants and three
quantized voice models.

Wave 6 made Mozhi translate the files people and translators work with
and anything on the screen: office documents and e-books (DOCX, PPTX,
XLSX, ODT, ODP, ODS, EPUB) keep their formatting and come back in the
same format; localisation files (XLIFF, PO, Android `strings.xml`, Apple
`.strings` and `.xcstrings`, CSV/TSV) and HTML pages round-trip with keys,
placeholders and markup intact; on Android a Quick Settings tile, a
shortcut and an optional bubble translate the screen from any app (one
screenshot with consent each time, recognised on the phone, deleted right
away); and an app lock uses the phone's biometrics or screen lock. It
also closed wave 5's gaps: free-space checks before every download,
hashing off the UI thread, imports without a second copy, pushed heat and
battery saver changes, a crash guard for the faster CPU builds, and long
on-device translations that wait while the phone is hot. A security
review of the new code led to linear-time CSV parsing, protection against
spreadsheet formulas in translated CSV cells, ZIP checks before anything
is unpacked, and a tighter app lock grace period.

Wave 7 made Mozhi translate what is in front of you as it happens, all on
the phone by default: a live camera that draws the translation over the
picture (Camera2, no camera library), PDF files read page by page and
written back as a translated PDF with real text (the framework's PDF
renderer and writer), translated captions of other apps' sound in a
floating bar (Android 10's playback capture with Whisper), a tap on any
word for a dictionary card from the offline packs, and the word being
read highlighted while Listen plays. Live features use the offline engine
unless the user picks another one for them, and an online engine asks
once. Conversation now picks the speaker from the spoken language and
ends a turn at a real pause; the web app keeps its own files for offline
use (an app-shell service worker) and imports language packs and
dictionaries from files; and wave 6's engineering leftovers are closed
(linear JSON search and streamed restore, the full-width CSV formula
guard, longer document placeholders, the "kept on this device" note for
photos and documents).

Wave 8 came from checking that Mozhi works for someone who just installed
it: CI now runs the APK on an Android emulator without Google services
and checks the public servers and every download. It showed a first run
that ended without a translation and a download button that only opened
a list. Now the default engine translates on the phone or asks before
going online, downloads happen in place, a server that fails is tried
last for a while, and errors say what to do. The web app is tested in
Firefox and WebKit, the store listings exist in all 18 languages, and
passphrases with accented letters match however they were typed.

Carried over to later waves:

- **Store presence:** fresh screenshots, an accurate store text in all
  listing languages, F-Droid per-ABI builds and changelogs.
- **Web app:** checks in Firefox, Safari and phone browsers (only
  Chromium was tested), the offline app shell and its update notice
  included; Transcribe and the screen wake lock in a real browser; the
  nginx example for serving it is untested (Caddy is).
- **Photos:** the overlay along tilted text lines (baselines, deskew),
  scene text (PP-OCR), and the overlay in the Play variant's ML Kit text
  recognition.
- **Voice:** long transcripts are cut at History's 20,000 characters;
  speaker detection and the pause that ends a turn work with the offline
  voice models only (the system recogniser still ends a turn after 3
  seconds).
- **Dictionaries:** WikDict translations and Tatoeba example sentences;
  resuming interrupted downloads; the first pack release (the workflow is
  ready: its sizes and the kaikki.org URL pattern are checked on the first
  run); glosses in the pack's own language for non-English packs.
- **Mirrors:** the manual download lists still show the publishers' links;
  `tool/check_model_downloads.py --mirror`; the nginx example in the docs is
  untested.
- **Privacy follow-ups:** the personal data shield can't apply to speech
  (documented); Tailscale `.ts.net` names count as private (no proxy),
  which also covers public Funnel addresses.
- **Engineering:** report the dart2js miscompile found in wave 3 (a
  nullable local assigned in `catch`, captured by a closure, read stale on
  the success path) to the Dart SDK; a connection given up during the TLS
  handshake through the proxy stays open until the server closes it;
  Documents' own placeholder tokens stop at six digits per paragraph;
  the JSON search in AI replies gives up (instead of slowing down) on
  replies that are mostly brackets; `DownloadOnlyModelDetails` is unused
  since the web imports.
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
- **Shared conversation:** the page is plain `http` (a phone has no
  certificate browsers trust), so others on the same Wi-Fi can read
  along; guests' devices are told apart by IP address, so someone who
  keeps changing addresses is held back only by the room-wide limits;
  a guest microphone needs a recogniser that doesn't send speech to the
  browser's maker.
- **On-device AI:** speed and memory measured on real phones (the speed
  table in docs/on-device-ai.md is from published figures); the 2-bit and
  1.25-bit Hy-MT2 files once llama.cpp ships Tencent's STQ kernel (440 MB
  instead of 1.1 GB); GPU and NPU backends (OpenCL on Adreno, Vulkan);
  on-device AI in the web app (llama.cpp as WebAssembly, models in the
  browser's private storage); images for the vision-capable models.
- **Voice:** measure the CPU variants and the quantized models on phones,
  and try q8_0 models.
- **Documents:** spreadsheet comments, chart data, alt text, sheet names and slide-master
  prompts are not translated yet; PO plural forms other than the singular
  all get the same text and Android plurals keep the source quantities;
  XLIFF `seg-source` segmentation is not mirrored in the targets; large
  files can pause the web app, which has no worker for parsing.
- **Translate screen:** try the capture timing, the bubble's snapping and
  remove target, and the detection of apps that block screenshots on real
  phones; the launcher shortcut is the fifth one, which Pixel launchers
  don't show; opt-in translation of incoming notifications with the
  offline engine only; the bubble may show over Mozhi itself when it is
  turned on from Mozhi (it learns which windows are on screen only after
  it starts, as the caption bar did before wave 7's fix).
- **App lock:** while the app is locked, screens opened before keep their
  data in memory (hidden, not encrypted); Android 11+ accepts the
  "weak" biometric class like the lock screen does; the live caption bar
  keeps showing captions while the app is locked (the transcript stays
  behind the lock).
- **Live camera:** try it on real phones: the preview's orientation in
  portrait and both landscapes, the preview under Impeller/Vulkan, zoom
  before and after Android 11, the torch, and the camera permission after
  "Don't ask again"; text along tilted lines.
- **PDF:** try the rendering colours, how translated text fits its box,
  selecting and searching the result and the memory of a 200-page file
  on real phones; PDFs with a text layer are still read with text
  recognition (Android 15's text extraction could read them directly and
  keep them sharp); the page backgrounds drop to about 40 dpi on 200-page
  files; text recognition does not pause when the phone is hot; PDF in the
  web app.
- **Live captions:** check on real phones that capture keeps going in the
  background on Android 14 and later with only the media projection
  service type, the caption bar's Open button on Android 15, the consent
  and permission order at the first start and the bar at 200% text; a
  Quick Settings tile for captions.
- **Tap a word:** words in the input can't be tapped yet; the highlight
  while Listen plays depends on the voice reporting its progress
  (browsers' word boundaries for Chinese, Japanese and Thai are rough).
- **Not done on purpose:** measuring instance speed automatically during
  setup (it contacts every listed volunteer server, so it stays a button:
  "Find the fastest server"); on-device AI as an automatic fallback (it
  would load a 1-3 GB model unasked); sending text translated on this
  device to a server or provider on its own (as a fallback, or for the
  automatic romanization).

## Later, or with owner sign-off

- **PDF translated in place** (the original text layer replaced, not
  drawn over a picture of the page) with pdfium (Apache-2.0), built from
  source.
- **Bundled neural text-to-speech for degoogled phones.** Piper and
  espeak-ng are GPL-3.0, so this needs a licence-clean voice stack. Until
  then, point users to SherpaTTS on F-Droid.
- **Handwriting input** with an open model.

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
