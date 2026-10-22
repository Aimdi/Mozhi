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
- **Your text is sent only to the back end you choose** for that
  translation: a Mozhi instance, an AI provider, a DeepL or LibreTranslate
  service, or nowhere at all with the offline engine and local models.
- **Personal data stays behind.** E-mail addresses, phone numbers, IBANs,
  card numbers and IP addresses are [replaced before text goes
  online](#personal-data-shield) and put back into the translation.
- **You can check what left the device.** [Network
  activity](#network-activity) lists every request of this session, without
  its text.

## Privacy modes

**Settings > Privacy > Privacy mode** decides how willing the app is to
send text over the network. The translation repository enforces it, not
just the screens, and checks it before every request.

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

### Personal data shield

**Settings > Privacy > Hide personal data from online engines** (on by
default) replaces e-mail addresses, phone numbers, IBANs (checked with
their check digits), payment card numbers (checked with the Luhn
algorithm) and IPv4 addresses with placeholders before the text goes to a
Mozhi instance, an AI provider or a DeepL or LibreTranslate service, and
puts them back into the translation on the device. The result says how
many items stayed on the device. Language detection and back-translation
for the meaning check are covered too. If an engine damages a placeholder,
the text is **not** sent again unmasked: the result is marked instead.

It doesn't apply to the on-device engine, which never sends anything. Not
yet covered: the AI extras (alternatives, word insights, explanations,
dictionary, alignment, proofreading, romanization) and text-to-speech,
which receive the text as written. Names and addresses aren't detected.

### Network activity

**Settings > Privacy > Network activity** lists every request the app made
this session: when, to which host, why (translation, AI, speech, photo,
catalogue, model download, web page), how many bytes went each way, the
answer's status, and whether it went through your proxy. It groups them by
destination with a line on who can read what was sent, and has Clear and
Copy summary actions.

The log never records text, paths, query strings, request bodies or
headers. It lives in memory only (the last 500 requests), is never saved
and is gone when the app closes. Requests the app refuses (for example
plain `http` to a public server) are never sent, so they don't appear.
Network use outside the app's own connections isn't listed: the system's
speech recognition and text-to-speech, links you open in the browser, and
in the web app the browser's own loading of the app's files.

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
| Language detection (**Detect language**, an "auto" source with a translation-only AI model) | The device first; if it is unsure, the AI provider itself or, for translation-only models, your Mozhi instance's Google engine, when the privacy rules allow that destination | The text | As for that destination. |
| Kagi-style extras, **Check meaning**, **Proofread** | The AI model for extras (**Settings > AI assistant for insights**) or the model you selected; **Check meaning** without one: the engine you translate with, to translate back | Source text, translation or both (the first 4,000 characters for **Check meaning**; the word for the dictionary) | The provider's policy. Results stay in memory only, except Dictionary tab look-ups: on the device, the word, its languages, the model's name, the detail level and a one-line summary go to the history unless incognito or **Save history** is off (or when you heart the entry). |
| **Listen** (read aloud) | The device's text-to-speech voice. A Mozhi instance only when the device has no voice for the language: never in Offline only or with **Device voice only**, and in Offline first only after you agree (**Listen online**) | Device voice: the text to the system's speech engine (voices marked **Needs internet** use its online service). Mozhi: the text **in the request address** (`GET /api/tts?text=…`, up to 200 characters per part) | Mozhi: the address can end up in the server's and any reverse proxy's access logs. The app keeps the last 20 clips in memory until it closes. |
| Image translation | **On-device text recognition** (Android, the default) sends the image nowhere: Tesseract reads it on the phone ([text recognition](text-recognition.md); ML Kit in the [Play variant](#google-code)), and only the recognised text follows the translation rows above. The AI model with **Supports images** gets the image itself; so does your Mozhi instance (experimental), which passes it to Google Translate (at most two instances are tried) | AI vision and Mozhi: the image, re-encoded first (no EXIF data such as the GPS location). On-device: nothing | The provider's or instance's policy. The app doesn't store the image. |
| Dictation, conversation | **System speech recognition** (the default): the system's recogniser (Google or the phone maker on Android; the browser's maker in the web app). **Offline (Whisper)** (Android, **Settings > Voice input**): nobody, it runs on the phone. In **Offline only** always Whisper, never the system recogniser ([voice input](voice-input.md)) | System: your voice. Whisper: nothing leaves the phone | System: the recogniser's policy; **Prefer on-device speech recognition** (Android 12+) only asks to keep it on the phone. Whisper: the recording stays in memory until it is transcribed, and is never stored. |
| Web page translator | The website you enter, then the translation engine | The page address and your IP address, with a desktop browser `User-Agent` and no cookies | The website's logs. The page text then follows the translation row above. |
| Offline model download | `storage.googleapis.com`: Mozilla's Firefox Translations bucket (`moz-fx-translations-data--303e-prod-translations-data`), hosted on Google Cloud Storage | Plain file requests (HTTPS `GET`, `Range` to resume): Google as the host sees your IP address, the time and which model files, so which languages, you download. No text, identifiers or cookies | Google Cloud Storage's logs. The models stay on the device until you delete them. |
| Text recognition data download (**Download German text recognition**, **Settings > Offline languages > Text recognition**) | `raw.githubusercontent.com`: Tesseract's [tessdata_fast](https://github.com/tesseract-ocr/tessdata_fast) on GitHub (owned by Microsoft), pinned to one commit | Plain file requests (HTTPS `GET`, `Range` to resume): GitHub sees your IP address, the time and which language files you download. No picture, text, identifiers or cookies | GitHub's logs. The data stays on the device until you delete it; **Import from files** contacts nothing. |
| Offline speech model download (**Settings > Voice input**) | `huggingface.co` (the [whisper.cpp models](https://huggingface.co/ggerganov/whisper.cpp)), which may redirect to its download servers | Plain file requests (HTTPS `GET`, `Range` to resume): Hugging Face sees your IP address, the time and which model (Fast or Better) you download. No voice, text, identifiers or cookies | Hugging Face's logs. The model stays on the device until you delete it; **Import from files** contacts nothing. |
| Engine and language lists | The Mozhi instances in your list | Nothing about you except your IP address | The instance's logs. Stored on the device as a cache. |
| **Check instances**, **Test**, **Test connection**, **Browse models** | Each instance or provider, only when you ask | A version request, or a model list request with your key | The server's logs. |
| Web app fonts | The server that hosts the web app: the release zip and the CI builds include the fonts for scripts the bundled font lacks (for example Chinese or Devanagari) and emoji. Only a web build made without `tool/web_fallback_fonts.py` ([building](building.md#web-build-self-hosted-fonts-and-deferred-languages)) fetches them from Google's `fonts.gstatic.com` | The font file name, so which scripts you read, and your IP address; not your text | The browser caches the font. |

Text from other apps (text selection, the share sheet, the Quick Settings
tile and widget) and links (`/translate?text=…`, `mozhi://…`) is treated
like typed text and follows the same rules and prompts. Shared text and
links never start a paid AI request on their own, even with **Instant
translate with AI** on (the quick-translate sheet of the selection menu translates
right away, since you asked for it). Links to the dictionary, Proofread and
the web page translator send nothing until you ask. In the web app, a
translate link puts the text in the page address, which reaches the server
that hosts the web app.

Nothing else: no update checks, no analytics, no remote configuration.
Opening **Settings > Mozhi instances** contacts nothing; instances are
checked only when you ask.

## On your device

| Data | Where | Notes |
| --- | --- | --- |
| Settings (instances, provider settings, translation options, approved language pairs and providers, appearance, recent and pinned languages) | App preferences | No secrets: the parts below are kept apart. |
| API keys, custom provider headers, user names and passwords in instance addresses (`https://user:password@host`) | Secure storage (Android Keystore; in the web app the browser's session storage) | Never in the settings, exports or history. Deleting a provider or an instance deletes its secrets. |
| History and favourites | App preferences, **encrypted with AES-256-GCM**; the key is in secure storage (Android Keystore) | Translations (text, translation, languages, engine, time) and dictionary look-ups (word, languages, AI model, detail level, a one-line summary of the entry, time). Up to 1,000 entries plus favourites. **Settings > Delete history automatically** removes entries older than 1, 7 or 30 days (favourites are kept). |
| Presets, glossaries, read-aloud settings, usage counters | App preferences | Usage counters are numbers only (requests, characters, estimated tokens per provider and month, for 13 months). |
| Cached engine and language lists | App preferences | Lists only, keyed by instance address without any password. |
| Offline language models | App storage (`<app files>/bergamot`) | About 50 MB to download and 73 MB on disk per language. Delete them under **Settings > Offline languages**. |
| Text recognition data | App storage (`<app files>/tesseract`) | 0.4 to 12 MB per language (median 2.4 MB). Delete it under **Settings > Offline languages > Text recognition**. |

**History encryption.** Each history value is encrypted with AES-256-GCM
(a fresh nonce per write) under a 256-bit key generated on the device. On
Android the key is kept in secure storage, wrapped by an Android Keystore
key that never leaves the phone. In the **web app** the key has to be kept
in the browser's storage next to the history (the web app's secure storage
only lasts as long as the tab), so there the encryption protects little:
anyone who can read the site's storage can read both. **Export history**
writes plain, unencrypted JSON, and says so.

**No backup, no device transfer.** The app opts out of cloud backup, and
its backup rules exclude everything from Android 12+'s device-to-device
transfer too, so nothing is copied to your Google account or to a new
phone: settings, history and keys have to be set up again. Use **Export
history** to move the history yourself.

**Memory only.** Recent translations are kept in memory for up to a day
while the app is running, so that translating the same text again doesn't
send it again. Memory also holds the last 20 read-aloud clips, the
translations into extra target languages and the meaning check of the
current translation. Closing the app clears them.

**Delete all local data** (**Settings > Privacy**) deletes the history and
its key, the settings with every key, header and password, presets,
glossaries, usage counters, speech settings, cached lists and the whole
offline models folder (partial downloads included), clears what the app
holds in memory, and starts setup again. Uninstalling the app removes all
of it too. In the web app, clearing the site's data does the same.

## Screen, keyboard and clipboard

- **Incognito** (**Settings > Privacy**): new translations and dictionary
  look-ups are not saved to the history (one you heart is still saved),
  and keyboards are asked not to learn what you type (Android's
  `IME_FLAG_NO_PERSONALIZED_LEARNING`; keyboards may ignore it). API key
  fields always ask that, whether incognito is on or not, and address and
  key fields turn off autocorrect and suggestions.
- **Hide content in recents & block screenshots** (Android): sets
  `FLAG_SECURE` on the app's window, which also blocks screen recording and
  screen sharing of the app.
- **Sensitive clipboard** (Android 13+): text you copy from the app is
  marked sensitive (`ClipDescription.EXTRA_IS_SENSITIVE`), so the system's
  copy preview and keyboard clipboard suggestions don't show it. The system
  then confirms the copy itself, so the app doesn't add its own "Copied"
  message. Clipboard managers can still read it. The app reads the
  clipboard only when you tap **Paste** or **Translate clipboard**.

## Network

- **HTTPS for public servers.** Plain `http` is only used for this device,
  your local network and Tor `.onion` or I2P `.i2p` addresses. Anything
  else is refused before a request is sent, and the Mozhi, LibreTranslate,
  DeepL and AI provider clients never follow a redirect from `https` to
  `http`. The Android app's platform networking (Java/Kotlin code and
  plugins) doesn't allow plain `http` at all.
- **HTTP proxy** (**Settings > Privacy > HTTP proxy**, Android): every
  request the app makes, including offline model downloads and the web
  page translator, goes through the proxy you set (`host:port`), as a
  `CONNECT` tunnel, plain `http` included. For Tor, use Orbot's HTTP proxy,
  `127.0.0.1:8118`. Requests to this device and your local network go
  direct, since a proxy such as Tor couldn't reach them. A change applies
  after restarting the app. Without a proxy, `.onion` and `.i2p` addresses
  are refused before they are looked up, so their names don't leak to your
  DNS resolver. SOCKS isn't supported. The web app uses the browser's
  proxy.
- **Little to identify the app.** Requests send `User-Agent: Mozhi`
  (no version, no device details), no cookies (there is no cookie jar) and
  no `Referer`. The web page translator sends a desktop browser
  `User-Agent` instead, so that sites serve their full page. In the web
  app, the browser chooses the `User-Agent`, and the page's referrer policy
  (`no-referrer`) keeps it from sending a `Referer`.

## Google code

The default build, used for the GitHub releases, F-Droid and the Play
bundle, contains no Google code: no ML Kit, Play services or Firebase
(CI checks every APK). Offline translation uses Mozilla's **Bergamot**
engine with the **Firefox Translations** models (MPL-2.0), the ones
Firefox uses for its built-in translation; it runs entirely on the phone.
**Translate offline** in Android's text selection menu uses only this
engine, whatever the privacy mode, so the selected text never leaves the
device.
The models are downloaded from Mozilla's bucket on Google Cloud Storage
(see the table above), only when you tap **Download** or **Update**, are
checked against the SHA-256 checksums bundled with the app, and are never
sent your text. With **Download over Wi-Fi only** on (the default), the app
asks before using mobile data or a metered network. To keep the phone from
contacting Google's servers at all, download the files on another computer
and use **Import from files** on **Settings > Offline languages** instead
([how](offline-engine.md#import-models-without-the-app-downloading-them)):
an import contacts nothing, so it also works in **Offline only**.

Voice input can run without Google too: **Offline (Whisper)** in
**Settings > Voice input** recognises speech on the phone with OpenAI's
Whisper models on whisper.cpp (MIT), downloaded from Hugging Face or
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

Add **Incognito**, **Device voice only** (**Settings > Read aloud**) and
**Offline (Whisper)** voice input (**Settings > Voice input**) to keep
history, speech and dictation on the device too. See [Security](security.md) for how the app
protects keys and handles text from other apps and links.

The app is open source (MIT); you can check all of the above in the code.
