# Feature tour

Everything Mozhi can do, screen by screen. Features marked **AI** need an
[AI provider](ai-providers.md); everything else works with a Mozhi instance
alone.

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
- [Voice](#voice)
- [Documents](#documents)
- [Web pages](#web-pages)
- [Offline translation](#offline-translation)
- [History and favorites](#history-and-favorites)
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
  device."). Paid AI providers are never tried automatically.
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
  downloaded a language.
- **Mozhi engines** of your preferred instance: Google, DeepL, Reverso,
  Yandex, LibreTranslate, DuckDuckGo and MyMemory, whichever it offers.
- **AI models**: every enabled AI provider, with its model name.

Your own [DeepL API and LibreTranslate](ai-providers.md#deepl-and-libretranslate)
services are listed too. Each engine has a short note on what it is good
for (for example **Good for European languages** for DeepL); an AI model's
id is shown there, not on the engine button.

A badge tells you who receives your text: **On device** (offline
translation), **Self-hosted** (a server on this device, your network, or a
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
its terms go to the engine as placeholders it keeps, are replaced by your
renderings (matching inflections) and a term that couldn't be placed is
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
screen when you come back.

Before a photo is uploaded (AI vision, Mozhi) it is re-encoded without its
metadata and scaled down to at most 1600 px on its longest side and about
1.5 MB. Mozhi gets up to 90 seconds to answer. A photo is sent to at most
two of your instances (after a time-out, to no other), and when a proxy in
front of the instance turns the upload down as too large, a smaller copy
(about 900 KB) is sent once more. Language codes are mapped to Google's own
(`zh-CN`, `zh-TW`, `iw`, ...), and a language Google does not offer is
reported before anything is uploaded.

## Voice

- **Dictation**: tap the microphone and speak instead of typing. By default
  speech recognition is provided by your device's operating system (or
  browser); on Android 12+ **Prefer on-device speech recognition** asks it
  to keep the audio on the phone. On Android you can instead choose
  **Offline (Whisper)** in **Settings > Read aloud & voice > Voice input**:
  OpenAI's Whisper model (Fast, 75 MB, or Better, 142 MB, downloaded from
  Hugging Face or imported from a file) recognises 99 languages on the
  phone, so your voice never leaves it. **Offline only** always uses Whisper (see
  [Voice input](voice-input.md)).
- **Conversation** (a tab of its own): two people, two languages. Each
  person speaks or types in turn and hears or reads the other's words in
  their own language. While the conversation is empty, a large microphone
  (*Let's talk!*) dictates in the first language of the pair; the pair sits
  in one pill above the two input fields (tap a language to change it, the
  arrows to swap). **Face to face** (the two-people button) turns the screen
  into two halves, the far one upside down, and covers the tabs; back
  returns to the tab.
- **Device voices**: besides your Mozhi instance's voices, the app can read
  text aloud with the device's built-in text-to-speech voices, with a speech
  rate and a voice per language of your choice (see
  [Text-to-speech](#text-to-speech)).

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

Documents are split into parts that are translated a couple at a time, with
progress shown as they finish; failed parts are retried.

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
second on a desktop computer) and **Import from files** isn't available.

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
  which instance answered; look-ups by the AI model that wrote them (a local
  model is **Self-hosted**, other providers **Cloud**). **Clear filters**
  shows everything again.
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
- **Phrasebook.** The **Favorites** tab groups your favorites by language
  pair, with chips to show one pair. **Export favorites** writes them to a
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
  secure storage), and it is never part of a backup or a device transfer.

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
- **Network > HTTP proxy** (Android): every request goes through it, for
  example Orbot's `127.0.0.1:8118` for Tor; needed for `.onion` and `.i2p`
  servers. Applies after restarting the app.
- **Hide personal data from online engines** (on by default): e-mail
  addresses, phone numbers, IBANs, card numbers and IP addresses are
  replaced before text goes online and put back into the translation; the
  result says how many items stayed on the device.
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

The sound comes from one of two places:

- **Device voices** (first): the text-to-speech voices of your phone,
  computer or browser read every language they have a voice for, and work
  offline when the voice is installed. Some of them are **online voices**
  that send the text to a speech service (Chrome's "Google …" voices, for
  example): the voice picker labels them **Online voice: the text goes to
  …**, a voice on the device is preferred, and before an online voice
  reads for the first time Mozhi asks (your answer is kept per voice;
  **Allowed online voices > Forget** asks again). In **Offline only** they
  never read. See [Online voices](privacy.md#online-voices).
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
  screen, or a subtitle, text or JSON **file** to open it in Documents.
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
field, then seven categories, each on a page of its own:

| Category | What it holds |
| --- | --- |
| **General** | App language, tab order, haptic feedback, multiline input |
| **Privacy & data** | **Privacy** (privacy mode, incognito, screenshot blocking, hiding personal data), **History** (saving, automatic deletion, export and import, recent language pairs), **Network** (approved pairs and cloud providers, HTTP proxy, network activity) and **Data** (**Clear history** and **Delete all local data**, last and in red) |
| **Translation engines** | Offline languages, Mozhi instances, translation services (DeepL API, LibreTranslate), quality modes, **Remember quality selection** and **Instant translate** |
| **AI** (marked **Advanced**) | AI providers, the AI assistant for insights, presets, glossaries, usage & costs |
| **Appearance** | Theme, dynamic color, dark theme, romanization, accent color |
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
| Offline translation | ✓ | |
| On-device text recognition | ✓ (Tesseract; ML Kit in the Play variant) | |
| Privacy screen, sensitive clipboard, HTTP proxy | ✓ | |
| Dynamic color from wallpaper | ✓ (12+) | |

On the web, the browser enforces some extra rules for self-hosted servers;
see the [FAQ](faq.md#does-the-web-app-work-with-my-self-hosted-servers).
