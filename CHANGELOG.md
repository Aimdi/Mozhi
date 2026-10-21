# Changelog

All notable changes to Mozhi, by release tag on GitHub (pre-releases end
in `-rc.N`).

## Unreleased

### Changed

- Android builds use the Android Gradle Plugin 9.4.1 and Gradle 9.6.0
  (see [Building](docs/building.md) for every pinned tool).

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
