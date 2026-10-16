# Mozhi documentation

Mozhi is a translator app for Android and the web. It translates through
self-hostable [Mozhi](https://codeberg.org/aryak/mozhi) instances (Google,
DeepL, Reverso, Yandex, LibreTranslate, DuckDuckGo, MyMemory) and through the
AI models you choose, cloud or local, with the extras you know from Kagi
Translate.

## For users

| Guide | What's inside |
| --- | --- |
| [Getting started](getting-started.md) | Install the app, first run, pick where translations come from, add an AI provider, Android shortcuts |
| [Features](features.md) | A tour of everything the app can do |
| [AI providers](ai-providers.md) | Keys, base URLs, models and costs for every provider; local models with Ollama, LM Studio, llama.cpp and vLLM; which model fits your hardware |
| [Self-hosting Mozhi](self-hosting-mozhi.md) | Run your own Mozhi instance with Docker Compose, HTTPS, LAN and Tor use, troubleshooting |
| [Privacy](privacy.md) | What stays on your device and what each back end sees |
| [Security](security.md) | Threat model: how API keys, network traffic, shared text, links and AI prompts are protected, and how to report a vulnerability |
| [FAQ](faq.md) | Short answers to common questions |

Ready-to-use server files are in [`deploy/`](../deploy/README.md).

## For contributors

| Guide | What's inside |
| --- | --- |
| [Architecture](architecture.md) | Packages and layers, data flow, how to add an AI provider |
| [Contributing](contributing.md) | Toolchain, flavors, tests, localisation, adding a UI language |

Mozhi (this app) is an independent, unofficial client. The Mozhi translation
front-end is a separate project by its own authors.
