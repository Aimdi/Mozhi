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
| **Your text**, translations and history | Servers you didn't choose, logs, cloud backup and device transfer, screenshots, keyboards and clipboard managers, someone holding your unlocked phone (with the app lock on) |
| **Your bill** with paid providers | Other apps or web pages starting requests without you |
| **Your local network** | Websites using the app to reach devices on your LAN |
| A **shared conversation** (Android) | Other devices on the same Wi-Fi, people who see or guess the link, web pages in a guest's browser, guests flooding the phone |
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
  exports or history, and in an encrypted backup only when the user
  includes them (see below). Settings written by older versions that
  still held headers or instance passwords are moved there on the next
  start, and the plain copy is removed. The cached engine lists are stored under the
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
- **Encrypted backups** (`.mozhibackup`, [Backup](backup.md)): the key is
  Argon2id of the passphrase in Unicode NFC (composed accents; files from
  before 0.1.0-rc.6, keyed with the passphrase as typed, are opened by
  trying that too when it differs: one more Argon2id, no weaker key; a
  sync file opened that way is written again once with the NFC key and a
  new salt, so sync doesn't keep the as-typed key)
  (64 MiB, 3 passes, 1 lane on Android; 19 MiB,
  2 passes in the web app, where it runs as JavaScript) with a random
  16-byte salt per file; the data is gzip'd JSON under AES-256-GCM with a
  random 96-bit nonce, and the whole readable header (magic, format,
  Argon2id parameters, salt, nonce, date, app version) is bound in as
  associated data, so any change fails like a wrong passphrase (one error
  for both, nothing restored). Neither the passphrase nor the key is ever
  stored; only the date of the last backup is. API keys and passwords are
  only included when the user turns that on, with a warning, and go back
  to secure storage on restore. Reading is bounded (file 64 MiB, header
  4 KiB, Argon2id at most 128 MiB, 8 passes, 4 lanes and 128 MiB × 4
  passes of work, under three times the Android parameters, since it runs
  before the passphrase can be checked; decompressed data 128 MiB) so a
  crafted file can't exhaust the device, and newer formats or unknown
  parts are refused or left out. No restore moves this device's keys to
  another server: a provider's key and headers only carry over (Replace
  keeping this device's, Merge filling in the backup's) between providers
  of the same id on the same server (service, provider type and
  normalised base URL). Merge adds nothing that gets text by itself: it
  never adds Mozhi instances (the failover would send text to them
  without asking), and providers it adds are used only once chosen
  (consents and engine choices left for their id are dropped, and those
  that need no consent of their own, on a private network or
  LibreTranslate, come turned off). A provider id never moves to another
  server: Merge doesn't add back a provider removed on this device
  (remembered by id and a hash of its server), and adds one on another
  server than this device's provider, or removed provider, of that id
  under an id of its own. Replace
  takes the backup's providers and instances, as the user chose; the
  review and the result list every provider and instance a restore adds,
  by host. Custom headers can't replace the key's auth header
  (`Authorization`, `x-api-key`, `x-goog-api-key`), which is sent last.
  Threat: whoever gets the file can guess passphrases offline; the
  strength hint (length and word count, computed on the device) asks for
  four or more random words, and at least 8 characters are required.
- **Sync** ([Sync](sync.md)): the sync file on the user's WebDAV server is
  a `.mozhibackup` (above) written with a key derived once from the sync
  passphrase (Argon2id with the salt and parameters of the file's header,
  so every device derives the same key) and kept in secure storage with
  the app password; the passphrase itself is never stored. Each write has
  a fresh nonce. A file encrypted with another key, one that fails the GCM
  check, or one from a newer format or section version is never merged and
  never overwritten; sections a device doesn't sync are written back
  untouched. Writes are conditional (`If-Match` with the ETag read, or
  `If-None-Match: *` for the first file), so two devices can't silently
  overwrite each other on servers that honour them. Secrets travel only
  with the settings and an explicit opt-in. Threat: the server's operator
  (or whoever gets its disks or backups) can copy the file and guess
  passphrases offline, and sees its size, its change times and the
  readable header; **Delete all local data** forgets the setup and key
  before anything else is deleted, so the deletion never syncs.
- **Deletion records:** to merge copies of the history (backups, sync), a
  deleted entry leaves its id and deletion time (never its text) for 180
  days, at most 10,000, encrypted like the history (AES-256-GCM, its own
  associated data) and removed by **Delete all local data**. Deleted
  presets and glossaries leave the same (id and time only), unencrypted
  like the presets and glossaries themselves.
- **Incognito** stops saving new translations to the history and asks
  keyboards not to learn what you type.
- **Screenshots:** **Hide content in recents & block screenshots** sets
  `FLAG_SECURE`, which also blocks screen recording and sharing.
- **App lock** (Android, off by default): protects against someone who
  holds your phone while it is unlocked, or picks it up later. While Mozhi
  is locked its screens are hidden: before the first unlock after a start
  none is built; after that they stay in memory so running work goes on,
  but under the lock screen they are `Offstage` (nothing painted, no hit
  testing, left out of the accessibility tree), their animations stop and
  they can't take keyboard focus (a focused field loses it, which closes
  the on-screen keyboard); messages they show don't appear on the lock
  screen. So there is no history, phrasebook, conversation, setting or key
  to see, read aloud, type into or tap. Locking also drops from memory
  what can be dropped:
  - **Translate:** the cache of recent translations is dropped. The text
    you typed and its translation stay, hidden (not drawn, not in the
    accessibility tree): dropping the translation would mean translating
    it again after the unlock, which sends your text to an online engine
    once more without you asking.
  - **History:** its decrypted entries leave memory (the cubit's list and
    the repository's copy); the encrypted history stays on disk and is
    read again after the unlock. At a start with the lock on it isn't
    read (decrypted) at all until the first unlock; the retention clean-up
    waits for the unlock too. What is saved while locked (a running
    Transcribe, a document) is written to disk without coming back into
    memory.
  - **Conversation:** kept, hidden like the translate screen: leaving the
    app for a moment must not end a conversation, and guests of a shared
    one keep seeing it. It is never stored; **Clear** removes it.
  - **Kept, hidden:** work that runs or that you would lose: a running
    Transcribe or live captions transcript, a document or image being
    translated, the dictionary, the phrasebook and the settings screens.
  Dropping means the app lets go of the text; Dart does not overwrite
  freed memory, so this narrows what a memory dump would find but is not
  erasure. Text shared to the app, the
  clipboard actions and `mozhi://` links (also shared files and the
  widget's buttons) wait for the unlock before they fill anything in,
  open a screen, translate or are saved; the clipboard is only read then,
  except by the translate bubble's press and hold: Android lets only the
  window in front read the clipboard, so that invisible window reads it at
  once (also while Mozhi is locked) and hands it to the quick translate
  window, which shows it only after the unlock. The quick translate and
  Translate screen windows ask to unlock first
  (they would otherwise show your languages and spend your AI providers'
  credit), and Recents shows no preview while the lock is on. Unlocking uses Android's
  system prompt (framework `BiometricPrompt` with `BIOMETRIC_STRONG` or the
  device credential on Android 11+, the device credential allowed on 10,
  the screen lock's own screen as fallback on 9 and as the only way on 7
  and 8; no third-party library); the app only learns whether it
  succeeded. On Android 11+ only a strong (Class 3) fingerprint or face
  unlocks Mozhi, or the screen lock: a "weak" (Class 2) face unlock,
  which many phones accept on their own lock screen, offers the PIN,
  pattern or password instead. On Android 10 the system picks which
  biometrics the prompt accepts. Turning it on needs one successful unlock, so a setting can't
  lock the owner out; without a secure screen lock on the phone it can't
  be turned on, and it stops locking if the screen lock is removed (that
  needs the phone's PIN anyway). Away time is measured by the platform
  with `SystemClock.elapsedRealtime` (monotonic, counts deep sleep), the
  same for every window of the app process; changing the clock changes
  nothing, and a new app process always starts locked. Trips that Mozhi
  starts for a result to pick, take or save something get at least 5
  minutes: a file, folder or photo picker (`ACTION_OPEN_DOCUMENT`,
  `ACTION_OPEN_DOCUMENT_TREE`, `ACTION_GET_CONTENT`, `ACTION_PICK`, the
  photo picker's `ACTION_PICK_IMAGES` and its androidx and Play services
  fallbacks), saving a file (`ACTION_CREATE_DOCUMENT`) and the camera
  (`ACTION_IMAGE_CAPTURE`), each also inside a chooser
  (`ACTION_CHOOSER`'s `EXTRA_INTENT`), and Translate screen's
  screen-capture consent. Anything else Mozhi opens, also for a result,
  is an ordinary absence: above all the share sheet (a chooser of
  `ACTION_SEND` or `ACTION_SEND_MULTIPLE`), which hands the text to another
  app, so with **Immediately** Mozhi is locked when you come back from a
  share; so are Android's settings (**Display over other apps**). The
  setting is device-only: backups, sync and Phone to phone leave it out,
  and a restore keeps this device's value.
  **What it doesn't do:** it is not encryption. The data stays encrypted
  as before (history, phrasebook and practice with their Keystore-wrapped
  keys, secrets in secure storage), not with a key that needs the unlock,
  so it doesn't protect against someone who can read the app's storage (a
  rooted phone, a forensic tool on an unlocked device) or against malware;
  and while locked, what the screens keep (above) is in memory as when
  unlocked. The home-screen widget shows no translations anyway.
  **Live captions** keep running while Mozhi is locked (they are for
  watching other apps), into the transcript behind the lock, but the
  caption bar shows only **Mozhi is locked**: the app sends it no caption
  text, and the bar itself ignores captions while the lock is engaged
  (the platform side learns of it with `setUnlocked`). When the phone
  locks the bar clears its text, and once the phone is unlocked the app
  lock checks the time away first (its timer doesn't count deep sleep)
  before a caption shows again.
  The **Live captions** Quick Settings tile stops running captions, or
  opens the captions screen with a start request
  (`mozhi://transcribe/captions?start=<token>`): on a locked phone the
  screen lock comes first, for stopping as for starting; a start then
  goes through Mozhi's app lock, the microphone permission and Android's
  capture dialog, as with **Start captions**. The token is random (32
  bytes from `SecureRandom`), made for each tap and kept only in the
  app's process; the screen starts the captions only after the platform
  side confirmed it is the tile's latest token, which uses it up
  (`consumeStartToken`). The main activity is exported, so another app
  can send the same link, but with any other `start` value it only opens
  the captions screen: nothing starts and no dialog opens.
- **Clipboard:** on Android 13+ copies are marked sensitive
  (`EXTRA_IS_SENSITIVE`), so the system's preview and keyboard suggestions
  don't show them.
- **Delete all local data** removes the sync setup with its key first, then
  the history and its key, the settings with their secrets, every other preference, the offline models folder and
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
  the Mozhi, LibreTranslate, DeepL and AI clients and of the downloads,
  redirects included), and
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
  `.i2p` addresses are refused before a DNS lookup. A connection given up
  during the TLS handshake through the tunnel (a server that never answers
  TLS, the timeout passed or the request cancelled) is closed at once:
  `dart:io` can't close a `Socket` once TLS has taken it over, so the
  tunnel (`lib/core/network/http_proxy_tunnel.dart`) is opened on a
  `RawSocket` that it closes itself until the handshake is done, and wraps
  the resulting `RawSecureSocket` as the `SecureSocket` the HTTP client
  uses.
- **Tailscale names** (`*.ts.net`) are not private by name: a Tailscale
  Funnel name resolves to Tailscale's public relays, which anyone on the
  internet reaches, and once Tailscale is off the network's own resolver
  answers for `ts.net` with whatever address it likes. A `.ts.net` host
  counts as private (direct connection around the proxy, plain `http`
  allowed, shown and asked about as your own server) only while all of
  this holds (`TailnetResolver`, `lib/core/network/tailnet_resolver.dart`):

  - **The phone is on its tailnet.** It has a Tailscale interface: an
    address in `fd7a:115c:a1e0::/48` (Tailscale's own IPv6 range, which
    carriers don't use; on Android Tailscale's interface is a `tun`), or
    an interface named `tailscale…` with an address in `100.64.0.0/10`. A
    `100.64.0.0/10` address on any other interface doesn't count: that is
    also the range mobile carriers use for CGNAT. This is checked again
    for every request, the answer reused for at most 2 seconds. Without a
    Tailscale interface no `.ts.net` name is looked up for this check and
    every one is public (a request resolves it like any public name, or
    the proxy does); whenever the phone's Tailscale addresses change (Tailscale
    turned on or off, another tailnet) every earlier answer is forgotten.
  - **A recent lookup returned only Tailscale's addresses**
    (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`). An answer is used for 60
    seconds, then the name is looked up again before the next request; a
    failed or slow (over 5 seconds) lookup, or any other answer, makes the
    name public.

  The lookups run before every backend request and in the connection
  factory of every connection, and for the configured servers at start.
  The connection then goes to **the very address that was checked**
  instead of resolving the name a second time (an `fd7a:` address first
  when the phone has one): with a connection factory, `dart:io` uses the
  socket the app returns as it is and adds no TLS of its own, so for
  `https` the app opens the connection to that address and runs TLS with
  the name itself (SNI and the certificate check use the name, never the
  address); the `Host` header always carries the name. A private name
  without a checked address fails to connect rather than being resolved.
  The lookup uses the system's resolver (Tailscale's MagicDNS while
  Tailscale is on), not the proxy, which therefore learns the name (as it
  would without a proxy). A redirect from a public server to any `.ts.net`
  name is refused without a lookup. Settings accept `http://` for a
  `.ts.net` name that wasn't looked up yet (it may be on the tailnet); its
  requests are refused unless it is. The web app does no lookups (a
  browser can't see the interfaces or resolve names): there every
  `.ts.net` name is public. **Offline only** looks nothing up.

  What remains: the interface check is a few seconds old at most, so a
  request in the seconds right after Tailscale is turned off may still be
  sent directly (and over plain `http`, if the server uses it) to the
  checked `100.64.0.0/10` or `fd7a:` address, which the network then routes,
  a hostile network included. A connection to the checked address that is
  kept open (idle connections stay open for 90 seconds) may be reused after
  a later check found Tailscale off; for plain `http` the network policy
  refuses the request first, so only `https` connections, whose certificate
  was checked for the name, are reused that way. The translation screen and
  the consent prompts use the last answer, so text may be sent without the
  consent a public server needs when, between two lookups, a name stopped
  leading to the tailnet; the request itself is then checked again (`https`
  only, through the proxy when there is one, the certificate checked for the
  name). A tailnet answer is trusted only because the phone has a Tailscale
  interface: while Tailscale is on, its client routes `100.64.0.0/10` and
  `fd7a:115c:a1e0::/48` into its tunnel, so the checked address leads into
  your tailnet even when a resolver other than MagicDNS gave it. A server
  entered by its `100.64.0.0/10` address rather than a name is treated as
  your network without these checks.
- **Headers:** requests carry `User-Agent: Mozhi`, no cookies and no
  `Referer`; the web app's page sets `referrer` to `no-referrer`.
- **Certificates:** the app never disables certificate checks. Release
  builds on Android trust only the system certificate authorities; CAs
  installed by the user (or by malware or device management) are trusted in
  debug builds only, for traffic inspection during development.
- **Redirects:** AI, DeepL and LibreTranslate requests never follow
  redirects (a redirect would otherwise carry headers such as `x-api-key`
  to another host); a moved API shows an error asking you to update the
  address. Mozhi requests follow at most three redirects, only on the same
  server (same scheme, host and port, or `http` upgraded to `https` on
  that host): a redirect to another server is an error naming it, so your
  text never goes to a host you didn't add as an instance. Downloads
  (offline models, dictionaries) follow at most five redirects, to other
  public `https` servers too (download sites hand files to their CDNs),
  and the network policy checks every hop: never from `https` to `http`,
  and never from a public server to this device, your local network, a
  Tailscale `.ts.net` name or a `.onion` or `.i2p` address (which would
  also go around the proxy).
- **WebDAV sync** uses HTTP Basic authentication, so it follows the same
  rule: `https`, or plain `http` only to this device, the local network
  and `.onion`. It never follows a redirect (the `Authorization` header
  would go along) and reads at most 64 MiB per answer. Its XML parser
  expands no entities but the five predefined ones and fetches nothing.
  Requests go through the session's client (proxy, network policy) and are
  listed as **Encrypted sync** in the network activity.
- **Timeouts and size limits** on every request. Mozhi failover does not
  resend your text to another instance after a timeout, when the first one
  may already have received it. A connection that can't be set up in time
  (also through the proxy) carried nothing yet, so it fails over.
- **Server health** (`InstanceHealth`,
  `packages/translation_repository/lib/src/repository/instance_health.dart`):
  a Mozhi server where a translation (text or photo) failed in a way that
  is failed over (see `MozhiPool.canFailOver`) is asked last for 12 hours.
  It only changes the order within your own list, so text never reaches a
  server that the failover could not have sent it to. Timeouts of
  requests that carry text don't count (counting them would send a retry
  of the same text to a second operator), and neither do input errors,
  cancelled requests, the engine and language lists, read-aloud or
  language detection (`recordHealth: false`). Only a failure the server
  answered with (`MozhiPool.answeredBy`: an HTTP status, or
  `InstanceDoesNotTranslateException`) is stored; a transport failure
  (no status: often the device's own connection) cools the server down
  in memory for the session only, so a phone that was briefly offline
  can't push your own first server behind a public one across restarts.
  **Make preferred**, **Switch instance** and **Try next instance**
  (`TranslationRepository.preferInstance`) forget the chosen server's
  failure and start there, also when it is first in the list already.
  Nothing is sent to test a server. The record is the address (no user
  info, query or fragment) and a time, at most 64 entries, in the app
  preferences under `mozhi.instanceHealth.v1`; it is read with a size cap
  and parsed defensively, never synced or backed up, and cleared by
  **Delete all local data**. A corrupt or hostile entry can at worst
  change which server of your list is asked first.
- **One-request consent** (**Once**, `TranslationRepository.allowOnce`,
  two-minute lifetime): on the Translate screen it belongs to the retry of
  the translation that asked (`TranslateCubit.retryAfterConsent`). When
  that retry ends or is cancelled (more typing, Stop, another
  translation) without using it, for example because the on-device
  engine tried first in Offline first now has the language, it is
  withdrawn (`revokeOnce`), so a later text with the same language pair
  (often "Detect language" into the same target) is asked about again
  instead of going to Google on the leftover approval. A prompt whose
  pair the device can now translate goes away once the language is
  downloaded.

## Shared conversation

**Share on this network** (Conversation tab, Android only;
`lib/conversation/share/`) runs a `dart:io` HTTP server while you share.
Threat model: the page travels as plain `http` over the local network, so
**anyone on the same network who can capture traffic can read the
conversation, the link and the PIN**, and could join, or act as a guest
whose key and device cookie they captured; we don't try to hide that, the
sharing page says so, and the hotspot (a network only your guests are on)
is the recommended way. What we do protect against:

- **Reach:** the server listens only on the phone's private IPv4 address
  (10/8, 172.16/12, 192.168/16, Wi-Fi first; not mobile data, VPN or CGNAT
  interfaces), on a random port, and refuses connections from any address
  that isn't private. It runs only while the conversation (or its sharing
  page) is on screen and stops 2 minutes after the app goes to the
  background, or at **Stop sharing**.
- **Guessing the link:** the path holds a 128-bit random token
  (`Random.secure`); a wrong token is a plain 404, compared in constant
  time. With the PIN (on by default), joining also needs 4 random digits:
  5 wrong PINs a minute per device and 10 per address, and after 20 wrong
  PINs in all nobody new can join until a new PIN is set. Each guest gets
  its own 128-bit key for its requests.
- **Web pages in a guest's browser** (CSRF, DNS rebinding): requests must
  carry the server's own address in `Host` (a rebound name is refused), and
  every change is a JSON `POST` with the guest's key in custom headers,
  which a cross-site page can't send without a CORS preflight the server
  never answers; an `Origin` other than the page's own is refused.
- **The page itself:** one self-contained page (HTML, CSS and JS shipped
  in the app), served with `Content-Security-Policy: default-src 'none';
  script-src 'self'; style-src 'self'; connect-src 'self'` (no inline
  script, nothing from other hosts, no framing), `nosniff`,
  `no-referrer`, `no-store` and one cookie, the device token (below:
  `HttpOnly`, `SameSite=Strict`, only for the link's path, gone when the
  browser closes; not a credential). It only ever sets
  `textContent`, so nothing the host or a guest types becomes markup;
  the configuration it embeds escapes `<`.
- **Telling guests apart:** each browser gets a random 128-bit device
  token in a cookie with its first answer, and the limits below count per
  device, so guests behind one router (one address) don't share them; the
  per-address limits are a few devices' worth on top. A request without a
  token the phone issued (none, or a made-up one) is a new device with a
  new token, at most 20 new devices a minute per address and 100 in all;
  beyond that such requests count as one device for their address. So
  someone who throws the cookie away, or keeps changing addresses, is
  still held back by the per-address and room-wide limits, and leaving and
  joining again from one browser doesn't reset a device's limits.
- **Flooding:** at most 8 guests, 20 joins a minute in all (10 per device
  and 30 per address), one update stream per guest; at most 64 open
  connections (16 per address; more are closed as soon as they open),
  idle ones closed after 10 seconds; 120 requests a minute per device and
  480 per address; request bodies of 4 KiB that must arrive within 10
  seconds; replies of 500 characters, one every 2 seconds and 12 a minute
  per device and 20 a minute from all guests together, language changes
  10 a minute per device and 30 in all; guests whose page is gone for 45
  seconds are removed. An update stream holds at most one snapshot: while a page
  hasn't taken in the last one, changes wait and go out as one, and a
  page that takes in nothing for 20 seconds is disconnected (it connects
  again by itself), so a guest that stops reading can't make the phone
  hold more and more data.
- **Your engine's bill:** guests can't make your engine translate more
  than they read: only the last 100 messages, only into languages a guest
  reads now (when a language's last guest leaves or switches, its queued
  and running translations stop at once; the finished ones stay for 5
  minutes, so coming back or switching back and forth costs nothing
  more), and at most 4 languages besides the conversation's two at a
  time (a guest asking for a fifth is told which ones they can pick; a
  language keeps its place for those 5 minutes). The sharing page lists
  every language being translated and how many messages are still to
  go.
- **Your privacy settings:** translations into the guests' languages only
  use an engine your settings allow without asking (or the offline
  engine); anything else waits for your OK on the sharing page (see
  [Privacy](privacy.md#shared-conversation)), one language pair at a
  time. What a **Once** there would still let through after its messages
  were sent (or dropped, e.g. when the guest left) is withdrawn, so it
  can't let a later, unrelated translation through without asking.

## Phone to phone

**Phone to phone** (Settings > Backup & sync, Android only; `lib/pairing/`,
[protocol](pairing.md#protocol)) sends your data or offline models from one
phone to the other over the local network. Threat model: someone on the
same network who can watch, change or redirect traffic; other devices
probing the open port; and the other phone itself, which may be modified
or malicious. What protects you:

- **End-to-end encryption:** fresh X25519 keys for every connection,
  HKDF-SHA256 with the code's 64-bit one-time secret mixed in, and
  AES-256-GCM frames numbered per direction, so a changed, replayed,
  dropped or reordered frame ends the transfer. Someone who didn't see the
  code learns nothing and can't connect: the sending phone proves it knows
  the secret in its first encrypted frame, before the receiver sends
  anything but its public key. Only a frame that fails to decrypt counts
  as a wrong code: three from one address shut that address out, 30 in
  all burn the code. So one device can neither guess the secret nor burn
  the code for everyone, and timeouts or garbage, which prove nothing,
  count for nothing. Encrypting, decrypting, compressing and hashing run
  on a background isolate, so a long transfer doesn't freeze the screen.
- **Someone in the middle** who did see the code (over your shoulder)
  shows up in the six-digit number both phones display: the sender commits
  to its key before it sees the receiver's, so they get one try in a
  million to make the numbers match. Compare them: both phones ask, and
  the receiving phone can't accept anything until you say they match.
- **A malicious sending phone** can't plant files: the receiver asks only
  for files its own bundled catalogue lists, checks each file's size and
  SHA-256 (and SHA-1 for speech models) while it arrives and installs only
  through each manager's import path, which checks again; file names come
  from the receiver's catalogue, never from the sender, and nothing is
  run. File data may come compressed (only to a phone that says it takes
  it): each frame is inflated on its own and refused once it would grow
  past 256 KiB, before its size and hashes are checked, so a
  decompression bomb gets nowhere. A backup goes through the normal restore (64 MiB at most, newer
  formats refused), limited to the sections the offer listed, which are
  the ones you see; a backup holding any other section, or API keys and
  passwords the offer didn't announce, is refused whole. It stays in
  memory (never in storage) and is parsed off the UI thread. You see the
  list first and accept or decline.
- **A malicious receiving phone** gets only what you chose to send; the
  sender reads only the files it offered, whatever is asked for.
- **Reach and limits:** the receiver listens only on its private IPv4
  address, for one connection and five minutes, and closes connections
  from any other address; the sender only connects to private addresses
  (a `mozhi://pair` link only fills in the code). Eight connections may
  set up at once (two per address), so a device that connects and stalls
  can't keep the real phone out; a newer one pushes out the oldest only
  after it had 2 seconds, so a flood from many addresses can't push out a
  phone in the middle of its key agreement (which takes well under a
  second). At most 6 key agreements are started a minute per address and
  30 in all for addresses that started one in that minute already;
  connections beyond that are closed at once and counted nowhere, so a
  flood makes the phone do little work (one key agreement per address and
  minute beyond the 30). An address's first connection in a minute is
  always taken on, so a few addresses can't use up the minute for the
  real phone. Every frame's length is checked before
  it is read (256 KiB at most), with one deadline for the key agreement
  and `hello` (10 seconds in all), timeouts between frames (30 seconds)
  and for the people deciding (10 minutes).
- **What it doesn't hide:** the phones' addresses and the port (they are in
  the code), and the sizes and timing of what goes across (with
  compression, sizes also hint at how well each 64 KiB piece compressed).
  Someone with the code can still connect first: the real sender is then
  turned away and has no number to show, so the receiving phone's
  question gets a no (make a new code). Devices that keep opening
  connections from many addresses can hold pairing back while they do, by
  keeping every place taken (the sending phone tries again after 1, 2, 4
  and 8 seconds, then every 10 seconds, for as long as the code works or
  until you cancel, when it is turned away before the key agreement; a
  wrong code stops it at once); once they stop, pairing works again
  within a minute.
  Anyone who floods or jams the network can delay it too.

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

## Documents and e-books

Office documents and e-books are ZIP packages of XML files, and they come
from anywhere, so they are read defensively (on the device, before anything
is translated):

- **Size limits:** at most 25 MB per file and 10,000 entries. Only the XML
  parts with text are unpacked: each at most 32 MB, at most 128 MB
  together, and a part over 1 MB that compresses better than 500:1 is
  refused (decompression bombs). Unpacking never goes past the size an
  entry declares. Images, fonts, embedded files and macros are never
  unpacked: they are copied into the translated file exactly as they were
  stored.
- **The ZIP directory is checked first,** byte by byte, before the ZIP
  library decodes anything: the entry count, the sizes entries declare
  (at most 2 GB together, and at most 500 times the size of the file),
  and where each entry lies. Entries outside the file are refused as
  damaged; entries that overlap each other or the directory are refused
  (copied entries would repeat the same bytes on every save, turning a
  small file into a huge one), and so are symbolic links (the library
  would unpack them while decoding, before any limit applies).
- **Macros are kept, never run:** Word, PowerPoint and Excel files with
  macros (VBA projects), ActiveX controls or Excel 4 macro sheets, and
  OpenDocument files with Basic or script libraries, are accepted under
  their usual extensions, as they are the user's own files. Their macros
  are neither unpacked nor translated: the translated file keeps them
  byte for byte, and the documents page says so.
- **No entities, no fetching:** XML parts with a document type declaration
  are refused (office files never have one; e-books may name the XHTML
  doctype, but never with an internal subset that could declare entities).
  Only XML's five built-in entities, character references and, in e-books,
  HTML's named characters are decoded; nothing is ever downloaded, and
  external references are kept as text.
- **Well-formed only:** malformed XML, mismatched tags, more than one root
  element and elements nested more than 256 deep are refused.
- **No paths out of the package:** entry names that are absolute, contain
  `..`, `.` or empty segments, backslashes, drive letters or control
  characters, and duplicate names, are refused (the translated file is
  never extracted anywhere, but other apps may).
- **Encrypted files are refused, not cracked:** password-protected Office
  files (which are not ZIP packages), encrypted ZIP entries, OpenDocument
  files with encryption data and e-books with DRM. Old binary `.doc`,
  `.xls` and `.ppt` files are refused as damaged.
- **The output stays well-formed:** translations are escaped, characters
  XML cannot hold are dropped, and formatting placeholders are turned back
  into balanced elements whatever order an engine returns them in; fields,
  bookmarks and comment ranges keep their original order. On Android,
  large files are read and written in a background isolate, so a hostile
  file can't freeze the screen.

### PDF documents

PDFs (Android only) are parsed by Android's own PDF renderer, the framework's
`PdfRenderer` (pdfium, updated with the system), not by code in the app:

- **Limits on both sides:** at most 25 MB and 200 pages, checked by the app
  and again by the platform code (`PdfPagesPlugin.kt`). A page is rendered
  with at most 8 megapixels (300 dpi at most); page sizes and every
  rendered image are checked before they are used, and running out of
  memory is reported as a file too large instead of crashing.
- **Only the app's own copy is opened:** the platform side reads and writes
  files only inside the app's private cache (canonical paths; anything
  else is refused), opens the copy read-only and deletes it as soon as it
  is open.
- **Password-protected PDFs are refused, not cracked** (the renderer's
  `SecurityException`); damaged ones are reported as damaged.
- **One document, one thread:** every call runs in order on one background
  thread, so one document is open at a time and the screen never waits for
  a page. A failed open closes the document, pages and bitmaps are released
  whatever happens, and the document is closed when it is removed, when
  the screen closes and when the engine goes.
- **Nothing in a PDF runs or is fetched:** pages are drawn to pixels;
  scripts, forms, links, attachments and embedded files are never run,
  followed or extracted. Only pixels reach the app, only the text
  recognised in them reaches the translation engine.
- **The translated PDF** is written with the framework's `PdfDocument` (the
  original pages as pictures, the translations as text); the pages, boxes,
  colours and texts the app sends for it are checked and kept on the page.

### Localisation files and web pages

HTML, XLIFF, Android strings, PO, CSV/TSV, `.strings` and `.xcstrings`
files are text, read on the device with the same care:

- **No entities, no fetching:** XLIFF and Android strings are checked with
  an XML parser that never reads a DTD or an external entity; a document
  type declaration that declares entities is refused outright, so nothing
  can expand (billion laughs) or point at a file or URL. Only XML's five
  built-in entities and character references are decoded (in HTML, HTML's
  named characters); unknown references are kept as they are.
- **Size and nesting limits:** documents over 16 million characters (text
  files are limited to 2 MB anyway), XML nested more than 256 levels and
  JSON (`.xcstrings`) nested more than 64 levels are refused with a message
  instead of exhausting memory or the stack. Malformed XML, PO, `.strings`,
  CSV (an unclosed quote) or JSON is refused, never half-read.
- **Linear time on hostile input:** HTML is read the forgiving way browsers
  do, but without ever reading the same text twice (a tag cut off by the
  end of the file ends the markup, as in a browser). The patterns that
  find placeholders, tags, values and formats (also when pasted text is
  recognised) never have two repetitions that can match the same text
  next to each other, CSV cells are only compared with the value patterns
  up to 256 characters, and text is never copied over and over while a
  document is put together, so a file of crafted cells, comments or runs
  of spaces is read in linear time and can't freeze the screen (tests
  check 200,000-character inputs of each kind). On Android, text
  documents from 64,000 characters on, and office files from 64 KB on,
  are read in a background isolate.
- **No formulas from translations (CSV and TSV):** a translated cell that a
  spreadsheet would run as a formula or a DDE call (it starts with `=`,
  `+`, `-`, `@`, a tab or a carriage return, after leading spaces) gets a
  `'` in front, as OWASP advises against CSV injection, so an engine
  (say, a prompt-injected AI) can't plant `=HYPERLINK(…)` or
  `=WEBSERVICE(…)` to leak other cells. A cell whose original already
  starts that way is the file's own and is left as it is; formulas of the
  original are never translated.
- **The output stays valid:** translations are escaped for the format,
  inline tags are put back into balanced elements whatever order an engine
  returns them in, and markup the engine never saw (scripts, styles,
  comments, attributes) is copied unchanged, so a translation can't inject
  markup or break the file.

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
- A `mozhi://` link opens the screen its host names. Dart's `Uri` reads
  `\` as `/`, decodes `%2e` and resolves `.` and `..`, so a path could
  otherwise climb to another screen
  (`mozhi://translate/..\transcribe/captions`): the main activity opens
  `/` instead for a link whose host isn't a plain name or whose path has
  a backslash, a `.` or `..` segment, or a percent-encoded dot, slash or
  backslash (`%2e`, `%2f`, `%5c`, any case). The router, for a
  `mozhi://` link that reaches it unchanged, opens `/` for a host the
  manifest's link filter doesn't list and drops dot segments and
  segments with a slash or backslash. Explicit intents to the exported
  main activity can still name any screen, so what a screen does on
  arrival is limited as listed here (the live captions start request
  needs the tile's token, see App lock).
- Replacing the selected text in the other app (PROCESS_TEXT) needs a tap
  on **Replace**, and Android only accepts the answer for a writable
  selection request that is still current.
- Exported Android components: the main activity (launcher, share,
  PROCESS_TEXT, `mozhi://` links) and the Quick Settings tiles (bound only
  by the system). The home-screen widget receiver is not exported, and its
  buttons use immutable pending intents. The Translate screen window, its
  capture service, the bubble and its clipboard window (see below) are not
  exported either: other apps can't start a screen capture or the bubble.

## Translate screen (Android)

Translate screen captures whatever another app shows, so it is built to
capture only on purpose and to keep nothing:

- **Consent every time.** The capture needs Android's own screen-capture
  dialog (`MediaProjectionManager.createScreenCaptureIntent`, for the whole
  display on Android 14+), every time; the result can't be reused. The
  window, the capture service and the bubble are not exported, so only the
  user (the tile, the app shortcut, the bubble) can start it. On a locked
  phone the tile asks to unlock the phone first.
- **One frame.** A foreground service of the type `mediaProjection` mirrors
  the display into an `ImageReader`, takes the newest frame once the
  screen is still, and stops the projection right away (at most 1.5
  seconds after the first frame, or 4 seconds without one).
- **Private, short-lived file.** The frame is written as a PNG into the
  app's cache (`<cache>/screen_translate`, private to the app and never
  backed up), handed to the window by its in-process result (not by a
  path another component could name), read into memory and deleted; any
  leftover goes when the window closes and when the next one opens, and
  one left by an app process that ended in between (after saving the PNG,
  before reading it) when the app next opens any window (once per app
  process, off the main thread, sparing the files of the running one). The
  window closes when it goes to the background, so the screenshot doesn't
  stay in memory, and it is in no Recents list.
- **Mozhi's own window stays out of the frame.** The window draws nothing
  until it has the screenshot, the bubble hides first, and the window's
  `FLAG_SECURE` (**Hide content in recents & block screenshots**) is held
  off for the second of the capture only (a secure window, even an empty
  one, would black out the whole frame) and set again right after.
- **The screenshot stays on the phone.** It is read by on-device text
  recognition only (no AI vision or image upload for screenshots); only
  the recognised text goes to the chosen engine, through the same privacy
  mode, consent prompts and personal data shield as typed text, and
  counts in Network activity. Other locations the window would open (for
  example the offline languages) open in the main window instead.
- **App lock.** When Mozhi is locked, the window asks to unlock after the
  capture and before it shows anything; a cancelled prompt leaves only
  **Unlock** and **Close**, and the screenshot is hidden again if the app
  locks while it is open. Since only this window may show its page before
  the unlock, no other app can start Mozhi as this window: the exported
  main window never starts at its route (or the quick translate window's),
  however the intent asks for it (Flutter's `route` extra, a link, an
  explicit intent's data), and the app lock takes a window for this one
  (or the quick translate one) only when its route and its activity agree
  (a Dart entrypoint argument set by the activity's class, not by the
  intent); otherwise it shows the full lock screen.
- **The bubble** needs **Display over other apps**, granted by the user in
  Android's settings, and runs as a `specialUse` foreground service with a
  visible notification and **Stop**. It reads nothing by itself: a tap
  starts the consent above, a long press reads the clipboard once (in a
  window that has input focus, as Android 10+ requires, so right away,
  also while Mozhi is locked) and opens it as a read-only selection in the
  quick translate sheet, which shows it only after the unlock and never
  starts a paid AI request on its own.

## Live camera (Android)

The live camera sees whatever the phone is pointed at, so it runs only on
purpose, only in front, and keeps nothing:

- **Permission when asked for.** `CAMERA` is requested at run time when the
  live camera opens (the framework's `requestPermissions`); a permanent
  refusal is only ever undone by the user in Android's settings. The
  camera is driven by the app's own `LiveCameraPlugin.kt` on the framework
  Camera2 API: no CameraX, no androidx camera, no Google classes.
- **Only from the app.** The route opens only from the image screen (an
  in-app `extra`); a link, `mozhi://image/live` included, shows the image
  screen instead, so no other app can turn the camera on through Mozhi.
- **Only in front.** The camera is closed when the activity stops (it is
  never used in the background, whatever Dart does), when the plugin
  detaches and when the engine goes; the app closes it too while it is in
  the background, while the app lock is locked and while the phone is
  critically hot. Each opening has its own camera thread, session, readers
  and texture, all released together.
- **Frames on request, in memory.** Frames are pulled: the platform copies
  a frame's grey plane only when Dart asks for one, at most a few a second,
  and closes every other frame unread. Dart checks each frame against its
  own size (at most 4096 pixels a side) before reading it, and a still
  must be a JPEG of at most 32 MB. Nothing is written to disk, logged or
  kept after it is read; translations stay in memory while the screen is
  open and are not added to the history.
- **The text** goes only to the live engine (the offline engine unless the
  user picked another for live use and confirmed a network one once),
  through the same privacy mode, consent prompts, personal data shield and
  Network activity as typed text. Recognised text is only ever translated,
  as text. A **Once** in a consent prompt covers the requests waiting at
  that moment; what they don't use is withdrawn when the camera closes
  (paused, frozen, failed, the screen left) and when the engine or the
  languages change, so it can't let typed text, a link or the frozen
  photo through later. Documents and web pages withdraw theirs when the
  run ends, is cancelled or the screen closes.

## Live captions (Android)

Live captions hear whatever other apps play, so they capture only on
purpose, only sound, and keep nothing:

- **Consent every time.** The capture needs Android's own capture dialog
  (`MediaProjectionManager.createScreenCaptureIntent`, for the whole
  display on Android 14+), every time, and the `RECORD_AUDIO` permission,
  asked at run time. The service (`LiveCaptionService`, a foreground
  service of the type `mediaProjection` with a visible notification and
  **Stop**) is not exported, so no other app can start a capture, and
  only the Flutter engine that started it receives the audio; it stops
  when that engine goes away.
- **Sound only.** `AudioPlaybackCaptureConfiguration` with the media,
  game and unknown usages: Android itself leaves out calls and apps that
  opt out of capture. No virtual display is created, so nothing of the
  screen (the caption bar included) is captured.
- **Memory only.** Blocks of 100 ms go from the recording thread to Dart
  over an event channel and are dropped once Whisper has read them;
  nothing is written to disk or logged. While the phone is locked (screen
  off, or the lock screen up) nothing is recorded: the `AudioRecord` is
  stopped (the projection is kept) and starts again once the phone is
  unlocked; if it can't start again, the captions end. Phrases waiting for
  the engine are bounded (20 s of
  audio, older phrases are skipped), the transcript too (2,000 phrases).
- **The text** goes only to the live engine (the offline engine unless
  the user picked another for live use and confirmed a network one once),
  through the same privacy mode, consent prompts, personal data shield and
  Network activity as typed text.
- **The caption bar** (`TYPE_APPLICATION_OVERLAY`, **Display over other
  apps**, granted by the user in Android's settings) is
  `FLAG_NOT_FOCUSABLE`: it can't take the keyboard or input focus from
  the app below, and touches outside it go to that app. Its buttons send
  nothing but a stop or "open Mozhi" to the app. It hides while a Mozhi
  window is on screen and while the phone is locked. Mozhi's windows are
  followed from the app's first window on, so the window that started the
  captions counts too (the microphone and capture dialogs in front of it
  only pause it), and Translate screen never reads the bar. While the app
  lock is engaged it shows only **Mozhi is locked**, no captions; the
  transcript stays behind the lock (see App lock).
- **It ends** with Stop (in the app, on the bar, in the notification),
  when the captions screen closes, when Android revokes the projection
  (the status bar's stop) or the recording breaks (or doesn't start again
  after the phone is unlocked), and when the app's
  engine goes away; it is never restarted by the system.

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

## On-device AI

[On-device AI](on-device-ai.md) runs language models inside the app with
llama.cpp (MIT, built from a pinned release in the repository's
`packages/llama_engine`), so its text never leaves the phone
([Privacy](privacy.md#on-device-ai)):

- **No network in the engine.** The native library is built without
  llama.cpp's download and HTTP code (`LLAMA_CURL` and `LLAMA_OPENSSL`
  off) and exports only Mozhi's small C API (a version script). The
  models are AI providers of their own kind (`onDevice`) whose client
  runs in the app: there is no URL to point elsewhere, and the
  repository gives them the device as their destination, so the privacy
  rules and the shield have nothing to send. A provider stored in the
  settings, a backup or a sync file can never become one: they are made
  from the installed models only, and a stored provider with an
  on-device id is ignored.
- **Only verified model files are loaded.** A GGUF model file is parsed
  by native code, so a crafted file could exploit a parser bug. The app
  loads only files of its catalogue: each download is checked against the
  size and SHA-256 pinned in the app (whatever server sent it) before it
  is installed, **Import from files** accepts a file only when it matches
  a catalogue entry (by name, or by exact size and SHA-256), and the
  engine is given the path of an installed, verified model only. The
  files are in the app's private storage, where other apps can't replace
  them. An imported document is read through Android's document picker
  (a one-time read grant, no storage permission) and copied by
  `DeviceStoragePlugin.kt` only to a path inside the app's own files,
  no-backup or cache folders (anything else is refused), then verified
  there before it is installed.
- **A faster native build that crashes is turned off.** Before a faster
  engine build (dotprod, i8mm) is opened, and before its first
  computation, a marker file is written in the app's private storage; a
  marker left by a process that died at that step counts as a crash, and
  two crashes in a row (with no successful first computation between them)
  turn the build off for good, so a phone that misreports its processor
  features doesn't crash in a loop (one extra crash at most, the price of
  not turning a working build off when Android kills the app for another
  reason during that step). Only the guarded build names are read from the
  state file; a damaged one counts as empty. Explicit library paths
  (tests) are never affected.
- **No state between requests.** Each request starts with an empty
  context (the cache is cleared), so one text can't leak into the answer
  to another, and requests run one at a time. Prompts that don't fit the
  model's context fail with an error instead of being cut; long texts are
  translated in parts.
- **Resources.** The engine runs in a background isolate (the screen stays
  responsive, and **Cancel** stops a reply at once). A model is mapped
  from its file, not copied, is offered only on phones with enough memory,
  and is unloaded after two idle minutes, in the background and on memory
  pressure.
- **Prompts and output** follow the rules above: the extras use the same
  tagged prompts (and a JSON grammar for the replies that must be JSON),
  and the output is shown as plain text.
- **Text can't forge the model's chat markers.** The engine formats each
  request with the model's chat template itself and tokenizes the parts
  separately: only the template's own text can contain special tokens,
  and the messages (the text you translate, a document, a web page,
  recognised text) are tokenized as plain text. Text such as
  `<|im_end|>`, `<|im_start|>`, `<turn|>`, `<|endoftext|>` or `<eos>` in
  them stays ordinary characters, never the model's turn, end-of-text or
  other special tokens (nor those a vocabulary would match in plain text,
  such as Gemma 4's `<|channel>`), so a text can't end its turn or open a
  system turn of its own.

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

- The **app lock** hides Mozhi's screens; it is no encryption beyond what
  the app and Android already do (see [Data on the device](#data-on-the-device)).
  When its time ran out while the phone slept (and the app could not run),
  Mozhi notices on return, a moment after the phone's own lock screen
  was passed; otherwise it is locked before you come back. Until that
  check answered, the last screen shows but nothing starts behind it: the
  live camera stays closed, and links and text from other apps wait.
- **Shared conversations are plain `http`** on the local network: anyone
  on that network who captures traffic can read them, and the PIN with
  them. Use the phone's hotspot for anything sensitive; there is no way to
  give a phone's local server a certificate browsers trust.
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
  it. A policy sent as a header applies on top of the page's own, so it
  must still allow the offline engine: `script-src 'self'
  'wasm-unsafe-eval'`, `worker-src 'self'` and `connect-src 'self'` (the
  worker loads `bergamot/` and the models from the same server); serve
  `.wasm` files as `application/wasm` (Caddy and nginx do by default).
  Debug web runs (`flutter run` in debug mode) are blocked by the
  policy; see [Contributing](contributing.md).
- **Web app shell (service worker):** `mozhi_sw.js` is served from the
  app's own origin (`worker-src 'self'`, no inline script) and only
  answers `GET` and `HEAD` requests for the files its build lists in
  `mozhi_sw_manifest.json`, under the app's own path; requests to other
  hosts (Mozhi instances, AI providers, model downloads), `POST`s, the
  language packs in the browser's private storage and every other path go
  to the network untouched. It keeps a file only when its size and
  SHA-256 match the manifest, which it fetches past the HTTP cache, and a
  new build waits until you choose **Reload**. A file it serves from its
  cache carries the security headers your server sent with it
  (`Content-Security-Policy` with `frame-ancestors`, `X-Frame-Options`,
  `Referrer-Policy`, `Permissions-Policy`, `X-Content-Type-Options` and the
  `Cross-Origin-*` policies), so the protection above holds offline too;
  after you change those headers, the next update of the app picks them
  up. Its caches are named after
  the app's path, so two copies of the app on one origin don't mix.
  Turning off **Settings > General > Keep the web app for offline use**
  unregisters it and deletes what it kept. Whoever controls the server can
  still change the app, as for any web app: the manifest only protects
  against damaged or half-finished downloads.
- Android release builds made without a signing key (forks, local builds)
  are signed with the debug key. Official releases must use the release
  key.
