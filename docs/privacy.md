# Privacy

Mozhi is built so that you decide where your text goes, and so that nothing
goes anywhere else.

## The short version

- **No account, no telemetry, no analytics, no ads, no crash reporting.** The
  app contains no tracking code of its own and does not contact any server
  run by the app's developers. (The one third-party library that reports
  usage metrics, Google's ML Kit, is covered [below](#google-ml-kit).)
- **Your history and settings stay on your device.**
- **Your text is sent only to the back end you choose** for that translation:
  a Mozhi instance, an AI provider, or nowhere at all with local and offline
  models.

## What is stored on your device

| Data | Where | Notes |
| --- | --- | --- |
| Settings (instances, provider settings, translation options, appearance) | App preferences | Never uploaded. |
| Your languages: recent and pinned languages, recent language pairs, the extra target languages of **Also translate into…** | App preferences | Part of the settings (languages only, not the translations). **Clear recent language pairs** (in **Settings** or the recent pairs sheet) forgets the pairs. |
| History and favourites | App preferences | Up to 1,000 entries plus favourites. **Settings > Delete history automatically** removes entries older than 1, 7 or 30 days (favourites are kept). Turn off **Settings > Save history** to stop saving; **Clear history** deletes them. |
| Presets and glossaries | App preferences | Exported only when you export them. |
| Read-aloud settings: speech rate, **Use device voice**, the device voice chosen per language | App preferences | The rate and each chosen voice's name, locale and engine details, never text. |
| Usage counters and budgets | App preferences | Numbers only (requests, characters, estimated tokens per provider and month, for the last 13 months), never text. **Reset usage** deletes them; deleting a provider deletes its counts. |
| API keys | Platform secure storage (Android Keystore, Apple Keychain, ...) | Kept apart from the settings and never included in exports. Deleting a provider deletes its key. |
| Offline language packs | App storage (Android and iOS) | Downloaded once; delete them in the offline settings. |

Recent translations are also kept in memory, never on disk, for up to a day
while the app is running, so that translating the same text again doesn't
send it again. Memory also holds the last 20 read-aloud audio clips (so
listening again usually needs no network), the translations into extra
target languages and the meaning check of the current translation. Closing
the app clears them.

Uninstalling the app removes all of it. In the web app, the same data lives
in your browser's storage for the site, and clearing the site's data removes
it; a browser protects API keys less strongly than a phone's secure storage.

The app itself never uploads this data. If you use your platform's device
backup (for example Android's backup to your Google account or an iCloud
backup), the operating system may include app data in it, as it does for
other apps.

## What each back end sees

When you translate, the selected engine receives your text, the languages,
and the network address of whoever sends the request.

| Back end | Receives your text | Notes |
| --- | --- | --- |
| **Public Mozhi instance** | The instance, then the engine (Google, DeepL, Reverso, Yandex, MyMemory, DuckDuckGo/Bing or the instance's LibreTranslate) | The engine sees the instance's IP address, not yours. The instance operator could see your text and IP address. |
| **Your own Mozhi instance** | Your server, then the engine | The engine sees your server's IP address. |
| **Your own Mozhi + LibreTranslate** | Only your server | No third party involved. |
| **Cloud AI provider** | The provider | Along with your IP address and API key. Your translation options (context, glossary) are part of the request. Retention and training policies are the provider's; check their terms. |
| **DeepL API, LibreTranslate** (your own key or server) | DeepL, or the LibreTranslate server you entered | Along with your IP address and key. DeepL also receives the formality and context of your translation options. |
| **Local AI model** | Only your computer | Nothing leaves your network. |
| **Offline (on-device)** | Nothing | Translation runs on the phone. Downloading a language pack contacts Google's servers. |

The engine list marks each engine **Local**, **Self-hosted** (Mozhi engines)
or **Cloud** (third-party AI). "Self-hosted" refers to the kind of engine: a
Mozhi engine on a public instance still passes through that instance's
operator.

Some features send additional data to the same back ends:

- **Kagi-style extras** (alternatives, insights, explanations, refinement
  chips and suggestions, romanization, alignment, the dictionary) send the
  source text, its translation or both (the dictionary: the word) to the AI
  model that provides them. When you translate with a Mozhi engine, that is the
  model chosen under **Settings > AI assistant for insights**. Extras are only
  requested when you ask for them; insights, alignment and a romanization you
  asked for then also load for the next translations you start. A
  romanization loads on its own only when that model runs on your device or
  network.
- **Short texts** translated with a cloud AI model and **Detect language**
  get a second, small request to the same provider to double-check the
  language. For short texts, AI models are also told which languages you
  recently translated from (the languages only, not what you translated).
- **Long texts** are sent to AI models in parts, each with the end of the
  part before it. Nothing goes anywhere else.
- **Check meaning** sends your text and its translation (the first 4,000
  characters of each) to the AI model for extras; when you translate with a
  Mozhi engine, that is the model chosen under **Settings > AI assistant
  for insights**. Without such a model, the translation is sent to the
  engine you translate with, to be translated back. Only when you press
  **Check meaning**.
- **Also translate into…** sends your text to the same engine once for
  each extra language, with the same options as the main translation. This
  includes text shared into the app or opened from a link whenever it is
  translated straight away (Mozhi engines, the DeepL API, LibreTranslate,
  offline, or an AI model with **Instant translate with AI** on), also
  right after the app starts, because your extra languages are remembered.
- **Proofread** sends the text to the AI model you selected. The writing
  statistics are calculated on the device.
- **Listen** (text-to-speech) sends the text to your Mozhi instance, which
  fetches the audio from Google (or Reverso). Device voices (with **Use
  device voice**, a voice chosen under **Settings > Read aloud**, or when
  Mozhi can't read a language) are provided by the operating system's or
  the browser's text-to-speech engine and usually run on the device; voices
  marked **Needs internet** are processed by that engine's online service.
  Voice previews in the settings use the device voices only.
- **Image translation** sends the image to the AI model (with **Supports
  images**) or to your Mozhi instance, which passes it to Google. On-device
  text recognition keeps the image on the phone.
- **Dictation** uses your operating system's speech recognition (or, in the
  web app, the browser's). Depending on the device and its settings, the audio
  may be processed online by Google (Android, Chrome) or Apple (iOS, macOS)
  rather than on the device. On Android 12+, iOS and macOS, **Prefer
  on-device speech recognition** asks the system to keep it on the device.
- **Text from other apps** (text selection, share sheet) and **links**
  (`/translate?text=...`, `mozhi://...`) are handled like typed text: they go
  to the engine you have selected. Shared text and links never start a paid
  AI request on their own unless **Instant translate with AI** is on (the
  quick-translate sheet of the selection menu translates right away, since
  you asked for it). Links to the dictionary, Proofread or the web page
  translator send nothing until you ask.

## Every connection the app makes

- The Mozhi instances in your list: translations, engine and language lists,
  text-to-speech and image translation. Opening **Settings > Mozhi instances**
  sends a lightweight `/api/version` request to every instance in the list to
  show its response time, and **Test** does the same for one. Out of the box,
  the list contains public instances, so a fresh install talks to the first
  one.
- The AI providers you added: translations, extras, proofreading, the model
  list (**Browse models**) and **Test connection**.
- Your DeepL API and LibreTranslate services: translations and **Test
  connection**.
- Google's servers, through ML Kit, on Android and iOS only (see below).
- Web pages you translate with **Web page**: the app downloads the page from
  its website, as a browser would (on Android, iOS and desktop it identifies
  as a desktop browser; in the web app, your browser makes the request). The
  website sees your IP address. The page's text then goes to the engine you
  chose.
- Web pages you open from the app (source code, licences, provider key
  pages), in your browser.
- Web app only: Google Fonts (`fonts.gstatic.com`), the first time the page
  has to display a script its bundled font doesn't cover (for example
  Chinese, Arabic or Devanagari). Flutter's web engine then downloads the
  matching Noto font. The request names the font file, not your text, and
  the browser caches it. The Android, iOS and desktop apps use the fonts
  installed on the device instead.

Nothing else: no update checks, no analytics, no remote configuration.

### Google ML Kit

Offline translation and on-device text recognition (Android and iOS) use
Google's ML Kit libraries. Translation and recognition run on the device; the
text and images are not sent anywhere. ML Kit does download language packs
and models from Google, and according to Google's
[ML Kit terms](https://developers.google.com/ml-kit/terms) it also sends
metrics about the performance and use of its APIs to Google. The web and
desktop apps don't include ML Kit.

## Keeping everything private

For translations that never leave hardware you control, use any of:

- your own Mozhi instance with LibreTranslate
  ([guide](self-hosting-mozhi.md#configuration)), and remove the public
  instances from your list;
- a local AI model ([guide](ai-providers.md#local-models));
- offline translation on Android and iOS.

The app is open source (MIT); you can check all of the above in the code.
