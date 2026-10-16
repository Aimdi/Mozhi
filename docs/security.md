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
| **Your text**, translations and history | Servers you didn't choose, logs, cloud backup |
| **Your bill** with paid providers | Other apps or web pages starting requests without you |
| **Your local network** | Websites using the app to reach devices on your LAN |
| **What the AI writes back** | Prompt injection through the text you translate, links and model output |

Out of scope: a rooted device, malware that already controls
the device or the user's account, and the servers you configure. The
operator of a Mozhi instance or an AI provider sees the text you send it;
pick ones you trust, or self-host them ([guide](self-hosting-mozhi.md)).

## API keys

- Stored only in secure storage (Android Keystore-backed encrypted
  preferences; in the web app, the browser's session storage, see below),
  never in the settings, exports or history.
- **Android:** cloud backup is off (`allowBackup="false"`). The backup and
  device-transfer rules also exclude the secure storage files, so keys stay
  on the phone.
- **Web app:** keys are kept in session storage, so they last only as long
  as the browser tab. Host the web app on its own origin (its own domain or
  subdomain); any page on the same origin can read the browser's storage.
- If secure storage doesn't work, keys are kept in memory only and the app
  says so; they are never written to plain storage instead.
- Keys are sent only in the provider's auth header, never in URLs. Error
  messages and server responses shown in the app have keys removed. Error
  descriptions (`toString`) leave out credentials and query strings in URLs.
- Debug builds log only bloc and state **type names**, never state contents
  (which hold your text and, while onboarding, the key you are typing).
  Release builds don't log app data.

## Network

- **HTTPS by default.** Addresses typed without a scheme get `https://`,
  except local ones (`localhost`, private IP ranges, `.local`, `.lan`, bare
  host names), which get `http://` because self-hosted servers on a LAN
  usually have no certificate.
- **Plain HTTP is allowed** (self-hosted servers), but the AI provider
  editor, Settings > Mozhi instances and first-run setup warn about a
  non-local `http://` address and ask you to confirm before saving a key
  for it or adding the instance.
  Prefer HTTPS, a VPN or Tailscale for servers outside your home network.
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
  may already have received it.

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
- Downloads are capped at 2 MiB and 25 seconds.
- `mozhi://web?url=…` and `/web?url=…` links only fill in the address; the
  page is loaded when you press the button.

## Text from other apps and links

Shared text, "Translate with Mozhi" in the text selection menu, the Quick
Settings tile, launcher shortcuts and widget, and links (`mozhi://…`,
`/translate?text=…`) are untrusted input:

- Text is capped at 5,000 characters, and the same text arriving again
  within two seconds is ignored.
- It never starts a **paid AI request** on its own unless you turned on
  **Instant translate with AI**. Free engines (Mozhi, offline) may translate
  it right away.
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
- Model output is shown as plain text (with bold, italics and code at most):
  no links, HTML, images or scripts are rendered.

Prompt injection can't be ruled out completely: a hostile text can still
make a model produce a wrong or misleading "translation". Check important
translations, for example with **Check meaning**.

## Other measures

- Photos sent to AI providers are re-encoded first, which removes EXIF data
  such as GPS location.
- Imported history is capped like the history itself.
- No analytics, telemetry or crash reporting libraries. ML Kit (offline
  translation, text recognition) is the only bundled library that sends
  usage metrics to its vendor; see [Privacy](privacy.md#google-ml-kit).
- Third-party licences, including ML Kit and native libraries, are listed
  under **Settings > About > Licences**.
- **Release builds:** Android APKs and the app bundle are built with
  `--obfuscate --split-debug-info`; the debug symbols are kept as a private
  workflow artifact (90 days), not attached to the public release.
- **CI supply chain:** third-party GitHub Actions and reusable workflows are
  pinned to full commit SHAs (with the version in a comment, which
  Dependabot updates), so a moved tag can't change what runs in CI.

## Known limitations

- Android's "translate clipboard" entry point (Quick Settings tile,
  home-screen widget, launcher shortcut) goes through a non-exported
  component, so other apps can no longer make Mozhi read the clipboard;
  the same request sent to Mozhi's main screen only opens the app. The app
  that hosts the widget (your launcher) can still press the widget's
  Translate clipboard button, like any widget button. Clipboard text is
  then handled like shared text: capped, no paid AI request on its own,
  but translated by a free engine and saved to history if those are on.
- Plain `http://` Mozhi instances outside your network can still be added
  (in Settings and in first-run setup): Mozhi shows a warning and asks you
  to confirm first, because your text then travels unencrypted. Instances
  on this device or your local network (`localhost`, private IP addresses,
  `.local`/`.lan` names and similar) are added without a warning. Instances
  added before this check are not re-checked.
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
