# Getting started

This guide takes you from download to your first translation, then shows how
to choose where your text goes and how to translate from inside other apps on
Android.

- [Install](#install)
- [First run](#first-run)
- [Choose where translations come from](#choose-where-translations-come-from)
- [Add an AI provider](#add-an-ai-provider)
- [Translate from other apps (Android)](#translate-from-other-apps-android)
- [Next steps](#next-steps)

## Install

### Android

Download an APK from one of two places:

- **Releases** (recommended): the app is released on GitHub only. Open the
  repository's [Releases page](https://github.com/Aimdi/Mozhi/releases) and
  download a file named like `mozhi-v1.2.3-arm64-v8a.apk` from the release
  marked **Latest**. From the stable `v0.1.0` on, Latest is always a stable
  version; release candidates (`v0.1.0-rc.14`, ...) are **pre-releases**
  for testers. The page also lists data releases (`dictionary-packs-…`,
  `phrasebooks-…`): they hold the offline dictionaries and starter
  phrasebooks the app downloads by itself, not the app.
- **Build artifacts** (newest code, for testers): open a recent successful run
  of the [`ci` workflow](https://github.com/Aimdi/Mozhi/actions/workflows/main.yaml)
  and download the `mozhi-android` artifact. It is a zip file with the same
  APKs (named without a version, such as `mozhi-arm64-v8a.apk`). Downloading
  artifacts requires a GitHub account, and GitHub deletes them after a while.

Pick the APK that matches your phone:

| File | For |
| --- | --- |
| `arm64-v8a` | Almost every phone and tablet from the last ten years. Start here. |
| `armeabi-v7a` | Old or low-end devices with a 32-bit system. |
| `x86_64` | Emulators, Chromebooks and other Intel/AMD devices. |
| `universal` | Any device. Larger download; use it if you are unsure. |

Optionally verify the download against `SHA256SUMS.txt` from the same release
or artifact:

```sh
sha256sum -c SHA256SUMS.txt --ignore-missing
```

Open the APK on your phone. Android asks you to allow the browser or file
manager to "install unknown apps" the first time; allow it, then tap
**Install**.

> **Updates and signing keys.** Install a newer APK over the old one to update;
> your settings and history are kept. Android only allows this when both APKs
> are signed with the same key. Builds made without the project's release key
> (for example from a fork or a pull request) are signed with a throwaway debug
> key, so to switch between such builds and official releases you have to
> uninstall first, which deletes your history. Export it first under
> **Settings > Privacy & data > Export history** if you want to keep it.

To get notified about new releases you can add the repository URL to an
update tracker such as [Obtainium](https://github.com/ImranR98/Obtainium).
In Obtainium, limit it to the app's releases so that it skips the data
releases (`dictionary-packs-…`, `phrasebooks-…`, which have no APK): app
tags start with `v`, so set a tag filter to `^v`; where your Obtainium
version only filters release titles (**Filter release titles by regular
expression**), use `^Mozhi v` (app releases are titled *Mozhi v0.1.0*,
data releases *Dictionary packs …* and *Starter phrasebooks …*). Data
releases are marked as pre-releases, so leaving **Include prereleases** off
skips them as well as the release candidates; turn it on (with the
filter) only if you want the candidates. Pick the APK of your phone
(`arm64-v8a` for most) when it asks.

### Web

There is no hosted copy of the web app; serve it yourself from any static web
server:

- Each release has a `mozhi-v1.2.3-web.zip` built for the root of a web
  server. It carries the starter phrasebooks (`models/phrasebooks/`), but
  not the offline languages, dictionaries or text recognition data: a
  browser can't download those from their publishers (no CORS), so the
  web app gets them from its own server's `models/` folder. Until you
  [mirror them](self-hosting-mozhi.md#mirror-the-on-device-models) there,
  those screens say *This web server doesn't host the downloads* and
  offer **Import from files** instead.
- Every CI run also produces the same static build (the `mozhi-web`
  artifact), also built for the root (base href `/`).

To serve it from a sub-path, change `<base href>` in its `index.html` (for
example to `/mozhi/`), or build it yourself with a different `--base-href`
(see [Contributing](contributing.md#building-releases)).

Once opened, the web app keeps its own files in the browser and opens again
without a network (turn it off in **Settings > General > Keep the web app
for offline use**); changing `<base href>` doesn't break this. Your server
should send `mozhi_sw.js`, `mozhi_sw_manifest.json`, `index.html` and
`flutter_bootstrap.js` with `Cache-Control: no-cache`; see
[Serve the web app](self-hosting-mozhi.md#serve-the-web-app).

The web app runs entirely in your browser and talks to Mozhi instances and AI
providers directly, which has a few consequences; see
[the FAQ](faq.md#does-the-web-app-work-with-my-self-hosted-servers).

## First run

When you open Mozhi for the first time, a short setup takes you through three
steps after the welcome screen (you can **Skip** at any point; everything is
also available in **Settings** later, and **Settings > About > Run setup
again** starts it over):

1. **Welcome**: what Mozhi does and how it handles your privacy.
2. **How private should translations be?**: pick the privacy mode.
   **Offline only** translates on the device and never contacts a server;
   **Offline first** (recommended) translates on the device when it can and
   asks you once per language pair before text goes to a server, even your
   own; **Online** uses the servers and AI providers you set up without
   asking each time (each cloud AI provider still asks once). See
   [Privacy](privacy.md) for the details.
3. **Pick your languages**: the languages you translate from (or Detect
   language) and into. While it is **Detect language**, Mozhi suggests one
   of your phone's other languages (**French is one of your phone's
   languages.** with **Translate from French**). Mozhi then offers to
   download the pair for offline use, with the size of each download: a
   checkbox per language, checked for you on Android when the phone has
   room. The checked languages download when you tap **Next** (never
   before; **Skip** downloads nothing); on mobile data it asks first, and
   **Download over Wi-Fi only** keeps downloads to Wi-Fi. Languages the
   offline engine doesn't support yet are named, because they need an
   online service.
4. **Online translation** (optional): for languages that aren't on the
   device. Mozhi uses one of the built-in public instances, run by
   volunteers, and tries the next one if it is down: **Using
   mozhi.example** names it, and **Change** lists the others to pick one.
   **Find the fastest server** translates the word "Hello" once on every
   listed server (with the engine Mozhi will use, Google unless you picked
   another; none of your text is sent), and puts the fastest first; a
   server that answers but doesn't translate is marked **Doesn't
   translate** and never picked. A server whose Google fails (Google
   rate-limits many of them) is tried once more with DuckDuckGo, as
   translations are with **If Google fails, use DuckDuckGo** (on by
   default): when that works it is marked **Via DuckDuckGo** and counts
   as working, after the servers where Google itself translates. It only
   runs when you tap it.
   **Use my own instance** lets you enter your server's address and **Test &
   add** it. AI translators are optional: **Open AI provider settings**
   finishes the setup and opens **Settings > AI > AI providers**.

Then tap **Start translating**.

**In the web app** the setup skips the privacy step: a browser can't
translate on its own, so your text always goes to a server. **Pick your
languages** has no downloads, and the **Online translation** step has an
**Ask before sending text** switch instead. It is off at first (the
**Online** privacy mode: the server is used without asking, and cloud AI
providers still ask once); turned on, Mozhi asks once for each language
pair before text goes to the server.

After that you land on the **Translate** tab:

1. The **language bar** at the bottom shows the source language (Detect
   language by default; once it has detected one, **Detected: German**)
   and the target language. Tap either one to search all languages, pin
   the ones you use or pick a recent one. The arrows in the middle swap
   them; long-press them for your recent language pairs. With no text yet,
   the bar sits in a card with the text box under a greeting and chips for
   **Camera** and **Document**; once you type, it stays docked at the
   bottom of the screen, right above the keyboard. On wide screens the
   languages sit above two panes instead, and the options and the go button
   under your text.
2. The **engine button** chooses who translates: one of the engines your
   Mozhi instance offers (Google, DeepL, ...) or one of your AI models.
   Right after the setup, in **Offline first**, it says **On device +
   Google**: what the device can translate stays on it, and for a language
   that isn't downloaded Mozhi asks before sending your text to Google
   (**Once** or **Always for** that pair), next to **Download French
   (49.6 MB)**, which downloads it right there and then translates on the
   device. Once
   you have chosen a Fast and a Best engine under **Settings > Translation
   engines > Quality modes**, a **Fast** / **Best** toggle next to it
   switches between them, and one of the two is always selected.
3. Type or paste text. With instant translation on (the default, for every
   engine) the translation appears as you type; otherwise press the go
   button at the right of the language bar (the arrow, **Translate**) or
   Ctrl+Enter on a keyboard. The tune icon at the left of the language bar
   opens the translation options.
4. The screen shows only the languages, your text and the translation,
   with its actions (copy, listen, favorite, share, full screen). Under an
   AI translation, the refinement chips (**More formal**, **Shorter**, ...)
   are always there. **Tools**, under the translation, opens the other
   tools: check meaning, insights, romanization, matching phrases, compare
   engines, alternatives and explanations (under **Learn**), definitions
   and **Also translate into**. Most of them need an AI model; see the
   [feature tour](features.md). When the privacy mode stops a translation
   before your text leaves the device, the prompt also offers **Translate
   on this device** (or, first, the download that language pair needs) if
   the offline engine supports the pair.

The other tabs are **Dictionary** (definitions, examples and translations of
a word) and **Proofread** (grammar and style checks), which use an AI model,
and **Conversation** (two people, two languages). **History** and
**Settings** are the clock and gear buttons at the top of every tab; their
back arrow returns to the tab. On wide screens, such as tablets and wide
browser windows, the tabs move into a sidebar and input and output sit side
by side.

## Choose where translations come from

Mozhi can use several kinds of back ends, and you can mix them:

| Back end | Setup | Who sees your text | Cost |
| --- | --- | --- | --- |
| Public Mozhi instance | None (a list is built in) | The instance operator, and the engine it forwards to (Google, DeepL, ...) | Free |
| Your own Mozhi instance | A server or home machine with Docker | The engine your instance forwards to; nobody else | Free |
| Your own Mozhi instance with LibreTranslate | As above, plus LibreTranslate | Nobody: everything stays on your server | Free |
| DeepL API or your own LibreTranslate server | A DeepL API key, or a LibreTranslate server address | DeepL, or nobody but your server | DeepL: Free plan with a monthly limit, or paid Pro; your own LibreTranslate: free |
| Cloud AI provider | An API key | The AI provider | Pay per use (some have free tiers) |
| Local AI model | Ollama, LM Studio or llama.cpp on a computer you own | Nobody: it runs on your hardware | Free |
| Offline (Android) | Download language packs once | Nobody: it runs on the device | Free |

### Public instances

Mozhi ships with the public instances listed in the
[Mozhi README](https://codeberg.org/aryak/mozhi#instances), so it works out of
the box. The servers that translate with Google, the default engine, come
first; servers an app can't use (gone, or behind a bot check that only lets
web browsers through) are left out, and the list is checked every week.
Open **Settings > Translation engines > Mozhi instances** to see
them with their response times. Instances are tried from top to bottom: if
the first one is down, slow or rate limited, the app quietly moves on to the
next. Drag an instance to reorder the list, or use **Make preferred** to move
it to the top. **Reset to public list** restores the built-in list.

After an update, a list you never changed gets the new built-in order, and
built-in servers that were retired are removed from every list. Instances
you added and a list you reordered stay as they are.

Public instances are run by volunteers. Be kind to them, and keep in mind
that their operators could see what you translate.

### Your own instance

Running your own instance takes a couple of minutes with Docker:

```sh
docker run -d --name mozhi --restart unless-stopped \
  -p 3000:3000 codeberg.org/aryak/mozhi:latest
```

Then, in **Settings > Translation engines > Mozhi instances > Add
instance**, enter
`http://<your-server-ip>:3000`, tap **Test**, save, and move it to the top.
Plain `http` works on your home network. The full guide, with HTTPS,
LibreTranslate and troubleshooting, is
[Self-hosting Mozhi](self-hosting-mozhi.md); ready-made Compose files are in
[`deploy/`](../deploy/README.md).

## Add an AI provider

An AI provider unlocks the Kagi-style features: translation options
(formality, reading level, context, glossary, ...), custom styles such as
*Pirate speak*, refinement chips, alternatives, word insights, explanations,
romanization and phrase alignment, the meaning check, the dictionary and the
Proofread tab.

1. Open **Settings > AI > AI providers** and tap **Add provider**.
2. Choose a preset: OpenAI, Anthropic, Google Gemini, OpenRouter, Groq,
   DeepSeek, Mistral AI, xAI, Together AI, Ollama, LM Studio, llama.cpp
   server, or **Custom (OpenAI-compatible)** for anything else. (**Machine
   translation** lists the DeepL API and LibreTranslate; see
   [AI providers](ai-providers.md#deepl-and-libretranslate).)
3. For a cloud provider, tap **Get an API key**, create a key on the
   provider's website and paste it. Local servers need no key.
4. Keep the suggested model or tap **Browse models** to pick another one.
5. Tap **Test connection**. Mozhi translates "Hello, world!" into French; if
   that works, tap **Save**.
6. Back on the Translate tab, tap the engine button and choose the new model.

Keys are stored in the platform's secure storage and are only ever sent to the
provider they belong to.

**Running a model on your own computer?** On a phone, `localhost` means the
phone itself, so use your computer's LAN address (for example
`http://192.168.1.20:11434` for Ollama) and make the server listen on the
network. [AI providers](ai-providers.md) has step-by-step instructions for
Ollama, LM Studio, llama.cpp and vLLM, and model recommendations for your
hardware.

**Mozhi engines plus AI.** You do not have to give up Google or DeepL to get
the AI extras: while a Mozhi engine translates, an AI model can still provide
alternatives, word insights, explanations, romanization, alignment, the
meaning check and the dictionary. Choose which model under **Settings > AI >
AI assistant for insights** (by default the first enabled provider).

## Translate from other apps (Android)

**Selected text.** Select text in any app (a browser, a chat, an e-mail) and
choose **Translate with Mozhi** in the selection menu. Depending on the app,
it may be hidden behind the menu's ⋮ overflow button. A quick-translate
sheet opens over the app with the translation into your current target
language. **Open in app** continues in the full translator.

If you selected the text in an editable field, such as a message you are
writing, the sheet also offers **Replace**. Tap it and the translation
replaces your selection in the other app.

**Translate offline**, next to it in the selection menu, translates the
selection with the [offline engine](offline-engine.md) only, whatever your
privacy mode: the text never leaves your phone. If a language isn't
downloaded yet, the sheet names it with its size, and its **Download**
button opens **Settings > Translation engines > Offline languages**; select
the text again once
it's there. **Replace** works the same; **Open in app** continues in the
full translator with your current engine.

**Improve with Mozhi**, the third entry, checks your writing instead of
translating it, like DeepL Write: the selection is proofread with the AI
model of the **Proofread** tab, and the sheet shows the improved text with
the changes highlighted. Pick a correction level or a style to try again,
**Copy** it, **Replace** your selection with it (in an editable field), or
**Open in Proofread** to review each change. It needs an AI provider or an
on-device AI model, and follows your privacy settings like the Proofread
tab: a cloud provider is asked about first, and **Offline only** keeps the
text on the phone.

**Share sheet.** Use **Share** in any app and pick **Mozhi** to translate the
shared text.

**Links.** Links such as
`https://<host>/#/translate?text=hola&from=es&to=en` (web app) or
`mozhi://translate?text=hola&from=es&to=en` (Android) open the
translator with the text and languages filled in. The parameters are the same
as Kagi Translate's, including options such as `formality` and `quality`;
`q`, `sl` and `tl` work too. The text is translated straight away with Mozhi
engines and other engines that aren't AI models. With an AI model, press
**Translate**: a link never starts a paid AI request on its own. See
[Features](features.md#links).

## Next steps

- Take the [feature tour](features.md).
- Choose a Fast and a Best engine under **Settings > Translation engines >
  Quality modes**.
- Pick a model with the help of [AI providers](ai-providers.md).
- Read what each back end can see in [Privacy](privacy.md).
