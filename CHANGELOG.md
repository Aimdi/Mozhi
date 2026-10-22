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
  Privacy & data). E-mail addresses, phone numbers, IBANs, card numbers and
  IP addresses are replaced before text leaves the device and put back into
  the translation; the result says how many items stayed on the device.
- **Network activity** (Settings › Privacy & data). A log of every request
  this session: where it went, why, how much was sent and received, and
  whether it went through your proxy. It never records text, and it is
  never saved.
- **Share images and files with Mozhi** on Android. Images open on the
  image screen (read on the device first), and subtitles, text and JSON
  files open in Documents. Neither starts an AI request by itself. The web
  app accepts shared text.
- **A way forward when a translation fails.** **Translate on this device**
  is offered when the network fails and the language pair can be
  translated offline; **Translate with Google** (or another engine you
  already allowed for the pair, never a cloud provider) and **Try next
  instance** are one tap away; and "You're offline" says when the device
  has no network.
- **Offline alignment.** Tap-to-highlight works with the on-device engine:
  free, instant and without a network.
- **DeepL:** glossaries now apply to the DeepL API, and an option prefers
  DeepL's quality-optimised model.
- **Short words and phrases.** For one to three words, a panel under the
  translation shows other translations (tap one to use it), definitions
  with examples and synonyms, from what the engine already sent: no extra
  request. **Open in Dictionary** opens the Dictionary tab, and with an AI
  model **More detail** loads the dictionary entry in place.
- **Show full screen:** the translation in large, high-contrast type, to
  show it to someone. Tap, Back or Escape closes it.
- **Unsure sentences.** Sentences the on-device engine is unsure about get
  a dotted underline, and a note offers **Compare with another engine**.
- **Start screen:** **Continue** brings back your last translation from
  the history on this device, and on Android **Paste and translate**
  appears when you come back with text on the clipboard. The app only
  checks that the clipboard holds text; it reads it when you tap.
- **Settings search**, and eight categories (General, Privacy & data,
  Backup & sync, Translation engines, AI, Appearance, Read aloud & voice,
  About), each on its own page. The search finds every setting and jumps to it.
- **Favorites as a phrasebook:** grouped by language pair, with filter
  chips, and **Export favorites** saves or shares them as a CSV file for
  Anki and spreadsheets. The file isn't encrypted and stays on the device
  unless you share it.
- **Offline languages in the language picker** (Android): languages that
  work offline with the other language are marked **Works offline**, and
  one that isn't on the device yet can be downloaded from its row.
- **Keyboard:**
  - Ctrl+Shift+1 to 4 switch to the tabs in your order, and Ctrl+Shift+H
    opens History;
  - "/" goes to the text box;
  - a focus ring shows where the keyboard is (never after a touch);
  - the shortcuts list has an "Anywhere in the app" section.
- **Photo translation over the picture** (Android): the translation is
  drawn over the original text, paragraph by paragraph, in matching size
  and colours. Hold to see the original, tap a paragraph to see and copy
  both, and **Save image** or **Share image** keeps the translated
  picture. **Text** shows the plain text as before.
- **Offline translation in the web app.** The same on-device engine and
  models as on Android run in the browser (WebAssembly in a background
  worker), with downloads kept in the browser's storage for the site:
  translation, language detection, alignment and unsure-sentence marks
  work without a network, and Offline only and Offline first work in the
  web app too. It needs a recent browser over `https`; the Offline
  languages screen says what's missing otherwise. Self-hosted web apps
  serve the models from their own server (Mozilla's storage doesn't allow
  other websites).
- **Transcribe** (More tools, and the Conversation menu): a running
  transcript of a talk or lecture, phrase by phrase with timestamps, on
  the device with the offline speech model on Android. Tap **Translate**
  to translate each phrase as it comes (on the device in Offline only),
  and copy, share, save as text or subtitles (.srt) or keep it in History.
  It pauses when the app is hidden and keeps the screen on while it
  listens.
- **Offline voice input phrase by phrase:** with the 0.9 MB speech
  detector (downloaded with the speech model, or on its own in Settings ›
  Read aloud & voice › Voice input), text appears after each phrase
  instead of at the end, sessions last up to a minute, and noise no longer
  counts as speech. Conversation uses it too.
- **Offline dictionaries** (Offline languages › Dictionaries): download a
  Wiktionary dictionary once, and the Dictionary tab and the panel under
  short translations show meanings, pronunciation, examples and
  inflected forms ("went" is a form of "go") without AI or a network,
  credited "From Wiktionary · CC BY-SA 4.0". **More detail** still asks
  your AI provider. Look-ups never leave the device. The dictionaries are
  published with the app's releases.
- **Model source** (Settings › Translation engines, and the Offline
  languages screen): download offline languages, voice input and text
  recognition models from the original publishers, from the server that
  hosts the web app, or from your own mirror (https, your network or a
  .onion address), optionally falling back to the publishers. Every file
  is still checked against the fingerprint built into Mozhi.
  `tool/mirror_models.py` fills a mirror, and the Caddy setup in `deploy/`
  serves it.
- **Glossaries with Mozhi and LibreTranslate:** the terms are protected
  on the device, translated your way and put back (whole words only, and
  acronyms like *IT* or case-sensitive terms in their exact case); a term
  that couldn't be placed is flagged. Every engine but the on-device one
  and translation-only AI models now applies glossaries.
- **Personal data stays hidden in the AI extras too:** alternatives,
  explanations, refining, meaning checks, dictionary look-ups, Proofread
  and image and document translation get placeholders instead of e-mail
  addresses, phone numbers and account numbers, and Proofread says how
  many items stayed on the device.
- **Online voices are labelled.** Voices that send the text to a speech
  service (such as Chrome's "Google …" voices) say so in the voice picker,
  local voices come first, and Mozhi asks once per voice before one reads
  aloud (Settings › Read aloud & voice › Allowed online voices). In
  offline-only mode they are not used.
- **Encrypted backup** (Settings › Backup & sync, and on the first
  screen of a new install). One file, encrypted with your passphrase
  (Argon2id and AES-256-GCM), holds your history and favorites,
  phrasebook, practice progress, presets, glossaries and settings; API
  keys and passwords only if you include them. There is no account and no
  server: you choose where the file goes. Restore **merges** with what is
  on the device (deleted entries stay deleted) or **replaces** it, and a
  backup made in the web app restores on Android and the other way round.
  See [Backup](docs/backup.md).
- **Sync through your own WebDAV folder** (Nextcloud, ownCloud, a NAS or
  `rclone serve webdav`): history, favorites, phrasebooks, practice
  progress, presets and glossaries stay the same on your phone, tablet and
  the web app. Everything is encrypted on the device with a sync
  passphrase before it leaves, so the server stores a file it can't read;
  changes from both sides are merged per entry. See [Sync](docs/sync.md).
- **Phone to phone** (Android): move your data or your offline languages,
  voice and text recognition models to another phone over the same Wi-Fi
  or a hotspot, end-to-end encrypted, with no account, server or internet.
  The receiving phone shows a QR code; both phones show a six-digit number
  to compare. See [Phone to phone](docs/pairing.md).
- **Phrasebook:** your favorites grow into named collections (*Trip to
  Lisbon*, *Pharmacy*), filled in a tap from a translation, a history
  entry, a dictionary entry or a conversation message, with notes,
  pronunciation and topics, CSV export and import, and offline starter
  phrasebooks for travellers from Wikivoyage (CC BY-SA). Open it from
  History › Favorites or More tools. See [Phrasebook](docs/phrasebook.md).
- **Practice:** flashcards of your phrasebook collections, scheduled with
  FSRS (the spaced-repetition algorithm Anki uses) and asked a few at a
  time, both ways round. Say the phrase aloud and on-device Whisper checks
  it, or type it; the app suggests a rating and you decide. Export a
  collection to Anki. Nothing leaves the device and there are no streaks.
  Open it from More tools (with the number of cards due), a phrasebook
  collection or the settings. See [Practice](docs/practice.md).
- **Shared conversation** (Android, the Conversation tab's menu › Share on
  this network): everyone in the room follows the conversation on their
  own phone, in their own language, and can reply by typing. Your phone
  serves the page on the local network, so there is no app to install and
  no server; guests scan a QR code and enter a PIN. See
  [Shared conversation](docs/features.md#shared-conversation).

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
- **Instant translation reacts sooner.** It starts right after a paste or
  the end of a sentence, and sooner after each word. AI and the DeepL API
  wait a moment at the end of a sentence, so a text of several sentences
  is sent once; the DeepL API, billed per character, keeps its slower pace
  while you type. Typing sends no more AI requests than before.
- **The translation** shows a placeholder as soon as it starts, keeps the
  previous result (dimmed) while a new one runs, and sits on a raised
  surface with its actions at the start. Nothing jumps while text streams
  in; on Android a light tick says it is done (with haptic feedback on).
  **Copy** turns into a check mark.
- **Instant translate** is one setting with three choices: Off, Online
  engines, or Online engines and AI (Settings › Translation engines ›
  Instant translate).
- **Tools** (formerly "More") under the translation lists the tools as
  rows: Check meaning, Insights, Romanization and Matching phrases switch
  on and off, Alternatives and Definitions unfold, Explain and Compare
  engines open their own view.
- **Refining:** More formal, More casual, Shorter and Simpler are always
  shown under an AI translation; the others and More suggestions are
  behind "+". An applied refinement is a tag in the header (× undoes it),
  and the words it changed light up for a moment.
- **Fast and Best:** once both are set up, one of them is always selected
  (the third state, your usual engine, is gone; you are moved to Fast or
  Best). Picking an engine sets the engine of the selected mode. The engine
  button names the engine only (an AI model's id is in the engine list),
  and every engine there has a short note on what it is good for.
- **Compare engines** starts at once, with the current translation as the
  first card. Engines with the same result share a card ("DeepL and Google
  agree"), words that differ are highlighted, and **Done** leaves.
- **Translation options:** Tone is Formal, Neutral or Casual (the softer
  "Prefer…" choices are under Advanced), options the engine ignores are
  greyed out ("AI engines only"), and wide windows open the options as a
  side sheet.
- **The detected language** is shown in the language bar, no longer under
  the translation; an uncertain detection still offers the other likely
  languages under the translation.
- **The character counter** appears from 80 % of the limit
  ("16,000 / 20,000").
- **Wide screens** (840 dp and up) show two fixed panes from the start,
  with the languages above them and the options and go button under your
  text; the bottom language bar is for phones only. The language picker
  drops down under its button, in columns, and its search is focused on
  wide windows or after keyboard use.
- **Language picker:** AI styles are behind a **Languages | Styles** switch
  (a search still finds them), and the pin button shows on Recent and
  Pinned languages, or while you point at a row.
- **Swapping languages** slides the two names across (no motion with
  reduced motion).
- **Android:** tapping outside the empty text box, or Back, closes it and
  brings back the start screen.
- **The ⋮ menu** holds Documents, Web page and Recent language pairs, plus
  Keyboard shortcuts where a keyboard is likely. Camera is on the start
  screen and in the text box, Compare engines in Tools, and Listen slowly
  is a long press on Listen.
- **In a browser,** the language pickers are Alt+L and Alt+Shift+L,
  because Ctrl+L belongs to the address bar.
- **History:** compact two-line rows with the language pair, the heart and
  a ⋮ menu (Copy, Share, Details, Delete; also on a long press), buttons on
  hover with a mouse, and highlighted search matches. The engine and time
  are in Details; wide screens show the list beside the details.
- **Settings:** Clear history and Delete all local data come last, in red,
  on Privacy & data; About has Run setup again and the licences.
- **Dictionary and Proofread** use the same composer as Translate, greet you
  with "Look up a word" and "Check your writing", and show the AI model in
  the app bar.
  - Dictionary: the search bar stays above the entry (no "New look-up"),
    the tabs are Meaning, Usage and Examples, the heart sits beside Listen,
    and Listen uses the entry's language.
  - Proofread: **Copy corrected text** is the main button, and each
    suggestion has its own accept and reject buttons, with **Reset** (no
    "Accept all" or "Reject all").
- **Errors** have a short title ("Couldn't connect", "AI provider problem",
  "Mozhi instance problem", ...) above the explanation, with Retry as the
  second action.
- **Setup in the web app** has no privacy step, since the browser can't
  translate on its own; an **Ask before sending text** switch takes its
  place. **Find the fastest server** contacts every listed server, and only
  when you tap it.
- **Look:**
  - the go button is an arrow instead of a rocket, quieter while instant
    translation is on;
  - the bottom bar shows labels, and the narrow sidebar small ones;
  - outlines of controls have at least 3:1 contrast, and secondary text is
    lighter in Dim and Lights out;
  - the heart is the favorite icon everywhere, and the app is in US
    English ("favorites").
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

- **Settings and API keys:** keys are no longer rewritten on every
  settings change, and a storage error no longer goes unnoticed: when the
  settings or a key can't be saved, the app says so. The change lasts
  until you close Mozhi, and a key is never saved unprotected.
- **Screen readers in the web app** work from the start (there is no
  hidden "Enable accessibility" button any more) and can read the
  translation.
- **Screen readers:** a translation's header, with its "Sent to …" chip,
  no longer reads as one button; the proofreading result no longer reads
  as its Share button; a refinement's undo tag no longer reads as
  disabled.
- **The splash screen and system bars** match the default light and dark
  looks on Android and the web.
- **HTTPS through a proxy** (Android): the connection timeout now covers
  the proxy's `CONNECT` answer and the TLS handshake too, so a server that
  never answers through Tor fails over in seconds instead of hanging until
  the request times out. Tor `.onion` and I2P sites in plain http go
  through a tunnel too, which Tor's HTTP tunnel port requires.
- **Voice models** are checked against their SHA-256 fingerprint as well
  as their SHA-1 one.
- **Saved glossaries apply.** The glossaries in Settings › AI ›
  Glossaries weren't applied to translations; now every enabled glossary
  applies to every translation of its language pair (also in
  Documents, Conversation, Transcribe and photo translation), and the
  terms you add in the options sheet win over them.
- **Glossary terms no longer match other words:** *IT* no longer matches
  "it", *Bank* no longer matches "Bankett", and a missing-term warning no
  longer appears for words that only look like a term.
- **Personal data:** e-mail addresses with accented letters
  (`info@müller.de`) and IPv6 addresses are hidden from online engines
  too.
- **Redirects can't move your text or downloads elsewhere.** A Mozhi
  instance's redirect is only followed on the same server (or from http to
  https on it): a redirect to another server, which could have received
  your text again outside your proxy, now shows an error naming that
  server. Model and dictionary downloads follow redirects only to public
  `https` servers: never to plain http, into your network or around your
  proxy.

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
