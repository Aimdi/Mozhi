# Changelog

All notable changes to Mozhi, by release tag on GitHub (pre-releases end
in `-rc.N`).

## Unreleased

### Added

- **Translation checks.** Every translation is checked on the device:
  placeholders, tags, links, e-mail addresses, numbers and glossary terms
  that went missing are flagged under the result, and AI engines get one
  corrected attempt. Machine-translation engines (Mozhi, DeepL,
  LibreTranslate) no longer see placeholders and markup at all; they are
  protected and put back.
- **Automatic fallback.** When an engine returns the original text, the
  wrong language, a garbled result or a chat-style reply instead of a
  translation, Mozhi tries another engine you already allowed, on this
  device first, and says so. Paid AI providers are never tried on their
  own.
- **Hide personal data from online engines** (on by default, Settings ›
  Privacy). E-mail addresses, phone numbers, IBANs, card numbers and IP
  addresses are replaced before text leaves the device and put back into
  the translation; the result says how many items stayed on the device.
- **Network activity** (Settings › Privacy). A log of every request this
  session: where it went, why, how much was sent and received, and whether
  it went through your proxy. It never records text, and it is never
  saved.
- **Share images and files with Mozhi** on Android. Images open on the
  image screen (read on the device first), and subtitles, text and JSON
  files open in Documents. Neither starts an AI request by itself. The web
  app accepts shared text.
- **Translate on this device** is offered when the network fails and the
  language pair can be translated offline.
- **Offline alignment.** Tap-to-highlight works with the on-device engine:
  free, instant and without a network.
- **DeepL:** glossaries now apply to the DeepL API, and an option prefers
  DeepL's quality-optimised model.

### Changed

- **Quick translate** opens as a sheet over the app you are in, instead of
  opening the whole app.
- **Faster and sturdier.**
  - An instance that doesn't answer is given up after 7 s (20 s through a
    proxy), and the next one is tried.
  - Startup reads run in parallel.
  - The offline engine preloads its models, can be cancelled and
    translates a text in one go.
  - AI requests are retried once after a temporary error (before any text
    has arrived).
  - Long texts keep their finished parts if a later part fails, and carry
    the previous part's translation and names for consistency.
- **Long texts** are split into parts for every engine, not only AI.
- **Short texts** are identified on the device first, which saves a second
  AI request.
- **AI translations** use a low temperature where the model allows it, for
  steadier results.
- **Glossaries** match whole words and common inflections (for example
  *Haus*/*Häuser*), and short glossaries are always sent whole.
- **Web app:**
  - about a third smaller: languages load on demand;
  - its fallback fonts are served with the app, so Google's font service
    no longer sees which scripts you type.
- **Memory:** the offline voice model is unloaded when idle or in the
  background, and the offline translator keeps fewer models on low-memory
  phones.
- **Build:** Android builds use the Android Gradle Plugin 9.4.1 and Gradle
  9.6.0 (see [Building](docs/building.md) for every pinned tool), and the
  NDK download is retried.

### Fixed

- **API keys:** they are no longer rewritten on every settings change, and
  a passing storage error no longer silently keeps keys in memory only.

## 0.1.0-rc.2

### Added

- **Settings › General:** app language (independent of the phone's), tab
  order (the app opens on the first tab), haptic feedback, multiline input
  (when off, Enter translates and Shift+Enter adds a line) and "Remember
  quality selection".
- **Dictionary:** Kagi-style result view (Meaning / More / Examples, a
  large headword with pronunciation and tappable synonyms, a big listen
  button, "New look-up"), the input docked at the bottom, and word
  bookmarks: look-ups are saved to History and can be marked with the
  heart.
- **Conversation:** hands-free, voice-to-voice mode (Beta). Tap the
  microphone once; each side's speech is translated and read aloud, then
  the app listens for the reply. On-device Whisper detects which of the two
  languages was spoken; other recognisers take turns.
- **History:** swipe to delete or favourite (with Undo); long-press the
  History button to open Favorites.
- **Translate:** the Fast/Best quality chip on the start screen, "Type or
  paste text" with a tappable "paste", and short language labels when the
  bar is narrow.
- **Android:** launcher shortcuts for Translate clipboard, Dictionary,
  Proofread and Conversation; per-app language in the system settings; a CI
  check that the native libraries work on 16 KB-page devices.

### Changed

- Proofread, documents, image, web page, quick translate, presets, offline
  packs and usage follow the new design (headlines on empty screens,
  outlined language pills, the rocket go button).
- System bars follow the app's light or dark look; the splash screen no
  longer flashes white in dark mode.

### Fixed

- Spoken words could be lost in conversations when Android's recogniser
  delivered its final result late.
- The web page translator's buttons acted on the Translate tab's text.
- Controls could sit under the navigation bar on Android 10–14 (quick
  translate sheet, the tablet layout), and the navigation buttons could be
  invisible on Android 8–9.
- On a phone set to a language Mozhi doesn't offer, the app showed Arabic;
  it now falls back to English.
- Offline only with no language pack installed now says so (and offers the
  download) instead of "this engine needs the network".
- The keyboard covered the proofreading context field and the dictionary's
  language list.

## 0.1.0-rc.1 and earlier

See the [GitHub releases](https://github.com/Aimdi/Mozhi/releases).
