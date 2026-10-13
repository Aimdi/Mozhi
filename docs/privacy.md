# Privacy

Mozhi is built so that you decide where your text goes, and so that nothing
goes anywhere else.

## The short version

- **No account, no telemetry, no analytics, no ads, no crash reporting.** The
  app contains no tracking code and does not contact any server run by the
  app's developers.
- **Your history and settings stay on your device.**
- **Your text is sent only to the back end you choose** for that translation:
  a Mozhi instance, an AI provider, or nowhere at all with local and offline
  models.

## What is stored on your device

| Data | Where | Notes |
| --- | --- | --- |
| Settings (instances, provider settings, languages, options, appearance) | App preferences | Never uploaded. |
| History and favourites | App preferences | Up to 1,000 entries plus favourites. Turn off **Settings > Save history** to stop saving; **Clear history** deletes them. |
| API keys | Platform secure storage (Android Keystore, Apple Keychain, ...) | Kept apart from the settings and never included in exports. Deleting a provider deletes its key. |
| Offline language packs | App storage (Android and iOS) | Downloaded once; delete them in the offline settings. |

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
| **Local AI model** | Only your computer | Nothing leaves your network. |
| **Offline (on-device)** | Nothing | Translation runs on the phone. Downloading a language pack contacts Google's servers. |

The engine list marks each engine **Local**, **Self-hosted** (Mozhi engines)
or **Cloud** (third-party AI). "Self-hosted" refers to the kind of engine: a
Mozhi engine on a public instance still passes through that instance's
operator.

Some features send additional data to the same back ends:

- **Kagi-style extras** (alternatives, insights, explanations, dictionary,
  suggestions) send the source text and its translation to the AI model that
  provides them. When you translate with a Mozhi engine, that is the model
  chosen under **Settings > AI assistant for insights**. Extras are only
  requested when you open them.
- **Proofread** sends the text to the AI model you selected.
- **Listen** (text-to-speech) sends the text to your Mozhi instance, which
  fetches the audio from Google (or Reverso). Device voices, where used, work
  on the device.
- **Image translation** sends the image to the AI model (with **Supports
  images**) or to your Mozhi instance, which passes it to Google. On-device
  text recognition keeps the image on the phone.
- **Dictation** uses your operating system's speech recognition. Depending on
  the device and its settings, the audio may be processed by Google (Android)
  or Apple (iOS, macOS) rather than on the device.
- **Text from other apps** (text selection, share sheet) is handled exactly
  like typed text: it goes to the engine you have selected.

## Every connection the app makes

- The Mozhi instances in your list: translations, engine and language lists,
  text-to-speech, image translation, and a lightweight `/api/version` request
  when you test an instance or open the instance settings. Out of the box, the
  list contains public instances, so a fresh install talks to the first one.
- The AI providers you added: translations, extras, proofreading, the model
  list (**Browse models**) and **Test connection**.
- Google's servers, only to download offline language packs or on-device
  recognition models.
- Web pages you open from the app (source code, licences, provider key
  pages), in your browser.

Nothing else: no update checks, no analytics, no remote configuration.

## Keeping everything private

For translations that never leave hardware you control, use any of:

- your own Mozhi instance with LibreTranslate
  ([guide](self-hosting-mozhi.md#configuration)), and remove the public
  instances from your list;
- a local AI model ([guide](ai-providers.md#local-models));
- offline translation on Android and iOS.

The app is open source (MIT); you can check all of the above in the code.
