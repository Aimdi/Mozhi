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

## Done: waves 1 to 10

Wave 1 (trust, speed and transparency), wave 2 (feel like the best app),
wave 3 (offline everywhere), wave 4 (continuity and learning), wave 5
(offline AI), wave 6 (translate everything, anywhere), wave 7 (live and
in place), wave 8 (works everywhere, the first time), wave 9 (in your
control) and wave 10 (works every time) are built; the
[changelog](../CHANGELOG.md) lists what changed (0.1.0-rc.3 for wave 5,
0.1.0-rc.4 for wave 6, 0.1.0-rc.5 for wave 7, 0.1.0-rc.6 for wave 8,
0.1.0-rc.7 for wave 9 and 0.1.0-rc.8 for wave 10).
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

Wave 9 put the user in control of what the app does on their behalf:
language downloads can be cancelled and resume where they stopped; image
translation, read-aloud and detection fail over between servers and say
plainly when all of them failed; the app lock keeps the decrypted history
out of memory and the caption bar quiet while locked, and asks for strong
biometrics; documents keep their plural forms, sheet names, comments and
alt text; words typed in the input can be looked up; Android 15 reads a
PDF's own text layer; live captions have a Quick Settings tile, and
`mozhi://` links can no longer reach screens they don't name.

Wave 10 closed what made the app fail or surprise in daily use: every
download can be cancelled and every server failure retried; sync settles
retention, races, ties and provider ids the same way on every device;
pairing keeps the screen responsive and gets through floods; Tailscale
Funnel names are public again; and CI's emulator run now also translates
with Offline only (checking the app sent nothing), a photo, a text file,
and cancels a download.

Waves 11 to 17 closed most of the remaining roadmap, audit and hands-on
gaps: Terminal style as the default look, DeepL-style Proofread tones
and sentence rephrasing, "Improve with Mozhi" text-selection action,
offline dictionary packs for 20 languages (including non-English gloss
languages and exact `glossLanguage` metadata), Android foreground model
downloads, Whisper 8-bit (`q8_0`) voice models, FSRS weight optimization
(off the UI thread, with undo tombstones and per-weight timestamps),
pure-Dart in-app QR scanning and per-source fair rate-limiting for
pairing, Argon2id in a web worker (with buffer zeroing and timeout
fallback), per-setting sync timestamps and provider secret remapping,
opt-in offline notification translation (with App Lock guard, target
language and muted apps), pure-Dart web PDF translation (preserving
page visuals underneath translated boxes, CJK wrapping and Unicode TTF
embedding), four new document formats (YAML, TOML, Java `.properties`,
TMX) plus XLSX `docProps/app.xml` sync, threaded-comment `@mentions`,
chart text and PPTX slide master/layout placeholders, `WebLlamaEngine`
OPFS storage and `mmproj` download/verification, `mozhi_cli` v2
(`dictionary`, `document`, `repl`, saved glossaries, direct MT
providers), Translate Regenerate & `autoExtras`, legacy web charsets,
`tool/check_model_downloads.py --mirror`, and 100% localization across
all 19 languages.

Carried over to later waves (mostly real-device checks and optional features):

- **Store presence:** fresh screenshots, an accurate store text in all
  listing languages, F-Droid per-ABI builds and changelogs.
- **Web app:** checks in Firefox, Safari and phone browsers (only
  Chromium was tested), the offline app shell and its update notice
  included; Transcribe and the screen wake lock in a real browser; the
  nginx example for serving it is untested (Caddy is).
- **Photos:** scene text (PP-OCR).
- **Voice:** speaker detection in Conversation works with the offline
  voice models only; how fast the system recogniser's partial results
  arrive (the pause that ends a turn) needs a check on real phones;
  measure the CPU variants and quantized models on phones.
- **Dictionaries:** first release check of non-English gloss packs and
  WikDict/Tatoeba builds.
- **Mirrors:** the nginx example in the docs is untested.
- **Privacy follow-ups:** the personal data shield can't apply to speech
  (documented); the web app can't look Tailscale names up, so a `.ts.net`
  server on your tailnet counts as public there.
- **Engineering:** file the dart2js miscompile found in wave 3 (a
  nullable local assigned in `catch`, captured by a closure, read from a
  stale temporary after the `try`) with the Dart SDK: the reproduction is
  in `tool/repro/dart2js_catch_closure/`.
- **Backup and sync:** sync not yet tried against real Nextcloud,
  ownCloud, Synology and rclone servers.
- **Phone to phone:** check the LAN address choice on real Android 11+
  phones and hotspots, and the local-network permission of newer Android
  versions.
- **Shared conversation:** the page is plain `http` (a phone has no
  certificate browsers trust), so others on the same Wi-Fi can read
  along; a guest microphone needs a recogniser that doesn't send speech
  to the browser's maker.
- **On-device AI:** speed and memory measured on real phones (the speed
  table in docs/on-device-ai.md is from published figures); the 2-bit and
  1.25-bit Hy-MT2 files once llama.cpp ships Tencent's STQ kernel (440 MB
  instead of 1.1 GB); GPU and NPU backends (OpenCL on Adreno, Vulkan);
  end-to-end multimodal image inference through `llama.cpp` mtmd once
  wired to the downloaded `mmproj` files.
- **Documents:** plural forms beyond the singular (Russian `few` and
  `many`, Arabic `two`…) still merit human review when source has only
  two forms; a sheet named anywhere formulas can't be rewritten (pivot
  sources, `INDIRECT` text, form controls, macros) keeps its name and
  other files linking to a renamed sheet need updating; in the web app
  very large single-part structured files other than plain text,
  subtitles and `.properties` (which parse cooperatively in chunks) or
  multi-part office/e-book packages still parse in one go on the UI
  thread.
- **Translate screen:** try the capture timing, the bubble's snapping and
  remove target, and the detection of apps that block screenshots on real
  phones; check the launcher shortcuts' order on Pixel and Samsung
  launchers (Translate screen is fourth, after Translate clipboard, Camera
  and Conversation; Proofread, sixth, is left out on Android 7 to 9).
- **App lock:** try on real phones that Android 11+ asks for a strong
  fingerprint or face (a weak face unlock falls back to the PIN) and the
  caption bar's locked line; the translate screen and a conversation stay
  in memory while locked (hidden), the history does not.
- **Live camera:** try it on real phones: the preview's orientation in
  portrait and both landscapes, the preview under Impeller/Vulkan, zoom
  before and after Android 11, the torch, and the camera permission after
  "Don't ask again"; text along tilted lines.
- **PDF:** try the rendering colours, how translated text fits its box,
  selecting and searching the result and the memory of a 200-page file
  on real phones; check the text layer on Android 15 phones (the line
  boxes the framework's selection gives, multi-column and right-to-left
  files, fonts without a character map falling back to text recognition);
  before Android 15 PDFs with a text layer are still read with text
  recognition (`PdfRendererPreV`, from an SDK extension, might read them
  on some Android 12 to 14 phones); the page backgrounds drop to about
  40 dpi on 200-page files.
- **Live captions:** check on real phones that capture keeps going in the
  background on Android 14 and later with only the media projection
  service type, the caption bar's Open button on Android 15, the consent
  and permission order at the first start, the bar at 200% text, and
  the Quick Settings tile (its state, a tap on a locked phone, a cold
  start from it).
- **Tap a word:** words in the input are looked up with "Look up" in the
  field's selection menu, not with a tap (a tap places the cursor); in the
  web app the field shows its own menu instead of the browser's while it
  has the focus (no browser spelling suggestions there); the highlight
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
