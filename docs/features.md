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
- [History and favourites](#history-and-favourites)
- [Privacy controls](#privacy-controls)
- [Usage and costs](#usage-and-costs)
- [Text-to-speech](#text-to-speech)
- [Android integration](#android-integration)
- [Links](#links)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Appearance and layout](#appearance-and-layout)
- [Platform support](#platform-support)

## Translate

- **Start screen.** With no text, the tab greets you (**Good morning**,
  **Good afternoon** or **Good evening**) with chips for **Camera** (image
  translation) and **Document**, and your recent language pairs. The
  composer waits at the bottom, as on Kagi Translate: a card with the text
  box (the microphone, and paste, at its top right) and the language bar.
  Tap it to type: the screen turns into the usual thread, your text with
  its language at the top and the translation under it, and the language
  bar stays docked at the bottom of the screen, right above the keyboard
  while it is open. Leave the empty text box to get the start screen back.
  On wide screens the composer sits under the greeting, and your text and
  the translation open side by side.
- **Language bar.** At the bottom of the screen, as on Kagi Translate:
  **Translation options** (the tune icon) on the left, the source and
  target languages with the swap button in the middle, and the go button
  (the rocket, **Translate**) on the right. The go button translates right
  away, or again; in compare mode it runs the comparison. While a
  translation is running it turns into **Stop translating**.
- **Instant translate.** The translation updates shortly after you stop
  typing, with Mozhi engines and AI engines alike. Each pause sends an AI
  model a request, which costs tokens with a paid provider; turn off
  **Settings > Instant translate with AI** to translate only when you press
  the go button. Text shared from other apps and links wait for the go
  button with an AI model either way (see [Links](#links)).
- **Output actions:** copy, share, listen, add to favourites,
  [**Check meaning**](#meaning-check), and the elapsed time per engine. With
  an AI model available, the output also offers **Insights**, **Show
  romanization** and **Show matching phrases** (see below).
- **More languages at once:** **Also translate into…** under the translation
  adds up to four more target languages; see
  [Extra target languages](#extra-target-languages).
- **Definitions.** For single words, Google and Reverso results from Mozhi
  include definitions with examples and synonyms.
- **Same language in and out** (AI): choose the same source and target
  language to have the text improved and rephrased instead of translated.
- **Long texts** (AI): the input holds up to 20,000 characters. AI models
  get texts longer than 6,000 characters in parts (2,500 characters for
  local models, which usually have small context windows). Parts are cut at
  paragraph boundaries where possible (else at line breaks or sentence
  ends; code blocks are never cut), two are translated at a time, and each
  part comes with the end of the part before it as context, so terms and
  tone stay consistent. The translation fills in as the parts finish.

## Languages and detection

- **Picking languages.** Tap the source or target language to open the
  picker: search by English or native name or by code, pick from **Recent**
  (your last eight languages) or **Pinned** languages (use the pin button
  next to a language), or browse **All languages**. Mozhi engines show the
  languages that engine supports; AI engines offer about 290 languages and
  variants, from Brazilian Portuguese and Cantonese to Latin and Toki Pona.
- **Detect language.** With the source set to **Detect language**, the
  detected language is shown under the translation (**Detected: Dutch**);
  tap it to choose another source language.
- **Uncertain detection.** Short texts are hard to detect: "Gift", "Bank" or
  "Hallo" are words in several languages. For a single short word, or when
  the engine says it isn't sure, the label reads **Detected: Dutch?** and
  chips for the other likely languages (for example German or Afrikaans)
  appear next to it; tap one to translate from that language instead. With a
  cloud AI model, input of up to three words also gets a second, small
  detection request, so that a doubtful guess is caught.
- **Your languages count** (AI): for short texts the model is told which
  languages you recently translated from (the sources of your recent
  language pairs) and prefers them when a word could be in several
  languages.
- **Swap languages** (the arrows between the two languages) exchanges them
  and moves the translation into the input. While detecting, it uses the
  detected language.
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
  tools > Recent language pairs**) to see the last eight pairs you
  translated with, such as *Spanish → English*, and pick one to set both
  languages at once. Pairs with a custom style are greyed out while the
  engine can't take one. **Clear recent language pairs** is in the sheet and
  under **Settings**.
- **Pinned target shortcuts.** On a keyboard, Alt+1 to Alt+9 translate into
  your first nine pinned target languages, in the order the picker lists them
  under **Pinned** (in a desktop browser the picker shows each one's
  shortcut). See [Keyboard shortcuts](#keyboard-shortcuts) for the browser
  and Mac variants.

## Extra target languages

Translate one text into several languages at once: **Also translate into…**
under the translation adds up to four more target languages next to the
main one.

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
  instant translation is on for the engine (**Instant translate**, or
  **Instant translate with AI**), otherwise when you press **Translate**. A language you add while a translation is shown is
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
services are listed too.

A badge tells you who receives your text: **On device** (offline
translation), **Self-hosted** (a server on this device, your network, or a
Tor or I2P address), **Public server** (a public Mozhi or LibreTranslate
instance run by someone else) or **Cloud** (an AI provider or DeepL's API).
After a translation, a chip under it names the exact destination ("Google
via mozhi.example.org"); tap it to see what that party can read. See
[Privacy](privacy.md#where-your-text-goes).

**Compare mode** (**Compare engines** in the toolbar) translates with all your
engines at once and shows the results side by side as they arrive, each with
its time, a copy button and **Use this** to make it the translation. Mozhi
engines are sent to the instance in a single request.

## Quality modes: Fast and Best

Like Kagi Translate's Standard and Best, you can keep two engines at hand: a
quick, cheap one for everyday text and your strongest one for text that
matters.

1. Open **Settings > Quality modes** (or **Quality modes** at the bottom of
   the engine list) and choose a **Fast engine** (for example Google or DeepL
   through Mozhi) and a **Best engine** (for example your best AI model).
2. A **Fast** / **Best** toggle appears next to the engine button. Choosing
   one translates the current text again with that engine; tapping the
   selected one again goes back to your **Usual engine**. On narrow screens
   the toggle shrinks to icons or a menu.

The translate screen remembers the mode you used last. Picking an engine from
the engine button turns the mode off. A link that carries text can ask for a
mode for that text with `quality=fast`, `quality=best` or `quality=standard`
(the usual engine); the link doesn't change your saved mode. See
[Links](#links).

## AI translation options

Open **Translation options** (the tune icon at the left of the language
bar) to shape AI translations. The icon changes when any option differs
from the defaults. **Done**, at the top right, closes the sheet, and
**Reset to defaults**, at the bottom, clears them. Options are remembered,
and the ones in use are shown as chips right above the language bar;
remove one with its chip, or all of them with **Reset options**.

| Option | Choices |
| --- | --- |
| Style | **Natural** (idiomatic, as a native speaker would say it) or **Literal** (close to the original wording) |
| Formality | Default, More formal, Less formal, Prefer formal, Prefer informal |
| Formality notes | Shown once a formality is chosen: free text such as "my boss, but we're on first-name terms" |
| Reading level | Standard, or a CEFR level from A1 (beginner) to C2 (proficient) to simplify the output for learners |
| Speaker gender / Addressee gender | Not specified, Masculine, Feminine, Neutral: for languages where grammar depends on who speaks or is spoken to |
| Context | Free text such as "a text message to my landlord" or "UI strings of a banking app" |
| Preserve formatting | Keep line breaks, Markdown, HTML tags, links, `{placeholders}`, `%s` and emoji intact (on by default) |
| Glossary | Term pairs that must always be translated the same way, e.g. product names |

Mozhi engines ignore these options. The DeepL API applies the formality and
the context; translation-only models (TranslateGemma, Hy-MT) ignore them.
With such an engine the sheet says so at the top and offers **Choose an AI
translator** (or **Add AI provider** when you have none). Your choices are
kept for when you use an AI model, and changing them doesn't translate
again with an engine that ignores them.

## Presets

**AI.** Like Kagi Translate's presets: a preset is a named set of translation
options (style, formality, reading level, genders, context and formatting)
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
under **Styles**. Custom targets appear in your recent languages.

The source can be custom too: type a dialect, or a style such as *LinkedIn
speak*, *Corporate jargon* or *Gen Z slang*, into the source language search
and choose **Use "…" as custom language**. For a style, the model works out
what the text really means (decoding the jargon, buzzwords and euphemisms)
and says it plainly in your target language, rather than imitating the
style.

## Refining a translation

**AI.** The chips under an AI translation, **More formal**, **More casual**,
**Shorter**, **Simpler**, **More fluent** and **More literal**, edit the
translation you are looking at instead of starting over:

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
- **More suggestions** asks the model for refinements that fit this
  particular text; they behave the same way.

Applied chips are cleared when you change the text, the languages, the
options or the engine. With a translation-only model (prompt style
TranslateGemma or Hunyuan-MT), a chip translates the text again with its
instruction instead, with nothing to stack or undo. Each refinement is one
request to the model.

## Kagi-style extras

These appear under a finished translation. With an AI engine they use that
model; with a Mozhi engine they use the model chosen under **Settings > AI
assistant for insights**, so you can translate with DeepL and still get the
extras.

- **Alternatives**: other ways to translate the text, each with a short note
  on how it differs. Pick one to make it the translation. To get
  alternatives for just a phrase, select it in the translation and choose
  **Alternatives** in the selection menu.
- **Insights**: underlines the phrases where the translation made a choice:
  idioms, nuances, wordplay, cultural references, grammar and ambiguities.
  Tap one to read why, and to swap in one of the **Other ways to say it**.
  Once switched on, insights load for each translation you start; after an
  instant translation with a cloud model they switch off instead, so typing
  never starts paid insight requests.
- **Explain**: a plain-language explanation of the translation, its grammar
  and its word choices. Ask follow-up questions in the same sheet.
- **Dictionary**: for inputs of one to three words; see
  [Dictionary](#dictionary).

## Romanization and alignment

**Romanization.** For translations in a non-Latin script (Japanese, Chinese,
Korean, Russian, Arabic, Hindi, Greek, Thai, ...), the output can be shown in
the Latin alphabet underneath. **Show romanization** (the *abc* button)
turns it on and off. AI models use the standard system for the language:
modified Hepburn for Japanese, Hanyu Pinyin with tone marks for Chinese,
Jyutping for Cantonese, the Revised Romanization for Korean, IAST for
Sanskrit, ISO 15919 for other Indic scripts, ALA-LC for Cyrillic and Arabic
scripts, RTGS for Thai, and so on.

It appears on its own (with **Settings > Show romanization** on, the
default) when that costs nothing: the Mozhi engine returned a
transliteration with the translation (Google does), or the AI model for
extras runs locally. With a cloud AI model each romanization is a separate
paid request, so it waits for you to press **Show romanization**. Once you
have, it stays on for the next translations you start; after an instant
translation it waits for you again.

**Alignment** (AI). **Show matching phrases** (the ⇄ button) asks the model which
phrases of the input and the translation correspond. Aligned phrases are
underlined; tap a phrase of the translation (or point at it with a mouse) to
highlight it and its counterpart in the input. Moving the cursor into an
underlined phrase of the input highlights its translation. Only the first
3,000 characters of long texts are aligned, and editing the input clears the
alignment. Alignment and insights are shown one at a time, and like insights
the alignment reloads for each translation you start.

## Meaning check

**Check meaning** (the checklist button under a finished translation) tells
you whether the translation still says what you wrote. It runs only when you
press it, never by itself; press it again (**Hide meaning check**) or use the
close button on the card to hide the result. Editing your text or getting a
new translation clears it.

**With an AI model for extras** (the AI model you translate with, or the one
under **Settings > AI assistant for insights** while you translate with a
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

- **Under a translation** of one to three words, the **Dictionary** card:
  **Look up "…"** shows the entry. Choose the **Detail level** (**Concise**,
  **Standard** or **Detailed**) before or after looking up. **Open
  dictionary** shows the word on the full dictionary page.
- **The Dictionary tab** (*What does this mean?*): type a word or phrase,
  choose its language (or **Detect language**) and the language of the
  translations, and press **Look up**. Opened from a translation's
  dictionary card, it looks that word up straight away.

Entries have the pronunciation (IPA), parts of speech, senses with
translations, examples, synonyms, etymology, usage notes and **Related
words** (tap one to look it up). For a misspelled word the entry offers
**Did you mean "…"?**. Definitions are written in the app's language by the
AI model (the one under **Settings > AI assistant for insights** when you
translate with a Mozhi engine) and are marked **AI-generated**.

A link such as `/dictionary?word=gato&from=es&to=en` opens the Dictionary tab
with the word filled in, but never looks it up on its own: press **Look up**.

## Proofread

**AI.** The **Proofread** tab (*Does this look right?*) checks grammar,
spelling, punctuation and style in any language.

- Choose the **Style** (General, Academic, Business, Casual, Creative, Email),
  the **Correction level** (*Light*: clear mistakes only; *Standard*: also
  awkward or unclear phrasing; *Comprehensive*: a thorough polish of wording,
  flow and tone), **Formality**, the **Model**, and optionally add
  **Context** such as "cover letter for a job application".
- **Reading level**: **As written** keeps the author's level; a CEFR level
  from A1 to C2 rewords the text for readers at that level.
- **Variety**: **As written** keeps the author's spelling and vocabulary; or
  convert to a regional variety: English (UK, US, Australia, Canada),
  Portuguese (Brazil, Portugal), Spanish (Spain, Latin America), French
  (France, Canada) or German (Germany, Switzerland, Austria). It applies to
  text in that language.
- The result shows the **Corrected text**; **Show changes** highlights what
  changed. Each **suggested edit** has a category (grammar, spelling,
  punctuation, style, clarity, word choice, tone, repetition) and an
  explanation, and can be applied or reverted individually, or all at once.
- **Writing statistics** compares the original and the corrected text:
  words, characters, sentences, paragraphs, words per sentence and reading
  time, plus the **Flesch reading ease** score (0 to 100, higher is easier)
  for English text. They are calculated on the device.
- **Use as input** continues from the corrected text. Ctrl+Enter runs the
  check. A link such as `/proofread?text=...` fills in the text without
  checking it.

## Image translation

Translate text in photos and screenshots: take a picture or pick one from your
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
  **Offline (Whisper)** in **Settings > Voice input**: OpenAI's Whisper
  model (Fast, 75 MB, or Better, 142 MB, downloaded from Hugging Face or
  imported from a file) recognises 99 languages on the phone, so your voice
  never leaves it. **Offline only** always uses Whisper (see
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

Translate whole files instead of copying them piece by piece: open a file (or
paste its content), translate it with any engine, then save or share the
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

**More tools > Web page** translates an article or a blog post: enter its
address and press **Translate page**. Mozhi downloads the page, keeps only
the readable text and translates it part by part with the engine and
languages you choose. Switch between **Translation**, **Original** and **Side
by side**, **Copy all** of it, or **Open original page** in your browser.
Very large pages are cut after their first part.

In the web app this only works for sites that allow cross-origin requests
(CORS), and most don't; use the Android app for those.

## Offline translation

On Android, Mozhi can translate without any network with Mozilla's
**Bergamot** engine and the **Firefox Translations** models (MPL-2.0), the
ones Firefox uses for its built-in translation: about 55 languages, each to
and from English, and between other languages through English. In
**Settings > Offline languages**, download the languages you need once
(about 50 MB to download and 73 MB on disk each; English is built in),
update them when a newer model is out, and delete them when you no longer
need them. With **Download over Wi-Fi only** on (the default), Mozhi asks
before using mobile data or a metered network. Models come from Mozilla's
storage (`storage.googleapis.com`) and are checked against bundled
checksums before use; none of your text is sent. To keep the app from
contacting that server at all (for example in **Offline only**), tap a
language to copy the links of its files, download them on another device,
copy them to the phone and use **Import from files**
([details](offline-engine.md#import-models-without-the-app-downloading-them)).
After that, translation
runs entirely on the phone, and results are marked **Offline**. Quality is
below the best online engines, but it works on a plane and nothing leaves
the device. Offline translation is not available on the web.

## History and favourites

- Every translation is saved on the device (unless you turn off
  **Settings > Save history**). When the same text is translated again into
  the same language with the same engine, for example after a refinement or
  after picking an alternative, the newest entry is updated instead of
  duplicated. Only the main translation is saved, not the translations into
  [extra target languages](#extra-target-languages).
- **History** (the clock button at the top of every tab) groups entries by
  day, with search across the text, the
  translation and the language names, and an **All / Favorites** filter.
  Below the search, **All language pairs** narrows the list to one pair
  (each with its number of translations; a detected source counts as the
  language it was detected as), and the **On device**, **Self-hosted**, **Public server**
  and **Cloud** chips to where the text was translated (only those that occur
  in your history are shown). Mozhi entries are classed by your current
  preferred instance, since an entry doesn't record which instance answered.
  **Clear filters** shows everything again. Tap an entry to open it in the
  translator; swipe it away to delete it (with undo).
- Star a translation to make it a **favourite**. Favourites are never removed
  automatically; the newest 1,000 other entries are kept.
- **Settings > Delete history automatically** removes translations older
  than 1, 7 or 30 days (**Never** by default); starred translations are
  always kept. If older translations already exist, Mozhi asks first
  (**Delete older translations now?**). While it is on, the History page says
  so, and **Import history** skips entries older than the setting.
- **Clear history** can keep your favourites.
- **Settings > Export history** copies your history as JSON or shares it as a
  file (plain, unencrypted JSON); **Import history** merges such JSON into
  your history, for example on a new phone.
- On the device the history is encrypted (AES-256-GCM, with the key in
  secure storage), and it is never part of a backup or a device transfer.

## Privacy controls

**Settings > Privacy** gathers what decides where your text goes and what
stays behind (details in [Privacy](privacy.md)):

- **Privacy mode**: **Offline only** (nothing leaves the device),
  **Offline first** (the default: on-device when the pair is installed,
  otherwise Mozhi asks once per language pair and destination) or
  **Online** (your services without asking; cloud providers still ask
  once each). A prompt shows the destination before anything is sent and
  offers **Once**, **Always for** the pair, downloading the pair for
  offline use, or changing the mode.
- **Incognito**: new translations aren't saved, and keyboards are asked
  not to learn what you type.
- **Hide content in recents & block screenshots** (Android): also blocks
  screen recording and screen sharing.
- **HTTP proxy** (Android): every request goes through it, for example
  Orbot's `127.0.0.1:8118` for Tor; needed for `.onion` and `.i2p`
  servers. Applies after restarting the app.
- **Delete all local data**: the history and its key, settings, keys and
  passwords, presets, glossaries, usage counters, cached lists and offline
  models; setup then starts again.

Copies are marked sensitive on Android 13+, so the system's copy preview
and keyboard clipboard suggestions don't show them. Plain `http` is used
only for this device, your network and Tor or I2P addresses.

## Usage and costs

**Settings > Usage & costs** shows, for each AI provider (and DeepL API or
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
- Open a provider under **Settings > AI providers** to set a **Monthly
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
- **More tools > Listen to the translation slowly** (for the translation).
- **Right-click Listen** and choose **Listen slowly** (not in a browser that
  shows its own menu).
- **Shift+Enter** (or Shift+Space) while **Listen** has keyboard focus.
- With a screen reader, the **Listen slowly** action of the button
  (TalkBack also offers it as the button's long press).

The sound comes from one of two places:

- **Device voices** (first): the text-to-speech voices of your phone,
  computer or browser read every language they have a voice for, and work
  offline when the voice is installed.
- **Mozhi voices**: only for a language the device has no voice for, your
  Mozhi instance fetches the audio from Google (with Reverso as a fallback).
  Mozhi receives the text in the request address, which can end up in its
  logs, so in **Offline first** the app asks first (**Listen online**), in
  **Offline only** it never does, and **Device voice only** turns it off.
  Long texts are read in parts, one after another.

**Settings > Read aloud** adjusts how text is read:

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
  A quick-translate sheet opens over the other app. If the text was selected
  in an editable field, **Replace** puts the translation back into that app;
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
- **Share** text from any app to Mozhi to translate it.
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
| `quality` | | `fast`, `best` or `standard` (your usual engine) for the link's own text; ignored by links without text. See [Quality modes](#quality-modes-fast-and-best) |

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
  **Translate**, even with **Instant translate with AI** on (it covers
  typing only).
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

| Shortcut | Action |
| --- | --- |
| Ctrl+Enter (⌘+Enter in a browser on a Mac) | Translate now (runs the comparison in compare mode); also runs Proofread |
| Ctrl+Shift+S (⌘+Shift+S) | Swap languages |
| Ctrl+Shift+C (⌘+Shift+C) | Copy the translation |
| Ctrl+L / Ctrl+Shift+L (⌘+L / ⌘+Shift+L) | Choose the target / source language (type to search, Enter picks the first match) |
| Alt+1 … Alt+9 | Translate into pinned language 1 to 9; in a browser Ctrl+Alt+1 … 9 (⌘+⌥+1 … 9 on a Mac), because browsers use Alt+digit for tabs |
| Esc | Clear the text (while typing) |
| Shift+Enter (on a focused Listen button) | [Listen slowly](#text-to-speech) from the start |
| ? or Ctrl+/ (⌘+/) | Show keyboard shortcuts |

The same list is under **More tools > Keyboard shortcuts**.

## Appearance and layout

- Light, dark or system theme; **Pure black** for OLED screens; Dynamic color
  or one of ten accent colours.
- Four tabs: **Translate**, **Dictionary**, **Proofread** and
  **Conversation**. **History** and **Settings** are the clock and gear
  buttons at the top of every tab; they open as full pages above the tabs,
  and their back arrow returns to the tab (or to Translate when a link or
  shortcut opened them).
- Phones use a bottom navigation bar (icons; each names itself to screen
  readers and in a tooltip). From 840 dp wide (tablets, foldables, wide
  browser windows) the app switches to a navigation rail with input and
  output side by side.
- Large touch targets and screen-reader labels throughout.

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
