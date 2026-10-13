# Mozhi

[![ci](https://github.com/Aimdi/Mozhi/actions/workflows/main.yaml/badge.svg)](https://github.com/Aimdi/Mozhi/actions/workflows/main.yaml)
[![style: very good analysis][very_good_analysis_badge]][very_good_analysis_link]
[![License: MIT][license_badge]][license_link]

A fast, private translator for Android, iOS, macOS, Windows and the web.

Mozhi is a client for self-hostable [Mozhi][mozhi] translation instances (the
privacy front-end for Google, DeepL, Reverso, Yandex, LibreTranslate and more)
and an AI translator that works with any OpenAI-compatible, Anthropic, Gemini
or Ollama endpoint, including models that run on your own machine. The aim is
to feel as good as Kagi Translate, without an account and without sending your
history anywhere.

---

## Features

**Translation engines**

- Every engine your Mozhi instance offers (Google, DeepL, Reverso, Yandex,
  LibreTranslate, DuckDuckGo, MyMemory, ...), with automatic failover across
  your ordered list of instances.
- **Compare mode**: run all engines (or the ones you pick) side by side and
  keep the best result.
- **AI providers**: OpenAI, Anthropic (Claude), Google Gemini, OpenRouter,
  Groq, DeepSeek, Mistral, xAI, Together, and local runtimes (Ollama,
  LM Studio, llama.cpp server) or any OpenAI-compatible URL. Local engines
  get a privacy badge.

**Kagi-style AI extras**

- Options: natural or literal style, formality, reading level (CEFR A1 to C2),
  speaker and addressee gender, free-form context, glossary.
- Custom target "languages" such as *Pirate speak*, *Plain English* or
  *LinkedIn speak*.
- Alternatives (for the whole text or a selected span), word insights with
  variations, one-tap refinement suggestions, *Explain this translation*,
  and a dictionary card for short inputs.
- AI engines can still assist while a Mozhi engine translates.
- **Proofread** tab: corrections with explanations, writing style and
  correction level.

**Everyday use**

- Instant translation while typing (debounced; optional for AI engines),
  detected source language with smart swap, transliteration, text-to-speech.
- **History and favourites**, searchable, with JSON export and import.
- **Android**: *Translate with Mozhi* in the text-selection menu of any app
  (it can replace the selected text with the translation in editable fields)
  and a share target for text.
- Links like `/translate?text=hola&from=es&to=en` open pre-filled (same
  parameters as Kagi Translate; `q`, `sl` and `tl` work too).
- Material 3 with Material You colours, dark mode and pure-black mode;
  bottom navigation on phones and a navigation rail on tablets and desktops.

**Privacy**

- No account, no telemetry, no analytics.
- History and settings stay on the device; API keys are kept in the platform's
  secure storage.
- Your text only goes to the Mozhi instance or AI provider you choose. Run both
  yourself and nothing leaves your network.

---

## Install

- **Android**: download an APK from [Releases][releases] (or the `mozhi-android`
  artifact of a recent [CI run][actions]). Pick `arm64-v8a` for almost every
  modern phone, `armeabi-v7a` for old 32-bit devices, or `universal` if unsure.
  Check downloads against `SHA256SUMS.txt`.
- **Web**: every CI run also produces a static build (`mozhi-web` artifact)
  that can be served from any web server under `/Mozhi/`.
- **iOS, macOS, Windows**: build from source (see below).

> APKs built without the release signing secrets are signed with a throwaway
> debug key. Android refuses to update an app signed with a different key, so
> uninstall first when switching between such builds.

---

## Connect your own Mozhi instance

A list of public instances is built in, but running your own takes a minute:

```sh
docker run -d --name mozhi --restart unless-stopped \
  -p 3000:3000 codeberg.org/aryak/mozhi:latest
```

(or use the `compose.yml` from the [Mozhi repository][mozhi]). Then open
**Settings > Mozhi instances**, add `http://<your-server-ip>:3000` and move it to
the top. Plain `http` on your LAN is allowed.

The web build calls instances from the browser, so a self-hosted instance used
from the web app must send CORS headers (for example via your reverse proxy).
The native apps do not need this.

## Connect an AI provider

Open **Settings > AI providers > Add** and pick a preset:

| Provider | Base URL | Notes |
| --- | --- | --- |
| OpenAI | `https://api.openai.com/v1` | API key |
| Anthropic | `https://api.anthropic.com/v1` | API key |
| Google Gemini | `https://generativelanguage.googleapis.com/v1beta` | API key from Google AI Studio |
| OpenRouter | `https://openrouter.ai/api/v1` | API key, hundreds of models |
| Groq | `https://api.groq.com/openai/v1` | API key, very fast |
| Ollama | `http://<pc-ip>:11434` | local, no key |
| LM Studio | `http://<pc-ip>:1234/v1` | local, no key |
| llama.cpp server | `http://<pc-ip>:8080/v1` | local, no key |
| Custom | any OpenAI-compatible URL | optional key and headers |

Use **Test** in the editor to send a tiny translation before saving.

**Local models on another computer.** `localhost` on a phone is the phone
itself; use your computer's LAN address instead (for example
`http://192.168.1.20:11434`), and make the server listen on the network:

- **Ollama**: start it with `OLLAMA_HOST=0.0.0.0` (for example
  `OLLAMA_HOST=0.0.0.0 ollama serve`, or set it in the systemd service /
  app settings). For the **web** build also set `OLLAMA_ORIGINS` to the web
  app's origin (or `*`) so the browser may call it.
- **LM Studio**: Developer tab, *Serve on Local Network* (and *Enable CORS*
  for the web build).
- **llama.cpp**: `llama-server -m model.gguf --host 0.0.0.0 --port 8080`.

Instruction-tuned models of 7B parameters or more give good results; smaller
models work for common language pairs.

---

## Build from source

Requirements: Flutter 3.47 (Dart 3.13). Android builds need JDK 17 and the
Android SDK.

```sh
flutter pub get

# Run (flavors: development, staging, production)
flutter run --flavor development -t lib/main_development.dart
flutter run --flavor production -t lib/main_production.dart

# Android release APKs
flutter build apk --release --flavor production -t lib/main_production.dart --split-per-abi

# Web
flutter build web --release -t lib/main_production.dart --base-href /Mozhi/
```

The three flavors install side by side on Android (`io.github.aimdi.mozhi`,
`.stg`, `.dev`).

**Release signing (Android).** Release builds use, in this order: the
environment variables `ANDROID_KEYSTORE_PATH`, `ANDROID_KEYSTORE_PASSWORD`,
`ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD`; or `android/key.properties`
(`storeFile`, `storePassword`, `keyAlias`, `keyPassword`); otherwise the debug
key. In GitHub Actions, add the repository secrets `ANDROID_KEYSTORE_BASE64`
(`base64 -w0 release.jks`), `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`
and `ANDROID_KEY_PASSWORD`.

**Releases.** Pushing a tag such as `v1.0.0` builds the APKs and publishes a
GitHub release.

### Tests

```sh
flutter test --coverage                       # app
(cd packages/translation_repository && dart test)   # each package
dart run bloc_tools:bloc lint lib             # bloc lints
```

---

## Architecture

A layered Flutter app with pure Dart packages:

| Path | Role |
| --- | --- |
| `packages/mozhi_api` | Client for the Mozhi REST API (`/api/translate`, `/api/engines`, languages, TTS, ...). |
| `packages/llm_api` | Streaming clients for OpenAI-compatible, Anthropic, Gemini and Ollama APIs. |
| `packages/translation_repository` | Domain models, language catalogue, prompts and parsers, and `TranslationRepository`, which unifies Mozhi engines and AI providers (failover, caching, compare, extras). |
| `lib/app` | Bootstrap wiring, router (`go_router`), adaptive shell, theme. |
| `lib/translate`, `lib/proofread`, `lib/history`, `lib/settings` | Features: Cubits (`flutter_bloc`) and views. |
| `lib/speech`, `lib/platform` | Text-to-speech and the Android share / text-selection bridge. |

User-facing strings live in `lib/l10n/arb`.

---

## License

[MIT](LICENSE). Mozhi (the translation front-end) is a separate project by
its own authors; this app is an independent client.

[mozhi]: https://codeberg.org/aryak/mozhi
[releases]: https://github.com/Aimdi/Mozhi/releases
[actions]: https://github.com/Aimdi/Mozhi/actions/workflows/main.yaml
[license_badge]: https://img.shields.io/badge/license-MIT-blue.svg
[license_link]: https://opensource.org/licenses/MIT
[very_good_analysis_badge]: https://img.shields.io/badge/style-very_good_analysis-B22C89.svg
[very_good_analysis_link]: https://pub.dev/packages/very_good_analysis
