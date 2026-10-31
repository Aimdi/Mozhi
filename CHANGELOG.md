# Changelog

All notable changes to Mozhi, by release tag on GitHub (pre-releases end
in `-rc.N`).

## 0.1.0-rc.8

### Added

- **Cancel any download:** text recognition languages and dictionary
  packs can now be cancelled too, and the language picker's download has
  a Cancel. A cancelled text recognition download resumes where it
  stopped.
- **Retry where it was missing:** Listen in quick translate and the voice
  preview in Settings offer Retry when the volunteer servers fail. A
  retry in Conversation uses the one-time approval you already gave for
  that text, instead of asking again.
- **The manual download lists** show the links Mozhi actually downloads
  from (your model source), with the publisher's link as a fallback.

### Changed

- **Sync keeps every device's data straight:**
  - Devices with different **Delete history automatically** settings no
    longer keep re-uploading what the other dropped, and nothing is
    deleted on the device that keeps history longer.
  - An edit made while a sync is merging is kept.
  - Presets and glossaries that two devices hold in different versions
    settle on the same one.
  - An AI provider from another device that shares an id with a different
    one here is added under its own id, instead of being dropped or taking
    the other's place; a provider you removed isn't added back.
- **Phone to phone** stays responsive during large transfers (encryption
  runs off the screen's thread), sends language packs compressed (to
  phones on this version), and lets a phone through even while many
  connection attempts arrive from other addresses.
- **Shared conversation** tells guests apart by a cookie, so the limits
  apply per guest and not only per address.

### Fixed

- **Tailscale Funnel addresses** (public `.ts.net` names) were treated as
  private, so text went to them without the proxy, the consent or the
  https rule. A `.ts.net` name now counts as private only when it leads
  into the tailnet (looked up on the phone, never in **Offline only**),
  and a public server can't redirect into the tailnet.
- A connection given up while connecting through a proxy is closed at
  once instead of staying open.
- AI replies made mostly of brackets are searched for their answer in
  linear time instead of giving up.
- A document paragraph with more than 999,999 placeholders is refused
  instead of leaking placeholder text into the result.
- First run: when your phone's language is the target, the language you
  picked earlier in setup is suggested for download.

## 0.1.0-rc.7

### Added

- **Cancel a language download**, on the Offline languages page, next to
  a translation and on the first run. What was downloaded is kept, so the
  next download of that language, or one that was cut off, goes on where
  it stopped (when the server allows it); every file is still checked
  before it is used.
- **Look up a word you typed:** select it in the input and choose
  **Look up** (the offline dictionary first, an AI model only when you
  ask).
- **Quick Settings tile for live captions** (Android 10+). It opens the
  captions screen, which asks for the microphone and screen capture as
  usual, and stops captions with one tap.
- **PDFs keep their own text on Android 15:** a page with a text layer is
  read from the file instead of with text recognition (sharper, faster,
  no text recognition download needed); scanned pages still use it. Text
  recognition pauses while the phone is hot.
- **A Camera launcher shortcut**, and the four shortcuts Pixel launchers
  show are now Translate clipboard, Camera, Conversation and Translate
  screen.

### Changed

- **Volunteer server failures look the same everywhere.** Image
  translation, read-aloud and language detection say in plain words when
  every server failed, with Retry where it fits, instead of an error
  code.
- **Documents keep more of their structure:** gettext and Android plural
  forms follow the target language's rules, spreadsheet sheet names (with
  the formulas that refer to them), cell comments, chart and axis titles,
  and image descriptions (alt text) in Word, PowerPoint and Excel files
  are translated; XLIFF files split into sentences keep their sentences.
- **The app lock** asks for a strong fingerprint or face on Android 11+
  (or the PIN), keeps the decrypted history out of memory while locked
  (also right after a start), and the live caption bar shows only
  **Mozhi is locked** while Mozhi is locked. The translate screen and a
  conversation stay as they were, hidden.

### Fixed

- `mozhi://` links with `..` or `\` in their path now open the start
  page instead of another screen, and live captions start only from the
  Quick Settings tile or the captions screen.
- A crafted gettext file can no longer stall document translation, and a
  download server's malformed answer to a resumed download restarts the
  download instead of failing with an internal error.

## 0.1.0-rc.6

### Changed

- **A first run that ends in a translation.** With the default settings
  (Offline first, nothing downloaded yet) the engine button now says
  **On device + Google**: Mozhi translates on the phone when the language
  is downloaded, and otherwise asks before sending the text to Google
  through a volunteer Mozhi server (**Download** keeps it on the phone,
  **Once** sends only this text). The first-run language step suggests a
  language from the phone's settings and offers its download with its
  size; it starts only when you tap **Next**.
- **"Download French" downloads French.** The download button next to a
  translation now downloads the language right there, with progress (on
  mobile data it asks first, as the Offline languages page does), and
  then translates on the phone. Before, it only opened the Offline
  languages page.
- **When the volunteer servers fail**, Mozhi says so in plain words
  instead of showing an HTTP error, and offers to translate on the phone,
  try another engine (it never switches on its own) or choose another
  server. A server that just failed is tried last for 12 hours (kept on
  the phone only; no request is made just to test a server).
- **Conversation** ends a turn at the pause you chose with the phone's
  own speech recognition too, not only with the offline voice models.
- **Long transcripts** from Transcribe and live captions are saved to
  History in numbered parts instead of being cut at 20,000 characters.
- **The floating bubble** waits until you leave Mozhi before it appears.
- **Store listings** in all 18 app languages, describing what the app
  does today.

### Fixed

- **Backup passphrases with accented letters.** A passphrase typed with a
  keyboard that composes accents differently (for example "é" as one
  character or as "e" plus an accent) now opens the backup or sync file;
  older backups still open with the passphrase as typed then. A sync file
  made before is moved to the new key the first time a device of this
  version joins it; the other devices ask for the passphrase once, and a
  device still on 0.1.0-rc.5 or older needs this update to open it.
- **A one-time approval on the Translate screen** that the phone ended up
  not needing (the language was downloaded meanwhile) is withdrawn, so a
  later text is asked about again.
- **Web app in Firefox and Safari:** offline language downloads no longer
  wait on Firefox's storage prompt, offline languages work in Safari 16
  and Chrome before 108, encrypted backups work without the browser's
  compression support (older Firefox and Safari), and dictionary packs in
  a private window say they can't be stored instead of failing. The web
  tests now also run in Firefox and WebKit.

## 0.1.0-rc.5

### Added

- **Live camera** (Android). Point the camera at a sign, a menu or a page
  and the translation is drawn over the live picture: the text is read on
  the phone a few times a second, only new or changed text is translated,
  and the boxes hold still while you move. **Freeze** takes the picture to
  the photo screen; torch and zoom are there too. It translates with the
  offline engine unless you pick another one for live translation (an
  online engine asks once, since it gets everything the camera reads).
  Frames stay in memory and are never saved or sent. Mozhi now asks for
  the camera permission when you open it.
- **PDF documents** (Android). PDF files are read page by page on the
  phone, translated with the document's engine and saved as a translated
  PDF: each page keeps its look, and the translation is real text that
  can be selected, searched and read aloud. **Save the text** keeps the
  translation alone. Files up to 25 MB and 200 pages; password-protected
  files are refused. PDFs can be shared to Mozhi from other apps.
- **Live captions** (Android 10 and later). **Caption other apps** on the
  Transcribe screen shows translated captions of what other apps play
  (videos, podcasts, calls in apps that allow it) in a small floating bar,
  recognised with the offline voice models and translated on the phone by
  default. Android asks for consent each time; the sound stays in memory,
  and the transcript is kept only if you save it.
- **Tap a word.** A tap on a word in a translation opens a small
  dictionary card from the offline dictionaries (also for languages
  written without spaces), with Listen, Copy, Open in Dictionary and Add
  to phrasebook; **Look up with …** asks an online dictionary engine only
  when you tap it. Selected words have **Look up** in the selection menu.
- **Follow along.** The word being read aloud is highlighted while Listen
  plays, in the translation and in the phrasebook, with voices that report
  their progress (the phone's voices, and the browser's).
- **The web app works offline.** Once opened, a self-hosted Mozhi web app
  keeps its own files in the browser and opens and translates with
  offline languages with no network at all; a new version shows **Update
  ready: Reload**. It can be turned off in Settings › General.
- **Import from files** for offline languages and dictionaries in the web
  app, and for dictionaries on Android.
- **Conversation picks the speaker** from the language spoken (with the
  offline voice models), and a turn ends at a real pause (0.8 seconds by
  default, adjustable) instead of after 3 seconds.

### Changed

- **"Once" means once.** A one-time approval to send text to an online
  engine covers the text waiting at that moment; what it didn't use is
  withdrawn when the work ends, in the live camera, documents, web pages,
  Transcribe and live captions (before, a camera or document run could
  leave approvals behind for a few minutes).
- **Take photo asks for the camera permission** the first time, because
  Mozhi now uses the camera itself (for the live camera).
- **Photo and document results say when personal data stayed on the
  phone**, like translations of typed text.

### Fixed

- **Online translation on a new install.** Mozhi started on public
  servers whose Google engine answered every translation with an error
  (and four of the built-in servers were gone or blocked apps), so a new
  install often waited or failed. The working servers now come first, the
  dead ones are gone, settings that still have the old default list are
  updated, and **Find the fastest server** times a translation of the word
  "Hello" instead of only asking each server for its version, so a server
  that doesn't translate is never picked.
- **Listen with the phone's voice on very long texts.** Texts over about
  4,000 characters are read in parts instead of failing.
- **Play variant:** screenshots and frozen live camera pictures are read
  by ML Kit too (it needs a file, so a temporary one is written and
  deleted right after).
- **Hostile engine replies** with thousands of brackets, or streamed
  replies with long runs of spaces, no longer slow the app down.
- **Translated CSV cells** that start with a full-width `＝`, `＋`, `－` or
  `＠` are protected from being run as spreadsheet formulas, like the
  ASCII ones.
- **Documents with very many inline tags** in one paragraph keep them all.

## 0.1.0-rc.4

### Added

- **Office documents and e-books.** Word (DOCX), PowerPoint (PPTX), Excel
  (XLSX), OpenDocument text, presentations and spreadsheets (ODT, ODP,
  ODS) and EPUB books are translated in place and saved in the same
  format: bold, links, footnotes, tables, images and layout stay as they
  were, and the document's language is set to the target. Files up to
  25 MB; damaged, password-protected and unsafe files (such as zip bombs)
  are refused with a clear message. They can also be shared to Mozhi from
  other Android apps.
- **Localisation files and web pages.** XLIFF 1.2 and 2.x, gettext PO and
  POT, Android `strings.xml`, Apple `.strings` and Xcode string catalogues
  (`.xcstrings`), CSV and TSV tables and HTML pages: only the text is
  translated; keys, comments, plural forms, format placeholders (`%s`,
  `{name}`, `%@`), inline tags and escaping are kept, and the target
  language is written where the format records it.
- **Translate screen** (Android). A Quick Settings tile, a launcher
  shortcut and an optional floating bubble translate what is on the
  screen in any app: Android asks for consent every time, one screenshot
  is taken, its text is recognised on the phone and the translation is
  drawn over it. The screenshot stays in Mozhi's private cache and is
  deleted right away. A long press on the bubble translates the
  clipboard.
- **App lock** (Settings › Privacy & data). Lock Mozhi with the phone's
  fingerprint, face or screen lock, immediately or after 1, 5 or 15
  minutes in the background. While it is locked nothing of the app is
  visible (also not in Recents), shared text and links wait for the
  unlock, and running work such as a document translation goes on behind
  the lock. The setting stays on the device: it is not synced or
  restored onto another phone.

### Changed

- **Downloads check the free space first.** Offline languages, text
  recognition data, voice models, on-device AI models, dictionary packs
  and starter phrasebooks are not started when the phone lacks room for
  them ("Not enough free space: needs 1.2 GB, 300 MB free").
- **On-device AI waits while the phone is hot.** A long text, a document
  or a web page translated part by part pauses between its parts while
  the phone is hot or battery saver is on, says so, and offers
  **Continue anyway**. Heat and battery saver changes now arrive at once
  instead of being polled. The AI extras show the same loading notice as
  the main translation while the model loads.
- **Importing an on-device AI or voice model** no longer makes a second
  copy of the file first, so it needs half the space.
- **Faster CPU builds fall back safely.** If a phone crashes twice in a
  row when it first loads the faster on-device AI or voice engine build,
  Mozhi uses the baseline build from then on (one crash gets another try,
  since Android may have closed the app for another reason). The build in
  use is shown on the On-device AI page and in the voice settings.

### Fixed

- **Text that froze the translate screen.** Some pasted or typed text
  (for example `<a` followed by thousands of spaces, or `%000…`) made the
  placeholder protection and the translation checks run for minutes; they
  now take milliseconds.

## 0.1.0-rc.3

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
  own, and text translated on this device (offline translation or
  on-device AI) is only tried again on this device.
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
- **On-device AI** (Android, 64-bit phones; Settings › AI › On-device
  AI): translation and every AI extra (refine, alternatives, insights,
  explanations, dictionary, proofreading, meaning checks) with a language
  model that runs on your phone, so no text leaves it and no network or
  account is needed. Hy-MT2 1.8B (Tencent, Apache-2.0, 33 languages)
  translates; Gemma 4 E2B or Qwen3 1.7B (Apache-2.0) handle the extras.
  Downloads are 1.1 to 3.1 GB, only when you ask, from the model source
  you chose, and checked against checksums built into the app; or import
  a file, or receive one from another phone. Each model says whether it
  fits your phone's memory. On-device engines read **On this device**
  everywhere, work in **Offline only**, and never ask for consent. While
  the phone is very hot or in battery saver, translating as you type
  doesn't start on-device AI (Enter still does). Chat markers in the text
  (from a document or a web page, say) are read as plain text, so they
  can't pose as the app's own prompt, and a reply that runs far longer
  than the text is cut short. Runs on llama.cpp (MIT), in three builds
  for older and newer ARM processors. See
  [On-device AI](docs/on-device-ai.md).
- **Faster offline voice input** on phones from about 2019 on: Whisper now
  uses the processor's dot-product, half-precision and matrix
  instructions when the phone has them. New voice models: **Better
  (compact)** (base, 60 MB), **Best** (small, 190 MB) and **Large**
  (large-v3-turbo, 574 MB, for phones with 8 GB or more), each offered
  only on phones with enough memory.

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

- **Phone to phone between app versions:** a phone now leaves out what it
  doesn't know how to receive (an on-device AI model from a newer Mozhi)
  instead of refusing the whole transfer.
- **Saving in the web app** (exporting favorites, a phrasebook collection
  or flashcards, saving a document) now says it was saved: the browser's
  download used to count as cancelled.
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
