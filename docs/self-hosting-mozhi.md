# Self-hosting Mozhi

Running your own Mozhi instance gives the app a fast, private translation
back end that nobody else can rate-limit, log or switch off. This guide covers
Docker Compose, HTTPS, use on your LAN and over Tor or I2P, the API the app
uses, and troubleshooting.

- [What Mozhi is](#what-mozhi-is)
- [What self-hosting changes](#what-self-hosting-changes)
- [Quick start](#quick-start)
- [Configuration](#configuration)
- [Connect the app](#connect-the-app)
- [Use it on your LAN](#use-it-on-your-lan)
- [HTTPS with Caddy](#https-with-caddy)
- [Tor and I2P](#tor-and-i2p)
- [Mirror the on-device models](#mirror-the-on-device-models)
- [The API the app uses](#the-api-the-app-uses)
- [Updating](#updating)
- [Troubleshooting](#troubleshooting)

## What Mozhi is

[Mozhi](https://codeberg.org/aryak/mozhi) (Tamil for "language") is an
open-source, AGPL-licensed alternative front-end for many translation engines:
Google, DeepL, Reverso, Yandex, LibreTranslate, MyMemory and DuckDuckGo (which
gives the same results as Bing Translator). It is a single Go program with a
small web page and a JSON API. Your request goes to Mozhi, Mozhi asks the
engine, and you get the result without the engine's website, scripts,
trackers or account.

This app uses Mozhi's API. Mozhi itself is developed by Arya K and
contributors; this app is an independent client.

## What self-hosting changes

- **No middleman.** On a public instance, the operator could see your text.
  On your own instance, only your server does.
- **The engine still sees the text.** Mozhi forwards each request to the
  engine you picked (Google, DeepL, ...), which receives the text from your
  server's IP address instead of your device. Only LibreTranslate, when you
  host it yourself (see below), keeps everything on your machine.
- **No shared rate limits.** Busy public instances are often throttled by the
  engines; your own instance only carries your traffic.
- **Mozhi stores nothing.** It keeps no database or history, and does not log
  requests by default, so there is nothing to back up.

## Quick start

You need a machine that is always on (a home server, a Raspberry Pi 4 or 5, a
NAS, or a small VPS) with Docker. The image is published for `amd64` and
`arm64`.

**One container:**

```sh
docker run -d --name mozhi --restart unless-stopped \
  -p 3000:3000 codeberg.org/aryak/mozhi:latest
curl http://localhost:3000/api/version
```

**Docker Compose (recommended):** the [`deploy/`](../deploy/README.md) folder
of this repository has a Compose file with sensible defaults, a working health
check, and optional profiles for local AI, LibreTranslate and HTTPS:

```sh
git clone https://github.com/Aimdi/Mozhi.git
cd Mozhi/deploy
cp .env.example .env        # optional: edit settings
docker compose up -d                     # Mozhi on port 3000
docker compose --profile ai up -d        # + Ollama on port 11434
docker compose --profile libre up -d     # + LibreTranslate (see below)
docker compose --profile https up -d     # + Caddy with automatic HTTPS
```

A minimal Compose file, if you prefer to write your own:

```yaml
services:
  mozhi:
    image: codeberg.org/aryak/mozhi:latest
    restart: unless-stopped
    ports:
      - "3000:3000"
    environment:
      MOZHI_REVERSO_ENABLED: "false"   # example: hide an engine
```

> **About health checks.** The official image is built `FROM scratch`: it
> contains the Mozhi binary and CA certificates, but no shell and no `wget`.
> A health check such as `wget ... /api/version` therefore cannot run inside
> it and the container is reported as unhealthy. The Compose file in
> `deploy/` builds a two-line image that adds BusyBox's static `wget`, so its
> health check on `/api/version` works.

## Configuration

Mozhi is configured with environment variables.

| Variable | Default | Effect |
| --- | --- | --- |
| `MOZHI_PORT` | `3000` | Port Mozhi listens on. |
| `MOZHI_HOST` | all interfaces | Address Mozhi listens on. Leave it unset in containers. |
| `MOZHI_DEFAULT_ENGINE` | `google` | Engine preselected on Mozhi's own web page. |
| `MOZHI_DEFAULT_SOURCE_LANG` | auto-detect | Source language preselected on the web page. |
| `MOZHI_DEFAULT_TARGET_LANG` | `en` | Target language preselected on the web page. |
| `MOZHI_DEFAULT_PREFER_AUTODETECT` | `false` | Web page: prefer auto-detect over the default source language. |
| `MOZHI_LIBRETRANSLATE_URL` | unset | Base URL of a LibreTranslate server, e.g. `http://libretranslate:5000`. The LibreTranslate engine is only offered when this is set. |
| `MOZHI_GOOGLE_ENABLED` | `true` | Offer Google. |
| `MOZHI_DEEPL_ENABLED` | `true` | Offer DeepL. |
| `MOZHI_REVERSO_ENABLED` | `true` | Offer Reverso. |
| `MOZHI_YANDEX_ENABLED` | `true` | Offer Yandex. |
| `MOZHI_MYMEMORY_ENABLED` | `true` | Offer MyMemory. |
| `MOZHI_DUCKDUCKGO_ENABLED` | `true` | Offer DuckDuckGo. |
| `MOZHI_LIBRETRANSLATE_ENABLED` | `true` | Offer LibreTranslate (also needs the URL). |
| `MOZHI_USER_AGENT` | a desktop Chrome string | User agent sent to the engines. |

Things worth knowing:

- **The `MOZHI_DEFAULT_*` variables only affect Mozhi's own web page.** The
  app always sends the engine and both languages explicitly.
- **An engine is enabled only if its `MOZHI_<ENGINE>_ENABLED` variable is
  unset or exactly `true`.** Any other value, including `1`, `yes` or an
  empty string, disables it. Disabled engines disappear from `/api/engines`,
  and the app stops offering them the next time it loads the engine list.
- **LibreTranslate** is a translation engine you can host yourself, so with
  it no third party sees your text. Mozhi offers a fixed set of 17 languages
  for it: Arabic, Chinese, English, French, German, Hindi, Indonesian, Irish,
  Italian, Japanese, Korean, Polish, Portuguese, Russian, Spanish, Turkish and
  Vietnamese. With the Compose file, enable it like this in `.env`:

  ```sh
  COMPOSE_PROFILES=libre
  MOZHI_LIBRETRANSLATE_ENABLED=true
  LT_LOAD_ONLY=en,ar,zh,fr,de,hi,id,ga,it,ja,ko,pl,pt,ru,es,tr,vi
  ```

  `LT_LOAD_ONLY` limits LibreTranslate to those languages; without it,
  LibreTranslate downloads models for every language it knows (several GB)
  on first start. Mozhi talks to LibreTranslate without an API key, so leave
  LibreTranslate's API keys off (its default).

## Connect the app

Open **Settings > Translation engines > Mozhi instances > Add instance**,
enter the address, tap **Test** (it shows the response time), optionally give
it a label, and save. Then drag it to the top of the list, or tap **Make
preferred**.

What you can type:

- `https://mozhi.example.com`, or just `mozhi.example.com` (`https://` is
  added for you).
- `192.168.1.10:3000`: for private and local addresses the app adds `http://`
  instead. This applies to `localhost`, `10.x`, `172.16-31.x`, `192.168.x`,
  `169.254.x`, Tailscale's `100.64-127.x`, IPv6 local addresses, single-word
  host names such as `raspberrypi`, and names ending in `.local`, `.lan`,
  `.internal`, `.home.arpa`, `.onion` or `.i2p`.
- A sub-path, such as `https://example.com/mozhi`, if your reverse proxy
  serves Mozhi there. A trailing `/api` is removed automatically.

**Failover.** Instances are used in list order. When an instance can't be
reached, times out, answers `429 Too Many Requests` or fails with a server
error, the app retries the request on the next instance and keeps using
whichever one worked for the rest of the session. Keep a public instance or
two below your own as a fallback, or delete them all if you never want your
text to leave your network.

## Use it on your LAN

You don't need a domain or HTTPS at home:

1. Find the server's address, e.g. `ip -4 addr` on Linux. Give it a fixed
   address (a DHCP reservation in your router) so it doesn't change.
2. Make sure port 3000 is reachable, e.g. `sudo ufw allow 3000/tcp` on a
   server with UFW.
3. Add `http://192.168.x.x:3000` in the app.

The Android app allows unencrypted `http` connections for exactly this
purpose. Certificates from your own private CA (for example
Caddy's `tls internal`) are **not** trusted by the app: release builds trust
the system certificate store only. For HTTPS on the LAN use a publicly
trusted certificate (e.g. Let's Encrypt via the ACME DNS challenge), or use
plain `http` on a network you trust, or a VPN such as WireGuard/Tailscale.

Notes:

- Guest Wi-Fi networks often isolate devices from each other; use the main
  network.
- **VPN from outside your home:** with WireGuard or Tailscale you can keep
  using the LAN address on the go. Tailscale addresses (`100.x.y.z`) get
  `http://` automatically; MagicDNS names (`*.ts.net`) get `https://`, so
  type `http://` yourself unless you set up `tailscale serve`.
- **Web app:** a web page served over `https` may not call an `http` address
  (browsers block this "mixed content"), so a web app on an `https` site needs
  your instance on `https` as well. CORS is not a problem: Mozhi's API sends
  `Access-Control-Allow-Origin: *`.

## HTTPS with Caddy

For an instance on the internet, put it behind a reverse proxy with HTTPS.
[Caddy](https://caddyserver.com) gets and renews certificates automatically.

**With the Compose file:** point a DNS name at your server, open ports 80 and
443, and set in `deploy/.env`:

```sh
COMPOSE_PROFILES=https
MOZHI_DOMAIN=mozhi.example.com
MOZHI_BIND_ADDRESS=127.0.0.1   # Mozhi is then only reachable through Caddy
```

`docker compose up -d` starts Caddy with [`deploy/Caddyfile`](../deploy/Caddyfile).
Add `https://mozhi.example.com` in the app.

**With Caddy installed on the host**, this is all you need:

```caddyfile
mozhi.example.com {
	reverse_proxy localhost:3000
}
```

**Other reverse proxies** work too. Keep the request body limit at 4 MB or
more for image translation; nginx allows only 1 MB by default
(`client_max_body_size 4m;`).

The `deploy/Caddyfile` also contains commented examples for:

- **Ollama behind an API key**, so you can use your home AI server from
  anywhere: Caddy rejects requests without `Authorization: Bearer <key>`, and
  the app sends that header when you enter the key in the Ollama provider.
- **HTTPS on a LAN without a public domain** using Caddy's internal CA.

## Tor and I2P

Mozhi works fine as a Tor onion service. With Tor installed on the same
machine, add to `/etc/tor/torrc`:

```text
HiddenServiceDir /var/lib/tor/mozhi/
HiddenServicePort 80 127.0.0.1:3000
```

Restart Tor and read the address from `/var/lib/tor/mozhi/hostname`. I2P
works the same way with an HTTP server tunnel pointing at port 3000. Several
public instances also have onion or I2P addresses (see the
[Mozhi README](https://codeberg.org/aryak/mozhi#instances)).

The app accepts `.onion` and `.i2p` addresses and uses `http://` for them, but
it has no built-in Tor or I2P client: the device has to route the app's
traffic through Tor or I2P, for example with Orbot's VPN mode on Android. If
such an address fails the **Test**, the tunnel isn't routing the app.

## Mirror the on-device models

The app's on-device models (offline languages, voice input, text
recognition) come from their publishers by default: Mozilla's Firefox
Translations bucket on Google Cloud Storage, the Whisper models on Hugging
Face and Tesseract's language data on GitHub. Each of them sees the IP
address and which files, so which languages, a user downloads. A mirror on
your server keeps that between your users and you.

**A mirror needs no trust.** Every file is pinned in the app's catalogues
by size and SHA-256 (Whisper also by SHA-1) and checked before it is
installed, whichever server sends it. A mirror that serves anything else
gets an error that names it (*Pashto didn't download correctly from
mirror.example.com…*), and nothing is installed.

### The layout

One plain directory of files, under their original names:

```text
models/
├── bergamot/<source>-<target>/<version>/<name>.gz   e.g. bergamot/en-de/retrain_hr_…/model.ende.intgemm.alphas.bin.gz
├── whisper/<name>                                   e.g. whisper/ggml-tiny.bin, whisper/ggml-silero-v6.2.0.bin
├── tesseract/<code>.traineddata                     e.g. tesseract/deu.traineddata
└── dictionary/<id>.mzd                              e.g. dictionary/es.mzd (offline dictionaries; `--only dictionary`, `--dictionaries es`)
```

The app asks for `<mirror>/bergamot/…`, `<mirror>/whisper/…` and
`<mirror>/tesseract/…` (plain `GET`, with `Range` to resume; no cookies,
nothing else).

### Fill it

[`tool/mirror_models.py`](../tool/mirror_models.py) (Python 3.10+, no
dependencies) downloads exactly the files of the catalogues in your
checkout, verifies them, resumes interrupted downloads, skips files already
in place and never deletes anything else (so one mirror can serve several
app versions):

```sh
python3 tool/mirror_models.py /srv/mozhi/models --list    # files and total size
python3 tool/mirror_models.py /srv/mozhi/models           # everything, about 3 GB
python3 tool/mirror_models.py /srv/mozhi/models \
    --languages de,fr,ja --whisper tiny,silero-vad        # what your users need
python3 tool/mirror_models.py /srv/mozhi/models --verify  # check, no network
```

Filters: `--only bergamot,whisper,tesseract`, `--languages` (translation in
both directions with English, and the text recognition data of those
languages), `--pairs en-de,de-en`, `--whisper tiny,base,silero-vad` (the
voice activity model `silero-vad` comes with every speech model download),
`--tesseract deu,chi_sim`. With the Compose file:

```sh
cd deploy
docker compose --profile mirror run --rm mirror --languages de,fr
```

writes to `deploy/models` (`MOZHI_MODELS_DIR` in `.env`). Run it again
after updating the app: a new model version is a new directory (or, for
Whisper and Tesseract, replaces the file of the same name). Delete old
`bergamot/<pair>/<version>` directories yourself when no user runs an app
version that still asks for them.

### Serve it

Any static web server works; it should allow `Range` requests, send no
directory listings, and, for web apps on other origins, CORS headers.

**Caddy (`deploy/Caddyfile`):** the `(models)` snippet serves
`/srv/models` at `/models/` on the Mozhi site, with CORS, a one-day cache
and `.part` files hidden. With the `https` profile, the mirror is at
`https://mozhi.example.com/models/`. A commented site serves the web app on
its own domain with the same `/models/` next to it.

**nginx:**

```nginx
location /models/ {
    alias /srv/mozhi/models/;
    autoindex off;
    # Partial downloads of the mirror tool.
    location ~ \.part$ { return 404; }
    add_header Access-Control-Allow-Origin "*" always;
    add_header Access-Control-Expose-Headers "Content-Length, Content-Range, Accept-Ranges, ETag" always;
    add_header Cache-Control "public, max-age=86400" always;
    # CORS preflight (headers set in an `if` replace the ones above).
    if ($request_method = OPTIONS) {
        add_header Access-Control-Allow-Origin "*";
        add_header Access-Control-Allow-Methods "GET, HEAD, OPTIONS";
        add_header Access-Control-Allow-Headers "Range";
        return 204;
    }
}
```

**A quick test on your LAN:** `python3 -m http.server 8000 --directory
/srv/mozhi` serves `http://<server-ip>:8000/models/` (no CORS, so for the
Android app only).

### Point the app at it

**Settings > Translation engines > Model source** (also on the
**Offline languages** page):

- **Original publishers:** the default of the Android app.
- **This web server** (web app only, its default): `models/` next to the
  web app, e.g. `https://translate.example.com/models/` for a web app at
  `https://translate.example.com/`. Unpack the web zip and put (or link)
  the mirror's `models/` directory next to its `index.html`, or serve it
  there as above.
- **Custom mirror…:** the mirror's address, e.g.
  `https://mozhi.example.com/models/`. `https` for public servers; plain
  `http` only for this device, your LAN and `.onion` / `.i2p` addresses
  (which need Orbot or another proxy).

**Use the original publishers when the mirror lacks a file** is off by
default: a file your mirror doesn't have then fails with *the mirror may not
have this language yet* rather than going to Google, GitHub or Hugging Face.
Turn it on to use the mirror for what it has and the publishers for the
rest. A file that doesn't match its checksum is never fetched elsewhere.

The **Network activity** log lists every download with its host (your
mirror, or the publisher).

## The API the app uses

All endpoints live under `/api`, send `Access-Control-Allow-Origin: *`, and
report errors as a non-2xx status with a plain-text message. Interactive
documentation is served at `/api/swagger/index.html` on every instance.

| Endpoint | Used for |
| --- | --- |
| `POST /api/translate` | Translating. Form fields `engine`, `from`, `to`, `text` (all required; `from=auto` detects the language). One engine returns one JSON object; several comma-separated engines (`engine=google,deepl`, used by compare mode) or `engine=all` return an array, silently leaving out engines that failed. Some engines, notably Google and Reverso, also return transliterations, definitions, examples and synonyms. |
| `GET /api/engines` | The engine list, e.g. `{"google": "Google", "deepl": "DeepL", ...}`. The pseudo-engines `all` and `some` are ignored by the app. |
| `GET /api/source_languages?engine=…` | Source languages of an engine: `[{"Id": "auto", "Name": "Detect Language"}, ...]`. |
| `GET /api/target_languages?engine=…` | Target languages of an engine. |
| `GET /api/tts?engine=…&lang=…&text=…` | Text-to-speech as MP3. Only `google` and `reverso` support it. The app uses Google and falls back to Reverso. |
| `POST /api/image` | Image translation. Multipart form with `engine`, `from`, `to` and the file field `image`, which must be a PNG (`Content-Type: image/png`). Only Google is implemented; the response contains the recognised text, its translation and a translated image. |
| `GET /api/version` | `{"fiberversion": "...", "goversion": "..."}`. Cheap, so the app uses it to test and ping instances. |

Try it from a shell:

```sh
curl -s http://localhost:3000/api/engines
curl -s -X POST http://localhost:3000/api/translate \
  --data-urlencode engine=google --data-urlencode from=auto \
  --data-urlencode to=en --data-urlencode text='Bonjour tout le monde'
```

## Updating

```sh
# Compose file from deploy/
docker compose build --pull && docker compose up -d

# Plain image
docker compose pull && docker compose up -d
```

Mozhi has no state, so updating is safe at any time.

## Troubleshooting

**Model downloads fail with "from mirror.example.com: it answered with
error 404".** The mirror lacks that language: run `tool/mirror_models.py`
with it (`--languages xx`), or turn on **Use the original publishers when
the mirror lacks a file**. *Didn't download correctly from …* means the
mirror's copy doesn't match the app's catalogue: run the tool again (it
replaces files that don't match), or check that nothing rewrites the files
(compression, a CDN that transcodes).

**The app says it couldn't reach the instance.**
Run `curl http://<server-ip>:3000/api/version` from another computer on the
same network. If that fails, check the firewall, that the container is
running (`docker compose ps`), and that you used the server's LAN address,
not `localhost`. If `curl` works but the app doesn't, look for a typo in the
scheme (`http` vs `https`) or port.

**Reverso fails while other engines work.**
Reverso blocks the IP addresses of many servers, especially data-centre and
VPS ranges, and it has no IPv6, so rotating addresses doesn't help (see
[Mozhi issue #27](https://codeberg.org/aryak/mozhi/issues/27)). It usually
works from a home connection. Otherwise hide it with
`MOZHI_REVERSO_ENABLED=false`. Reverso is also the fallback voice for
text-to-speech; Google is tried first.

**"Too many requests" or engines failing randomly.**
Google, DeepL and Yandex rate-limit IP addresses that send many requests.
This is common on busy public instances and on shared VPS addresses. Your own
instance at home rarely hits limits. When it happens, wait a little, switch
engines, or keep another instance below yours in the list so the app can fail
over. With **Instant translate**, the app waits until you pause typing before
sending a request.

**Image translation fails with an error about size (`413 Request Entity Too
Large`).**
Mozhi accepts request bodies up to 4 MB, which includes uploaded images. The
app scales photos down before uploading (longest side 2048 px, under 4 MB),
so a `413` usually comes from a reverse proxy in front of Mozhi with a lower
limit: nginx allows only 1 MB by default (`client_max_body_size 4m;` fixes
it). If you call the API yourself, note that Mozhi only accepts PNG images
("Invalid image, only png images are accepted").

**LibreTranslate doesn't show up as an engine.**
It needs both `MOZHI_LIBRETRANSLATE_URL` and an enabled flag (the Compose
file defaults `MOZHI_LIBRETRANSLATE_ENABLED` to `false` until you turn it on).
After changing variables, recreate the container with `docker compose up -d`,
then reload the engines in the app (reopen it). If it shows up but fails,
check `docker compose logs libretranslate`: on first start it downloads its
models, and a language missing from `LT_LOAD_ONLY` cannot be translated.

**"Engine does not exist or has been disabled."**
The app asked an instance for an engine it doesn't offer, usually because
you disabled the engine after the app loaded its engine list. Reopen the app
so it reloads the list.

**The container is "unhealthy".**
You are probably using a health check that needs a shell or `wget` with the
official `FROM scratch` image. Use the Compose file in `deploy/`, or remove
the health check.

**The web app can't connect.**
See [Use it on your LAN](#use-it-on-your-lan): an `https` page can't call an
`http` instance. Also check that your reverse proxy doesn't add
authentication or strip the CORS header Mozhi sends.
