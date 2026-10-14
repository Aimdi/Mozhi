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

- **Releases** (recommended): open the repository's
  [Releases page](https://github.com/Aimdi/Mozhi/releases) and download a file
  named like `mozhi-v1.2.3-arm64-v8a.apk` from the latest release.
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
> **Settings > Export history** if you want to keep it.

To get notified about new releases you can add the repository URL to an
update tracker such as [Obtainium](https://github.com/ImranR98/Obtainium).

### Web

The [project website](https://aimdi.github.io/Mozhi/) links to a hosted copy
of the web app (**Try the web app**). To host it yourself:

- Each release has a `mozhi-v1.2.3-web.zip` built for the root of a web
  server. To serve it from a sub-path, change `<base href>` in its
  `index.html` (for example to `/mozhi/`).
- Every CI run also produces a static build (the `mozhi-web` artifact) built
  for the `/Mozhi/app/` sub-path.

To use another path, you can also build it yourself with a different
`--base-href` (see [Contributing](contributing.md)).

The web app runs entirely in your browser and talks to Mozhi instances and AI
providers directly, which has a few consequences; see
[the FAQ](faq.md#does-the-web-app-work-with-my-self-hosted-servers).

### iOS, macOS and Windows

There are no prebuilt packages yet. Build from source as described in
[Contributing](contributing.md).

## First run

When you open Mozhi for the first time, a short setup takes you through three
steps (you can **Skip** at any point; everything is also available in
**Settings** later):

1. **Welcome**: what Mozhi does and how it handles your privacy.
2. **Choose a translation service**: **Find the fastest public instance**
   tests the built-in public instances and moves the fastest to the top
   (**Sort by speed** orders them all by response time), or **Use my own
   instance** to enter your server's address and **Test & add** it.
3. **Add an AI translator** (optional): pick a provider, enter its key or
   your local server's address, and test it.

Then tap **Start translating**.

After that you land on the **Translate** tab:

1. The **language bar** at the top shows the source language (Detect language
   by default) and the target language. Tap either one to search all
   languages, pin favourites or pick a recent one. The arrows in the middle
   swap them; long-press them for your recent language pairs.
2. The **engine button** chooses who translates: one of the engines your
   Mozhi instance offers (Google, DeepL, ...) or one of your AI models. Once
   you have chosen a Fast and a Best engine under **Settings > Quality
   modes**, a **Fast** / **Best** toggle next to it switches between them.
3. Type or paste text. With **Instant translate** on (the default for Mozhi
   engines) the translation appears as you type; otherwise press
   **Translate** (or Ctrl+Enter on a keyboard).
4. Under the translation, the chips (**More formal**, **Shorter**, ...) and
   the extras need an AI model; see the [feature tour](features.md).

The other tabs are **Proofread** (grammar and style checks with an AI model),
**History** and **Settings**. On wide screens, such as tablets and desktops,
the tabs move into a side rail and input and output sit side by side.

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
| Offline (Android and iOS) | Download language packs once | Nobody: it runs on the device | Free |

### Public instances

Mozhi ships with the public instances listed in the
[Mozhi README](https://codeberg.org/aryak/mozhi#instances), so it works out of
the box. Open **Settings > Mozhi instances** to see them with their response
times. Instances are tried from top to bottom: if the first one is down, slow
or rate limited, the app quietly moves on to the next. Drag an instance to
reorder the list, or use **Make preferred** to move it to the top. **Reset to
public list** restores the built-in list.

Public instances are run by volunteers. Be kind to them, and keep in mind
that their operators could see what you translate.

### Your own instance

Running your own instance takes a couple of minutes with Docker:

```sh
docker run -d --name mozhi --restart unless-stopped \
  -p 3000:3000 codeberg.org/aryak/mozhi:latest
```

Then, in **Settings > Mozhi instances > Add instance**, enter
`http://<your-server-ip>:3000`, tap **Test**, save, and move it to the top.
Plain `http` works on your home network. The full guide, with HTTPS,
LibreTranslate and troubleshooting, is
[Self-hosting Mozhi](self-hosting-mozhi.md); ready-made Compose files are in
[`deploy/`](../deploy/README.md).

## Add an AI provider

An AI provider unlocks the Kagi-style features: translation options
(formality, reading level, context, glossary, ...), custom styles such as
*Pirate speak*, refinement chips, alternatives, word insights, explanations,
romanization and phrase alignment, the dictionary and the Proofread tab.

1. Open **Settings > AI providers** and tap **Add provider**.
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
alternatives, word insights, explanations, romanization, alignment and the
dictionary. Choose which model under **Settings > AI assistant for insights**
(by default the first enabled provider).

## Translate from other apps (Android)

**Selected text.** Select text in any app (a browser, a chat, an e-mail) and
choose **Translate with Mozhi** in the selection menu. Depending on the app,
it may be hidden behind the menu's ⋮ overflow button. A quick-translate
sheet opens over the app with the translation into your current target
language. **Open in app** continues in the full translator.

If you selected the text in an editable field, such as a message you are
writing, the sheet also offers **Replace**. Tap it and the translation
replaces your selection in the other app.

**Share sheet.** Use **Share** in any app and pick **Mozhi** to translate the
shared text.

**Links.** Links such as
`https://<host>/Mozhi/app/#/translate?text=hola&from=es&to=en` (web app) or
`mozhi://translate?text=hola&from=es&to=en` (Android and iOS) open the
translator with the text and languages filled in. The parameters are the same
as Kagi Translate's, including options such as `formality` and `quality`;
`q`, `sl` and `tl` work too. The text is translated straight away with Mozhi
engines and other engines that aren't AI models. With an AI model, press
**Translate**: a link never starts a paid AI request on its own, unless you
turned on **Instant translate with AI**. See [Features](features.md#links).

## Next steps

- Take the [feature tour](features.md).
- Choose a Fast and a Best engine under **Settings > Quality modes**.
- Pick a model with the help of [AI providers](ai-providers.md).
- Read what each back end can see in [Privacy](privacy.md).
