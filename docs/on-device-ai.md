# On-device AI

Mozhi can run AI models on the phone itself: AI translation and every AI
extra (refine, alternatives, insights, dictionary, explain, proofread,
meaning check, romanization, matching phrases) without a network and
without your text ever leaving the device. It works like an AI provider
that happens to live inside the app, so nothing else changes: the same
screens, the same buttons, marked **On this device**.

| | On-device AI | A cloud AI provider | Offline translation (Bergamot) |
| --- | --- | --- | --- |
| Where your text goes | Nowhere: it never leaves the phone | To the provider | Nowhere |
| Needs | A downloaded or imported model (about 1 to 3 GB), a 64-bit Android phone with enough memory | An account, a key and the network | A language pack (about 50 MB) |
| Does | Translation and the AI extras | Translation and the AI extras | Translation only |
| Speed | Seconds per sentence (see [Speed](#speed)) | Usually faster | A fraction of a second |
| Works in **Offline only** | Yes | No | Yes |

It is in the Android app. The web app shows it as unavailable (a browser
version may come later).

- [Getting started](#getting-started)
- [Models](#models)
- [Does it fit my phone?](#does-it-fit-my-phone)
- [Speed](#speed)
- [Battery and heat](#battery-and-heat)
- [Privacy](#privacy)
- [Free space](#free-space)
- [Where the models come from](#where-the-models-come-from)
- [Import from files](#import-from-files)
- [Troubleshooting](#troubleshooting)
- [For contributors](#for-contributors)

## Getting started

1. Open **Settings > AI > On-device AI** (also linked from **Settings >
   Translation engines**, the **Offline languages** screen and, when no
   model is installed yet, **Add on-device AI…** at the bottom of the
   engine list on the translate screen).
2. Pick a model. Each one shows its size, its licence, its languages and
   whether it fits your phone. Nothing is downloaded until you tap
   **Download**. Mozhi first checks that the phone has room for it (see
   [Free space](#free-space)); with **Download over Wi-Fi only** on (the
   default), it then asks on mobile data or a metered network.
3. Once it is installed, the translation model appears in the engine list
   under **On this device**, next to offline translation, with a memory
   chip icon. Choose it like any other engine. The assistant model writes
   the AI extras.

On a phone that can run a model and has no AI provider yet, the translate
screen offers this once: **Translate and explain with AI that stays on your
phone**. **See models** opens the page above; **Not now** hides the card
for a while, **Don't show again** for good. The card never downloads
anything itself.

## Models

Two kinds of models, chosen separately on the On-device AI page:

- **Translation model:** translates, and applies your glossary terms. Like
  other translation-specialised models it takes no style or tone options,
  and it needs to know the source language (pick it, or let it be
  detected); the extras use the assistant model.
- **Assistant model:** the AI extras (refine, alternatives, insights,
  dictionary, explain, proofread, meaning check, romanization, matching
  phrases), and translation too if you choose it as the engine.

| Model | Role | Publisher | Licence | Download (Q4_K_M GGUF) | Languages |
| --- | --- | --- | --- | --- | --- |
| **Hy-MT2 1.8B** | Translation | Tencent ([Hy-MT2](https://github.com/Tencent-Hunyuan/Hy-MT2)) | Apache-2.0 | 1.13 GB | 33 languages and 5 variants ([list](#hy-mt2-languages)) |
| **Gemma 4 E2B** | Assistant | Google (weights only, no Google code) | Apache-2.0 | 3.11 GB | 140+ languages |
| **Qwen3 1.7B** | Assistant (the small option) | Alibaba Qwen | Apache-2.0 | 1.28 GB | 100+ languages |

The page shows each file's exact size before you download it. The files
come from Hugging Face, pinned to one commit of each repository: Hy-MT2
from Tencent's own repository, Qwen3 from ggml-org's (the llama.cpp
project) and Gemma 4 E2B from Unsloth's, since Google doesn't publish a
4-bit GGUF. Whichever server sends a file, the app checks its size and
SHA-256 against the catalogue built into Mozhi before it is used. All
three are 4-bit quantized (Q4_K_M): about a quarter of the original size,
with a small loss of quality.

Why these: Hy-MT2 is the strongest translation model with a clean
open-source licence that fits a phone (Tencent reports that the 1.8B model
beats Microsoft Translator and Doubao overall; that is their own
measurement). Gemma 4 E2B and Qwen3 are good general models of that size
for the extras. Mozhi never offers models whose licences restrict who may
use them: HY-MT1.5 (its licence excludes the EU, the UK and South Korea),
NLLB and Aya (non-commercial only).

Quality: a 2-billion-parameter model on a phone is good, not perfect. It
is strongest in widely used languages; it can miss nuance, a rare word or
the right register, and like every AI it can now and then write something
the text doesn't say. Keep a cloud provider or Mozhi's online engines at
hand for text that matters, or compare (**Tools > Compare engines**).

### Hy-MT2 languages

Arabic, Bengali, Burmese, Cantonese, Chinese, Traditional Chinese, Czech,
Dutch, English, Filipino, French, German, Gujarati, Hebrew, Hindi,
Indonesian, Italian, Japanese, Kazakh, Khmer, Korean, Malay, Marathi,
Mongolian, Persian, Polish, Portuguese, Russian, Spanish, Tamil, Telugu,
Thai, Tibetan, Turkish, Ukrainian, Urdu, Uyghur and Vietnamese, in every
direction between them.

## Does it fit my phone?

A model has to fit in the phone's memory next to Android and your other
apps. The page compares each model's needs with your phone's memory (RAM)
and says:

| Shown | Meaning |
| --- | --- |
| **Fits this phone** | Enough memory: it should run comfortably |
| **May be slow on this phone** | It runs, but other apps may be closed while it does, and it may be slow |
| **Needs more memory** | Not offered for download. You can still import it from a file, with a warning |

As a rule of thumb, by the RAM a phone is sold with:

| Model | Offered from | Comfortable from |
| --- | --- | --- |
| Hy-MT2 1.8B | 6 GB (5,000 MB reported by Android) | 8 GB (7,000 MB) |
| Qwen3 1.7B | 6 GB (5,000 MB) | 8 GB (7,000 MB) |
| Gemma 4 E2B | 8 GB (7,000 MB) | 12 GB (11,000 MB) |

Android reports a little less than the advertised RAM; the page goes by
what it reports. Using the translation model and an assistant model one
after the other is fine: only one is in memory at a time. Only 64-bit
phones (ARM64 or x86_64) can run it at all: a model of 1 to 3 GB doesn't
fit in a 32-bit app's address space. Where on-device AI can't run, the
page says so and nothing is offered.

The app keeps a model in memory only while it works: it is loaded on first
use (a few seconds), freed after 2 minutes without use, as soon as the app
goes to the background and when Android runs low on memory.

## Speed

The model runs on the phone's processor (CPU). Mozhi picks the fastest
code its processor supports when it starts (the ARM dot-product, half
precision and int8 matrix instructions of newer phones). Rough figures for
one sentence of about 40 words:

| Phone class | Examples | Hy-MT2 1.8B | Gemma 4 E2B |
| --- | --- | --- | --- |
| Flagship (2024 or later) | Snapdragon 8 Elite, Dimensity 9400 | 1 to 3 s | 2 to 5 s |
| Mid-range (2024 or later) | Snapdragon 7 Gen 3, Dimensity 7300 | 4 to 7 s; the first words after about a second | 7 to 10 s |
| Older or entry-level | Without the dot-product instructions | 10 s or more | Not recommended |

These are estimates from published llama.cpp figures, not measurements of
Mozhi on your phone. Text streams in as it is written, so you can start
reading before it is done. The first request after a pause also loads the
model: the translation says **Loading the on-device model…** (with
**Cancel**) for a few seconds, then the text streams in as usual. The AI
extras say the same while they wait for the model (alternatives,
insights, explanations, the dictionary card and page, proofreading, the
meaning check and the word alignment), and so does a refinement of a
translation that is already shown.

The page also names the **engine build** this phone uses (for support:
`i8mm`, `dotprod` or `baseline`). If a faster build ever stopped the app
(a phone that reports processor features it doesn't really have), Mozhi
notices it at the next start, turns that build off for good and uses the
baseline, which every phone runs; the line then says so.

Tips:

- For translate-as-you-type, long text and documents, offline translation
  (Bergamot) is much faster; keep it for those and use on-device AI where
  quality or the extras matter. With [Quality modes](features.md#quality-modes-fast-and-best),
  make offline translation **Fast** and on-device AI **Best**.
- Long text is split into parts of about 1,200 characters, which fit the
  model's 4,096-token window even in Chinese or Japanese, and translated
  part by part.

## Battery and heat

Running a model keeps several processor cores busy for seconds at a time:
it uses noticeably more battery than offline translation, and a long
session warms the phone. Mozhi is careful about that:

- **When the phone is hot** (Android reports a severe thermal status or
  worse; Android 10 and later) or **battery saver is on**, typing doesn't
  start on-device AI, nor the extras it would otherwise refresh on its own
  (romanization, insights, matching phrases). With on-device AI as the
  engine, a line under your text says why; press **Enter** or **Translate**
  to translate. Everything else works as usual.
- Choosing on-device AI as the engine loads the model in the background,
  so that the first translation is quicker, but not while the phone is hot
  or battery saver is on: the first translation loads it then.
- Every reply has a length limit in proportion to the text (about three
  times its length, plus a little), so a model that starts repeating
  itself stops early instead of running until its 4,096-token window is
  full. Such a reply is shown as cut short.
- The model is freed when you leave the app, so it doesn't hold memory or
  run in the background.
- Nothing runs on its own: on-device AI only works when you translate or
  ask for an extra.
- **A long job pauses while the phone is hot or battery saver is on.** A
  long text, a document or a web page is translated part by part; when
  the phone gets hot (or battery saver comes on) the next part waits,
  and the screen says **Paused while the phone cools down** (or **Paused
  while battery saver is on**) with **Continue anyway** and **Cancel**.
  It goes on by itself once the phone has cooled down; **Continue
  anyway** lets the rest of that job run regardless. What you just asked
  for never waits: the first part of a job, a single translation or an
  extra starts at once. (The rule: a request that comes while another one
  runs, or less than two seconds after one ended, is the next part of the
  same job.)
- Android tells Mozhi when the heat or battery saver changes (Android 10
  and later for the heat), so these rules follow it right away without
  asking the system again and again.

## Privacy

- Your text, the translation and the extras never leave the phone: the
  model runs inside the app. The engine and the result carry the **On
  this device** badge (a memory chip), there is no consent prompt, the
  [Network activity](features.md#privacy-controls) log shows nothing for
  it, and it works in **Offline only**.
- With an on-device engine selected and a privacy mode other than
  **Online**, the extras use the on-device assistant model rather than a
  cloud provider, so they stay on the phone too.
- A result that looks wrong (the original text, the wrong language, a
  chat-style reply) is never sent to another engine automatically: Mozhi
  only tries offline translation (Bergamot), on the phone, and otherwise
  shows the result with a note. Text from on-device AI goes to a Mozhi
  instance, your own server or a provider only when you choose to compare
  it with one (**Compare engines**). Its romanization only starts on its
  own when the extras engine is on the phone too.
- History lists on-device AI translations under **On device**.
- The only network use is downloading a model, when you tap **Download**:
  from the model source you chose (below). That server sees your IP address
  and which file you download, nothing else. Importing a file needs no
  network at all.
- The models are kept in the app's private storage (not in backups) until
  you delete them; **Delete all local data** removes them too. Phone to
  phone can send them to your other phone over your own network.

See [Privacy](privacy.md) and [Security](security.md) for the details.

## Free space

Before a download (or an import) writes anything, Mozhi checks the free
space: the model's size plus a margin of 5 % (at least 50 MB), so the
phone is never filled to the last byte. A download that was interrupted
only needs room for the rest. Without enough room nothing is downloaded,
and the page says how much is needed, for example **Not enough free space
for Hy-MT2 1.8B: needs 1.2 GB, 300 MB free.** The file is downloaded into
a partial file next to the models and renamed into place, so it needs
room for the model once, not twice. This check happens before Mozhi asks
about mobile data.

The checks of a model file (its size and SHA-256 fingerprint, a few GB to
read) run in the background, so the app stays smooth while a model
downloads, resumes or is imported.

## Where the models come from

The model files are the publishers' own GGUF files on Hugging Face, each
pinned to a fixed revision in the app's catalogue. They come from the model
source in **Settings > Translation engines > Model source**, like the other
on-device models:

- **Original publishers** (Hugging Face; the Android default);
- **This web server** (a copy next to the web app);
- a **Custom mirror** (your server, a computer on your network or a
  `.onion` address), optionally falling back to the publishers. A mirror
  keeps the files in an `llm/` folder (`<mirror>/llm/<file name>`); how to
  fill one: [Mirror the on-device models](self-hosting-mozhi.md#mirror-the-on-device-models).

An interrupted download resumes where it stopped (from the same source;
another model source starts it over). Every file is checked against the
size and SHA-256 fingerprint built into the app before it is used and
installed in one step, so a model is either complete or absent, and a
mirror can't change a file.

## Import from files

To install a model without the app going online (for example in
**Offline only**), use **Copy download links** on the On-device AI page,
download the file on another device, copy it to the phone and choose
**Import from a file**. A renamed copy is recognised by its exact size and
fingerprint; a damaged or unknown file is refused. The picked file is only
read, never changed. A model that needs more memory than your phone has can
be imported too, after a warning.

Mozhi reads the picked file where it is (Android's document picker): it is
copied once, straight into the models folder, after its name, size and
the free space were checked, then verified there and moved into place. No
second copy of a few GB lands in the app's cache first, and a file that is
no model is never copied at all.

## Troubleshooting

- **No On-device AI anywhere, or "Needs the Android app on a 64-bit
  phone":** the web app and 32-bit phones can't run it.
- **"Needs more memory" for every model:** your phone has too little RAM
  for these models. Offline translation (Bergamot) still works.
- **"Loading the on-device model…" takes long:** the first request after
  a pause reads the model from storage (a few seconds, longer on slow
  storage). **Cancel** stops it.
- **It is slow:** see [Speed](#speed). Close heavy apps, keep text short,
  or use offline translation for typing.
- **Typing doesn't translate:** the phone is hot or battery saver is on
  (the line under your text says which). Press **Enter** or **Translate**.
- **The app restarted while translating in the background:** Android
  closed it to free memory. On-device AI is freed in the background to
  avoid that, but a long translation may not survive switching apps.
- **The download doesn't start:** on mobile data with **Download over
  Wi-Fi only** on, Mozhi asks first.
- **"Not enough free space":** free the amount it names (the model's size
  plus 5 %, at least 50 MB) and try again; an interrupted download keeps
  what it already has.
- **"Paused while the phone cools down":** a long text, document or web
  page waits between its parts; it goes on by itself, or tap **Continue
  anyway**.
- **"Engine build: baseline (the faster … build stopped the app …)":** the
  app crashed once with the faster build for this processor, so it now
  uses the slower baseline; mention it when you report a problem.
- **"The file is damaged" after a download or import:** the size or
  fingerprint didn't match. Download again (or from another model source).
- **It doesn't appear in the engine list:** the translation model is
  listed under **On this device** once it is installed and selected on the
  On-device AI page.

## For contributors

The engine is `packages/llama_engine`: [llama.cpp](https://github.com/ggml-org/llama.cpp)
v0.6.0 (MIT) as a pinned submodule, built for `arm64-v8a` (a baseline,
a dot-product + fp16 and an i8mm library, chosen at run time from
`/proc/cpuinfo`) and `x86_64`, CPU only, with a C API (`mozhi_llama_*`)
used through FFI in a background isolate. Its catalogue
(`assets/models.json`) pins each model's URL, size and SHA-256; CI
resolves them from Hugging Face (`tool/llm_catalog.py`). In the app,
`lib/on_device_ai/` holds the models (`OnDeviceModels`), the runtime
(`OnDeviceAi`, an in-process `LlmClient` for `LlmProvider.onDevice`) and
the settings page. Installed models become AI providers `device-<model>`
(engine ids `ai:device-<model>`) that are never stored in the settings;
the repository treats them as `OnDeviceDestination`. Hy-MT2 uses its own
prompt templates (`PromptProfile.hunyuanMt`) and sampling (temperature
0.7, top-p 0.6, top-k 20, repetition penalty 1.05). The heat and battery
saver guard is `lib/platform/device_conditions.dart`: changes are pushed
by `DeviceConditionsPlugin.kt` on an event channel (a thermal status
listener on API 29+ and an `ACTION_POWER_SAVE_MODE_CHANGED` receiver,
registered only while Dart listens); `thermalStatus` and `isPowerSaveMode`
on the privacy channel of `MainActivity.kt` remain the fallback when no
event arrives. `OnDeviceRuntime` pauses the next part of a job while the
device is strained (`OnDeviceAiPaused`, `OnDeviceAi.continueAnyway`; shown
by `OnDeviceAiPausedNotice` on the translate screen and the web page
translator; other long-job screens can drop the same widget in).

Storage: `lib/platform/free_space.dart` (`FreeSpace`, `StatFs` through
`DeviceStoragePlugin.kt`, the Storage API estimate on the web) is given to
every model manager (`freeSpace`); `LlamaModelManager.requiredSpace` is
the size plus max(50 MiB, 5 %). `FileHashing` hashes in background
isolates (`Isolate.run` for files, a long-lived isolate fed with a
download's chunks), with an inline mode for tests. Imports from the picker
are `LlamaImportSource`s (`lib/platform/model_file_picker.dart`:
`ACTION_OPEN_DOCUMENT`, then `copyFile` straight into the staging folder).

CPU variants: `CpuVariantGuard` (`packages/llama_engine/lib/src/engine/`)
writes `llama_cpu_variant.<role>.marker` in the support directory before a
non-baseline build is opened and before its first generation, and removes
it once that worked (then `llama_cpu_variants.json` records the build as
verified for its engine version). A marker left by another process at the
next start means that process died there: the build is added to the
skipped ones for good and the baseline runs. The explicit library path and
`$LLAMA_LIBRARY_PATH` are never guarded. `llamaEngineBuild()` names the
build for the page.
