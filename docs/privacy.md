# Privacy

Mozhi is built so that you decide where your text goes, and so that nothing
goes anywhere else.

## The short version

- **No account, no telemetry, no analytics, no ads, no crash reporting.** The
  app contains no tracking code and does not contact any server run by the
  app's developers. The default build contains no Google code at all (see
  [Google code](#google-code)).
- **Offline first by default.** Out of the box, translation runs on the
  phone when the language pair is installed, and the app asks before your
  text goes over the network for the first time. You can choose
  [Offline only or Online](#privacy-modes) instead.
- **You always see where a translation went.** Every result carries a
  [destination chip](#where-your-text-goes) ("On device", "your server",
  "Google via mozhi.example.org", "OpenAI"); tap it for what that party can
  see.
- **Your history, settings and keys stay on your device.** The history is
  encrypted, secrets are in secure storage, and nothing is backed up or
  copied to a new phone.
- **Sync stays yours.** If you want your devices in sync, they use a
  WebDAV folder on your own server (Nextcloud, a NAS, rclone), end-to-end
  encrypted with your passphrase: the server stores only what it can't
  read, and there is no account ([Sync](sync.md)).
- **Your text is sent only to the back end you choose** for that
  translation: a Mozhi instance, an AI provider, a DeepL or LibreTranslate
  service, or nowhere at all with the offline engine and [on-device
  AI](#on-device-ai).
- **Personal data stays behind.** E-mail addresses, phone numbers, IBANs,
  card numbers and IP addresses are [replaced before text goes
  online](#personal-data-shield), also for the AI extras, and put back
  into the translation.
- **You can check what left the device.** [Network
  activity](#network-activity) lists every request of this session, without
  its text.

## Privacy modes

**Settings > Privacy & data > Privacy mode** decides how willing the app is to
send text over the network. The translation repository enforces it, not just
the screens, and checks it before every request.

| Mode | What happens |
| --- | --- |
| **Offline only** | Only on-device translation. Nothing you type leaves the device; requests that would need the network are refused, and no engine or language list is loaded from a server. |
| **Offline first** (default) | On-device translation when the language pair is installed. Otherwise the app asks before text leaves the device, for that language pair and destination. Engine and language lists of Mozhi instances are not refreshed by themselves: the app does not contact a server until you let it (for example by opening the engine list). |
| **Online** | Your translation services are used without asking, in the order you set. Cloud providers still ask once each. |

In every mode, text goes to a **cloud provider** (an AI provider such as
OpenAI or Anthropic, or DeepL's API) only after you agreed once for that
provider.

### Consent prompts

When a request needs your OK, nothing has been sent yet. The prompt names
the destination and what it can see, and offers:

- **Once**, or **Always for** the language pair (for example *French →
  English*); the approved pairs are kept in the settings;
- **Download** the pair for offline use instead, when the offline engine
  has it;
- **Change privacy mode**.

For a Mozhi request the prompt also says when the text may go on to the
other servers in your list if the first one doesn't answer (failover, in
your order). The app never moves text to another back end by itself: an
offline or Mozhi translation is never retried with an AI provider, a
helper request (language detection, the AI model for extras, Reverso
after Google for speech) is checked as its own destination, and when the
engine you selected is gone, only the on-device engine may take its place;
otherwise you pick one.

## Where your text goes

The **destination chip** under a translation names who received the text:

- **On device**: translated on this phone. Your text isn't sent anywhere.
- **Your server** (this device, your local network, a Tor `.onion` or I2P
  `.i2p` address): only whoever runs that server can read it. A Mozhi
  instance passes the text on to its engine (for example Google), which can
  read it too.
- **A public server** ("Google via mozhi.example.org"): a public Mozhi or
  LibreTranslate instance run by someone else. Its operator, and the engine
  it forwards to, can read your text.
- **A cloud provider** ("OpenAI"): the provider can read your text and
  handles it under its own privacy policy.

The chip names the instance that actually answered, so a failover is
visible. The engine list shows the same categories as a badge: **On
device**, **Self-hosted**, **Public server** or **Cloud**.

When an engine's result is clearly wrong (the original text, the wrong
language, a garbled or chat-style reply), Mozhi may translate again with
another engine, and the result says so. It only uses engines that need no
new consent: the on-device engine first, then servers and providers you
already allowed. A paid AI provider is never tried automatically.

Text that an engine on this device translated (offline translation or
on-device AI) is never sent to another engine automatically: its only
fallback is offline translation, which runs on the phone too, never a
Mozhi instance, your own server or a provider. Its romanization (with
**Show transliterations** on) only starts on its own when the extras
engine is on this device too. Comparing it with another engine (**Compare
engines**) stays your choice.

### Personal data shield

**Settings > Privacy & data > Hide personal data from online engines** (on by
default) replaces e-mail addresses, phone numbers, IBANs (checked with their
check digits), payment card numbers (checked with the Luhn algorithm) and IPv4
addresses with placeholders before the text goes to a Mozhi instance, an AI
provider or a DeepL or LibreTranslate service, and puts them back into the
translation on the device. The result says how many items stayed on the
device. Language detection and back-translation for the meaning check are
covered too. If an engine damages a placeholder, the text is **not** sent
again unmasked: the result is marked instead.

The AI extras are covered as well: alternatives, word insights,
refinement suggestions, explanations (your question included), refining a
translation (its instruction included), dictionary look-ups (the word and
its context), alignment, romanization, **Check meaning** and **Proofread**.
So are the translation options you type (context, tone notes,
instructions), which go to AI models and DeepL masked like the text; the
same e-mail address in the text and in the context gets the same
placeholder. The model is told that the placeholders stand for personal
data it should keep, and its answer gets the values back on the device.
When a model changes a placeholder so that it can't be put back (for
example an explanation that writes about "the token"), the placeholder
stays as the model wrote it: the value is never sent to fill the gap.
Dictionary entries and proofreading results say how many items stayed on
the device.

It doesn't apply to the on-device engine, which never sends anything. It
can't apply to what isn't text: a photo sent to an AI model with **Supports
images** or to a Mozhi instance goes as it is (the options sent with it are
masked), and so does text read aloud, by an online voice or a Mozhi
instance, since the voice would read the placeholders. Names and addresses
aren't detected.

### Glossaries with Mozhi and LibreTranslate

Mozhi engines and LibreTranslate can't use a glossary, so the app applies
it on the device: each glossary term in the text (as a whole word, in
any case unless the term is case-sensitive or an acronym such as *IT*,
and with a plain plural *s* or *es*) goes to the engine as a placeholder
like `⟨1⟩`, which engines keep, and the app writes your translation of the
term in its place. The engine never receives the glossary, and doesn't see
the terms. When an engine damages a placeholder, the text is translated
again without the glossary (personal data stays masked) and the result
says which terms couldn't be placed. AI models and DeepL get the glossary
as before (Hy-MT, translation-only, gets the terms that occur in the text,
in its own terminology template); the offline engine and TranslateGemma
don't apply it.

### Online voices

Some voices of the device's text-to-speech are online voices: the text
they read goes to a speech service. In the web app these are the browser
voices that aren't a local service, such as Chrome's "Google …" voices
(the text goes to Google) and Edge's "Microsoft … Online" voices; on
Android, voices that need a network connection, and the voices of a
language whose voice data isn't on the phone. The voice picker
(**Settings > Read aloud & voice > Read aloud**) labels them **Online
voice** and says where the text goes.

When the language has a voice on the device, it reads, even if the
browser or the phone would pick an online voice by default. Before an
online voice reads for the first time, the app asks (**Listen online**);
your answer is kept per voice, and **Allowed online voices > Forget**
asks again. In **Offline only** online voices never read, not even a
preview. Personal data can't be hidden from an online voice: it would
read the placeholders aloud. Previews in the voice picker read a sample
(the language's name and a few numbers), never your text.

### Network activity

**Settings > Privacy & data > Network activity** lists every request the app
made this session: when, to which host, why (translation, AI, speech, photo,
catalogue, model download, web page, encrypted sync), how many bytes went each way, the
answer's status, and whether it went through your proxy. It groups them by
destination with a line on who can read what was sent, and has Clear and Copy
summary actions.

The log never records text, paths, query strings, request bodies or
headers. It lives in memory only (the last 500 requests), is never saved
and is gone when the app closes. Requests the app refuses (for example
plain `http` to a public server) are never sent, so they don't appear.
Network use outside the app's own connections isn't listed: the system's
speech recognition and text-to-speech, links you open in the browser, and
in the web app the browser's own loading of the app's files.

### Where model files come from

The on-device models (offline languages, voice input, text recognition)
are downloaded only when you ask, from the source in **Settings >
Translation engines > Model source** (also on the **Offline languages**
page):

| Model source | Who serves the files | What that server sees |
| --- | --- | --- |
| **Original publishers** (default on Android) | Mozilla's bucket on Google Cloud Storage (`storage.googleapis.com`, translation models), Hugging Face (`huggingface.co` and its download servers, Whisper), GitHub (`raw.githubusercontent.com`, Tesseract data) | Your IP address, the time and which files, so which languages, you download |
| **This web server** (web app only, its default) | The server the web app comes from, at `models/` next to it | The same, but only whoever hosts the web app sees it; nothing goes to Google, GitHub or Hugging Face |
| **Custom mirror…** | The server you enter: your own, one on your LAN, a `.onion` address (`https`; plain `http` only for this device, the local network and `.onion` / `.i2p`) | The same, only that server (and, through Tor, not even your IP address) |

A mirror can't change what you install: every file is pinned in the app by
its size and SHA-256 (the Whisper models by their SHA-1 as well) and checked
before it is used, whichever server sent it. A file that doesn't match is
discarded with an error that names the mirror. **Use the original publishers
when the mirror lacks a file** is off by default; then a file the mirror
doesn't have fails instead of going to the publisher. No text, voice,
picture, identifier or cookie is sent with a download. To run a mirror, see
[self-hosting](self-hosting-mozhi.md#mirror-the-on-device-models).

### Offline dictionaries

Dictionary packs (**Settings > Offline languages > Dictionaries**) are
downloaded only when you tap **Download**, once, from the same [model
source](#where-model-files-come-from) (by default the project's GitHub
release, `github.com` and its download servers, which see your IP address
and which languages you download), checked against the SHA-256 pinned in
the app and kept in the app's private storage (in a browser, its private
storage for the site). Looking a word up in them never leaves the device:
no request is made, nothing is logged, and only **More detail** (or a word
the packs don't have, when you have an AI provider) goes to your AI
provider, as before.

### On-device translation in the web app

The web app translates without the network too, in browsers that can run
Mozilla's engine: current Chrome, Edge, Firefox and Safari (WebAssembly
SIMD, the private storage for sites, a secure `https` page). The engine is
the same as on Android (Mozilla's Firefox Translations engine and CLD2
for **Detect language**), compiled to WebAssembly and served by the web
app's own server (`bergamot/` next to the app); it runs in a worker inside
the page, so your text never leaves the browser. Language packs are
downloaded only when you tap **Download** on **Offline languages**, from the
[model source](#where-model-files-come-from) (by default the server the web
app comes from: Mozilla's bucket doesn't let other websites download its
files), checked against the SHA-256 checksums bundled with the app, and
kept in the browser's private storage for the site; the app asks the
browser to keep them (`navigator.storage.persist()`: Firefox may ask you,
Chrome decides by itself). The downloads go through the same request log as
the Android app's ([Network activity](#network-activity)). **Offline only**
and **Offline first** work as on Android. A browser without what the engine
needs (an old one, a private window without site storage, a page opened over
plain `http`) keeps the old behaviour, online only, and **Offline languages**
says why. Details: [offline engine](offline-engine.md#web-app).

### On-device AI

On Android phones with enough memory, AI models can run inside the app
(**Settings > On-device AI**, [details](on-device-ai.md)): Hy-MT2 (Tencent,
Apache-2.0) translates, and Gemma 4 E2B or Qwen3 1.7B (Apache-2.0) does
the AI extras: refine, alternatives, word insights, dictionary,
explanations, **Proofread**, **Check meaning**, romanization and word
alignment. They run on llama.cpp (MIT), compiled into the app; the model
files are downloaded only when you tap **Download** (see below).

- **Nothing leaves the device.** Their engines are labelled **On this
  device**, and their destination is the device, like the offline engine:
  no consent prompt, no approved language pairs, and they work in
  **Offline only**. No request is made, so **Network activity** shows
  nothing for them. The [personal data shield](#personal-data-shield)
  isn't needed: the text, your options and glossary stay on the phone as
  they are.
- **Helpers stay on the device too.** With an "auto" source, Hy-MT2 needs
  the language first: it is identified on the device, never by a Mozhi
  instance. When you translate on the device (or the privacy mode isn't
  **Online**), the AI extras use the on-device assistant model, unless you
  chose another model under **Settings > AI > AI assistant for insights**
  (that choice asks before text leaves, as before, and in **Offline only**
  it is skipped for the on-device model).
- **Nothing is kept.** Your text is in memory only while the model writes
  its answer: each request starts from an empty context, and nothing is
  logged or written to disk (the history follows your history settings,
  as for every engine). A model is unloaded two minutes after its last
  use, when the app goes to the background and when the phone runs low
  on memory.
- **Model files.** They come from the [model
  source](#where-model-files-come-from) (by default Hugging Face, pinned
  to one commit of the publisher's repository; a mirror otherwise), which
  sees your IP address, the time and which model you download, never any
  text. Every file is checked against the size and SHA-256 pinned in the
  app before it is installed; **Import from files** only accepts a file
  that matches a model of the catalogue. They are kept in the app's
  private storage (`<app files>/llm`), until you delete them on the
  On-device AI page or with **Delete all local data**.

The web app has no on-device AI yet; its On-device AI page says so.

## What is sent, to whom, and how long it is kept

Mozhi itself keeps nothing off the device. "Kept" below means what Mozhi
stores on the device and what the other party may keep.

| Feature | Destination | What is sent | Kept |
| --- | --- | --- | --- |
| Translate with a Mozhi engine | The Mozhi instance (then the next ones in your list if it fails), which forwards to its engine (Google, DeepL, Reverso, Yandex, MyMemory, DuckDuckGo/Bing or its LibreTranslate) | Text, languages and engine in the request body (`POST`); your IP address to the instance, the instance's IP to the engine | On the device: in the history unless incognito or **Save history** is off. The instance and engine: their own logs and policies, unknown for public instances. |
| Translate with a cloud AI provider | The provider's API (only after your one-time OK) | Text, languages, your translation options (context, glossary, instructions), the API key, your IP address. For short texts, the languages you recently translated from (not the texts) | The provider's retention and training policy; check its terms. History as above. |
| Translate with a local AI model or your own server | That server | As above | Only on your server. |
| DeepL API, LibreTranslate | The service you set up | Text, languages, formality, context or glossary (DeepL), the key | The service's policy. |
| Offline translation | Nowhere | Nothing | History as above. |
| Translation and AI extras with [on-device AI](#on-device-ai) | Nowhere: the model runs in the app | Nothing | In memory while the model writes; history as above. |
| Language detection (**Detect language**, an "auto" source with a translation-only AI model) | The device first; if it is unsure, the AI provider itself or, for translation-only models, your Mozhi instance's Google engine, when the privacy rules allow that destination | The text | As for that destination. |
| Kagi-style extras, **Check meaning**, **Proofread** | The AI model for extras (**Settings > AI > AI assistant for insights**) or the model you selected; **Check meaning** without one: the engine you translate with, to translate back | Source text, translation or both (the first 4,000 characters for **Check meaning**; the word for the dictionary), with [personal data masked](#personal-data-shield) | The provider's policy. Results stay in memory only, except Dictionary tab look-ups: on the device, the word, its languages, the model's name, the detail level and a one-line summary go to the history unless incognito or **Save history** is off (or when you heart the entry). |
| **Listen** (read aloud) | The device's text-to-speech voice, one on the device whenever the language has one. An [online voice](#online-voices) only after you agree, once per voice. A Mozhi instance only when the device has no voice for the language: never in Offline only or with **Device voice only**, and in Offline first only after you agree (**Listen online**) | Device voice on the device: nothing leaves it. Online voice: the text to the voice's speech service (for example Google). Mozhi: the text **in the request address** (`GET /api/tts?text=…`, up to 200 characters per part). The [personal data shield](#personal-data-shield) can't apply to speech | Online voice: its service's policy. Mozhi: the address can end up in the server's and any reverse proxy's access logs. The app keeps the last 20 clips in memory until it closes. |
| Image translation | **On-device text recognition** (Android, the default) sends the image nowhere: Tesseract reads it on the phone ([text recognition](text-recognition.md); ML Kit in the [Play variant](#google-code)), and only the recognised text follows the translation rows above. The AI model with **Supports images** gets the image itself; so does your Mozhi instance (experimental), which passes it to Google Translate (at most two instances are tried) | AI vision and Mozhi: the image, re-encoded first (no EXIF data such as the GPS location). On-device: nothing | The provider's or instance's policy. The app doesn't store the image. |
| Dictation, conversation | **System speech recognition** (the default): the system's recogniser (Google or the phone maker on Android; the browser's maker in the web app). **Offline (Whisper)** (Android, **Settings > Read aloud & voice > Voice input**): nobody, it runs on the phone. In **Offline only** always Whisper, never the system recogniser ([voice input](voice-input.md)) | System: your voice. Whisper: nothing leaves the phone | System: the recogniser's policy; **Prefer on-device speech recognition** (Android 12+) only asks to keep it on the phone. Whisper: the recording stays in memory until it is transcribed, and is never stored. |
| Web page translator | The website you enter, then the translation engine | The page address and your IP address, with a desktop browser `User-Agent` and no cookies | The website's logs. The page text then follows the translation row above. |
| Offline model download (**Settings > Translation engines > Offline languages**, or a language's download button in the language picker) | The [model source](#where-model-files-come-from); by default `storage.googleapis.com`: Mozilla's Firefox Translations bucket (`moz-fx-translations-data--303e-prod-translations-data`), hosted on Google Cloud Storage | Plain file requests (HTTPS `GET`, `Range` to resume): Google as the host sees your IP address, the time and which model files, so which languages, you download. No text, identifiers or cookies | Google Cloud Storage's logs. The models stay on the device until you delete them. |
| Text recognition data download (**Download German text recognition**, **Settings > Translation engines > Offline languages > Text recognition**) | The [model source](#where-model-files-come-from); by default `raw.githubusercontent.com`: Tesseract's [tessdata_fast](https://github.com/tesseract-ocr/tessdata_fast) on GitHub (owned by Microsoft), pinned to one commit | Plain file requests (HTTPS `GET`, `Range` to resume): GitHub sees your IP address, the time and which language files you download. No picture, text, identifiers or cookies | GitHub's logs. The data stays on the device until you delete it; **Import from files** contacts nothing. |
| Offline speech model download (**Settings > Read aloud & voice > Voice input**) | The [model source](#where-model-files-come-from); by default `huggingface.co` (the [whisper.cpp models](https://huggingface.co/ggerganov/whisper.cpp), and the 0.9 MB speech detector from [ggml-org/whisper-vad](https://huggingface.co/ggml-org/whisper-vad), downloaded with the first model), which may redirect to its download servers | Plain file requests (HTTPS `GET`, `Range` to resume): Hugging Face sees your IP address, the time and which model (Fast or Better, and the speech detector) you download. No voice, text, identifiers or cookies | Hugging Face's logs. The model stays on the device until you delete it; **Import from files** contacts nothing. |
| On-device AI model download (**Settings > On-device AI**) | The [model source](#where-model-files-come-from); by default `huggingface.co` (the publishers' repositories, pinned to one commit), which may redirect to its download servers | Plain file requests (HTTPS `GET`, `Range` to resume): Hugging Face sees your IP address, the time and which model you download. No text, identifiers or cookies | Hugging Face's logs. The model stays on the device until you delete it; **Import from files** contacts nothing. |
| Engine and language lists | The Mozhi instances in your list | Nothing about you except your IP address | The instance's logs. Stored on the device as a cache. |
| **Check instances**, **Find the fastest server** (setup), **Test**, **Test connection**, **Browse models** | Each instance or provider, only when you ask | A version request, or a model list request with your key | The server's logs. |
| Sync (**Settings > Backup & sync > Sync**, only once you set it up) | Your WebDAV server | The sync file, encrypted on the device (`GET`, `PUT`), folder checks (`PROPFIND`, `MKCOL`), your user name and app password (HTTP Basic over `https`; plain `http` only to this device, your local network or `.onion`), your IP address. Never in Offline only | The server keeps the file: it sees its name, size, when it changes and its readable header (app version, when it was written, the key derivation parameters), never its contents ([what the server sees](sync.md#what-the-server-sees)). **Turn off sync** can delete it. |
| Web app fonts | The server that hosts the web app: the release zip and the CI builds include the fonts for scripts the bundled font lacks (for example Chinese or Devanagari) and emoji. Only a web build made without `tool/web_fallback_fonts.py` ([building](building.md#web-build-self-hosted-fonts-and-deferred-languages)) fetches them from Google's `fonts.gstatic.com` | The font file name, so which scripts you read, and your IP address; not your text | The browser caches the font. |

Text from other apps (text selection, the share sheet, the Quick Settings tile
and widget) and links (`/translate?text=…`, `mozhi://…`) is treated like typed
text and follows the same rules and prompts. Shared text and links never start
a paid AI request on their own, even with **Instant translate** set to
**Online engines and AI** (the quick-translate sheet of the selection menu
translates right away, since you asked for it). Links to the dictionary,
Proofread and the web page translator send nothing until you ask. In the web
app, a translate link puts the text in the page address, which reaches the
server that hosts the web app.

Nothing else: no update checks, no analytics, no remote configuration. Opening
**Settings > Translation engines > Mozhi instances** contacts nothing;
instances are checked only when you ask, and so are the servers behind **Find
the fastest server** during setup.

## On your device

| Data | Where | Notes |
| --- | --- | --- |
| Settings (instances, provider settings, translation options, approved language pairs and providers, appearance, recent and pinned languages) | App preferences | No secrets: the parts below are kept apart. |
| API keys, custom provider headers, user names and passwords in instance addresses (`https://user:password@host`) | Secure storage (Android Keystore; in the web app the browser's session storage) | Never in the settings, exports or history, and in an encrypted [backup](backup.md) only when you include them. Deleting a provider or an instance deletes its secrets. |
| History and favorites | App preferences, **encrypted with AES-256-GCM**; the key is in secure storage (Android Keystore) | Translations (text, translation, languages, engine, time) and dictionary look-ups (word, languages, AI model, detail level, a one-line summary of the entry, time). Up to 1,000 entries plus favorites. **Settings > Privacy & data > Delete history automatically** removes entries older than 1, 7 or 30 days (favorites are kept). |
| Presets, glossaries, read-aloud settings, usage counters | App preferences | Usage counters are numbers only (requests, characters, estimated tokens per provider and month, for 13 months). |
| Cached engine and language lists | App preferences | Lists only, keyed by instance address without any password. |
| Sync setup | App preferences (server address, user name, folder, what to sync, the last sync's time and result, the sync file's ETag and a fingerprint of the synced data); secure storage (the app password and the key derived from your passphrase) | Never the passphrase. In the web app the app password and the key last as long as the tab. **Turn off sync** and **Delete all local data** forget all of it. |
| Offline language models | App storage (`<app files>/bergamot`); in the web app the browser's private storage for the site (the Origin Private File System, folder `bergamot`), which no other site and no page script outside the app can read | About 50 MB to download and 73 MB on disk per language. Delete them under **Settings > Translation engines > Offline languages**; in the web app clearing the site's data deletes them too. |
| Text recognition data | App storage (`<app files>/tesseract`) | 0.4 to 12 MB per language (median 2.4 MB). Delete it under **Settings > Translation engines > Offline languages > Text recognition**. |
| On-device AI models | App storage (`<app files>/llm`) | One to a few GB per model (the On-device AI page shows each size). Delete them under **Settings > On-device AI**. Which model translates and which does the extras is kept in the app preferences. |

**History encryption.** Each history value is encrypted with AES-256-GCM (a
fresh nonce per write) under a 256-bit key generated on the device. On Android
the key is kept in secure storage, wrapped by an Android Keystore key that
never leaves the phone. In the **web app** the key has to be kept in the
browser's storage next to the history (the web app's secure storage only lasts
as long as the tab), so there the encryption protects little: anyone who can
read the site's storage can read both. **Export history** writes plain,
unencrypted JSON, and says so. **Export favorites** (on History's Favorites
tab) writes a plain CSV file of your favorites; the app says that it isn't
encrypted, and the file stays on the device unless you share it.

**Phrasebook.** Your phrasebook collections ([details](phrasebook.md)):
their phrases, your notes (also those on favorites) and a record of deleted
phrases and collections (their ids and when, never their text, for 180
days, so that merging a backup doesn't bring them back) are kept in the app
preferences, encrypted with AES-256-GCM under a key of their own in secure
storage, like the history (in the web app that key sits in the browser's
storage, as the history's does). The Favorites collection is your history's
favorites, not a copy. **Starter phrasebooks** are downloaded only when you
tap **Download**, once, from your [model
source](#where-model-files-come-from) (by default the project's GitHub
release, which sees your IP address and which languages you download),
checked against the SHA-256 pinned in the app and kept unencrypted (they are
public Wikivoyage text); reading them sends nothing. **Export as CSV**
writes a plain, unencrypted file, and says so; it stays on the device unless
you share it. **Import CSV** reads the file on the device.

**Practice.** Practice ([details](practice.md)) keeps the progress of each
flashcard you reviewed (its FSRS scheduling state, review count and dates;
the texts stay in the phrasebook and the history) and the practice settings
in the app preferences, encrypted with AES-256-GCM under a key of its own in
secure storage, like the history (in the web app that key sits in the
browser's storage, as the history's does). Scheduling runs on the device.
Speaking practice records only while you hold or tap the microphone; the
audio stays in memory, is transcribed on the phone by Whisper and dropped,
never stored or sent. **Export to Anki** writes a plain, unencrypted text
file, and says so; it stays on the device unless you share it.

**No cloud backup, no device transfer.** The app opts out of cloud backup,
and its backup rules exclude everything from Android 12+'s device-to-device
transfer too, so nothing is copied to your Google account or to a new
phone by the system.

**Encrypted backups, made by you.** **Settings > Backup & sync > Back up
now** writes your history and favorites, presets, glossaries and settings
into one `.mozhibackup` file encrypted with your passphrase (Argon2id and
AES-256-GCM), which you save wherever you like; **Restore from a backup**
reads it back, on Android or in the web app ([Backup](backup.md)). Nothing
is sent anywhere: there is no account and no server. API keys and
passwords are left out unless you turn on **Include API keys and
passwords**. Only the date of your last backup is stored, never the
passphrase or the key. Anyone who has the file sees only when it was made,
by which app version and its size, and can only read it by guessing the
passphrase, so pick a long one. To make merging copies work, the history
keeps a record of deleted entries (their id and when, never their text) for
180 days. **Export history** still writes plain JSON, and says so.

**Sync with your own server.** **Settings > Backup & sync > Sync** keeps
your devices in sync through a WebDAV folder you control ([Sync](sync.md)).
The data goes there as one file encrypted like a backup (Argon2id and
AES-256-GCM, with a key derived from your sync passphrase), so neither the
server nor anyone who reads its disks can read it; it sees the file's size,
when it changes and, like any server, your IP address. Settings are left
out unless you choose them, and API keys and passwords only travel when you
also turn on **Include API keys and passwords**. Sync runs only while the
app is open (at start, a minute after a change, or on **Sync now**), never
in Offline only, and on Android not over mobile data if you choose **Sync
on Wi-Fi only**.

**Memory only.** Recent translations are kept in memory for up to a day
while the app is running, so that translating the same text again doesn't
send it again. Memory also holds the last 20 read-aloud clips, the
translations into extra target languages and the meaning check of the
current translation. Closing the app clears them.

**Delete all local data** (**Settings > Privacy & data**) first forgets the
sync setup with its app password and key (without contacting the server,
where the sync file stays), then deletes the history
with its deletion records and its key, the date of the last backup (the
backup files you saved are yours and stay where you put them), the
phrasebook with its key and the starter phrasebooks, the
settings with every key, header and password, presets and
glossaries (with their deletion records), usage counters, speech settings, cached lists, the whole
offline models folder (partial downloads included) and the on-device AI
models, clears what the app holds
in memory, and starts setup again. Uninstalling the app removes all of it too.
In the web app, clearing the site's data does the same.

## Screen, keyboard and clipboard

- **Incognito** (**Settings > Privacy & data**): new translations and
  dictionary look-ups are not saved to the history (one you heart is still
  saved), and keyboards are asked not to learn what you type (Android's
  `IME_FLAG_NO_PERSONALIZED_LEARNING`; keyboards may ignore it). API key
  fields always ask that, whether incognito is on or not, and address and key
  fields turn off autocorrect and suggestions.
- **Hide content in recents & block screenshots** (Android): sets
  `FLAG_SECURE` on the app's window, which also blocks screen recording and
  screen sharing of the app.
- **Sensitive clipboard** (Android 13+): text you copy from the app is
  marked sensitive (`ClipDescription.EXTRA_IS_SENSITIVE`), so the system's
  copy preview and keyboard clipboard suggestions don't show it. The system
  then confirms the copy itself, so the app doesn't add its own "Copied"
  message. Clipboard managers can still read it.
- **Reading the clipboard.** The app reads the clipboard only when you tap
  **Paste**, **Translate clipboard** or the start screen's **Paste and
  translate** (**Paste copied text**) chip. To offer that chip, the Android
  app asks the system whether the clipboard holds text when you come back
  to it. That check doesn't read the text (so Android shows no "pasted"
  notice), and the web app doesn't make it.

## Network

- **HTTPS for public servers.** Plain `http` is only used for this device,
  your local network and Tor `.onion` or I2P `.i2p` addresses. Anything
  else is refused before a request is sent, and the Mozhi, LibreTranslate,
  DeepL and AI provider clients and the downloads never follow a redirect
  from `https` to `http`. A Mozhi instance can't redirect your text to
  another server, and a download can't be redirected from a public server
  into your local network. The Android app's platform networking
  (Java/Kotlin code and plugins) doesn't allow plain `http` at all.
- **HTTP proxy** (**Settings > Privacy & data > Network > HTTP proxy**,
  Android): every request the app makes, including offline model downloads and
  the web page translator, goes through the proxy you set (`host:port`), as a
  `CONNECT` tunnel, plain `http` included. For Tor, use Orbot's HTTP proxy,
  `127.0.0.1:8118`. Requests to this device and your local network go direct,
  since a proxy such as Tor couldn't reach them. A change applies after
  restarting the app. A server that doesn't answer through the proxy
  within 20 seconds (the tunnel and, for `https`, the encrypted connection
  through it) counts as unreachable, so a Mozhi translation moves on to the
  next instance in your list, as it does without a proxy; nothing was sent
  to the slow server. Without a proxy, `.onion` and `.i2p` addresses are
  refused before they are looked up, so their names don't leak to your DNS
  resolver. SOCKS isn't supported. The web app uses the browser's proxy.
- **Little to identify the app.** Requests send `User-Agent: Mozhi`
  (no version, no device details), no cookies (there is no cookie jar) and
  no `Referer`. The web page translator sends a desktop browser
  `User-Agent` instead, so that sites serve their full page. In the web
  app, the browser chooses the `User-Agent`, and the page's referrer policy
  (`no-referrer`) keeps it from sending a `Referer`.

### Shared conversation

**Share on this network** (the Conversation tab, Android) turns your phone
into a small web server on your local network for as long as you share
([how it works](features.md#shared-conversation)):

- **What guests get:** the messages said after you started sharing, the
  original and its translation into their language, and nothing else: not
  the earlier conversation, your history, settings or anything about your
  engines. The page loads nothing from the internet and sets no cookies;
  the guest's browser keeps only a random guest id and key for that tab
  (session storage), so a reload doesn't join twice.
- **Translations for guests** follow your privacy settings: a guest's
  language is translated by your engine only for a language pair your
  settings already allow without asking. Otherwise the offline engine on
  the phone translates it, or it waits for your OK on the sharing page;
  in **Offline only** nothing leaves the phone. A guest can't make your
  phone send text anywhere you haven't allowed, nor use up a "just this
  once" you gave for something else.
- **What guests type** becomes a message of your conversation and is
  translated like yours. It isn't saved anywhere (the conversation isn't
  in the history).
- **Who can read along:** the page is plain `http` on the local network
  (a phone has no certificate a browser would trust). It answers only
  devices with a private network address and only at the link's random
  128-bit address, with the PIN if you ask for one, but anyone on the same
  network who captures its traffic can read the conversation and the
  PIN. Your phone's hotspot is best; don't share sensitive talk on public
  Wi-Fi.
- **When it ends:** sharing stops when you tap **Stop sharing**, leave the
  conversation, or the phone stays locked (the app in the background) for
  2 minutes. Nothing about the guests is kept. These connections come in
  to the phone, so [Network activity](#network-activity), which lists what
  the app sends out, doesn't show them.

### Phone to phone

**Phone to phone** (Settings > Backup & sync, Android) moves your data or
your offline languages between two phones directly
([how it works](features.md#phone-to-phone)):

- **Nothing leaves the local network:** the phones talk to each other over
  the Wi-Fi or hotspot they share, end-to-end encrypted, with no server, no
  account and no internet; no model host is contacted either.
- **What the other phone gets:** only what you choose to send and it
  accepts: the parts of your data you pick (API keys and passwords only if
  you turn that on, and the receiving phone is told), and the offline files
  you pick. It sees the list you offer, nothing else about your phone.
- **What's kept:** your data stays in memory until it is restored, and
  only offline files pass through the app's cache folder while they are
  checked; they are deleted after each transfer (what an interrupted one
  left, at the next). Nothing about the other phone is remembered. These
  connections are between your phones, so
  [Network activity](#network-activity), which lists what the app sends
  to servers, doesn't show them.

## Google code

The default build, used for the GitHub releases, F-Droid and the Play bundle,
contains no Google code: no ML Kit, Play services or Firebase (CI checks every
APK). Offline translation uses Mozilla's **Bergamot** engine with the
**Firefox Translations** models (MPL-2.0), the ones Firefox uses for its
built-in translation; it runs entirely on the phone. **Translate offline** in
Android's text selection menu uses only this engine, whatever the privacy
mode, so the selected text never leaves the device. The models are downloaded
from Mozilla's bucket on Google Cloud Storage (see the table above), only when
you tap **Download** (on the offline languages page or in the language picker)
or **Update**, are checked against the SHA-256 checksums bundled with the app,
and are never sent your text. With **Download over Wi-Fi only** on (the
default), the app asks before using mobile data or a metered network. To keep
the phone from contacting Google's servers at all, download the files on
another computer and use **Import from files** on **Settings > Translation
engines > Offline languages** instead
([how](offline-engine.md#import-models-without-the-app-downloading-them)): an
import contacts nothing, so it also works in **Offline only**.

Voice input can run without Google too: **Offline (Whisper)** in **Settings >
Read aloud & voice > Voice input** recognises speech on the phone with
OpenAI's Whisper models on whisper.cpp (MIT), downloaded from Hugging Face or
imported from files ([voice input](voice-input.md)). The default **System
speech recognition** is the phone's own recogniser, on most phones Google's,
which is outside the app.

Photo and camera translation reads text on the phone with the open-source
Tesseract engine and language data downloaded from GitHub only when you ask,
or imported from files ([text recognition](text-recognition.md)).

An optional **Play variant** uses Google's ML Kit for on-device text
recognition in image translation instead. The recognition runs on the phone, but
according to Google's [ML Kit terms](https://developers.google.com/ml-kit/terms)
ML Kit sends metrics about the performance and use of its APIs to Google.
The default build and the web app don't include it.

## Keeping everything private

For translations that never leave hardware you control, use any of:

- **Offline only** with the offline engine on Android;
- your own Mozhi instance with LibreTranslate
  ([guide](self-hosting-mozhi.md#configuration)), and remove the public
  instances from your list;
- a local AI model ([guide](ai-providers.md#local-models)).

To download the offline models without Google, GitHub or Hugging Face
learning your languages, use a [model mirror](#where-model-files-come-from)
on your own server.

Add **Incognito**, **Device voice only** (**Settings > Read aloud & voice >
Read aloud**, with voices that aren't [online voices](#online-voices)) and
**Offline (Whisper)** voice input (**Settings > Read aloud & voice > Voice
input**) to keep history, speech and dictation on the device too. See [Security](security.md) for how the app protects keys and handles
text from other apps and links.

The app is open source (MIT); you can check all of the above in the code.
