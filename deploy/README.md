# Self-hosting quickstart

Everything here runs with Docker Compose (v2.20 or newer). The full guide,
with background and troubleshooting, is
[docs/self-hosting-mozhi.md](../docs/self-hosting-mozhi.md).

| File | Purpose |
| --- | --- |
| `docker-compose.yml` | Mozhi, plus optional Ollama, LibreTranslate and Caddy |
| `.env.example` | Every setting, with defaults. Copy to `.env` to change them |
| `Caddyfile` | HTTPS reverse proxy for Mozhi (and, optionally, Ollama), the model mirror at `/models/` and, optionally, the web app |
| `webdav-cors.Caddyfile` | CORS (and HTTPS) in front of your WebDAV server, so the web app can [sync](../docs/sync.md#the-web-app-and-cors) with it |

## 1. Mozhi on your network

```sh
cd deploy
docker compose up -d
docker compose ps        # wait until mozhi shows "healthy"
curl http://localhost:3000/api/version
```

In the app open **Settings > Mozhi instances > Add instance**, enter
`http://<server-ip>:3000` (for example `http://192.168.1.10:3000`), tap
**Test**, save, and drag it to the top of the list. Plain `http` is fine on
your own network.

The first `up` builds a tiny local image: the official
`codeberg.org/aryak/mozhi:latest` plus BusyBox's `wget`, so Docker can run the
health check (the official image has no shell or tools). To update later:

```sh
docker compose build --pull && docker compose up -d
```

## 2. Optional services

Start them with `--profile`, or list them once in `.env` as
`COMPOSE_PROFILES=ai,libre,https`.

**Local AI with Ollama** (`ai` profile, port 11434):

```sh
docker compose --profile ai up -d
docker compose exec ollama ollama pull translategemma:4b   # or gemma3:12b, qwen3:14b, ...
```

In the app: **Settings > AI providers > Add provider > Ollama**, base URL
`http://<server-ip>:11434`, then pick the model. For an NVIDIA or AMD GPU,
uncomment the matching lines in `docker-compose.yml`. Model advice:
[docs/ai-providers.md](../docs/ai-providers.md#which-local-model).

**LibreTranslate** (`libre` profile): a fully self-hosted engine that Mozhi
offers next to Google, DeepL and the others. In `.env`:

```sh
COMPOSE_PROFILES=libre
MOZHI_LIBRETRANSLATE_ENABLED=true
LT_LOAD_ONLY=en,ar,zh,fr,de,hi,id,ga,it,ja,ko,pl,pt,ru,es,tr,vi
```

then `docker compose up -d`. The first start downloads the language models
and can take a while; `docker compose logs -f libretranslate` shows progress.

**HTTPS with Caddy** (`https` profile): needs a domain name pointing at this
server and ports 80 and 443 open. In `.env`:

```sh
COMPOSE_PROFILES=https
MOZHI_DOMAIN=mozhi.example.com
MOZHI_BIND_ADDRESS=127.0.0.1   # optional: only reachable through Caddy
```

then `docker compose up -d` and add `https://mozhi.example.com` in the app.
The `Caddyfile` also has commented examples for Ollama behind an API key and
for HTTPS on a LAN without a public domain.

## 3. Mirror the on-device models

The app downloads its offline languages, voice input and text recognition
models from their publishers (Mozilla's bucket on Google Cloud, Hugging
Face, GitHub), which see each user's IP address and languages. Serve them
from your server instead:

```sh
docker compose --profile mirror run --rm mirror --list        # what and how much
docker compose --profile mirror run --rm mirror --languages de,fr,ja --whisper tiny,silero-vad
docker compose --profile mirror run --rm mirror               # everything, about 3 GB
```

The files land in `./models` (`MOZHI_MODELS_DIR`), checked against the
SHA-256 built into the app; run it again after updating the app (it
resumes, skips what is in place and never deletes other files). Caddy (the
`https` profile) serves them at `https://mozhi.example.com/models/`. In the
app: **Settings > Translation engines > Model source > Custom mirror** with
that address. A web app served from the same site (see the commented web
app block in the `Caddyfile`) uses it by default ("This web server").

Without Docker: `python3 tool/mirror_models.py /path/to/models [filters]`
from a checkout of the repository, and serve the directory as static files
(guide: [docs/self-hosting-mozhi.md](../docs/self-hosting-mozhi.md#mirror-the-on-device-models)).

## Everyday commands

```sh
docker compose ps                     # status and health
docker compose logs -f mozhi          # logs
docker compose down                   # stop (volumes and models are kept)
docker compose pull && docker compose up -d   # update Ollama/LibreTranslate/Caddy
```

`docker compose pull` acts on the profiles you enabled (in `.env` or with
`--profile`) and does not update Mozhi, which is built locally; use the
`build --pull` command above for it.
