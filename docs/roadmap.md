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
  AI, dictionary data only from AI.
- **Reach:** no image or file share target, quick translate opens the full
  app, no camera overlay, no continuous transcription.
- **Continuity:** no encrypted backup or sync, favourites aren't a
  phrasebook, no learning tools.

## Wave 1: trust, speed and transparency

No new dependencies.

- **Translation QA:** placeholders, tags, URLs, numbers and glossary terms
  are checked after every translation and protected for machine-translation
  engines. AI engines regenerate once when the check fails.
- **Echo, garbage and prompt-injection detection,** with automatic fallback
  to an engine the privacy settings already allow, preferring on-device.
- **PII shield:** e-mail addresses, phone numbers, IBANs and card numbers
  are masked before any online request and restored afterwards.
- **Network activity:** a local, text-free log of every request this
  session, with destination, size and purpose.
- **Faster failover:** short connect timeouts and long keep-alive. Startup
  reads run in parallel. Secrets are written only when they change.
- **Web build:** localisations are loaded on demand, and the fallback fonts
  are self-hosted, so Google's font CDN no longer sees the user.
- **Offline engine:** requests can be cancelled, models preload, pieces are
  batched, debounce is shorter, alignment and confidence come from Bergamot,
  "Translate on this device" is offered when the network fails, and a
  memory budget unloads idle models.
- **AI robustness:** transient errors retry before any output arrives.
  Long texts keep finished parts, carry the previous translation and a
  term map, and get per-chunk retries. Glossary matching understands word
  boundaries and inflections. Ollama keeps its context size and warms up.
- **Machine-translation engines:** long input is split for them too. DeepL
  uses glossaries and the quality-optimised model. Short AI queries use
  on-device language detection first.
- **Android:** a share target for images and files, and quick translate in
  a translucent sheet over the calling app.

## Wave 2: feel like the best app

These items come from the UX review.

- **Instant feel:** no debounce on paste or Enter, an immediate shimmer,
  reserved row heights; the actions never jump.
- **Desktop:** a stable two-pane editor with a language picker above each
  pane.
- **Short queries:** 1–3 word queries show alternatives, definitions and
  synonyms inline.
- **Refine and engines:** refine chips sit in view under the result, with
  a visible "what changed" highlight. Fast/Best is the one engine control.
- **History and Settings:** compact two-line History rows with highlighted
  search matches; Settings in categories with search.
- **Accessibility:** web semantics on, with the translation readable by
  screen readers. A visible focus ring, controls with 3:1 outline contrast,
  labelled navigation, logical tab order, shortcuts that don't fight the
  browser.
- **Consistency:** one composer pattern on Translate, Dictionary and
  Proofread. Clearer error states with a one-tap alternative. Consistent
  wording.
- **First run:** onboarding fitted to the device (no "Offline first"
  recommendation where there is no offline engine), with the fastest public
  instance picked automatically.
- **Delight:**
  - a full-screen "Show" mode;
  - word highlighting while Listen plays;
  - tap a word for a mini dictionary;
  - an animated swap;
  - recent pairs on the empty screen;
  - an "offline ✓" mark in the picker;
  - a "Translate copied text?" chip on resume, never automatic.
- **Store presence:** fresh screenshots, an accurate store text in all
  listing languages, F-Droid per-ABI builds and changelogs.

## Wave 3: offline everywhere

- **Offline translation in the web app:** Bergamot WASM in a Web Worker,
  models stored in the browser (OPFS) and served from the same origin or a
  configured mirror, plus an app-shell service worker so a self-hosted
  Mozhi works with no network at all. No mainstream app offers this.
- **Model mirror setting:** for Bergamot, Whisper and Tesseract files,
  keeping the SHA-256 checks.
- **Photos:** OCR line and word boxes, with the translation drawn over the
  photo (Tesseract boxes first; PP-OCR later for scene text).
- **Voice:** a transcribe mode for lectures and tours (rolling transcript
  and translation, on-device Whisper with VAD), and Conversation picking the
  speaker from the spoken language.
- **Offline dictionary packs:** from Wiktionary (wiktextract, CC BY-SA) and
  WikDict, with real example sentences from Tatoeba, as downloads that also
  work on the web.

## Wave 4: continuity and learning

- **Encrypted backup** (Argon2id + AES-256-GCM, with no account), then
  end-to-end-encrypted sync to the user's own WebDAV/Nextcloud folder,
  then device-to-device pairing on the local network (QR code, X25519).
- **Phrasebook:** collections built from favourites, history and the
  dictionary; offline starter phrasebooks (Wikivoyage, CC BY-SA).
- **Practice:** spaced-repetition flashcards (FSRS), CSV/Anki export, and
  pronunciation practice with on-device Whisper.
- **Shared conversations without a server:** the host phone serves a
  LAN page that guests join by QR code.

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
