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
| [Voice input](voice-input.md) | Dictation with the system recognizer or offline with Whisper: models, languages, privacy, import from files |
| [Text recognition](text-recognition.md) | Reading text in photos on the phone with Tesseract: languages, sizes, where the data comes from, import from files |
| [Offline dictionaries](dictionary-packs.md) | Wiktionary dictionaries for the Dictionary tab without AI or a network: what's in a pack, downloads, attribution, building and publishing packs |
| [Phrasebook](phrasebook.md) | Collections of phrases built from favorites, history and the dictionary; CSV import and export; offline starter phrasebooks from Wikivoyage |
| [Practice](practice.md) | Flashcards of your phrasebook (FSRS), speaking practice with on-device Whisper, Anki export |
| [Backup](backup.md) | Encrypted backups of your history, favorites, phrasebook, practice progress, settings, presets and glossaries: what's inside, restoring, the file format, passphrase advice |
| [Sync](sync.md) | End-to-end-encrypted sync between your devices through your own WebDAV folder: setup per server, how it works, what the server sees, CORS for the web app |
| [Phone to phone](pairing.md) | Moving your data or language packs to another phone over the local network, end to end encrypted: how pairing works and what is checked |
| [Privacy](privacy.md) | What stays on your device and what each back end sees |
| [Security](security.md) | Threat model: how API keys, network traffic, shared text, links and AI prompts are protected, and how to report a vulnerability |
| [FAQ](faq.md) | Short answers to common questions |

Ready-to-use server files are in [`deploy/`](../deploy/README.md).

## For contributors

| Guide | What's inside |
| --- | --- |
| [Architecture](architecture.md) | Packages and layers, data flow, how to add an AI provider |
| [Contributing](contributing.md) | Toolchain, flavors, tests, localisation, adding a UI language |
| [Offline engine](offline-engine.md) | Mozilla Bergamot: why it was chosen, the native and WebAssembly (web app) builds, models and catalogue |
| [Building](building.md) | Pinned toolchain, build variants (default, Play, F-Droid), reproducible builds, checking an APK for Google code |
| [Dependencies](dependencies.md) | Every dependency with version, licence and purpose |
| [Releasing](release.md) | Release checklist, signing, tracker scan, verifying a release |
| [Privacy audit](audit/2026-audit.md) | The 2026 privacy audit and [progress log](audit/progress.md) |
| [Roadmap](roadmap.md) | What comes next and why: the plan to make Mozhi the best translator that stays private |

Mozhi (this app) is an independent, unofficial client. The Mozhi translation
front-end is a separate project by its own authors.
