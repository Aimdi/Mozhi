# Feature tour

Everything Mozhi can do, screen by screen. Features marked **AI** need an
[AI provider](ai-providers.md); everything else works with a Mozhi instance
alone.

- [Translate](#translate)
- [Engines and compare mode](#engines-and-compare-mode)
- [AI translation options](#ai-translation-options)
- [Presets](#presets)
- [Custom languages and styles](#custom-languages-and-styles)
- [Kagi-style extras](#kagi-style-extras)
- [Proofread](#proofread)
- [Image translation](#image-translation)
- [Voice](#voice)
- [Documents](#documents)
- [Offline translation](#offline-translation)
- [History and favourites](#history-and-favourites)
- [Text-to-speech](#text-to-speech)
- [Android integration](#android-integration)
- [Links](#links)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Appearance and layout](#appearance-and-layout)
- [Platform support](#platform-support)

## Translate

- **Languages.** Tap the source or target language to open the picker: search
  by English or native name or by code, pick from **Recent** (your last eight
  languages) or **Pinned** languages, or browse **All languages**. Mozhi
  engines show the languages that engine supports; AI engines offer about 290
  languages and variants, from Brazilian Portuguese and Cantonese to Latin and
  Toki Pona.
- **Detect language.** With the source set to *Detect language*, the
  detected language is shown under the translation, and **Swap** uses it.
- **Instant translate.** With Mozhi engines the translation updates shortly
  after you stop typing. For AI engines this is off by default because each
  request costs tokens; turn on **Settings > Instant translate with AI** if you
  want it. Otherwise press **Translate**.
- **Output actions:** copy, share, listen, add to favourites, and the elapsed
  time per engine.
- **Transliteration.** For non-Latin scripts, a romanised version appears
  under the text when the engine provides it (Google does). Turn it off under
  **Settings > Show transliteration**.
- **Definitions.** For single words, Google and Reverso results from Mozhi
  include definitions with examples and synonyms.
- **Same language in and out** (AI): choose the same source and target
  language to have the text improved and rephrased instead of translated.

## Engines and compare mode

The engine button lists two groups:

- **Mozhi engines** of your preferred instance: Google, DeepL, Reverso,
  Yandex, LibreTranslate, DuckDuckGo and MyMemory, whichever it offers.
- **AI models**: every enabled AI provider, with its model name.

A badge tells you where your text goes: **Local** (a model on your device or
network), **Self-hosted** (a Mozhi engine, through your instance list) or
**Cloud** (a third-party AI provider). See [Privacy](privacy.md).

**Compare mode** (**Compare engines** in the toolbar) translates with all your
engines at once and shows the results side by side as they arrive, each with
its time, a copy button and **Use this** to make it the translation. Mozhi
engines are sent to the instance in a single request.

## AI translation options

Open **Translation options** (the tune icon) to shape AI translations. The
icon changes when any option differs from the defaults, and **Reset to
defaults** clears them. Options are remembered.

| Option | Choices |
| --- | --- |
| Style | **Natural** (idiomatic, as a native speaker would say it) or **Literal** (close to the original wording) |
| Formality | Default, More formal, Less formal, Prefer formal, Prefer informal |
| Reading level | Standard, or a CEFR level from A1 (beginner) to C2 (proficient) to simplify the output for learners |
| Speaker gender / Addressee gender | Not specified, Masculine, Feminine, Neutral: for languages where grammar depends on who speaks or is spoken to |
| Context | Free text such as "a text message to my landlord" or "UI strings of a banking app" |
| Preserve formatting | Keep line breaks, Markdown, HTML tags, links, `{placeholders}`, `%s` and emoji intact (on by default) |
| Glossary | Term pairs that must always be translated the same way, e.g. product names |

Mozhi engines ignore these options.

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

## Kagi-style extras

These appear under a finished translation. With an AI engine they use that
model; with a Mozhi engine they use the model chosen under **Settings > AI
assistant for insights**, so you can translate with DeepL and still get the
extras.

- **Refine** chips (AI engines): one tap to retranslate *More formal*, *More
  casual*, *Shorter*, *Simpler*, *More fluent* or *More literal*. **More
  suggestions** asks the model for refinements that fit this particular text.
- **Alternatives**: other ways to translate the text, each with a short note
  on how it differs. Pick one to make it the translation.
- **Insights**: underlines the phrases where the translation made a choice:
  idioms, nuances, wordplay, cultural references, grammar and ambiguities.
  Tap one to read why, and to swap in one of the **Other ways to say it**.
  Once switched on, insights load for each new translation.
- **Explain**: a plain-language explanation of the translation, its grammar
  and its word choices. Ask follow-up questions in the same sheet.
- **Dictionary**: for inputs of one to three words, **Look up** shows
  definitions, examples, synonyms and etymology. Entries are AI-generated and
  marked as such.

## Proofread

**AI.** The **Proofread** tab checks grammar, spelling, punctuation and style
in any language.

- Choose the **Style** (General, Academic, Business, Casual, Creative, Email),
  the **Correction level** (*Light*: clear mistakes only; *Standard*: also
  awkward or unclear phrasing; *Comprehensive*: a thorough polish of wording,
  flow and tone), **Formality**, the **Model**, and optionally add
  **Context** such as "cover letter for a job application".
- The result shows the **Corrected text**; **Show changes** highlights what
  changed. Each **suggested edit** has a category (grammar, spelling,
  punctuation, style, clarity, word choice, tone, repetition) and an
  explanation, and can be applied or reverted individually, or all at once.
- **Use as input** continues from the corrected text. Ctrl+Enter runs the
  check.

## Image translation

Translate text in photos and screenshots: take a picture or pick one from your
gallery, then choose how to translate it:

- **AI vision**: an AI model with **Supports images** turned on reads and
  translates the text itself, with your translation options. One choice per
  such model.
- **Mozhi (Google Lens)**: when your instance offers Google, Mozhi sends the
  image to Google and returns the recognised text, its translation and a copy
  of the image with the translation drawn in.
- **On-device recognition** (Android and iOS): ML Kit reads the text on the
  phone, and the text is then translated with your current engine.

Large photos are scaled down before uploading (longest side 2048 px, under
4 MB), which keeps them within Mozhi's upload limit.

## Voice

- **Dictation**: tap the microphone and speak instead of typing. Speech
  recognition is provided by your device's operating system (or browser).
  On Android 12+, iOS and macOS you can turn on **Prefer on-device speech
  recognition** so the audio isn't sent to an online service.
- **Conversation**: two people, two languages. Each person speaks in turn and
  hears or reads the other's words in their own language.
- **Device voices**: besides your Mozhi instance's voices (see
  [Text-to-speech](#text-to-speech)), the app can read text aloud with the
  device's built-in text-to-speech voices.

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

## Offline translation

On Android and iOS, Mozhi can translate without any network using Google's ML
Kit on-device models (about 60 languages). In the offline languages page,
download the languages you need once (around 30 MB each; **Wi-Fi only** is on
by default) and delete them when you no longer need them. After that,
translation runs entirely on the phone, and results are marked **Offline**.
Quality is below the online engines, but it works on a plane and nothing
leaves the device. Offline translation is not available on the web or
desktop.

## History and favourites

- Every translation is saved on the device (unless you turn off
  **Settings > Save history**). When the same text is translated again into
  the same language with the same engine, for example after a refinement or
  after picking an alternative, the newest entry is updated instead of
  duplicated.
- **History** groups entries by day, with search across the text, the
  translation and the language names, and an **All / Favorites** filter. Tap
  an entry to open it in the translator; swipe it away to delete it (with
  undo).
- Star a translation to make it a **favourite**. Favourites are never removed
  automatically; the newest 1,000 other entries are kept.
- **Clear history** can keep your favourites.
- **Settings > Export history** copies your history as JSON or shares it as a
  file; **Import history** merges such JSON into your history, for example on
  a new phone.

## Text-to-speech

**Listen** reads the source or the translation aloud. The audio comes from
your Mozhi instance (Google's voices, with Reverso as a fallback), so it needs
a reachable instance; see also [device voices](#voice). Tap again to stop.

## Android integration

- **Translate with Mozhi** appears in the text-selection menu of other apps.
  A quick-translate sheet opens over the other app. If the text was selected
  in an editable field, **Replace** puts the translation back into that app;
  **Open in app** continues in the full translator.
- **Quick Settings tile** and the **Translate clipboard** app shortcut open
  the translator with the clipboard text.
- **Share** text from any app to Mozhi to translate it.
- **Material You**: with **Dynamic color** on (Android 12 and later), the app
  takes its colours from your wallpaper.

## Links

Mozhi understands Kagi Translate-style links. In the web app:

```text
https://<host>/Mozhi/#/translate?text=hola&from=es&to=en
https://<host>/Mozhi/?text=hola&from=es&to=en
```

| Parameter | Also accepted | Meaning |
| --- | --- | --- |
| `text` | `q` | Text to translate (optional: leave it out to only set languages) |
| `from` | `sl`, `source` | Source language: a code (`es`, `pt-BR`), an English or native name, or `auto` |
| `to` | `tl`, `target` | Target language: a code or a name the selected engine supports |

The app waits for the engines to load and selects the languages. Text from
links, shares and other apps is limited to 5,000 characters. It is translated
straight away only with engines that cost nothing (Mozhi, offline, local
models); with a paid AI provider, press Translate yourself. Custom styles
such as *Pirate speak* can't be set from a link; pick them in the app.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| Ctrl+Enter (⌘+Enter on Apple devices) | Translate now (runs the comparison in compare mode); also runs Proofread |
| Ctrl+Shift+S (⌘+Shift+S) | Swap languages |
| Ctrl+Shift+C (⌘+Shift+C) | Copy the translation |
| Ctrl+L / Ctrl+Shift+L (⌘+L / ⌘+Shift+L) | Choose the target / source language |
| Esc | Clear the input |
| ? or Ctrl+/ (⌘+/) | Show all shortcuts |

## Appearance and layout

- Light, dark or system theme; **Pure black** for OLED screens; Dynamic color
  or one of ten accent colours.
- Phones use a bottom navigation bar. From 840 dp wide (tablets, foldables,
  desktop windows) the app switches to a navigation rail with input and
  output side by side.
- Large touch targets and screen-reader labels throughout.

## Platform support

| Feature | Android | iOS | macOS | Windows | Web |
| --- | --- | --- | --- | --- | --- |
| Mozhi engines, AI providers, Proofread, history | ✓ | ✓ | ✓ | ✓ | ✓ |
| Text selection menu and share target | ✓ | | | | |
| Offline translation, on-device text recognition | ✓ | ✓ | | | |
| Dynamic color from wallpaper | ✓ (12+) | | | | |

On the web, the browser enforces some extra rules for self-hosted servers;
see the [FAQ](faq.md#does-the-web-app-work-with-my-self-hosted-servers).
