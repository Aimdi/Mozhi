# FAQ

**General**

- [Is this the official Mozhi app?](#is-this-the-official-mozhi-app)
- [Is it free? Do I need an account?](#is-it-free-do-i-need-an-account)
- [Which back end should I use?](#which-back-end-should-i-use)
- [How many languages are supported?](#how-many-languages-are-supported)
- [Can I use it completely offline?](#can-i-use-it-completely-offline)

**AI**

- [Can I use my ChatGPT Plus, Claude or Gemini subscription?](#can-i-use-my-chatgpt-plus-claude-or-gemini-subscription)
- [Why are the translation options ignored?](#why-are-the-translation-options-ignored)
- [Why is AI translation slow?](#why-is-ai-translation-slow)
- [The model adds notes, answers questions in the text, or uses the wrong language](#the-model-adds-notes-answers-questions-in-the-text-or-uses-the-wrong-language)
- [What do Fast and Best do?](#what-do-fast-and-best-do)
- [Why is romanization not shown automatically?](#why-is-romanization-not-shown-automatically)
- [How do I keep an eye on what AI costs me?](#how-do-i-keep-an-eye-on-what-ai-costs-me)

**Translating**

- [Why didn't the link translate automatically?](#why-didnt-the-link-translate-automatically)
- [Why did the target language change by itself?](#why-did-the-target-language-change-by-itself)
- [Why does it ask which language a word is in?](#why-does-it-ask-which-language-a-word-is-in)

**Mozhi instances**

- [Why does it say it couldn't reach the Mozhi instance?](#why-does-it-say-it-couldnt-reach-the-mozhi-instance)
- [Why does Reverso (or DeepL) fail?](#why-does-reverso-or-deepl-fail)
- [What does the "Self-hosted" badge mean on a public instance?](#what-does-the-self-hosted-badge-mean-on-a-public-instance)

**Apps and platforms**

- [Does the web app work with my self-hosted servers?](#does-the-web-app-work-with-my-self-hosted-servers)
- ["Translate with Mozhi" is missing from the selection menu](#translate-with-mozhi-is-missing-from-the-selection-menu)
- [Android refuses to install the update](#android-refuses-to-install-the-update)
- [How do I move my history to a new device?](#how-do-i-move-my-history-to-a-new-device)
- [Where do I report bugs or ask for features?](#where-do-i-report-bugs-or-ask-for-features)

---

## General

### Is this the official Mozhi app?

No. [Mozhi](https://codeberg.org/aryak/mozhi) is a translation front-end by
Arya K and contributors; this app is an independent, unofficial client for
its API that also adds AI translation. Please report problems with the app
here, not to the Mozhi project.

### Is it free? Do I need an account?

The app is free and open source (MIT) and needs no account. Mozhi instances
are free to use. Cloud AI providers charge for their API (some have free
tiers); local models and offline translation are free. See
[What it costs](ai-providers.md#what-it-costs).

### Which back end should I use?

- **Just want it to work:** the built-in public Mozhi instances. Google and
  DeepL quality, nothing to set up.
- **Best quality and the Kagi-style extras:** a strong cloud AI model, such
  as Claude, GPT or Gemini.
- **Privacy first:** a local AI model, your own Mozhi instance with
  LibreTranslate, or offline translation.

You can combine them: for example DeepL through your own instance for quick
translations, with a local model for insights and alternatives, or a Fast
and a Best engine you switch between with one tap
([quality modes](features.md#quality-modes-fast-and-best)). See
[Getting started](getting-started.md#choose-where-translations-come-from).

### How many languages are supported?

It depends on the engine. Mozhi engines offer whatever the engine supports
(Google well over a hundred, LibreTranslate 17 through Mozhi). AI engines can
use any of about 290 languages and variants in the app's catalogue, plus any
custom target you type. Offline translation covers about 60 languages.

### Can I use it completely offline?

On Android and iOS, yes: download offline language packs and translate
without any network. A local AI model on a laptop also works without
internet, as long as the phone can reach the laptop (the same Wi-Fi, or the
laptop's hotspot).

## AI

### Can I use my ChatGPT Plus, Claude or Gemini subscription?

No. Chat subscriptions don't include API access. The app needs an API key,
which is billed separately by usage (often cheaply; see
[What it costs](ai-providers.md#what-it-costs)). Google AI Studio and some
other providers have free API tiers.

### Why are the translation options ignored?

Formality, reading level, context, glossary, custom styles and the other
options only work with AI engines. Mozhi engines (Google, DeepL, ...) don't
support them; your own [DeepL API](ai-providers.md#deepl-and-libretranslate)
service applies only the formality and the context. Translation-specialised
local models such as Hy-MT2 and TranslateGemma also ignore most of them; use
a general model for those
([details](ai-providers.md#which-local-model)).

### Why is AI translation slow?

- Models that "think" first are slower. Set **Reasoning effort** to **Low**
  in the provider settings (the default for OpenAI and Anthropic presets), or
  choose a non-reasoning model.
- Bigger models are slower. Try a smaller one (Claude Haiku, Gemini Flash,
  GPT mini) or a fast provider such as Groq.
- Local models: the first request loads the model into memory; after that,
  speed depends on your hardware. A model that doesn't fit in GPU memory runs
  partly on the CPU and is much slower.

### The model adds notes, answers questions in the text, or uses the wrong language

The app instructs models to output only the translation, to treat the text
strictly as something to translate, and to answer in the target language,
and it removes common additions such as surrounding quotes, a
"Translation:" label or a trailing "Note: ..." paragraph.
Small models sometimes don't follow these instructions. A larger model (12B+
for local models) fixes this in almost all cases.

### What do Fast and Best do?

They are Kagi Translate's quality modes. Under **Settings > Quality modes**
you choose a **Fast engine** (quick and free or cheap, such as Google or
DeepL through Mozhi) and a **Best engine** (your strongest model). The
**Fast** / **Best** toggle next to the engine button then switches between
them in one tap and translates the text again; tap the selected one again to
go back to your usual engine. The app remembers the mode, and a link can ask
for one with `quality=fast`, `quality=best` or `quality=standard`. See
[Quality modes](features.md#quality-modes-fast-and-best).

### Why is romanization not shown automatically?

Because it would cost money. Romanization (the Latin-script line under, say,
a Japanese translation) appears on its own only when it is free: when the
Mozhi engine sends one with the translation (Google does) or when the AI
model for extras runs locally. With a cloud AI model, every romanization is a
separate request, so it waits until you press **Show romanization** (the
*abc* button under the translation). Automatic romanization also needs
**Settings > Show transliteration** on (the default), and romanization only
applies to translations in a non-Latin script. See
[Romanization and alignment](features.md#romanization-and-alignment).

### How do I keep an eye on what AI costs me?

**Settings > Usage & costs** counts requests, characters and estimated tokens
per provider and month: translations, refinements, extras, proofreading,
documents and the dictionary. Results the app already had in memory aren't
counted, because they cost nothing. Set a **Monthly budget** on a provider to
be warned at 80 % and at 100 %. The counts are estimates kept on your device;
your provider's dashboard has the real bill.

## Translating

### Why didn't the link translate automatically?

A link (like text shared from another app) never starts a paid AI request
on its own, so that anyone who can send you a link can't spend your credit.
It fills in the text and languages and applies its options; with an AI model
you then press **Translate**. Mozhi engines, the DeepL API, LibreTranslate
and offline translation translate straight away, and so does an AI model if
you turned on **Settings > Instant translate with AI**. Links to the
dictionary, Proofread and the web page translator only fill in the word,
text or address. See [Links](features.md#links).

### Why did the target language change by itself?

That's the smart swap: the text was already in the target language (for
example English while translating into English), so Mozhi translated it into
another language you use instead and said **Translating into ... instead**.
Tap **Undo** in that message to go back; Mozhi then leaves that target alone
until you restart the app. Choosing the target yourself has the same effect.

### Why does it ask which language a word is in?

Short words often exist in several languages ("Gift" is English and German,
"Hallo" German and Dutch), so a single short word, or a text the engine is
unsure about, gets **Detected: Dutch?** with chips for the other likely
languages. Tap the right one, or set the source language yourself. With AI
models, the languages you recently translated from are preferred for short
texts.

## Mozhi instances

### Why does it say it couldn't reach the Mozhi instance?

Every instance in your list failed. Public instances go down or get rate
limited from time to time: open **Settings > Mozhi instances** to see which
ones respond, reorder them, or **Reset to public list** to restore the
built-in list. For your own instance, see
[Troubleshooting](self-hosting-mozhi.md#troubleshooting).

### Why does Reverso (or DeepL) fail?

Reverso blocks many server IP addresses, and DeepL and others rate-limit busy
instances. Try another engine or instance, or host your own instance at
home. See [Troubleshooting](self-hosting-mozhi.md#troubleshooting).

### What does the "Self-hosted" badge mean on a public instance?

The badge marks the kind of engine, not who runs it: **Self-hosted** means a
Mozhi engine (through your instance list), **Local** means a model on your
device or network, and **Cloud** a third-party AI provider. A public instance
is run by someone else, who could see your text. See [Privacy](privacy.md).

## Apps and platforms

### Does the web app work with my self-hosted servers?

Yes, with two browser rules to keep in mind:

1. **Mixed content.** A web app served over `https` can't call `http`
   addresses, except `localhost`. Serve your Mozhi instance and AI server over
   `https` (see [HTTPS with Caddy](self-hosting-mozhi.md#https-with-caddy)),
   or serve the web app itself over `http` on your LAN.
2. **CORS.** The server must allow requests from the web app's origin. Mozhi
   already does (`Access-Control-Allow-Origin: *`). For Ollama set
   `OLLAMA_ORIGINS`; in LM Studio turn on **Enable CORS**; llama.cpp's server
   allows cross-origin requests by default.

The native apps (Android, iOS, macOS, Windows) are not affected by either
rule. Also note that the CI build of the web app expects to be served from
`/Mozhi/app/`, and the release zip from the root of a web server (see
[Getting started](getting-started.md#web)).

### "Translate with Mozhi" is missing from the selection menu

Some apps show only a few actions and hide the rest behind the ⋮ button of
the selection menu. A few apps use custom text views that don't offer other
apps' actions at all; use **Share** there, or copy and paste. If you have
several flavours of the app installed (for example a development build),
each adds its own entry.

### Android refuses to install the update

The new APK is signed with a different key than the installed one, usually
because one of them came from a fork, a pull request build or a local build.
Export your history (**Settings > Export history**), uninstall, install the
new APK and import the history again.

### How do I move my history to a new device?

**Settings > Export history** on the old device (copy the JSON or share it as
a file), then **Settings > Import history** on the new one. Provider API keys
are not exported; enter them again. If **Delete history automatically** is on
on the new device, entries older than that setting are skipped.

### Where do I report bugs or ask for features?

Open an issue on [GitHub](https://github.com/Aimdi/Mozhi/issues). For problems
with a specific Mozhi instance or engine, check first whether Mozhi's own web
page on that instance shows the same error. Contributions are welcome; see
[Contributing](contributing.md).
