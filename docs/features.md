# Feature tour

Everything Mozhi can do, screen by screen. Features marked **AI** need an
[AI provider](ai-providers.md) or [on-device AI](#on-device-ai); everything
else works with a Mozhi instance alone.

- [Translate](#translate)
- [Languages and detection](#languages-and-detection)
- [Extra target languages](#extra-target-languages)
- [Engines and compare mode](#engines-and-compare-mode)
- [Quality modes: Fast and Best](#quality-modes-fast-and-best)
- [AI translation options](#ai-translation-options)
- [Presets](#presets)
- [Custom languages and styles](#custom-languages-and-styles)
- [Refining a translation](#refining-a-translation)
- [Kagi-style extras](#kagi-style-extras)
- [Romanization and alignment](#romanization-and-alignment)
- [Meaning check](#meaning-check)
- [Dictionary](#dictionary)
- [Proofread](#proofread)
- [Image translation](#image-translation)
- [Live camera](#live-camera)
- [Voice](#voice)
- [Shared conversation](#shared-conversation)
- [Transcribe](#transcribe)
- [Live captions](#live-captions)
- [Documents](#documents)
- [Web pages](#web-pages)
- [Offline translation](#offline-translation)
- [On-device AI](#on-device-ai)
- [History and favorites](#history-and-favorites)
- [Phrasebook](#phrasebook)
- [Practice](#practice)
- [Backup and restore](#backup-and-restore)
- [Sync](#sync)
- [Phone to phone](#phone-to-phone)
- [Privacy controls](#privacy-controls)
- [Usage and costs](#usage-and-costs)
- [Text-to-speech](#text-to-speech)
- [Android integration](#android-integration)
- [Links](#links)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Settings](#settings)
- [Appearance and layout](#appearance-and-layout)
- [Platform support](#platform-support)

## Translate

- **Start screen.** With no text, the tab greets you (**Good morning**,
  **Good afternoon** or **Good evening**) with chips for **Camera** (image
  translation) and **Document**. Below them:
  - **Continue** with your last translation (its text and language pair,
    such as *EN → FR*), from the history on this device: one tap shows it
    again, without a new request. It is hidden while history is off or in
    incognito.
  - **Paste and translate** (Android), when you come back to the app with
    text on the clipboard. The app only asks Android whether the clipboard
    holds text, and reads it when you tap the chip. With instant
    translation off, the chip says **Paste copied text** and only pastes.
    Not in the web app.
  - your **Recent pairs**, and on large screens a hint that **?** shows the
    keyboard shortcuts.
- **Phones.** The composer waits at the bottom, as on Kagi Translate: a
  card with the text box (the microphone, and paste, at its top right) and
  the language bar. Tap it to type: the screen turns into the usual thread,
  your text with its language at the top and the translation under it, and
  the language bar stays docked at the bottom of the screen, right above
  the keyboard while it is open. Tap outside the empty text box, or press
  Back on Android, to get the start screen back; the next Back leaves the
  app. Windows narrower than 840 dp use this layout too.
- **Wide screens** (840 dp and wider: tablets, foldables, desktop
  browsers). Two panes from the start: your text and the translation, with
  the languages in a header above them (the source over your text, the
  target over the translation, the swap button between them).
  **Translation options**, the chips of the options in use and the go
  button sit under your text; there is no language bar at the bottom. The
  empty text pane says **Type or paste text**, with the greeting,
  **Camera**, **Document** and your recent pairs under it, and the empty
  translation pane a muted **Translation**. Nothing moves when you click
  into the text box. On a foldable the panes split at the hinge.
- **Language bar** (phones). At the bottom of the screen, as on Kagi
  Translate: **Translation options** (the tune icon) on the left, the
  source and target languages with the swap button in the middle, and the
  go button (an arrow, **Translate**) on the right. The go button
  translates right away, or again; in compare mode it runs the comparison.
  While instant translation is on it is quieter, since typing translates
  anyway. While a translation is running it turns into **Stop
  translating**.
- **Instant translate.** The translation updates as you type: right after
  a paste or the end of a sentence, otherwise shortly after each word (a
  little later with AI models). AI models and the DeepL API wait a moment
  at the end of a sentence, so that a text of several sentences is sent
  once, and the DeepL API, which bills per character, waits for a pause in
  typing. Each pause sends an AI model a request, which costs tokens with a
  paid provider. **Settings > Translation engines > Instant translate**
  chooses which engines translate while you type: **Online engines and AI**
  (the default), **Online engines** (Mozhi, translation services and
  on-device translation; AI waits for the go button) or **Off** (only the
  go button translates). Text shared from other apps and links wait for the
  go button with an AI model either way (see [Links](#links)).
- **The translation** sits on a raised surface under a header with the
  target language, the engine (and, once done, the time) and where the
  text went. As soon as a translation starts, its header and three
  placeholder lines show (screen readers hear **Translating…**); while a
  new translation of a shown result runs, the old one stays, dimmed. The
  actions keep their place while the text streams in and fade in once it
  is complete; on Android a light tick says it is done (with **Haptic
  feedback** on).
- **Output actions,** at the start edge: **Copy** (the icon turns into a
  check mark, and screen readers hear **Copied to clipboard**; there is no
  extra message on Android 13 and later, which confirms copies itself, or
  in the web app), **Listen** (long-press it to [listen
  slowly](#text-to-speech)), the heart (**Add to favorites**), **Share**
  and **Show full screen**.
- **Show full screen** shows the translation as large as it fits, black on
  white (white on black in the dark theme), to show it to someone across a
  counter. It lays itself out again when you turn the device, and has a
  **Copy** button; tap anywhere, press Back or Escape to close it.
- **Tools.** **Tools**, under the actions, unfolds the other tools as one
  list: **Check meaning** ([meaning check](#meaning-check)), **Insights**,
  **Romanization** and **Matching phrases** switch on and off (a check mark
  shows which are on), and **Compare engines** opens
  [compare mode](#engines-and-compare-mode). Under **Learn**,
  **Alternatives** unfolds other translations and **Explain** opens an
  explanation (see [Kagi-style extras](#kagi-style-extras)). For longer
  texts, **Definitions** unfolds the definitions the engine sent along.
  **Also translate into…** is there too. Which rows show depends on the
  engine: Insights, Alternatives and Explain need an AI model; **Matching
  phrases** also works with the on-device engine, for free and without a
  network. Whether Tools is open is remembered until the app closes.
- **Short words and phrases.** For one to three words, a panel under the
  translation shows what the engine sent along with it, without a new
  request: up to four **Other translations** (tap one to use it), up to two
  **Definitions** with an example, and **Synonyms** (Google through Mozhi
  sends the most). **Open in Dictionary** opens the word on the
  [Dictionary](#dictionary) tab, and with an AI model for extras **More
  detail** loads the AI dictionary entry right there (one request).
- **Tap a word** of a finished translation for its word card, a small
  dictionary entry in a sheet: the word in its language, its pronunciation
  and part of speech, up to three meanings with their translations into
  your text's language, and where the data comes from (**From Wiktionary ·
  CC BY-SA 4.0**). It comes from the [offline dictionaries](#dictionary) on
  the device first, without a network: an inflected form finds its lemma
  (*“went” is a form of “go”*), and in Chinese, Japanese, Thai, Lao, Khmer
  and Myanmar, written without spaces, the tap finds the longest word of
  the installed dictionary there (one character without a dictionary).
  Elsewhere the word under your finger is taken whole, without the
  punctuation around it (*don't*, *E-Mail-Adresse*). **Listen**, **Copy**,
  **Open in Dictionary** (the Dictionary tab with the word and both
  languages) and **Add to phrasebook…** are on the card. A word the
  dictionaries don't have, or one in a language without a dictionary, can
  be looked up with your AI model, only when you tap **Look up with …**
  (one request with the word and its sentence; see
  [privacy](privacy.md#offline-dictionaries)). Selecting, copying, the long
  press and the double tap work as before: the card opens once a double
  tap could no longer follow, and not while **Matching phrases**,
  **Insights** or a meaning check difference is shown. Look-ups on the card
  are not saved to History. **Settings > Appearance > Tap a word to look it
  up** turns the tap off. **Look up** in the selection toolbar opens the
  card for one to three selected words, also when you select with a
  keyboard or a screen reader.
- **Unsure sentences** (on-device engine). Sentences the offline engine is
  unsure about get a dotted underline (tap or point at one: **The on-device
  engine is unsure about this sentence**), and a note under the
  translation counts them and offers **Compare with another engine**, which
  runs [compare mode](#engines-and-compare-mode).
- **Translation checks.** Every result is checked on the device. A note
  under it says when placeholders (`{name}`, `%s`), tags, links, e-mail
  addresses, numbers or glossary terms went missing, when the result looks
  like the original text, the wrong language or a reply instead of a
  translation, and how many personal details stayed on the device. AI
  models get one corrected attempt first. Mozhi, DeepL and LibreTranslate
  never see placeholders and markup: they are protected and put back.
- **Automatic fallback.** When an engine returns the original text, the
  wrong language or a garbled or chat-style result, Mozhi translates again
  with another engine you already allowed (on this device first) and says
  which one ("Google returned the original text. Translated on this
  device."). Paid AI providers are never tried automatically, and neither
  are on-device AI models (they would load a large model unasked). Text
  from an engine on this device (offline translation or on-device AI) is
  never sent to another engine automatically: it only falls back to
  offline translation, on the phone, never to a server. Comparing it with
  another engine (**Compare engines**, **Compare with another engine**) is
  always your choice.
- **Errors** have a short title in the error colour (**Couldn't connect**,
  **AI provider problem**, **Mozhi instance problem**, ...) above what to
  do; with no network on the device the title is **You're offline**. When
  there is a one-tap way out it comes first, with **Retry** next to it:
  **Translate with Google** (an engine you already allowed for this
  language pair, never a cloud provider) or **Try next instance** (makes
  the next instance of your list the preferred one and translates again).
  When the network fails, the error also offers **Translate on this
  device** if the language pair is installed, or its download.
- **More languages at once:** **Also translate into…** in **Tools** adds up
  to four more target languages; see
  [Extra target languages](#extra-target-languages).
- **Same language in and out** (AI): choose the same source and target
  language to have the text improved and rephrased instead of translated.
- **Long texts:** the input holds up to 20,000 characters; a counter shows
  up from 16,000 (**16,000 / 20,000**).
  - **AI models** get texts longer than 6,000 characters in parts (2,500
    characters for local models, which usually have small context windows).
    Parts are cut at paragraph boundaries where possible (else at line
    breaks or sentence ends; code blocks are never cut), and two are
    translated at a time. Each part comes with the end of the part before
    it and of its translation, plus the names and glossary terms used so
    far, so terms and tone stay consistent.
  - **Mozhi engines, DeepL and LibreTranslate** get parts too, within each
    engine's limit (for example 4,500 characters for Google, 1,500 for
    Reverso).
  - The translation fills in as the parts finish. If a part fails, the
    finished parts stay on screen with the error.

## Languages and detection

- **Picking languages.** Tap the source or target language to open the
  picker: full screen on phones; on wide screens it drops down under the
  language button, with the languages in columns (Esc or a click outside
  closes it). Search by English or native name or by code (accents don't
  matter: *francais* finds Français), pick from **Recent** (your last eight
  languages), **Pinned** or **Downloaded (offline)**, or browse **All
  languages**. The search field is ready to type in on wide screens and
  after you used the keyboard; on a phone, a key typed on a hardware
  keyboard starts the search. Recent and pinned languages have a pin
  button; other languages show it while you point at them or focus them,
  and a long press pins or unpins any language. Mozhi engines show the
  languages that engine supports; AI engines offer about 290 languages and
  variants, from Brazilian Portuguese and Cantonese to Latin and Toki Pona.
- **Works offline** (Android). A language that the on-device engine can
  translate together with the other language of the pair is marked
  **Works offline**. A language it supports that isn't on the device yet
  has a download button in its row (for example **Download German (24.0
  MB)**). It downloads only that language, with the same **Download over
  Wi-Fi only** setting and mobile-data question as
  [Offline translation](#offline-translation).
- **Detect language.** With the source set to **Detect language**, the
  source button in the language bar (on wide screens, above your text)
  names the detected language (**Detected: Dutch**), and the source picker
  lists it under **Detected**; tap it to choose another source language.
- **Uncertain detection.** Short texts are hard to detect: "Gift", "Bank" or
  "Hallo" are words in several languages. For a single short word, or when the
  engine says it isn't sure, the label reads **Detected: Dutch?**, and chips
  for the other likely languages (for example German or Afrikaans) appear
  under the translation's actions; tap one to translate from that language
  instead. With a cloud AI model, input of up to three words also gets a
  second, small detection request, so that a doubtful guess is caught.
- **Your languages count** (AI): for short texts the model is told which
  languages you recently translated from (the sources of your recent
  language pairs) and prefers them when a word could be in several
  languages.
- **Swap languages** (the arrows between the two languages) exchanges them
  and moves the translation into the input; the two language names slide
  across and trade places (no motion when the system asks for reduced
  motion). While detecting, it uses the detected language.
- **Smart swap.** If the detected language is the target language (you
  typed English while translating into English), Mozhi translates into
  another language you use instead: a recent or pinned language, then your
  device's languages, English, or another widely used language. A message
  says **Translating into Spanish instead**; **Undo** goes back and
  translates into the original target (an AI model then polishes the text in
  its own language). Uncertain detections never swap, and a target you chose
  yourself, or went back to with **Undo**, isn't swapped away again until
  you restart the app.
- **Recent language pairs.** Long-press the swap button (or choose **More
  tools > Recent language pairs** in the ⋮ menu) to see the last eight
  pairs you translated with, such as *Spanish → English*, and pick one to
  set both languages at once; the start screen shows the latest ones too.
  Pairs with a custom style are greyed out while the engine can't take one.
  **Clear recent language pairs** is in the sheet and under **Settings >
  Privacy & data**.
- **Pinned target shortcuts.** On a keyboard, Alt+1 to Alt+9 translate into
  your first nine pinned target languages, in the order the picker lists them
  under **Pinned** (in a desktop browser the picker shows each one's
  shortcut). See [Keyboard shortcuts](#keyboard-shortcuts) for the browser
  and Mac variants.

## Extra target languages

Translate one text into several languages at once: **Also translate into…**
in **Tools** under the translation adds up to four more target languages
next to the main one. Their cards stay under the translation when Tools is
closed.

- **Picking them.** The sheet lists the engine's target languages; search by
  English or native name, or by code. The languages you picked are listed
  first, also the ones the selected engine doesn't offer (for example Thai,
  picked with an AI model, while an engine without Thai is selected): they
  stay checked, marked **Not offered by this engine; kept for one that
  does**, and unchecking one removes it. **Remove all** clears every pick,
  kept ones included, and **Done** closes the sheet. With four picked (kept
  ones count), the others are greyed out: **Remove a language to pick
  another one.** The button then names the picks this engine translates
  into, for example **Also into: French, German**.
- **Results.** Each language gets a card under the translation, with buttons
  to copy it, listen to it and use it as the input (**Use the French
  translation as input**), and one to remove the language. Using a
  translation as the input replaces your text (and a source language you
  chose) and offers **Undo**. A language that failed has its own **Retry**.
- **Same engine, same rules.** The extra languages are translated with the
  same engine and translation options as the main translation, one request
  per language. They follow the main translation: while you type when
  **Instant translate** covers the engine, otherwise when you press
  **Translate**. A language you add while a translation is shown is
  translated right away. Translations of text you have since edited are
  dimmed until the new ones arrive.
- **Skipped languages.** The main target language, your source language (the
  one you chose, or the one detected) and languages the selected engine
  doesn't offer get no card; they come back once they apply again, for
  example with an engine that offers them (switching to such an engine
  translates your text into them too). Custom languages and styles can't
  be extra targets, and compare mode shows no extra targets.
- **Remembered.** Your extra languages are saved with your settings and
  come back the next time you open the app; one that the selected engine
  doesn't offer stays picked for an engine that does (see **Picking them**).
  The translations themselves are not kept: history saves the main
  translation only. Each extra translation counts as a request in
  [Usage and costs](#usage-and-costs) (unless the app already had it in
  memory).
- **Shared text and links too.** Text shared into the app or opened from a
  [link](#links) is translated into your extra languages as well whenever
  it is translated straight away: with Mozhi engines, the DeepL API,
  LibreTranslate and offline, also right after the app starts. With a paid DeepL API or
  LibreTranslate plan, each shared text is then billed once per language;
  remove the extra languages you don't need, or use **Remove all**.
- Screen readers hear which languages arrived (**Also translated into
  French, German.**) and which failed.

## Engines and compare mode

The engine button lists:

- **On this device**: [offline translation](#offline-translation), once you
  downloaded a language, and the [on-device AI](#on-device-ai) translation
  model (a memory chip icon), once installed. Without one, **Add on-device
  AI…** at the bottom of the list opens its settings on phones that can
  run it.
- **Mozhi engines** of your preferred instance: Google, DeepL, Reverso,
  Yandex, LibreTranslate, DuckDuckGo and MyMemory, whichever it offers.
- **AI models**: every enabled AI provider, with its model name.

Your own [DeepL API and LibreTranslate](ai-providers.md#deepl-and-libretranslate)
services are listed too. Each engine has a short note on what it is good
for (for example **Good for European languages** for DeepL); an AI model's
id is shown there, not on the engine button.

A badge tells you who receives your text: **On device** (offline
translation; **On this device** with a memory chip for on-device AI),
**Self-hosted** (a server on this device, your network, or a
Tor or I2P address), **Public server** (a public Mozhi or LibreTranslate
instance run by someone else) or **Cloud** (an AI provider or DeepL's API).
When every engine of a section sends text to the same kind of place, the
badge is shown once, in the section's header. After a translation, a chip
under it names the exact destination ("Google via mozhi.example.org"); tap
it to see what that party can read. See
[Privacy](privacy.md#where-your-text-goes).

**Compare mode** (**Compare engines** in **Tools** under a translation)
translates with all your engines at once and starts right away. The
current translation is the first card (**Current translation**); the
others follow in the order of the engine list, each with its time, a copy
button and **Use this** to make it the translation. Engines with the same
result share one card (**DeepL and Google agree**), and the words in which
a card differs from the current translation are highlighted. **Done**
leaves compare mode; after you edit the text, **Compare** runs it again.
Mozhi engines are sent to the instance in a single request.

## Quality modes: Fast and Best

Like Kagi Translate's Standard and Best, you can keep two engines at hand: a
quick, cheap one for everyday text and your strongest one for text that
matters.

1. Open **Settings > Translation engines > Quality modes** (or **Quality
   modes** at the bottom of the engine list) and choose a **Fast engine**
   (for example Google or DeepL through Mozhi) and a **Best engine** (for
   example your best AI model).
2. A **Fast** / **Best** toggle appears next to the engine button (on the
   start screen, a chip such as **Fast · Google**). One of the two is always
   selected; choosing the other translates the current text again with its
   engine. On narrow screens the toggle shrinks to icons or a menu.

With Fast and Best set up, the engine list starts with the two modes.
Picking an engine there (**Custom engine…** opens the whole list) makes it
the engine of the selected mode; picking the other mode's engine switches
to that mode. The translate screen remembers the mode you used last
(**Remember quality selection**, next to Quality modes; when it is off, the
app starts in Fast). A link that carries text can ask for a mode for that
text with `quality=fast` or `quality=best`; `quality=standard` means Fast
once Fast and Best are set up, and your usual engine before that. The link
doesn't change your saved mode. See [Links](#links).

## AI translation options

Open **Translation options** (the tune icon at the left of the language
bar; on wide screens under your text) to shape AI translations. On wide
windows the options open as a side sheet. The icon changes when any option
differs from the defaults. **Done**, at the top right, closes the sheet,
and **Reset to defaults**, at the bottom, clears them. Options are
remembered, and the ones in use are shown as chips right above the
language bar; remove one with its chip, or all of them with **Reset
options**.

| Option | Choices |
| --- | --- |
| Style | **Natural** (idiomatic, as a native speaker would say it) or **Literal** (close to the original wording) |
| Tone | **Formal**, **Neutral** (the default) or **Casual**; under **Advanced**, the softer **Prefer formal** and **Prefer informal** (only where it sounds natural) |
| Formality notes | Shown once a tone other than Neutral is chosen: free text such as "my boss, but we're on first-name terms" |
| Reading level | Standard, or a CEFR level from A1 (beginner) to C2 (proficient) to simplify the output for learners |
| Speaker gender / Addressee gender | Not specified, Masculine, Feminine, Neutral: for languages where grammar depends on who speaks or is spoken to |
| Context | Free text such as "a text message to my landlord" or "UI strings of a banking app" |
| Preserve formatting | Keep line breaks, Markdown, HTML tags, links, `{placeholders}`, `%s` and emoji intact (on by default) |
| Glossary | Term pairs that must always be translated the same way, e.g. product names |

Mozhi engines and LibreTranslate apply only the glossary, on the device:
its terms (whole words only, so *Bank* never matches *Bankett*; acronyms
such as *IT* and case-sensitive terms in their exact case) go to the engine
as placeholders it keeps, are replaced by your renderings and a term that
couldn't be placed is
flagged under the result. The DeepL API applies the tone, the context,
formatting and the glossary; translation-only models (TranslateGemma,
Hy-MT) and the on-device engine ignore them all. With such an engine the
sheet says so at the top and offers **Choose an AI translator** (or **Add
AI provider** when you have none), and each option the engine ignores is
greyed out with **AI engines only**, **AI engines and DeepL only** or, for
the glossary, **Not with this engine**. Your choices are kept
for when you use an AI model, and changing them doesn't translate again
with an engine that ignores them.

## Presets

**AI.** Like Kagi Translate's presets: a preset is a named set of translation
options (style, tone, reading level, genders, context and formatting)
that you apply in one tap. A few examples to start from are included, such
as *Email to colleague (formal)*, *Chat with friends (casual)* and *Simple (A2
reading level)*; edit, rename or delete them, add your own, and choose one to
apply by default.

**Glossaries** are managed next to presets and are not part of them. Each
glossary has a name, applies to a source and a target language (or to any
language), can be switched on and off, and holds term pairs ("always
translate X as Y"), optionally case-sensitive and with a private note. Presets and glossaries can be exported (copied as text or
shared as a file) and imported again, glossaries also from pasted text such as
CSV.

## Custom languages and styles

**AI.** The target does not have to be a language. Type anything into the
language search and choose **Use "…" as custom language**: *Pirate speak*,
*Shakespearean English*, *Gen Z slang*, *Plain English (explain like I am
five)*, *LinkedIn Speak*, *Corporate jargon*, *Formal business email*,
*Emoji*, or a dialect such as *Bavarian* or *Scots*. Popular ones are listed
under **Styles**: the target picker of an AI engine switches between
**Languages** and **Styles** at the top, and a search lists matching styles
after the languages. Custom targets appear in your recent languages.

The source can be custom too: type a dialect, or a style such as *LinkedIn
speak*, *Corporate jargon* or *Gen Z slang*, into the source language search
and choose **Use "…" as custom language**. For a style, the model works out
what the text really means (decoding the jargon, buzzwords and euphemisms)
and says it plainly in your target language, rather than imitating the
style.

## Refining a translation

**AI.** The refinement chips edit the translation you are looking at
instead of starting over. **More formal**, **More casual**, **Shorter** and
**Simpler** are always shown under an AI translation, after its actions;
**+** (**More refinements**) holds **More fluent**, **More literal** and
**More suggestions**. A chip you applied from that menu shows next to the
others.

- **What changed.** An applied refinement shows as a tag in the
  translation's header (**More formal ×**; the × undoes it), the words it
  changed light up for a moment, and the translation scrolls into view.
- **They stack.** Apply **Shorter**, then **More formal**, and the result is
  both. Applied chips show a check mark.
- **Opposites replace each other.** **More formal** and **More casual**
  exclude each other, as do **Shorter** and suggestions that make the text
  longer. Choosing one replaces the other (its tooltip says **Replaces
  "More casual"**); chips applied after the replaced one are dropped too.
- **Tap again to undo.** Tapping an applied chip brings back the translation
  from before it, without a new request (chips applied after it are undone
  as well).
- While a chip is working it shows a spinner; tap it to cancel. If the
  request fails, the translation stays as it was.
- **More suggestions** (in the **+** menu, which stays open while they
  load) asks the model for refinements that fit this particular text; they
  behave the same way.

Applied chips are cleared when you change the text, the languages, the
options or the engine. With a translation-only model (prompt style
TranslateGemma or Hunyuan-MT), a chip translates the text again with its
instruction instead, with nothing to stack or undo. Each refinement is one
request to the model.

## Kagi-style extras

These are in **Tools** under a finished translation (**Alternatives** and
**Explain** under **Learn**). With an AI engine they use that model; with a
Mozhi engine they use the model chosen under **Settings > AI > AI assistant
for insights**, so you can translate with DeepL and still get the extras.

- **Alternatives** unfolds other ways to translate the text, each with a
  short note on how it differs. Pick one to make it the translation. To get
  alternatives for just a phrase, select it in the translation and choose
  **Alternatives** in the selection menu.
- **Insights**: underlines the phrases where the translation made a choice:
  idioms, nuances, wordplay, cultural references, grammar and ambiguities.
  Tap one to read why, and to swap in one of the **Other ways to say it**.
  Once switched on, insights load for each translation you start; after an
  instant translation with a cloud model they switch off instead, so typing
  never starts paid insight requests.
- **Explain** opens a plain-language explanation of the translation, its
  grammar and its word choices. Ask follow-up questions in the same sheet.
- **Dictionary**: **More detail** in the panel under a translation of one
  to three words; see [Dictionary](#dictionary).

## Romanization and alignment

**Romanization.** For translations in a non-Latin script (Japanese, Chinese,
Korean, Russian, Arabic, Hindi, Greek, Thai, ...), the output can be shown in
the Latin alphabet underneath. **Romanization** (the *abc* row in **Tools**)
turns it on and off. AI models use the standard system for the language:
modified Hepburn for Japanese, Hanyu Pinyin with tone marks for Chinese,
Jyutping for Cantonese, the Revised Romanization for Korean, IAST for
Sanskrit, ISO 15919 for other Indic scripts, ALA-LC for Cyrillic and Arabic
scripts, RTGS for Thai, and so on.

It appears on its own (with **Settings > Appearance > Show romanization** on,
the default) when that costs nothing: the Mozhi engine returned a
transliteration with the translation (Google does), or the AI model for
extras runs locally. With a cloud AI model each romanization is a separate
paid request, so it waits for you to turn on **Romanization**. Once you
have, it stays on for the next translations you start; after an instant
translation it waits for you again.

**Alignment** (AI, or the on-device engine). **Matching phrases** (the ⇄ row
in **Tools**) asks the model which phrases of the input and the translation
correspond (the on-device engine knows them already). Aligned phrases are
underlined; tap a phrase of the translation (or point at it with a mouse) to
highlight it and its counterpart in the input. Moving the cursor into an
underlined phrase of the input highlights its translation. Only the first
3,000 characters of long texts are aligned, and editing the input clears the
alignment. Alignment and insights are shown one at a time, and like insights
the alignment reloads for each translation you start.

## Meaning check

**Check meaning** (the checklist row in **Tools** under a finished
translation) tells you whether the translation still says what you wrote.
It runs only when you press it, never by itself; press it again or use the
close button on the card to hide the result. Editing your text or getting a
new translation clears it.

**With an AI model for extras** (the AI model you translate with, or the one
under **Settings > AI > AI assistant for insights** while you translate with a
Mozhi engine, the DeepL API, LibreTranslate or offline), the model translates
the translation back into the language of your text, as literally as grammar
allows, and compares its meaning with your original. The **Meaning check**
card shows:

- **A verdict**: **Same meaning**, **Minor differences** (a nuance or a small
  detail) or **Meaning differs** (the translation says something else, leaves
  out or adds something important, or could mislead). Each verdict has its
  own icon, so it isn't told by colour alone.
- **The back-translation**, in the language and writing direction of your
  text.
- **The differences**, each with its kind: **Omission**, **Addition**,
  **Negation** (lost, added or misplaced), **Number** (numbers, amounts,
  dates, times, units, singular or plural), **Tense** (also mood, or who does
  what to whom), **Mistranslation** (a false friend, the wrong sense of a
  word) or **Other difference**. Each one says what differs, in the app's
  language, where it is (**In your text: …**, **In the translation: …**)
  and often gives a **Suggested wording**. Tap a difference to highlight it
  in both your text and the translation; tap it again to remove the
  highlight.

Only real differences in meaning are listed, not style, word order,
punctuation, synonyms or idioms rendered with an equivalent. Suggested
wordings are only shown, never applied for you. When the model reports
differences that can't be pinpointed in the texts, the card says so; compare
the back-translation with your text instead. Of long texts, the first 4,000
characters of each text are checked, and the card says **Only the beginning
of the text was checked.**

**Without an AI model for extras** (no AI provider, or a translation-only
model such as TranslateGemma or Hunyuan-MT as the engine), the card is
called **Back-translation**: the translation is translated back into your
text's language with the engine you are using (**Translated back with DeepL.
Compare it with your text.**), and you compare the two yourself. This needs
to know your text's language: choose the source language, or let it be
detected.

Each check is one request to the AI model, or one translation with your
engine, and is counted in [Usage and costs](#usage-and-costs); a
back-translation the app already had in memory is free and not counted.
Screen readers hear the verdict and the number of differences (or
**Back-translation ready**) when the result arrives.

## Dictionary

**AI.** Look up words and short phrases in two places:

- **Under a translation** of one to three words, in the panel with the
  other translations: **More detail** looks the word up and shows the
  **Dictionary** card in place, where you can change the **Detail level**
  (**Concise**, **Standard** or **Detailed**). **Open in Dictionary** shows
  the word on the Dictionary tab and looks it up there straight away.
- **The Dictionary tab** (**Look up a word**: *Meanings, pronunciation and
  examples from your AI provider.*): type a word or phrase in the composer
  at the bottom, which works like Translate's. Its bar holds the options
  (detail level, languages and AI model), the two languages (the word's, or
  **Detect language**, and the one of the translations) and, at the end,
  the go button (**Look up**, or Enter). The app bar shows the AI model in use (**AI model:
  …**); tap it to choose another. The search field takes the focus by
  itself only when you use a keyboard, or when the tab was opened from a
  shortcut or a link, so no keyboard pops up over the greeting.
- **The entry** keeps the search bar on top, so the next word is one edit
  away, and is split into tabs: **Meaning** (the headword, its
  pronunciation, synonyms and first definition, with a large **Listen**
  button), **Usage** (the other senses, related words, etymology and notes)
  and **Examples**. **Listen** reads the word in its language: the one you
  chose, or the one its script or the on-device engine identifies.

Entries have the pronunciation (IPA), parts of speech, senses with
translations, examples, synonyms, etymology, usage notes and **Related
words** (tap one to look it up). For a misspelled word the entry offers
**Did you mean "…"?**. Definitions are written in the app's language by the
AI model (the one under **Settings > AI > AI assistant for insights** when
you translate with a Mozhi engine) and are marked **AI-generated**.

**Offline.** With dictionaries downloaded under **Settings > Offline
languages > Dictionaries** (Wiktionary packs, one per language, checked
against the app's SHA-256), the Dictionary tab answers from them first,
without a network or an AI provider: definitions, part of speech,
pronunciation, examples, synonyms, related words, a short etymology and
translations, labelled **From Wiktionary · CC BY-SA 4.0** (tap it for the
attribution and the licence) instead of **AI-generated**. Case and accents
don't matter (`cafe` finds *café*), and an inflected form finds its lemma
(*“went” is a form of “go”*). **More detail** under such an entry asks your
AI provider for its fuller entry; a word the dictionaries don't have goes to
the AI provider as before. Without one, the tab suggests similar words of
the dictionaries, or says how to get a dictionary for the word's language.
**Import from files** on the Dictionaries screen installs packs you
downloaded by hand (`<language>.mzd`, from the links of the [pack
catalogue](dictionary-packs.md)), on Android and in the web app: matched by
name (or, renamed, by size and checksum) and checked like a download,
without any request.
The panel under a short translation shows the dictionaries' definitions
when the engine returned none, and so does the word card of a word you tap
in a translation ([Tap a word](#translate)). Details: [Offline dictionary
packs](dictionary-packs.md).

A link such as `/dictionary?word=gato&from=es&to=en` opens the Dictionary tab
with the word filled in, but never looks it up on its own: press **Look up**.

**Bookmarks.** Every look-up on the Dictionary tab that finds an entry is
saved to [History](#history-and-favorites), under the same rules as
translations (not with **Save history** off or in incognito). History keeps
the word, its languages, the AI model, the detail level and a one-line
summary (the part of speech and first definition, or else the first
translation), not the whole entry; looking the same word up again with the
same languages updates that one entry instead of adding another. The
**heart** beside **Listen** adds the word to your favorites (or takes it
out), as on History; it saves the look-up even when history is off or in
incognito, like the heart of a translation.

## Proofread

**AI.** The **Proofread** tab (**Check your writing**: *Fix grammar,
spelling and style, one suggestion at a time.*) checks grammar, spelling,
punctuation and style in any language. Its composer works like
Translate's: the options, the language (it picks the regional variety) and
the go button at the end; the app bar shows the AI model in use (**AI
model: …**).

- In the options, choose the **Style** (General, Academic, Business, Casual,
  Creative, Email), the **Correction level** (*Light*: clear mistakes only;
  *Standard*: also awkward or unclear phrasing; *Comprehensive*: a thorough
  polish of wording, flow and tone), **Formality**, the **Model**, and
  optionally add **Context** such as "cover letter for a job application".
- **Reading level**: **As written** keeps the author's level; a CEFR level
  from A1 to C2 rewords the text for readers at that level.
- **Variety**: **As written** keeps the author's spelling and vocabulary; or
  convert to a regional variety: English (UK, US, Australia, Canada),
  Portuguese (Brazil, Portugal), Spanish (Spain, Latin America), French
  (France, Canada) or German (Germany, Switzerland, Austria). It applies to
  text in that language.
- The result shows the **Corrected text**, with **Copy corrected text** as
  the main button; the eye button (**Show changes** / **Hide changes**)
  highlights what changed. Each **suggested edit** has a category (grammar,
  spelling, punctuation, style, clarity, word choice, tone, repetition) and
  an explanation, and its own **Accept** (✓) and **Reject** (✕) buttons;
  after you reject one, **Reset** applies every suggestion again. Once there
  is a result, your text shrinks to make room for it.
- **Writing statistics** compares the original and the corrected text:
  words, characters, sentences, paragraphs, words per sentence and reading
  time, plus the **Flesch reading ease** score (0 to 100, higher is easier)
  for English text. They are calculated on the device.
- **Use as input** continues from the corrected text. Ctrl+Enter runs the
  check. A link such as `/proofread?text=...` fills in the text without
  checking it.

## Image translation

Translate text in photos and screenshots: tap **Camera** on the start screen
(or the camera button in the text box), take a picture or pick one from your
gallery, then choose how to translate it. The methods are offered in this
order:

- **On-device text recognition** (Android, recommended and selected by
  default): the open-source Tesseract engine reads the text on the phone
  (the photo is not sent anywhere), and the text is then translated with
  your current engine. Each language's data (most are 1 to 4 MB) is
  downloaded once when you ask (**Download German text recognition**) or
  imported from files; see [Text recognition](text-recognition.md). With
  **Detect language**, text that was hard to read gets a **Wrong language?
  Choose the language of the text** hint. The
  [Play variant](contributing.md#build-variants) uses Google's ML Kit
  instead.

  The translation is then **drawn over the photo**, in place of the
  original text, like a camera translator: each paragraph's area is filled
  with the colour around it and the translation is written in it, sized to
  fit, in the text's own colour (or black or white, whichever reads
  better), right to left for Arabic or Hebrew. Pinch to zoom and drag to
  pan; tap a paragraph to see the original and the translation and copy
  either; press and hold **Original** to look at the photo without the
  overlay. **Overlay | Text** above the photo switches to the plain photo
  with the recognised text (which you can correct and translate again)
  and the translation below it; your choice is kept for the next photos.
  **Share image** and **Save image** make a PNG of the photo with the
  translation, at the photo's resolution (at most 4096 px on its long
  side), on the phone; nothing is uploaded. All the paragraphs of a photo
  are translated in one request, so a cloud engine gets no more requests
  than before. Screen readers read each paragraph as its translation, with
  the original as hint.
- **AI vision**: an AI model with **Supports images** turned on reads and
  translates the text itself, with your translation options. One choice per
  such model.
- **Mozhi via Google Translate (experimental)**: when your instance offers
  Google, Mozhi passes the photo on to Google Translate's image translation
  and returns the recognised text, its translation and a copy of the image
  with the translation drawn in. This relies on an unofficial Google
  interface that often refuses such requests (Mozhi then answers with
  nothing, shown as **Google Translate sent nothing back**), so it is
  offered last. When it fails, **Use on-device text recognition** reads the
  photo on the phone instead.

The method you choose is remembered for next time. A photo you took just as
Android closed the app to free memory for the camera opens on the image
screen when you come back. To translate as you point the camera, without
taking a photo first, use the [live camera](#live-camera).

Before a photo is uploaded (AI vision, Mozhi) it is re-encoded without its
metadata and scaled down to at most 1600 px on its longest side and about
1.5 MB. Mozhi gets up to 90 seconds to answer. A photo is sent to at most
two of your instances (after a time-out, to no other), and when a proxy in
front of the instance turns the upload down as too large, a smaller copy
(about 900 KB) is sent once more. Language codes are mapped to Google's own
(`zh-CN`, `zh-TW`, `iw`, ...), and a language Google does not offer is
reported before anything is uploaded.

## Live camera

Point the camera at text and see it translated over the camera picture as
you go, like a camera translator, on the phone (Android). **Live camera**
is on the image screen (and in its toolbar while a photo is shown):

- **The camera permission** is asked the first time you open it, by
  Android's own dialog. When you refused it for good (**Don't ask again**),
  **Open settings** takes you to Mozhi's page in Android's settings, and
  coming back checks again.
- **On-device reading.** The back camera's picture is read by the same
  on-device text recognition as photos (Tesseract, see
  [Text recognition](text-recognition.md)), in the language at the top
  left; **Detect language** reads with the languages you installed (up to
  three, your recent ones first). Missing language data is offered for
  download or import, as on the image screen, and **Choose the language of
  the text** is always at hand.
- **Steady translations.** Each paragraph is followed from one frame to the
  next, so its box holds still while the camera moves a little, and it is
  translated once: only new or changed text is translated again (a reading
  that differs by a letter or two is taken for the same text), and text
  seen before is translated from memory. New paragraphs of a frame go to
  the engine in one request. The translations are drawn like the photo
  overlay: each paragraph's area is filled with the colour around it and the
  translation fitted in, right to left for Arabic or Hebrew; text still
  being read shows as a thin outline.
- **Translate live with** (the chip under the languages) chooses the engine
  of the live features (also [Live captions](#live-captions)): the offline
  engine by default, an on-device AI model, or any other engine you set up.
  An engine that sends text off the phone asks once first, saying it will
  get the text of everything live translation reads, as it comes in; your
  privacy mode and consent prompts still apply on top.
- **Gentle on the phone.** One frame is read at a time (the next is taken
  once the last one is done, at most about three a second), less often
  while the phone is hot or saving battery. The camera stops while Mozhi is
  in the background, while the app lock is locked and while the phone is
  critically hot, and goes on by itself afterwards.
- **Flashlight, zoom, Freeze.** The flashlight button lights the text up;
  the zoom button steps through 1×, 2×, 4× and back (as far as the camera
  goes), or pinch the picture. **Freeze** takes a photo and opens it on the
  image screen, translated with on-device text recognition, with the full
  photo overlay: zoom, tap a paragraph for both texts, share or save the
  image. **Close** goes back to the image screen.
- **Accessible.** Every button has a label and a 48 dp target. Screen
  readers find each translation where it is drawn, with the original as
  hint. The status line under the picture is a live region that speaks only
  when the status changes (paused, slower, the engine), never for every
  frame.
- **Private.** The camera picture never leaves the phone and is never
  stored: frames are read in memory and dropped. Only the recognised text
  goes to the live engine. A link (`mozhi://image/live`) opens the image
  screen, never the camera. See [Privacy](privacy.md#screen-keyboard-and-clipboard).

Live camera needs the Android app (it uses Android's own Camera2 interface,
no Google code); the web app doesn't offer it.

## Voice

- **Dictation**: tap the microphone and speak instead of typing. By default
  speech recognition is provided by your device's operating system (or
  browser); on Android 12+ **Prefer on-device speech recognition** asks it
  to keep the audio on the phone. On Android you can instead choose
  **Offline (Whisper)** in **Settings > Read aloud & voice > Voice input**:
  OpenAI's Whisper model (Fast, 75 MB, or Better, 142 MB, downloaded from
  Hugging Face or imported from a file) recognises 99 languages on the
  phone, so your voice never leaves it. **Offline only** always uses Whisper (see
  [Voice input](voice-input.md)). A small speech detector (Silero VAD,
  0.9 MB, downloaded with the model) tells speech from noise, so Whisper
  writes each phrase down as soon as you pause, while you go on speaking,
  and a recording may last a minute.
- **Conversation** (a tab of its own): two people, two languages. Each
  person speaks or types in turn and hears or reads the other's words in
  their own language. While the conversation is empty, a large microphone
  (*Let's talk!*) dictates in the first language of the pair; the pair sits
  in one pill above the two input fields (tap a language to change it, the
  arrows to swap). **Face to face** (the two-people button) turns the screen
  into two halves, the far one upside down, and covers the tabs; back
  returns to the tab. With Whisper and its speech detector, each phrase is
  transcribed while the person goes on speaking, so the translation follows
  sooner after they stop, and a turn ends at a real pause (0.8 s of
  silence by default) instead of after 3 seconds. **Detect the speaker**
  (on by default) lets whoever speaks take the turn: the side whose
  language Whisper hears translates next; off, the person whose turn it is
  speaks and Whisper listens in their language only. Both are in the
  menu's **Voice options**, with the pause (0.5 to 2 s; longer lets people
  think mid-sentence). With the system recogniser the turns work as before
  (it ends them itself). The menu's **Transcribe a talk** opens [Transcribe](#transcribe).
  On Android, the menu's **Share on this network** lets everyone else
  follow on their own phone, in their own language
  ([Shared conversation](#shared-conversation)).
- **Device voices**: besides your Mozhi instance's voices, the app can read
  text aloud with the device's built-in text-to-speech voices, with a speech
  rate and a voice per language of your choice (see
  [Text-to-speech](#text-to-speech)).

## Shared conversation

On Android, **Share on this network** (the Conversation tab's menu) lets
everyone in the room read the conversation in their own language on their
own phone, with no app to install and no server: your phone serves a small
page on the local network, and guests on the same Wi-Fi (or on your phone's
hotspot) scan its QR code, or open the link, in their browser.

- **Guests** pick their language from your engine's list (and enter the
  4-digit PIN, which is asked for unless you switch it off). Each message
  appears in their language in large type, with the original beneath it,
  light or dark as their phone is set; new messages are announced to
  screen readers. They can reply by typing: the reply becomes a message of
  the conversation ("Guest 2"), translated for you and read aloud when
  **Read translations aloud** is on (switch **Guests can reply** off to
  stop replies). The page speaks the guest's language when Mozhi does. It
  has no microphone: browsers send speech to their maker to recognise it.
- **Translation:** guests reading one of the conversation's two languages
  see its own translations. Any other language is translated once for all
  its guests by your engine, under your privacy settings: a pair your
  settings would ask about is translated on the phone (the offline engine)
  when it can, and otherwise waits for your OK on the sharing page (one
  language pair at a time), while its guests read the original. In
  **Offline only** only the phone translates. A guest can never make your
  phone send text anywhere you haven't allowed, and a **Once** you give
  there covers just the messages waiting for it. Each extra language is
  one more request per message to your engine (counted in
  [Usage](#usage-and-costs) for your own keys), for the messages guests
  can see only and only while a guest reads it: when its last guest
  leaves or switches, what was still to translate is dropped (the
  finished translations stay for 5 minutes, so coming back costs
  nothing). Guests can read up to 4 languages besides the conversation's
  two at a time; a language keeps its place for those 5 minutes, and a
  guest asking for one more is told which ones they can pick. The sharing
  page lists each language and how many messages are still to translate.
- **What guests see:** what is said after you start sharing (the last 100
  messages), nothing from before, from your history or anywhere else.
- **The sharing page** shows the QR code, the link (with **Copy link**),
  the PIN (switch it off and on for a new one), the guests and their
  languages, and **Stop sharing**; from 840 dp the code sits beside the
  rest. Back on the conversation, a bar says it is shared and how many
  guests follow, with **Show code** and Stop. The screen stays on while you
  share, also in face-to-face mode.
- **It stops** when you tap **Stop sharing**, leave the conversation
  (another tab or screen), or the app stays in the background (the phone
  locked) for 2 minutes. Guests then see *The conversation ended*.
- **Limits:** 8 guests at a time and 20 joins a minute; 4 other
  languages at a time; replies of up to 500 characters, at most one every
  2 seconds and 12 a minute per phone (also after leaving and joining
  again) and 20 a minute from all guests together; after 20 wrong PINs
  nobody new can join until you set a new PIN. A guest's page that stops
  taking in updates for 20 seconds is disconnected and connects again by
  itself.
- **Privacy:** only devices on the local network can open the page, but it
  is plain `http` (a phone has no certificate browsers trust), so other
  devices on the same Wi-Fi could read along. Avoid public Wi-Fi for
  sensitive talk; your phone's hotspot is best. See
  [Privacy](privacy.md#shared-conversation) and
  [Security](security.md#shared-conversation).
- Not in the web app: a browser cannot host the page.

## Transcribe

For a lecture, a guided tour or a meeting: **Transcribe** (in the
translate screen's **More tools** menu and the Conversation tab's menu)
listens for as long as you like and writes down what it hears, one
paragraph per phrase with its time (`1:05`), as a rolling transcript.

- **Start**, **Pause** (resume continues the same transcript and its time
  line, pauses left out) and **Stop**. The screen stays on while Mozhi
  listens; it only listens while it is on screen, so switching apps or
  turning the screen off pauses it.
- **What hears**: on Android, offline Whisper (the speech model of
  [Voice input](voice-input.md)), so the speech stays on the phone, also
  when voice input is set to the system recogniser (it stops after every
  pause and cannot transcribe a talk). Without a model, Transcribe says so
  and opens the voice input settings to get one. With the speech detector
  (0.9 MB, offered on the screen when it is missing) phrases end at real
  pauses; without it, loudness decides, which noise can fool. When
  transcription falls behind (the Better model on a slow phone), speech is
  skipped rather than piling up, and the transcript says so. In the web
  app, the browser's own speech recognition listens continuously where it
  can; the screen says that it may send the audio to the browser's maker
  (Chrome to Google), and in **Offline only** Transcribe is off there.
- **Translation** is off until you turn on **Translate**: then each phrase
  (and the transcript so far) is translated into the language you choose,
  with the translate screen's engine and options, one phrase at a time.
  The screen says where the phrases go ("Each phrase is sent to DeepL to be
  translated", or translated on this device), and the usual privacy rules
  apply: a phrase that needs your OK waits for it in the transcript; in
  **Offline only** the on-device engine translates. From 840 dp the
  translation sits beside each phrase.
- **Copy**, **Share**, **Save as text (.txt)** and **Save as subtitles
  (.srt)** (times from the transcript, the translation as a second line);
  **Save to History** saves the transcript as one entry, only when you ask
  (as a favourite while history is paused). Nothing is saved otherwise:
  the transcript is gone when you leave the screen.
- **Caption other apps** (the closed-caption button, Android 10 and
  later) opens [Live captions](#live-captions): the same on-device
  transcription for the sound other apps play.

## Live captions

Translated captions of what your phone plays: a video, a podcast, a call
in an app that allows it. Open **Transcribe > Caption other apps**
(Android 10 and later) and tap **Start captions**.

- **What is captured.** Only the sound other apps play (media, games and
  other sound; Android never lets apps capture phone calls or the sound of
  apps that opt out, and many streaming and calling apps do), never the
  screen. Android asks every time whether Mozhi may capture (it calls this
  "recording or casting"); the first time Mozhi also asks for the
  microphone permission, which Android requires for capturing other apps'
  sound (the microphone itself is not used), and, on Android 13 and
  later, for notifications.
- **On the phone.** Whisper (the speech model of
  [Voice input](voice-input.md); without one, the screen offers to
  download it) writes each phrase down on the phone as soon as there is a
  pause (with the speech detector) or at most every 8 seconds, so the
  captions keep up with speech and music that never pause. **Sound:
  Detect language** lets Whisper tell the language phrase by phrase (the
  screen shows what it heard), or pick it. A phrase already in the
  captions' language is shown as it is.
- **Translation** uses the live engine (**Translate live with**, the
  engine chip; the same choice as the live camera): the offline engine
  unless you picked another, and a network engine asks once before it
  gets the text of everything the captions hear. One phrase at a time, in
  order; when phrases come faster than they translate, older ones are
  skipped so the captions stay current.
- **The caption bar** floats over the app you watch: the translation in
  large text, the original smaller below it (**Show the original on the
  caption bar** turns it off), **Open** (back to Mozhi) and **Stop**. Drag
  it up or down; it remembers where. It follows the system font size,
  never takes the keyboard from the app below, and hides while Mozhi is
  on screen and while the phone is locked. It needs **Display over other
  apps**, which Mozhi explains and opens before the first start; without
  it, the captions show on Mozhi's screen only. A notification with
  **Stop** shows while captions run.
- **In Mozhi** the captions are a transcript (time, original,
  translation; side by side from 840 dp), with Copy, Share, **Save as
  text (.txt)**, **Save as subtitles (.srt)** and **Save to History** in
  the menu, only when you ask. Nothing is kept otherwise: the transcript
  goes when you leave the screen.
- **When nothing is heard** for 20 seconds, the screen and the bar say
  that the app playing may not allow capturing its sound (or nothing
  plays). Captions pause while the phone is locked (the recording stops:
  nothing is captured) and, on-device work being heavy, while the phone is
  hot; they go on by themselves afterwards (if the recording can't start
  again after the lock, the captions end). They keep running while you use other apps, and
  stop with **Stop** (in Mozhi, on the bar or in the notification), when
  you leave the captions screen, or when Android ends the capture (the
  status bar's cast or record icon). Screen readers hear when captions
  start, stop and pause, not every caption.
- See [Privacy](privacy.md#on-your-device) and
  [Security](security.md#live-captions-android). Not in the web app.

## Documents

Translate whole files instead of copying them piece by piece: tap **Document**
on the start screen (or **More tools > Documents** in the ⋮ menu), open a file
(or paste its content), translate it with any engine, then save or share the
result. Supported formats:

| Format | Extensions | What is kept |
| --- | --- | --- |
| Plain text | `.txt` | Paragraphs (translated one by one) |
| Markdown | `.md`, `.markdown` | Markup, code, inline code and URLs stay verbatim |
| SubRip subtitles | `.srt` | Numbering and timestamps |
| WebVTT subtitles | `.vtt` | Header, notes, styles, timings and cue settings |
| JSON / ARB string tables | `.json`, `.arb` | Keys, `@` metadata and ICU placeholders/plurals; only string values are translated |
| HTML and XHTML pages | `.html`, `.htm`, `.xhtml` | Markup, attributes, scripts, styles, code and `pre`; text, the title, `alt`/`title`/`placeholder`/`aria-label` and meta descriptions are translated |
| XLIFF 1.2 and 2.x | `.xlf`, `.xliff` | Sources, notes, IDs and inline codes; sources are translated into targets |
| Android string resources | `strings.xml` | Names, `translatable="false"`, `<xliff:g>`, styling tags, escapes and format arguments; strings, string arrays and plurals are translated |
| Gettext catalogues | `.po`, `.pot` | Header, comments, references, flags, contexts and placeholders; `msgid`s are translated into `msgstr`s |
| CSV and TSV tables | `.csv`, `.tsv`, `.tab` | Quoting, the header row, and columns of numbers, dates, URLs, e-mail addresses and IDs |
| Apple strings | `.strings` | Keys, comments, escapes and format specifiers; values are translated |
| Xcode string catalogues | `.xcstrings` | Every other language, comments, extraction state and variations; the target language is added |
| Word documents | `.docx` | Paragraph and character formatting, styles, lists, tables, headers and footers, footnotes, endnotes, comments, text boxes, links, fields, images and tracked changes |
| PowerPoint presentations | `.pptx` | Slides, speaker notes, tables, text boxes, chart titles and SmartArt with their formatting, links and slide numbers; layouts, images and animations |
| Excel workbooks | `.xlsx` | Text cells (plain and rich text, each distinct text translated once); numbers, dates, formulas, sheet names and charts' data |
| OpenDocument text, presentations, spreadsheets | `.odt`, `.odp`, `.ods` | Headings, paragraphs, lists, tables, spans, links, notes, frames, headers and footers; spreadsheet cells with numbers, dates or formulas |
| EPUB e-books | `.epub` | Every chapter in reading order, the table of contents and the title; inline markup, links, images, code, scripts, styles and `pre` blocks |
| PDF documents (Android) | `.pdf` | Every page as it looks, with the translation written over the original text as real text; pages without text as they are (see [PDF documents](#pdf-documents)) |

Documents are split into parts that are translated a couple at a time, with
progress shown as they finish; failed parts are retried.

### Office documents and e-books

Word, PowerPoint, Excel, OpenDocument and EPUB files are translated in
place: **Save file** and **Share file** give back the same kind of file
(`report.docx` becomes `report.de.docx`) with its layout, styles, images and
everything else as it was; only the text changes. Like the other formats,
they are translated with the engine and privacy mode you choose.

- **Formatting inside a paragraph** (bold words, a link, a footnote mark, an
  image in the text) travels with the text as numbered placeholders
  (`⟨1⟩`), so it stays on the right words even when the translation puts
  them in another order. If an engine drops a placeholder, kept content
  such as an image, a note or a field is put at the end of the paragraph
  instead of being lost.
- **Text that appears several times** (a footer on every slide, a value
  repeated in a spreadsheet, a text box Word stores twice) is translated
  once.
- **The language** of the document is set to the target where the file
  records one (Word's and PowerPoint's text language, which the spelling
  checker uses; OpenDocument's styles; the e-book's language). Custom AI
  "languages" leave it as it was.
- **The preview** shows the text only (the saved file keeps the layout).
  Office files can't be pasted, their format can't be changed, and there is
  no bilingual export.
- **Macros** (VBA projects, ActiveX controls, Excel 4 macro sheets,
  OpenDocument Basic and scripts) are neither translated nor run: the
  translated file keeps them as they are, and the page says so when a
  document has some.
- **Limits:** office files and e-books up to 25 MB (text files up to 2 MB);
  on Android, files from 64 KB on are read in the background. Not opened:
  password-protected or encrypted files (remove the protection first),
  e-books with DRM (fonts that are only obfuscated are fine), old `.doc`,
  `.xls` and `.ppt` files renamed to the new extensions, damaged files,
  files that unpack to far too much data, and ZIP files with symbolic
  links or overlapping entries (see
  [Security](security.md#documents-and-e-books)).
- **Not translated:** text in images, alternative text, spreadsheet
  comments, sheet names, the data behind charts, slide master and layout
  prompts, and document properties other than the e-book's title. In a
  spreadsheet, formulas that compare cells with a text (`=IF(A1="Yes";…)`)
  may need the translated word.

### PDF documents

On Android, PDFs are translated page by page on the phone: each page is
drawn (with Android's own PDF renderer), its text is read with on-device
text recognition (the same Tesseract data as photos: the source language's,
or for **Detect language** the languages you use most), its paragraphs are
translated with the engine you chose, like any document, and the
translation is written back where the original text was.

- **Open:** pick a `.pdf` or share one to Mozhi. A file that is a PDF is
  read as one whatever its name says. The page count is shown, and the
  first page is read right away so you see what was recognised; the other
  pages are read when you translate. If the source language's recognition
  data is missing, the page offers to download it (or import it from files)
  and never downloads it by itself.
- **Progress** goes page by page ("Page 3 of 12: reading the text…", then
  "translating…"); **Cancel** keeps the pages that are done. A page that
  can't be read or translated is listed with a retry; the rest go on.
  On-device AI pauses while the phone is hot or saving battery, as for other
  documents.
- **Save file** / **Share file** give `<name>.<target>.pdf`: every page is
  the original page as a picture, each translated paragraph's area is
  covered in the colour around it, and the translation is drawn there as
  real text in the colour of the original text, aligned like it and written
  in the target language's direction. It can be selected, searched, copied
  and read aloud. Translations that are longer than the original are drawn
  smaller, down to 6 pt; one that does not fit even then runs on below its
  box rather than becoming unreadable. Pages without text, and paragraphs
  that were not translated, are kept as they are.
- **Save the text** saves the translation as plain text, page by page
  (`<name>.<target>.txt`); **Copy text** copies it.
- **Limits:** PDFs up to 25 MB and 200 pages; pages are read at up to
  300 dpi and 8 megapixels. Password-protected PDFs aren't opened (remove
  the password first, for example by printing to a new PDF), nor damaged
  ones; a PDF with no text that can be recognised says so.
- **What to expect:** the original's own text becomes part of the page
  picture (Android can't edit PDFs in place), so the translated file is
  usually larger than the original, and in long documents the pages are
  stored at a lower resolution (150 dpi for short ones, less from about 15
  pages on) so that the whole file can be written on the phone. Text in a
  photo or a drawing is read and translated like any other text; very
  unsure readings (patterns, textures) are left as they are.
- **The web app** lists PDFs as needing the Android app: they can't be read
  in a browser.

### Localisation files and web pages

Translators' and developers' files come back in the same format, ready to
use: only natural-language text changes, and a file that is not translated
(or whose translations are all left out) is written back byte for byte,
with its line endings, byte order mark, indentation and comments.

- **Placeholders stay intact.** printf conversions (`%s`, `%1$d`, `%.2f`,
  `%lld`, `%@`, `%%`), Apple substitutions (`%#@files@`), `{name}` and
  `{0}`, `{{mustache}}` and `${name}`, Qt's `%1`, ICU plurals and selects,
  inline tags (`<b>`, `<a>`, `<xliff:g>`, XLIFF's `<g>`, `<x/>`, `<ph>`,
  `<pc>`), escapes such as `\n`, URLs and e-mail addresses become
  numbered placeholders (`⟨1⟩`) that engines must keep. Inline tags an
  engine reorders or drops are put back so that the file stays
  well-formed.
- **Escaping is done for you.** Translations are written with the format's
  own escaping: `&amp;` and `&lt;` in HTML and XML, `\'` and `\"` in Android
  strings, `\"` in PO and `.strings`, doubled quotes in CSV. In a format
  string (one with `%s`-style arguments) a literal `%` becomes `%%`; a
  translated Android string that starts with `@` or `?` is escaped.
- **Bilingual files keep their translations.** XLIFF, PO and `.xcstrings`
  get translations only where they are missing (an empty `<target>` or
  `msgstr`, an XLIFF 1.2 target that is `new` or `needs-translation`, an
  XLIFF 2 segment that is `initial`, an `.xcstrings` localisation that is
  `new`); when the file belongs to another target language (`Language:`,
  `target-language`, `trgLang`), everything is translated again.
- **The target language is recorded:** XLIFF's `target-language` /
  `trgLang`, PO's `Language:` header, the new `.xcstrings` localisation and
  `<html lang>` (with `dir="rtl"` for right-to-left languages). This happens
  only once something is translated; custom AI "languages" are never
  written into a file. A legacy charset declaration (`ISO-8859-1`,
  `windows-1252`) becomes UTF-8, since translations are written as Unicode.
- **Review states:** new XLIFF 1.2 targets are marked
  `needs-review-translation`, XLIFF 2 segments `translated`, and new
  `.xcstrings` string units `needs_review`, so translators can find
  machine translations. PO entries are not marked `fuzzy` (gettext would
  ignore them); an untranslated entry that was `fuzzy` loses the flag once
  it is translated.
- **Skipped:** anything marked not to translate (`translatable="false"`,
  `translate="no"`, `class="notranslate"`, `"shouldTranslate" : false`),
  resource references (`@string/name`), the PO header, obsolete `#~`
  entries, and values that are not words (numbers, identifiers such as
  `snake_case`, paths, colours).
- **HTML:** each block (paragraph, heading, list item, cell, button,
  option…) is one piece of text, with its inline elements as placeholders.
  Scripts, styles, templates, `<code>`, `<pre>`, `<kbd>`, `<svg>`, comments
  (also conditional comments) and form text areas are kept, and so are
  attributes other than `alt`, `title`, `placeholder`, `aria-label`,
  `aria-description`, the value of `<input>` buttons and `<meta>`
  descriptions.
- **Plurals:** PO entries get every `msgstr[n]` of the plural rule:
  the header's `Plural-Forms`, or, for a template or a catalogue moved to
  another language, the target language's rule (written into the header).
  The form for one item gets the singular translation and all others the
  plural one, so languages with several plural forms (Russian, Arabic…)
  need a review. `.xcstrings` plurals follow the target language's
  categories (a missing one is filled from `other`). Android `<plurals>`
  keep the source quantities: add `few`/`many` items by hand where the
  target language needs them.
- **CSV and TSV:** fields may be quoted (RFC 4180, also with line breaks);
  a CSV file may use `;` or tabs instead of commas. The first row is kept
  as a header when the file has at least two rows and every cell of the
  first row is a short, distinct label (at most 4 words or 40 characters,
  no sentence punctuation, not a number, date, URL or e-mail address); in
  a one-column file the label must also look like a column name (`text`,
  `source_text`, `English`). A column is kept as it is when at least 80% of
  its filled cells are numbers, dates, times, URLs, e-mail addresses,
  `true`/`false`/`null` or identifiers (`snake_case`, `SKU-123`, UUIDs), or
  when it repeats a handful of one-word codes (at least 4 filled cells, at
  most half of them different); only cells of up to 256 characters count
  as such values. In the other columns every cell with words is
  translated; formulas (`=SUM(A1:A3)`) stay as they are. A translation
  that a spreadsheet would read as a formula (one that starts with `=`,
  `+`, `-`, `@`, their full-width forms `＝＋－＠`, a tab or a carriage
  return) gets a `'` in front, so that
  it shows as text and can't run anything (see
  [Security](security.md#localisation-files-and-web-pages)); cells whose
  original starts that way already are left alone. To fill a language
  column of a translation table, copy the source column into it first.
- **Pasting:** HTML, XLIFF, Android strings, PO catalogues, Xcode string
  catalogues, `.strings` files and cells copied from a spreadsheet (TSV)
  are recognised when pasted; choose **CSV** yourself.
- **Limits:** a translation identical to the original (a name, "OK") is
  left out of bilingual files, which then use the source text anyway.
  XLIFF targets are written as whole sentences, without the `<mrk>`
  segmentation of a `<seg-source>`. XML files that declare entities in a
  document type declaration, and `.strings` files in property-list format,
  can't be opened. Legacy-charset files are always written back as UTF-8.

## Web pages

**More tools > Web page** (in the ⋮ menu) translates an article or a blog
post: enter its address and press **Translate page**. Mozhi downloads the
page, keeps only the readable text and translates it part by part with the
engine and languages you choose. Switch between **Translation**, **Original**
and **Side by side**, **Copy all** of it, or **Open original page** in your
browser. Very large pages are cut after their first part.

In the web app this only works for sites that allow cross-origin requests
(CORS), and most don't; use the Android app for those.

## Offline translation

On Android and in the web app, Mozhi can translate without any network
with Mozilla's **Bergamot** engine and the **Firefox Translations** models
(MPL-2.0), the ones Firefox uses for its built-in translation: about 55
languages, each to and from English, and between other languages through
English. In **Settings > Translation engines > Offline languages** (or with the
download button in the [language picker](#languages-and-detection)), download
the languages you need once (about 50 MB to download and 73 MB on disk each;
English is built in), update them when a newer model is out, and delete them
when you no longer need them. With **Download over Wi-Fi only** on (the
default), Mozhi asks before using mobile data or a metered network. Models are
checked against bundled checksums before use; none of your text is sent.

**Where models come from** (**Settings > Translation engines > Model source**,
also on the Offline languages screen, for offline languages, voice input and
text recognition alike): the **Original publishers** (Mozilla's storage at
`storage.googleapis.com`, GitHub and Hugging Face; the Android default),
**This web server** (a copy next to the web app; the web app's default, since
Mozilla's storage doesn't let other websites download from it) or a **Custom
mirror** (your server, a computer on your network or a `.onion` address),
optionally falling back to the publishers when the mirror lacks a file. A
mirror can't change a file: each one is checked against the fingerprint built
into Mozhi. How to set one up: [Mirror the on-device
models](self-hosting-mozhi.md#mirror-the-on-device-models).

To keep the Android app from contacting any server at all (for example in
**Offline only**), tap a language to copy the links of its files, download
them on another device, copy them to the phone and use **Import from files**
([details](offline-engine.md#import-models-without-the-app-downloading-them)).
After that, translation runs entirely on the device, and results are marked
**Offline**. Quality is below the best online engines, but it works on a plane
and nothing leaves the device.

**In the web app** the engine runs as WebAssembly in a background worker of
the browser, and the models are kept in the browser's private storage for this
site (they stay after a reload and are removed with the site's data). It
needs a recent browser (Chrome or Edge 102, Firefox 125, Safari 16.4 or
later), `https` (or `localhost`) and the site's storage (Firefox's private
windows have none); the Offline languages screen says what is missing. It is slower than on Android (about 120 to 150 words a
second on a desktop computer). **Import from files** works there too: tap a
language for the links of its files, download them (in the browser or on
another device), then pick them under **Import from files**; they are read
in the browser, checked against the bundled checksums like downloads (by
name, or renamed by size and checksum, published or decompressed) and kept
in its private storage, without any request.

### The web app with no network

Once you have opened the web app, it opens again with no network at all:
with **Settings > General > Keep the web app for offline use** on (the
default; web app only), the browser keeps the app's own files (about 35 MB,
plus the fonts of the scripts you see), and with offline languages
downloaded or imported it also translates offline. The switch says where
the copy is (**Saving the app in this browser…**, **Opens in this browser
without a network**, or that the browser can't keep it: that needs `https`
or `localhost`). When the server has a new version, the app keeps it in the
background and says **Update ready** with **Reload**; the settings offer
**Reload** too, and otherwise the new version starts the next time every tab
of the app was closed. Turning the switch off removes the copy. Hosting it
needs two headers ([Serve the web app](self-hosting-mozhi.md#serve-the-web-app)).

## On-device AI

On Android, AI models can run on the phone itself: AI translation and
every AI extra without a network, and your text never leaves the device
(details: [On-device AI](on-device-ai.md)).

- **Models** (**Settings > AI > On-device AI**, also linked from
  **Translation engines** and **Offline languages**): **Hy-MT2 1.8B**
  (Tencent, Apache-2.0) translates between 33 languages; **Gemma 4 E2B**
  or the smaller **Qwen3 1.7B** (both Apache-2.0) write the extras
  (refine, alternatives, insights, dictionary, explain, proofread, meaning
  check). Each shows its size (about 1 to 3 GB), licence, languages and
  whether it fits your phone (**Fits this phone**, **May be slow on this
  phone**, **Needs more memory**). Downloads only start when you tap one,
  when the phone has room for them (**Not enough free space: needs …**
  otherwise), over Wi-Fi unless you allow mobile data, from your
  [model source](#offline-translation), and are checked before use (in
  the background); or **Import from a file** without any network (read
  where it is and copied once into place). The page names the engine
  build for this processor, for support.
- **Using it:** the translation model is an engine under **On this
  device**; results show **On this device** with a memory chip, no
  consent is asked, and it works in **Offline only**. The first request
  after a pause loads the model: **Loading the on-device model…** with
  **Cancel**, then the text streams in; the AI extras say so too while
  they wait for it. A sentence takes a few seconds on a mid-range phone,
  about a second or two on a flagship.
- **Battery and heat:** while the phone is hot or battery saver is on,
  typing doesn't start on-device AI; a line under the text says why, and
  **Enter** or **Translate** still translate. A long text, document or
  web page already under way pauses before its next part (**Paused while
  the phone cools down**, with **Continue anyway** and **Cancel**) and
  goes on once the phone has cooled down. The model is freed after 2
  minutes without use, in the background and when memory runs low.
- **First run:** on a phone that can run a model and has no AI provider,
  the translate screen offers it once (**See models**, **Not now**,
  **Don't show again**); it never downloads by itself.
- Not in the web app yet (shown as unavailable there).

## History and favorites

- Every translation is saved on the device (unless you turn off
  **Settings > Privacy & data > Save history**). When the same text is
  translated again into the same language with the same engine, for example
  after a refinement or after picking an alternative, the newest entry is
  updated instead of duplicated. Only the main translation is saved, not the
  translations into [extra target languages](#extra-target-languages).
- [Dictionary](#dictionary) look-ups are saved too, as entries marked
  **Dictionary** (a book icon): the word, its languages and a one-line
  summary of the entry. Looking a word up again with the same languages
  updates its entry and moves it to the top. Look-ups never count as
  earlier translations ("From your history").
- **History** (the clock button at the top of every tab, or Ctrl+Shift+H)
  has two tabs, **All** and **Favorites**, groups entries by day and
  searches the text, the translation and the language names (for look-ups:
  the word and its summary); matches are highlighted.
- **Rows** are compact, about ten to a phone screen: your text, the
  translation under it, a language tag such as **EN → FR**, the heart, and
  **More actions** (⋮, or a long press on the row) with **Copy**,
  **Share**, **Details** and **Delete**. With a mouse, Copy, Share and
  Delete also appear on the row you point at. **Details** shows the whole
  text and translation, the engine and the time: in a sheet on phones, and
  beside the list on wide screens, where tapping a row selects it.
- **Filters.** Below the search, **All language pairs** narrows the list to
  one pair (each with its number of entries; a detected source counts as
  the language it was detected as), and the **On device**, **Self-hosted**,
  **Public server** and **Cloud** chips to where the text was translated
  (only those that occur in your history are shown). Mozhi entries are
  classed by your current preferred instance, since an entry doesn't record
  which instance answered; AI translations and look-ups by the AI model
  that wrote them (a model on this phone is **On device**, a local model
  **Self-hosted**, other providers **Cloud**). **Clear filters** shows
  everything again.
- **Opening an entry.** Tap a translation to open it in the translator (on
  wide screens: from its details), or a look-up to open the Dictionary tab,
  which looks the word up again with the detail level it was saved with
  (the entry itself is not stored, so this is a new request to the AI
  model). Swipe an entry towards the start to delete it, or towards the end
  to add it to (or remove it from) your favorites; both offer **Undo**, and
  screen readers get the same actions on each entry.
- **Favorites.** Tap the heart on a translation or a dictionary entry to
  make it a favorite. Long-press the History button to open **Favorites**
  directly. Favorites are never removed automatically; the newest 1,000
  other entries (translations and look-ups together) are kept.
- **Favorites by language pair.** The **Favorites** tab groups your
  favorites by language pair, with chips to show one pair, and **Open
  phrasebook** opens them in the [Phrasebook](#phrasebook), where they are
  its built-in Favorites collection. **Export favorites** writes them to a
  CSV file (**Save as CSV** or **Share CSV**): one row per favorite with
  the text (or the looked-up word), its translation (or the entry's
  summary), the source and target language and the date, in UTF-8, ready
  for Anki flashcards and spreadsheets. The file isn't encrypted, and it
  stays on the device unless you share it.
- **Settings > Privacy & data > Delete history automatically** removes
  translations and look-ups older than 1, 7 or 30 days (**Never** by
  default); favorites are always kept. If older entries already exist,
  Mozhi asks first (**Delete older translations now?**). While it is on,
  the History page says so, and **Import history** skips entries older than
  the setting.
- **Clear history** (on the History page, and at the end of **Settings >
  Privacy & data**) removes look-ups too, and can keep your favorites.
- **Settings > Privacy & data > Export history** copies your history,
  look-ups included, as JSON or shares it as a file (plain, unencrypted
  JSON); **Import history** merges such JSON into your history, for example
  on a new phone. Exports from older versions import as before; a look-up
  of a word you already have keeps your entry (and becomes a favorite if
  the imported one was).
- On the device the history is encrypted (AES-256-GCM, with the key in
  secure storage), and it is never part of Android's cloud backup or
  device transfer; an encrypted [Mozhi backup](#backup-and-restore) carries
  it instead. **Export history** says that its JSON is unencrypted and
  offers **Make an encrypted backup instead**.

## Phrasebook

Collections of phrases, on the device and offline (details in
[Phrasebook](phrasebook.md)):

- **Open it** from **History > Favorites** (**Open phrasebook**), **More
  tools > Phrasebook** on the Translate tab, or `/phrasebook`. It lists
  **Favorites** (your history's hearts, nothing copied), **Your
  collections** (*Trip to Lisbon*, *Pharmacy*...: **New collection**,
  rename, reorder by dragging or **Move up**/**Move down**, delete with
  **Undo**) and your **Starter phrasebooks**. From 840 dp wide the list
  sits beside the open collection.
- **Add phrases** with **Add to phrasebook…**: the bookmark button beside
  the heart under a translation, a History row's menu, and beside the
  heart of a Dictionary entry (the word and its translation). The last
  collection you used comes first, collections that have the phrase are
  ticked, and **New collection** makes one on the spot.
- **Each phrase**: **Listen to the phrase** and **to the translation** (a
  long press reads slowly; the word being read is
  [highlighted](#text-to-speech)), **Copy translation**, **Show full screen**,
  and in its menu **Copy phrase**, **Share**, a **note**, **Copy to** or
  **Move to collection…** and **Remove** (with **Undo**). Search, a
  language pair filter and **Newest first** / **A to Z** sorting.
- **CSV.** **Export as CSV** writes a collection for Anki and spreadsheets
  (as **Export favorites** does, with your notes); **Import CSV** reads a
  CSV or tab-separated file on the device, with a preview, the choice of
  the two columns, a header row and the languages.
- **Starter phrasebooks** for travellers, from Wikivoyage (**From
  Wikivoyage · CC BY-SA 4.0**): downloaded once on request from your model
  source and checked against their SHA-256, then offline and read-only,
  with pronunciations; copy phrases out of them into your own collections.
  None are available until their first release of data, and the app says
  so.
- The phrasebook is encrypted on the device like the history, is part of
  [backups](#backup-and-restore) (not the starter phrasebooks, which can be
  downloaded again) and goes with **Delete all local data**.

## Practice

Flashcards of the phrases you keep, on the device (details in
[Practice](practice.md)):

- **Practice** in the translate screen's **More tools** (with the number
  of cards due for review), or **Practice** on a phrasebook collection.
- Your favorites and phrasebook collections become cards, asked one way
  or both: **Recognize** (see the phrase, recall its meaning) and
  **Produce** (see your language, say or type the phrase). Cards follow
  edits to their phrase and go when it is deleted.
- Short sessions of the cards due, plus up to **New cards per day** (10 by
  default). Show the answer (Space), listen to it (slowly on a long
  press), then rate **Again**, **Hard**, **Good** or **Easy** (1 to 4):
  each button shows when the card comes back. **Undo last rating** (Z)
  takes a rating back; a summary ends the session. No streaks, no
  account.
- Scheduling is **FSRS-5**, the algorithm Anki uses, in pure Dart, with
  its default weights, learning steps (1 and 10 minutes), interval fuzz
  and **Desired retention** (90 % by default).
- **Speaking practice** (Android, with an offline speech model): hold the
  microphone and say the phrase; Whisper transcribes it on the phone and
  each word is marked right, nearly right or missed (ignoring case,
  punctuation and accents), with a suggested rating. The recording is
  never stored or sent. **Type answers** adds an answer field with the
  same comparison.
- **Export to Anki** writes a tab-separated text file (one collection or
  all) with tags for the collection and the language pair, ready for
  Anki's **File > Import**.
- The progress is encrypted on the device like the history, carried by
  backups and sync, and deleted by **Delete all local data**.

## Backup and restore

One encrypted file holds your data, readable only with your passphrase,
with no account and no server (details and the file format in
[Backup](backup.md)):

- **Settings > Backup & sync > Back up now**: choose what to include
  (history and favorites, presets, glossaries, settings, and in versions
  that have them the phrasebook and practice progress). **Include API keys
  and passwords** is off unless you turn it on, with a warning. Enter a
  passphrase twice; a hint says how strong it is (from its length and word
  count, on the device). Android saves `mozhi-<date>.mozhibackup` where
  you choose; the web app downloads it. The row shows when you last backed
  up.
- **Restore from a backup**: pick the file (Mozhi shows when it was made
  and by which version), enter the passphrase, see what it holds (how many
  items per part, and whether it has API keys), choose the parts, then
  **Merge with my data** (keeps yours, adds what's only in the backup; the
  newer copy of an entry wins and deleted entries stay deleted) or
  **Replace my data**. The result says what changed.
- Wrong passphrase or a damaged file: one clear error, nothing restored.
  A backup made on Android opens in the web app and the other way round.
- Encryption: Argon2id (64 MiB, 3 passes on Android; 19 MiB, 2 passes in
  the web app) and AES-256-GCM over the compressed data. Offline models
  and dictionaries aren't included: download them again.

## Sync

Keep your devices in sync through a WebDAV folder on your own server
(Nextcloud, ownCloud, a Synology or other NAS, Apache, `rclone serve
webdav`), end-to-end encrypted, with no Mozhi account and no third party
(details, server setup and CORS for the web app in [Sync](sync.md)):

- **Settings > Backup & sync > Set up sync**: the WebDAV address (for
  Nextcloud and ownCloud the server's address is enough), user name, an
  app password and a folder (`Mozhi` by default, created if needed).
  **Test connection** checks them and says whether another device already
  syncs there; then enter that device's sync passphrase, or choose a new
  one (with the same strength hint as backups), and **Turn on sync**. A
  second device's data is merged in, never replaced.
- **What to sync**: history and favorites, phrasebooks, practice progress,
  presets and glossaries by default; the settings only if you choose them,
  and their API keys and passwords only with **Include API keys and
  passwords** (with a warning). Each device can choose differently.
- It syncs at app start, a minute after a change (only when something
  synced changed), when you leave the app with a change waiting, and on
  **Sync now**; never in Offline only, and with **Sync on Wi-Fi only**
  (Android) not automatically over mobile data. There is no background
  service.
- The row shows where it syncs and the last sync's time or why it failed,
  in plain words (wrong app password, folder missing, not a WebDAV server,
  no connection, certificate, blocked by the browser's CORS, ...).
  **Unlock sync** asks again for what the device forgot (the web app
  forgets the app password and the key when its tab closes); a passphrase
  changed on another device asks for the new one.
- **Change sync passphrase** re-encrypts the file (other devices then ask
  for the new passphrase); **Turn off sync** forgets the server, the app
  password and the key, and can delete the sync file from the server.
- The server only stores one encrypted file (`mozhi-sync.mozhibackup`, the
  [backup](backup.md) format): it sees its size and when it changes, never
  its contents. Requests show as **Encrypted sync** in Network activity.

## Phone to phone

Move your data or your offline languages to another phone nearby, over the
same Wi-Fi or a phone's hotspot, end-to-end encrypted and without the
internet (Android; details in [Phone to phone](pairing.md)):

- **Settings > Backup & sync > Receive on this phone** shows a QR code and
  the same code as text, valid for five minutes (**New code** makes
  another; with several networks, pick the one both phones are on).
- On the other phone, scan the QR code with the camera app (it opens Mozhi)
  or open **Send to another phone** and type or paste the code, then
  **Connect**. Both phones show the same six-digit number: compare them
  and confirm on both (the receiving phone can only accept after that).
- Choose what to send: **Your data** (pick the parts; **Include API keys and
  passwords** is off unless you turn it on, with a warning) and any
  translation models, speech models, text recognition languages and
  dictionaries on the phone. **Offline languages > Share language packs**
  opens the same screen with the packs selected.
- The receiving phone lists what it gets (and what it already has or its
  version can't use), lets you untick items, **Merge with my data** or
  **Replace my data** as for a backup, and **Accept** or **Decline**. Every
  file is checked against the receiving phone's own catalogue before it is
  installed.
- Both phones show the progress and keep the screen on, then what became of
  each item. Clear errors say when the phones aren't on the same network,
  the code expired, the other phone said no, or storage ran out.

## Privacy controls

**Settings > Privacy & data** gathers what decides where your text goes and
what stays behind, in four groups: **Privacy**, **History**, **Network**
and **Data** (details in [Privacy](privacy.md)):

- **Privacy mode**: **Offline only** (nothing leaves the device),
  **Offline first** (the default: on-device when the pair is installed,
  otherwise Mozhi asks once per language pair and destination) or
  **Online** (your services without asking; cloud providers still ask
  once each). A prompt shows the destination before anything is sent and
  offers **Once**, **Always for** the pair, downloading the pair for
  offline use, or changing the mode.
- **Incognito**: new translations and dictionary look-ups aren't saved,
  and keyboards are asked not to learn what you type.
- **Hide content in recents & block screenshots** (Android): also blocks
  screen recording and screen sharing.
- **App lock** (Android): Mozhi asks for your fingerprint, face or the
  phone's screen lock (PIN, pattern or password) when it starts and when
  you come back to it after the time you choose: **Immediately**, **After
  1 minute**, **After 5 minutes** or **After 15 minutes**. Until you
  unlock, it shows only **Mozhi is locked** and **Unlock** (the prompt
  opens by itself once each time you come back; if you cancel it, tap
  **Unlock**). Nothing of the app shows behind it, and Recents shows no
  preview of Mozhi while the lock is on (on Android 12 and older that
  also blocks screenshots of Mozhi, as **Hide content in recents** does).
  - Turning it on asks you to unlock once, so you can't lock yourself out.
    It needs a screen lock on the phone; without one the row says so, and
    it isn't available in the web app.
  - Opening the camera, a file or photo picker or a save dialog from
    Mozhi (and Translate screen's capture prompt) gives you at least 5
    minutes before it locks, so a photo or file you pick isn't lost to the
    lock. Sharing doesn't: the app you share to is somewhere else, so
    with **Immediately** Mozhi is locked when you come back from it.
  - Text selected in another app (**Translate with Mozhi**, **Translate
    offline**) and **Translate screen** ask you to unlock first when the
    app is locked: their windows would otherwise show your languages and
    let anyone use your AI providers. Unlocking there unlocks the app. The
    home-screen widget only has buttons and never shows your text, so it
    stays the same.
  - What was running keeps running while it is locked: a document being
    translated, a conversation, a shared conversation or Transcribe go on
    behind the lock, and after you unlock you are back where you were.
    Until then the screens are hidden from view, touch, screen readers and
    the keyboard (a text field loses the focus and the keyboard closes).
    Before the first unlock after Mozhi starts, none of its screens opens.
  - Text shared to Mozhi, **Translate clipboard** (tile, widget, shortcut)
    and links (`mozhi://…`, the widget's **Type** and **Camera**, shared
    images and files) wait for the unlock: nothing is filled in,
    translated, opened or saved before, and the clipboard is read only
    then. The translate bubble's press and hold is the exception: Android
    lets only the window in front read the clipboard, so it reads it right
    away, and the quick translate sheet shows it once you unlock.
  - It is a setting of this phone: backups, sync and Phone to phone never
    carry it, and restoring one doesn't change it.
- **Network > HTTP proxy** (Android): every request goes through it, for
  example Orbot's `127.0.0.1:8118` for Tor; needed for `.onion` and `.i2p`
  servers. Applies after restarting the app.
- **Hide personal data from online engines** (on by default): e-mail
  addresses, phone numbers, IBANs, card numbers and IP addresses are
  replaced before text goes online and put back into the translation; the
  result says how many items stayed on the device (also for the text of a
  photo and for documents, under their translation).
- **Network activity**: every request of this session, grouped by
  destination, with its purpose and size and never its text. Kept in
  memory only.
- **Clear history** and **Delete all local data** come last, in red. Delete
  all local data removes the history and its key, settings, keys and
  passwords, presets, glossaries, usage counters, cached lists and offline
  models; setup then starts again.

Copies are marked sensitive on Android 13+, so the system's copy preview
and keyboard clipboard suggestions don't show them. Plain `http` is used
only for this device, your network and Tor or I2P addresses.

## Usage and costs

**Settings > AI > Usage & costs** shows, for each AI provider (and DeepL API or
LibreTranslate service) you added, this month's and last month's requests,
characters sent and received, and estimated tokens.

- Counted: translations (also in compare mode, into
  [extra target languages](#extra-target-languages) and of documents),
  refinements, the AI extras (alternatives, insights, explanations,
  suggestions, romanization, alignment, [meaning checks](#meaning-check) and
  the dictionary), back-translations and proofreading.
- Not counted: results the app already had. Translating the same text again
  with the same engine, languages and options while the app is open is
  answered from memory, without a request.
- Tokens are estimates (about 4 characters per token, or 1 per Chinese,
  Japanese or Korean character), so your provider's bill may differ.
- Open a provider under **Settings > AI > AI providers** to set a **Monthly
  budget** in characters. You get a warning at 80 % of it and when it is
  reached.
- **Reset usage** deletes the counts; budgets stay. Only counts are kept,
  never text, and only on the device.

## Text-to-speech

**Listen** (the speaker button) reads your text or the translation aloud; tap
it again (**Stop**) to stop.

**Listen slowly** reads the text again from the start at a slower speed
(0.6× your speech rate), also while it plays. Any of these starts it:

- **Long-press Listen.** On a touch screen this also shows the button's
  tooltip, which names what it reads (for example **Listen to German**) and
  says **Long-press to listen slowly**; with a mouse the tooltip appears
  when you point at the button.
- **Right-click Listen** and choose **Listen slowly** (not in a browser that
  shows its own menu).
- **Shift+Enter** (or Shift+Space) while **Listen** has keyboard focus.
- With a screen reader, the **Listen slowly** action of the button
  (TalkBack also offers it as the button's long press).

**Follow along.** While a device voice reads a translation, or a phrase of
the [phrasebook](#phrasebook), the word it is reading is highlighted. It
moves from word to word without animation (also with reduced motion on),
and screen readers hear nothing extra. It needs a voice that tells where it
is: Android 8.0 and later, and browsers that report word boundaries for
their voices; Mozhi voices and voices that don't report it show no
highlight. In Chinese, Japanese or Thai a browser may highlight up to the
next punctuation mark. While part of the text is selected the highlight
holds still. **Settings > Appearance > Highlight the word being read**
turns it off.

The sound comes from one of two places:

- **Device voices** (first): the text-to-speech voices of your phone,
  computer or browser read every language they have a voice for, and work
  offline when the voice is installed. Some of them are **online voices**
  that send the text to a speech service (Chrome's "Google …" voices, for
  example): the voice picker labels them **Online voice: the text goes to
  …**, a voice on the device is preferred, and before an online voice
  reads for the first time Mozhi asks (your answer is kept per voice;
  **Allowed online voices > Forget** asks again). In **Offline only** they
  never read. See [Online voices](privacy.md#online-voices). A text longer
  than 3,900 characters (Android's voices take at most 4,000 at once) is
  read in parts, cut at sentence ends.
- **Mozhi voices**: only for a language the device has no voice for, your
  Mozhi instance fetches the audio from Google (with Reverso as a fallback).
  Mozhi receives the text in the request address, which can end up in its
  logs, so in **Offline first** the app asks first (**Listen online**), in
  **Offline only** it never does, and **Device voice only** turns it off.
  Long texts are read in parts, one after another.

**Settings > Read aloud & voice > Read aloud** adjusts how text is read:

- **Speech rate**: from 0.5× to 1.5× in steps of 0.1 (1.0× is normal
  speed). The play button next to the slider (**Preview speech rate**)
  reads a sample sentence at that speed. The rate applies to device voices,
  and to Mozhi audio where the platform's audio player can change the speed
  (elsewhere Mozhi audio plays at normal speed).
- **Device voice only**: never send text to a Mozhi instance to read it
  aloud, not even for languages the device has no voice for.
- **Voice per language**: choose one of the device's voices for the
  languages you used recently (your current target and source languages,
  then recent ones: up to four, plus every language you already chose a
  voice for). **French voice**, for example, lists the voices installed for
  French with their locale and labels such as **High quality** or **Needs
  internet**; play one to hear it before you choose, or keep **System
  default**. A chosen voice reads its language instead of the Mozhi voice.
  If a language has no voice, install one in your device's text-to-speech
  settings.

**Device voice only** and **Voice per language** appear only where the device
has a text-to-speech engine (Android and most browsers). The settings are kept on the device.

## Android integration

- **Translate with Mozhi** appears in the text-selection menu of other apps.
  A quick-translate sheet opens over the other app, which stays visible
  behind it; closing the sheet returns to it. If the text was selected in
  an editable field, **Replace** puts the translation back into that app;
  **Open in app** continues in the full translator.
- **Quick Settings tile** and the **Translate clipboard** app shortcut open
  the translator with the clipboard text.
- **Translate screen**: translate what is on the screen, in any app, like
  a camera translator for the screen. Start it from the **Translate
  screen** Quick Settings tile (on Android 13 and later **Settings >
  General > Add the Quick Settings tile** adds it for you), the
  **Translate screen** app shortcut (long-press the app icon; it comes
  fifth, so launchers that show four leave it out) or the bubble (below).
  Android asks every time whether Mozhi may capture the screen; Mozhi then
  takes one screenshot, stops the capture, reads the text on the phone
  (on-device text recognition, as for [photos](#image-translation)) and
  draws the translation over the screenshot, full screen. Tap a paragraph
  for its original and translation, press and hold **Original** to see
  the screen without the translation, **Show as text** for all of it,
  **Copy translation**, or **Open in Mozhi** to continue with the
  recognised text in the translator. The languages at the top work as on
  the image screen. ✕ or Back returns to the app. The screenshot never
  leaves the phone: only the recognised text goes to your translation
  engine, with your [privacy mode](privacy.md#privacy-modes). An app that
  blocks screenshots (many banking apps do) comes out black, and Mozhi
  says so. With the [app lock](#privacy-controls) on, Mozhi asks to
  unlock before it shows anything.
- **Translate bubble** (**Settings > General > Android integration**,
  off by default): a small round button floating over other apps. Tap it
  to translate the screen, press and hold it to translate the clipboard
  in the quick translate sheet, drag it anywhere (it snaps to the nearest
  side) and drop it on the ✕ that appears at the bottom to remove it.
  Turning it on asks once for **Display over other apps** and, on Android
  13 and later, for notifications: while the bubble is on, a notification
  says so and has **Stop**. The bubble hides while a Mozhi window is on
  the screen, and it doesn't come back after the phone restarts. With a
  screen reader, double-tap it to translate the screen; its actions are
  **Translate clipboard** and **Remove the bubble**.
- **Home-screen widget**: long-press the home screen, choose **Widgets**
  and add **Mozhi**. It has three buttons:
  - **Clipboard** opens the translator with the clipboard text, like the
    Quick Settings tile. The widget never reads the clipboard itself; Mozhi
    reads it once it is open (Android 10 and later only let the app in front
    read the clipboard).
  - **Type** opens the translator (`mozhi://translate`).
  - **Camera** opens camera translate with the camera ready
    (`mozhi://image?source=camera`).

  The widget is resizable. When it is narrow the labels are hidden (screen
  readers still announce each button), and at about two cells wide the
  Camera button is left out. On Android 12 and later it uses your
  wallpaper colours (Material You) and the launcher's corner radius; it
  follows light and dark mode on all versions.
- **Share** text from any app to Mozhi to translate it. Share an
  **image** (a screenshot, a photo) to read and translate it on the image
  screen, or a document **file** (text, subtitles, JSON, HTML, CSV, PO,
  office documents, e-books) to open it in Documents.
  Shared content never starts an AI request by itself: with an AI engine it
  waits for **Translate**.
- **Material You**: with **Dynamic color** on (Android 12 and later), the app
  takes its colours from your wallpaper.

## Links

Mozhi understands Kagi Translate-style links. In the web app:

```text
https://<host>/#/translate?text=hola&from=es&to=en
https://<host>/?text=hola&from=es&to=en
```

On Android the same links work with the `mozhi://` scheme:

```text
mozhi://translate?text=hola&from=es&to=en&formality=more&quality=best
```

`/translate` (and `/` in the web app) takes these parameters:

| Parameter | Also accepted | Meaning |
| --- | --- | --- |
| `text` | `q` | Text to translate (optional: leave it out to only set languages or options) |
| `from` | `sl`, `source` | Source language: a code (`es`, `pt-BR`), an English or native name, or `auto` |
| `to` | `tl`, `target` | Target language: a code or a name the selected engine supports |
| `style` | `translation_style` | `natural` or `literal` |
| `formality` | | `default`, `more` (or `formal`), `less` (or `informal`), `prefer_more`, `prefer_less` |
| `language_complexity` | `readingLevel` | Reading level: `standard`, or `a1` to `c2` |
| `speaker_gender`, `addressee_gender` | `speakerGender`, `addresseeGender` | `masculine` (or `male`), `feminine` (or `female`), `neutral` |
| `preserve_formatting` | `preserveFormatting` | `true` or `false` |
| `quality` | | `fast`, `best` or `standard` (Fast once Fast and Best are set up, otherwise your usual engine) for the link's own text; ignored by links without text. See [Quality modes](#quality-modes-fast-and-best) |

The app waits for the engines to load, selects the languages and applies the
options, which then stay your translation options like ones you set
yourself. Unknown values are ignored.

Links come from outside the app, so they are limited:

- Text is cut to 5,000 characters. Only fixed choices can be set: free
  text such as `context` and `formality_context` (Kagi accepts them) is
  ignored, because it would go into the AI prompt. Language values must be
  in the engine's list: custom styles such as *Pirate speak* (as target or
  source), glossaries and refinement instructions can't be set from a link
  either.
- **A link never starts a paid AI request on its own.** The text is
  translated straight away only with engines that are not AI models (Mozhi,
  the DeepL API, LibreTranslate, offline); with an AI model press
  **Translate**, even with **Instant translate** set to **Online engines
  and AI** (it covers typing only).
  When it is translated straight away, it is also translated into your
  [extra target languages](#extra-target-languages), one request each.
  Changing the quality mode or the options for a link doesn't translate
  anything either.

Other screens can be linked too, and never send anything until you ask:

| Link | Opens |
| --- | --- |
| `/proofread?text=...` | The **Proofread** tab with the text filled in; press **Proofread** |
| `/dictionary?word=gato&from=es&to=en` | The [dictionary](#dictionary) with the word filled in; press **Look up** |
| `/web?url=...` | The [web page translator](#web-pages) with the address filled in; press **Translate page** |

As `mozhi://` links: `mozhi://proofread?text=...`,
`mozhi://dictionary?word=...` and `mozhi://web?url=...`; `mozhi://image`,
`mozhi://documents` and `mozhi://conversation` (the Conversation tab) open
those screens; `/history` and `/settings` (and `/settings/...`) open those
pages. In the web
app, put the path after `#`, for example
`https://<host>/#/dictionary?word=gato`.

## Keyboard shortcuts

On the Translate tab:

| Shortcut | Action |
| --- | --- |
| Ctrl+Enter (⌘+Enter in a browser on a Mac) | Translate now (runs the comparison in compare mode); also runs Proofread |
| Ctrl+Shift+S (⌘+Shift+S) | Swap languages |
| Ctrl+Shift+C (⌘+Shift+C) | Copy the translation |
| Ctrl+L / Ctrl+Shift+L | Choose the target / source language (type to search, Enter picks the first match); in a browser Alt+L / Alt+Shift+L (⌥+L / ⌥+Shift+L on a Mac), because Ctrl+L belongs to the browser's address bar |
| / | Go to the text box (when no text field has focus) |
| Alt+1 … Alt+9 | Translate into pinned language 1 to 9; in a browser Ctrl+Alt+1 … 9 (⌘+⌥+1 … 9 on a Mac), because browsers use Alt+digit for tabs |
| Esc | Clear the text (while typing) |
| Shift+Enter (on a focused Listen button) | [Listen slowly](#text-to-speech) from the start |
| ? or Ctrl+/ (⌘+/) | Show keyboard shortcuts |

Anywhere in the app (Ctrl on a Mac too):

| Shortcut | Action |
| --- | --- |
| Ctrl+Shift+1 … Ctrl+Shift+4 | Switch to tab 1 to 4, in your order (**Settings > General > Tab order**) |
| Ctrl+Shift+H | Open History |

The app shows the same list as a two-column table (press ?). It is also
under **More tools > Keyboard shortcuts** in the ⋮ menu, which offers it on
wide screens, in desktop browsers and once you have used a hardware
keyboard.

**Keyboard navigation.** While you use a keyboard or a mouse, the focused
control has a visible ring in the accent colour, with a small gap around
it; it never shows after a touch. Tab moves through the sidebar first, then
the tab's app bar and content (on phones: the tab, then the bottom bar). On
the Translate tab it goes from the text box to the language controls, then
to the translation.

## Settings

**Settings** (the gear button at the top of every tab) starts with a search
field, then eight categories, each on a page of its own:

| Category | What it holds |
| --- | --- |
| **General** | App language, tab order, haptic feedback, multiline input, **Keep the web app for offline use** (web app); **Android integration**: [Translate screen](#android-integration) (with **Add the Quick Settings tile** on Android 13+) and the **Translate bubble** |
| **Privacy & data** | **Privacy** (privacy mode, incognito, screenshot blocking, [app lock](#privacy-controls), hiding personal data), **History** (saving, automatic deletion, export and import, the phrasebook, recent language pairs), **Network** (approved pairs and cloud providers, HTTP proxy, network activity) and **Data** (**Clear history** and **Delete all local data**, last and in red) |
| **Backup & sync** | **Encrypted backup** ([**Back up now**](#backup-and-restore) with the date of the last backup, **Restore from a backup**), then sync and phone to phone |
| **Translation engines** | Offline languages, on-device AI, Mozhi instances, translation services (DeepL API, LibreTranslate), quality modes, **Remember quality selection** and **Instant translate** |
| **AI** (marked **Advanced**) | On-device AI, AI providers, the AI assistant for insights, presets, glossaries, usage & costs |
| **Appearance** | Theme, dynamic color, dark theme, romanization, **Tap a word to look it up**, **Highlight the word being read**, accent color |
| **Read aloud & voice** | Read aloud and voice input |
| **About** | Version, privacy, source code, the Mozhi project, open-source licenses and **Run setup again** |

The search looks through every setting's title, description and choices,
highlights the matches, and opens the category at the setting you pick. On
wide screens the categories are listed beside the open one. Links such as
`/settings/privacy` open a category directly.

If your settings can't be saved, the app says so (**Couldn't save your
settings. Changes stay until you close Mozhi.**), and the same goes for an
API key or password that secure storage refuses (**Couldn't store your API
key or password securely. It works until you close Mozhi and is never saved
unprotected.**).

## Appearance and layout

- Light, dark or system theme. The dark theme is **Lights out** (true
  black, easy on OLED screens) by default, or **Dim** (dark blue-grey);
  pick it under **Settings > Appearance > Dark theme**.
- Dynamic color or one of ten accent colours, including a soft
  **Lavender**.
- Rounded, outlined controls: pill-shaped chips and buttons, rounded
  cards, sheets and text fields, and big bold headings. Outlines of
  controls have at least 3:1 contrast in every look, and secondary text is
  lighter in **Dim** and **Lights out**.
- Four tabs: **Translate**, **Dictionary**, **Proofread** and
  **Conversation**. **History** and **Settings** are the clock and gear
  buttons at the top of every tab; they open as full pages above the tabs,
  and their back arrow returns to the tab (or to Translate when a link or
  shortcut opened them).
- Phones use a bottom navigation bar with an icon and a label for each tab.
  From 840 dp wide (tablets, foldables, wide browser windows) the app
  switches to a sidebar with small labels under the icons (from 1200 dp,
  the labels sit beside them); Translate then shows
  [two panes](#translate), History the list beside the details, and
  Settings the categories beside the open one. Between 600 and 840 dp the
  phone layout stays.
- The splash screen and the system bars match the light and dark looks on
  Android and the web.
- Large touch targets and screen-reader labels throughout. In the web app
  screen-reader support is on from the start, and screen readers can read
  the translation.

## Platform support

| Feature | Android | Web |
| --- | --- | --- |
| Mozhi engines, AI providers, Proofread, history | ✓ | ✓ |
| Text selection menu and share target | ✓ | |
| `mozhi://` links | ✓ | |
| Offline translation | ✓ | ✓ (models in the browser's private storage; **Import from files** too) |
| Opens with no network (after a first visit) | ✓ | ✓ (**Keep the web app for offline use**) |
| On-device AI | ✓ (64-bit phones with enough memory) | |
| On-device text recognition | ✓ (Tesseract; ML Kit in the Play variant) | |
| Live camera (translation over the camera picture) | ✓ (a camera; Camera2) | |
| Office documents, e-books, localisation files and HTML | ✓ | ✓ (large files can pause the page while they are read) |
| PDF documents (pages read on the device, translated PDF and text) | ✓ | — (listed as needing the Android app) |
| Translate screen, floating bubble | ✓ | |
| App lock | ✓ (with a screen lock set) | |
| Privacy screen, sensitive clipboard, HTTP proxy | ✓ | |
| Dynamic color from wallpaper | ✓ (12+) | |

On the web, the browser enforces some extra rules for self-hosted servers;
see the [FAQ](faq.md#does-the-web-app-work-with-my-self-hosted-servers).
