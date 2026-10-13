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

**AI.** Save the current translation options as a named preset, for example
"E-mail to clients" (formal, business context, your product glossary) or
"Chat with friends" (informal), and switch between them in one tap.

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
gallery.

- With an AI model that has **Supports images** turned on, the model reads
  and translates the text in the image itself, with your translation options.
- With a Mozhi instance, the image is translated by Google through Mozhi,
  which returns the recognised text, its translation and a translated copy of
  the image. Mozhi accepts images up to 4 MB.
- On Android and iOS the text can also be recognised on the device (ML Kit
  text recognition) and then translated with any engine.

## Voice

- **Dictation**: tap the microphone and speak instead of typing. Speech
  recognition is provided by your device's operating system.
- **Conversation**: two people, two languages. Each person speaks in turn and
  hears or reads the other's words in their own language.
- **Device voices**: besides your Mozhi instance's voices (see
  [Text-to-speech](#text-to-speech)), the app can read text aloud with the
  device's built-in text-to-speech voices.

## Documents

Translate whole text documents instead of copying them piece by piece: open a
file, translate it with the current engine and options, then save or share
the result. Long documents are sent in parts. AI engines with **Preserve
formatting** on keep the structure (headings, lists, Markdown) intact.

## Offline translation

On Android and iOS, Mozhi can translate without any network using Google's ML
Kit on-device models (about 60 languages). Download the languages you need
once (around 30 MB each, over Wi-Fi by default); after that, translation runs
entirely on the phone. Quality is below the online engines, but it works on a
plane and nothing leaves the device. Offline translation is not available on
the web or desktop.

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
  Mozhi opens with the selection translated. If the text was selected in an
  editable field, **Replace text** puts the translation back into the other
  app.
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
| `to` | `tl`, `target` | Target language; with an AI engine also a custom style such as `Pirate%20speak` |

The app waits for the engines to load, selects the languages, and translates.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| Ctrl+Enter (⌘+Enter on Apple devices) | Translate now (runs the comparison in compare mode); also runs Proofread |
| Ctrl+Shift+S (⌘+Shift+S) | Swap languages |

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
