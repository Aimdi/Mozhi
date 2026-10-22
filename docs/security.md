# Security

This page covers what the Mozhi app protects, what it doesn't, and how. For
which data goes where, see [Privacy](privacy.md).

## Reporting a vulnerability

Please report security problems privately through **Report a vulnerability**
on the repository's GitHub **Security** tab
(<https://github.com/Aimdi/Mozhi/security/advisories/new>), not in a public
issue. Say which version and platform you used and how to reproduce the
problem.

## What we protect, and from whom

| Asset | Threats considered |
| --- | --- |
| AI / DeepL / LibreTranslate **API keys** (they cost money) | Other apps on the device, backups and device transfer, logs, a misconfigured or hostile server, hostile Wi-Fi |
| **Your text**, translations and history | Servers you didn't choose, logs, cloud backup and device transfer, screenshots, keyboards and clipboard managers |
| **Your bill** with paid providers | Other apps or web pages starting requests without you |
| **Your local network** | Websites using the app to reach devices on your LAN |
| **What the AI writes back** | Prompt injection through the text you translate, links and model output |

Out of scope: a rooted device, malware that already controls
the device or the user's account, and the servers you configure. The
operator of a Mozhi instance or an AI provider sees the text you send it;
pick ones you trust, or self-host them ([guide](self-hosting-mozhi.md)).

## API keys and other secrets

- API keys, custom provider headers and the user name and password of an
  instance address (`https://user:password@host`) are stored only in
  secure storage (Android Keystore-backed encrypted preferences; in the web
  app, the browser's session storage, see below), never in the settings,
  exports or history. Settings written by older versions that still held
  headers or instance passwords are moved there on the next start, and the
  plain copy is removed. The cached engine lists are stored under the
  instance address without its password.
- **Android:** cloud backup is off (`allowBackup="false"`), and the backup
  and device-transfer rules exclude every file of the app, so keys stay on
  the phone.
- **Web app:** keys are kept in session storage, so they last only as long
  as the browser tab. Host the web app on its own origin (its own domain or
  subdomain); any page on the same origin can read the browser's storage.
- If secure storage doesn't work when the app starts, keys are kept in
  memory only and the app says so; they are never written to plain storage
  instead. A later failure (after a working start) is retried once and then
  reported: **Couldn't store your API key or password securely. It works
  until you close Mozhi and is never saved unprotected.** Keys are never
  moved to memory silently. Settings that can't be saved are reported the
  same way (**Couldn't save your settings. Changes stay until you close
  Mozhi.**).
- Keys are sent only in the provider's auth header, never in URLs. Error
  messages and server responses shown in the app have keys removed. Error
  descriptions (`toString`) leave out credentials and query strings in URLs.
- Debug builds log only bloc and state **type names**, never state contents
  (which hold your text and, while onboarding, the key you are typing).
  Release builds don't log app data.
- Key fields ask keyboards not to learn what is typed and turn off
  autocorrect and suggestions; address fields do the same for autocorrect
  and suggestions.

## Data on the device

- **History:** encrypted with AES-256-GCM (a random nonce per write, the
  format version bound in as associated data) under a 256-bit key that is
  kept in secure storage, wrapped by an Android Keystore key. Damaged data
  or a missing key is reported, never silently replaced. In the web app
  the key has to live in the browser's storage next to the history, so the
  encryption protects little there. **Export history** is plain JSON.
- **No backup or transfer:** nothing the app stores goes to cloud backup or
  to a new phone (see [Privacy](privacy.md#on-your-device)).
- **Incognito** stops saving new translations to the history and asks
  keyboards not to learn what you type.
- **Screenshots:** **Hide content in recents & block screenshots** sets
  `FLAG_SECURE`, which also blocks screen recording and sharing.
- **Clipboard:** on Android 13+ copies are marked sensitive
  (`EXTRA_IS_SENSITIVE`), so the system's preview and keyboard suggestions
  don't show them.
- **Delete all local data** removes the history and its key, the settings
  with their secrets, every other preference, the offline models folder and
  what the app holds in memory.

## Network

- **HTTPS by default.** Addresses typed without a scheme get `https://`,
  except local ones (`localhost`, private IP ranges, `.local`, `.lan`, bare
  host names), which get `http://` because self-hosted servers on a LAN
  usually have no certificate.
- **Plain HTTP only for your own and private servers:** this device, your
  local network, Tor `.onion` and I2P `.i2p` addresses. The app refuses
  plain `http` to any other host before anything is sent (the network
  policy in `lib/core/network/network_policy.dart` checks every request of
  the Mozhi, LibreTranslate, DeepL and AI clients, redirects included), and
  Settings and first-run setup don't accept such an address. Use HTTPS, a
  VPN, Tailscale or Tor for servers outside your home network.
- **Android platform networking** (Java/Kotlin code and plugins) allows no
  plain `http` at all (`network_security_config.xml`). Dart's HTTP client
  ignores that file, which is why the app's own policy above exists.
- **Proxy:** with **Settings > Privacy & data > Network > HTTP proxy** (for
  example Orbot, `127.0.0.1:8118`) every request goes through a `CONNECT`
  tunnel; a proxy setting that can't be parsed never falls back to a direct
  connection. The app opens the tunnel itself and runs TLS through it with
  the system's certificate checks, so the connection timeout (20 s through
  a proxy, 7 s direct) covers the proxy's answer and the TLS handshake
  too; `dart:io`'s own proxy support would time only the connection to
  the proxy. A proxy that answers with anything but `200`, or sends data
  before the TLS handshake, is refused. Without a proxy, `.onion` and
  `.i2p` addresses are refused before a DNS lookup.
- **Headers:** requests carry `User-Agent: Mozhi`, no cookies and no
  `Referer`; the web app's page sets `referrer` to `no-referrer`.
- **Certificates:** the app never disables certificate checks. Release
  builds on Android trust only the system certificate authorities; CAs
  installed by the user (or by malware or device management) are trusted in
  debug builds only, for traffic inspection during development.
- **Redirects:** AI, DeepL and LibreTranslate requests never follow
  redirects (a redirect would otherwise carry headers such as `x-api-key`
  to another host); a moved API shows an error asking you to update the
  address. Mozhi requests follow at most three redirects and never from
  `https` to `http`.
- **Timeouts and size limits** on every request. Mozhi failover does not
  resend your text to another instance after a timeout, when the first one
  may already have received it. A connection that can't be set up in time
  (also through the proxy) carried nothing yet, so it fails over.

## Web page translator

The web page translator downloads pages itself (outside the web app), so a
link could otherwise be used to make the app fetch something you didn't mean
to:

- Only `http` and `https` addresses are fetched; pages are read as text and
  shown in a reader view. No JavaScript runs, there is no WebView, and
  links on the page are not followed.
- **No redirects into your network:** a public page that redirects to this
  device or your local network (`localhost`, private and link-local IP
  addresses including cloud metadata addresses, numeric shorthands such as
  `0x7f.1`, `.local` names) is refused. Typing a local address directly
  still works. A host name that *resolves* to a private address
  (DNS rebinding) is not detected; the reader view still runs no scripts,
  and the page's text goes only to the translation engine you selected.
- Downloads are capped at 2 MiB and 25 seconds, go through the HTTP proxy
  when one is set, and carry no cookies or `Referer`; a `.onion` or `.i2p`
  page needs the proxy.
- `mozhi://web?url=…` and `/web?url=…` links only fill in the address; the
  page is loaded when you press the button.

## Text from other apps and links

Shared text, "Translate with Mozhi" in the text selection menu, the Quick
Settings tile, launcher shortcuts and widget, and links (`mozhi://…`,
`/translate?text=…`) are untrusted input:

- Text is capped at 5,000 characters, and the same text arriving again
  within two seconds is ignored.
- It never starts a **paid AI request** on its own, even with **Instant
  translate with AI** on (that setting covers typing only). Free engines
  (Mozhi, offline) may translate it right away.
- Links may set only the fixed translation options (style, formality,
  reading level, genders, formatting) and languages from the catalogue.
  Free-text options (context, glossary, instructions) and unknown target
  languages are ignored, because they would end up in later AI prompts.
- Dictionary, Proofread and web page links send nothing until you ask.
- Replacing the selected text in the other app (PROCESS_TEXT) needs a tap
  on **Replace**, and Android only accepts the answer for a writable
  selection request that is still current.
- Exported Android components: the main activity (launcher, share,
  PROCESS_TEXT, `mozhi://` links) and the Quick Settings tile (bound only by
  the system). The home-screen widget receiver is not exported, and its
  buttons use immutable pending intents.

## AI prompts and output

The text you translate may come from a web page or another person, so it is
treated as data, not instructions:

- Source text, context and other inputs are wrapped in tags such as
  `<source>…</source>`, and the same tags inside the data are neutralised so
  the text can't close them early.
- Custom language names are cleaned (no quotes, control characters or
  angle brackets) and shortened before they go into a prompt.
- Refinement suggestions written by the model go into the prompt as a
  lower-trust "refinement preference", never as an instruction from you.
- With the personal data shield, the AI extras get placeholders such as
  `⟨1⟩` and a system note that they stand for personal data to keep; the
  values are put back on the device only, into the model's answer, and a
  placeholder the model changed is never filled in by sending the value.
  Glossary terms for Mozhi and LibreTranslate are placeholders too, so
  those engines never see the glossary.
- Model output is shown as plain text (with bold, italics and code at most):
  no links, HTML, images or scripts are rendered.

Prompt injection can't be ruled out completely: a hostile text can still
make a model produce a wrong or misleading "translation". Check important
translations, for example with **Check meaning**.

## Other measures

- Photos sent to AI providers are re-encoded first, which removes EXIF data
  such as GPS location.
- Imported history is capped like the history itself.
- No analytics, telemetry or crash reporting libraries, and no Google code
  in the default build (CI checks every APK with
  `tool/check_no_google.sh`). Offline translation uses Mozilla's Bergamot
  engine with the Firefox Translations models (MPL-2.0); downloaded models
  are checked against bundled SHA-256 checksums before use. Only the
  optional Play variant includes ML Kit (on-device text recognition), which
  sends usage metrics to Google; see [Privacy](privacy.md#google-code).
- Third-party licences, including the native engine's components (and ML
  Kit in the Play variant), are listed under **Settings > About >
  Open-source licenses**.
- **Release builds:** Android APKs and the app bundle are built with
  `--obfuscate --split-debug-info`; the debug symbols are kept as a private
  workflow artifact (90 days), not attached to the public release.
- **CI supply chain:** third-party GitHub Actions and reusable workflows are
  pinned to full commit SHAs (with the version in a comment, which
  Dependabot updates), so a moved tag can't change what runs in CI.

## Known limitations

- **Online voices** are recognised by what the platform reports: the
  browser's `localService` flag in the web app, and Android's
  network-required flag and installed voice data. A speech engine that
  reports an online voice as local, or switches to its online service on
  its own, isn't caught; [Offline only](privacy.md#privacy-modes) and
  **Device voice only** can't stop that either. The personal data shield
  can't apply to speech.

- Android's "translate clipboard" entry point (Quick Settings tile,
  home-screen widget, launcher shortcut) goes through a non-exported
  component, so other apps can no longer make Mozhi read the clipboard;
  the same request sent to Mozhi's main screen only opens the app. The app
  that hosts the widget (your launcher) can still press the widget's
  Translate clipboard button, like any widget button. Clipboard text is
  then handled like shared text: capped, no paid AI request on its own,
  but translated by a free engine and saved to history if those are on.
- An `http://` address that the app treats as local (`localhost`,
  private IP addresses, `.local`/`.lan` names, bare host names and
  similar) is trusted as your own network; on a hostile LAN its traffic
  can still be read. A public `http://` instance added by an older version
  stays in the list, but nothing is sent to it.
- **Web app Content Security Policy:** `index.html` allows scripts only from
  the app's own origin (no inline scripts, `'wasm-unsafe-eval'` for
  CanvasKit), but it must let the app connect to **any** `http(s)` server,
  because you choose your own Mozhi instances and AI providers, including
  ones on your LAN. Inline styles are allowed because the Flutter engine
  needs them. A `<meta>` policy can't set `frame-ancestors`: if you host
  the web app, send `Content-Security-Policy: frame-ancestors 'none'` (or
  `X-Frame-Options: DENY`) as an HTTP header to stop other sites framing
  it. Debug web runs (`flutter run` in debug mode) are blocked by the
  policy; see [Contributing](contributing.md).
- Android release builds made without a signing key (forks, local builds)
  are signed with the debug key. Official releases must use the release
  key.
