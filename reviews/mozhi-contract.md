# Mozhi API contract test against the real server

Date: 2026-10-13. Owner: `tool/mozhi_contract/**`.

`packages/mozhi_api` (and the Mozhi side of `translation_repository`) was
run against a Mozhi server **built from upstream source**. Every check is
recorded below.

| | |
| --- | --- |
| Server | `codeberg.org/aryak/mozhi` `v0.0.0-20261011165718-6464aa2e3739` (commit `6464aa2e3739`) |
| Library | `codeberg.org/aryak/libmozhi` `v0.0.0-20260409092721-7dfc07322cac` |
| Stack | Fiber `2.52.12`, Go `go1.25.0` (as reported by `/api/version`) |
| Env | defaults (no `MOZHI_*` vars), bound to `127.0.0.1:3123` |
| Egress | blocked: the proxy answered `403 Forbidden` for Google, DeepL, Reverso, Yandex, MyMemory and DuckDuckGo, so every upstream translation fails. This is how the error paths were exercised. |

**Result:** 54 checks, 39 pass, 15 gap, **0 fail** (53/39/14/0 without
`--destructive`).

**Parsing:** the client and the real server agree on every field name and
body format: `Name`/`Id`, the engines map, `LangOut` keys,
`fiberversion`/`goversion`, `ImgOut` keys, and plain-text errors. The
problems found are about behaviour, not parsing. The 15 GAPs are listed in
priority order below.

## How to reproduce

```sh
# Build the pinned server and run everything (the script starts/stops it):
tool/mozhi_contract/run.sh                 # add --destructive, --json out.json
# Or, against a server you started yourself:
(cd tool/mozhi_contract/server && go build -o /tmp/mozhi-server .)
/tmp/mozhi-server 127.0.0.1 3123 &
dart run tool/mozhi_contract/contract_test.dart --base http://127.0.0.1:3123
```

- `tool/mozhi_contract/server/` is a 20-line Go module that calls
  `serve.Serve(host, port)` from the pinned Mozhi revision.
  - `go.sum` is committed.
  - `proxy.golang.org` serves the `codeberg.org` modules, so codeberg itself
    is not needed. Building with a cold cache takes about 4 minutes.
- `contract_test.dart` runs from the repo root. It uses the app's package
  config, which already contains `mozhi_api`, `translation_repository` and
  `http`.
  - It deliberately has no `pubspec.yaml`: CI runs `flutter analyze` over
    `tool/` but only runs `pub get` for `packages/*`, so a nested package
    would fail analysis there.
  - `dart analyze tool/mozhi_contract` reports no issues.
- Exit code: 0 when nothing FAILs. GAP means the server behaves in a way the
  client handles poorly. Checks that need a reachable upstream accept both
  outcomes and print which one they saw.
- `--destructive` runs one extra check, always last, that crashes the server
  (see G1).

## Language lists (every engine, live)

The client counts match the raw JSON item for item. "Repository" is the count
after `mapMozhiLanguages`, which moves `auto` first and drops duplicate ids.

| Engine | In `/api/engines` | Source | Target | `auto` in source | `auto` in target | Duplicate ids | Repository (source/target) |
| --- | --- | ---: | ---: | --- | --- | --- | --- |
| deepl | yes | 30 | 36 | no | no | 0 | 30 / 36 |
| duckduckgo | yes | 129 | 128 | yes | no | 0 | 129 / 128 |
| google | yes | 250 | 249 | yes (first) | no | 0 | 250 / 249 |
| mymemory | yes | 325 | 324 | yes (**last**, index 324) | no | 1 (`mfi`) | 324 / 323 |
| reverso | yes | 26 | 26 | no | no | 0 | 26 / 26 |
| yandex | yes | 103 | 102 | yes | no | 0 | 103 / 102 |
| libre | **no** | 18 | 17 | yes | no | 0 | not asked |

- **`auto` handling is correct.**
  - `auto` is never in a target list.
  - It is in the source list of 5 of 7 engines. DeepL and Reverso are the
    exceptions (see G7).
  - The repository puts `Language.auto` first even when MyMemory lists it
    last.
- **Non-ASCII names decode correctly**, e.g. `Baoulé`, `Qʼeqchiʼ`, `Māori`,
  `Norwegian (bokmål)`. Most responses send `application/json;
  charset=utf-8`, but `/api/version` sends it without a charset. The client
  decodes the bytes as UTF-8 either way, which is correct.
- `libre` is left out of `/api/engines` unless `MOZHI_LIBRETRANSLATE_URL` is
  set (`utils.EngineList`). Its static lists are still served.
- Engines turned off with `MOZHI_<X>_ENABLED=false` are only hidden from
  `/api/engines`. Their lists and `/api/translate` still work (checked by
  hand with `MOZHI_GOOGLE_ENABLED=false`). The client treats
  `/api/engines` as the source of truth, which is fine.

## Observed endpoint contract

| Request | Status | Body |
| --- | --- | --- |
| `GET /api/version` | 200 `application/json` | `{"fiberversion":"2.52.12","goversion":"go1.25.0"}` (no `v` prefix) |
| `GET /api/engines` | 200 | `{"all":"All Engines","some":"Some Engines","google":"Google",...}` |
| `GET /api/source_languages` (no engine) | 400 text/plain | `engine is a required query string.` |
| `GET /api/source_languages?engine=nope` (or `all`) | 500 | `Engine does not exist or has been disabled.` |
| `/api/translate` with any field missing (GET or POST) | 400 | `from, to, engine, text are required query strings.` |
| `/api/translate` unknown engine, or `some` | 500 | `Engine does not exist or has been disabled.` |
| `/api/translate` `google,nope` | 500 | `Engine nopenot supported or implemented` (sic) |
| `/api/translate` bad `to` / `from` | 500 | `Target Language Code invalid` (Google) / `Target language code invalid`, `Source language code invalid` (others) |
| `/api/translate` single engine, upstream down | 500 | raw Go error, e.g. `Post "https://translate.google.com/_/TranslateWebserverUi/data/batchexecute": Forbidden` |
| `/api/translate` DeepL, upstream down | **200** | `LangOut` with `"translated-text": ""` |
| `/api/translate` DuckDuckGo, upstream down | 500 | `runtime error: invalid memory address or nil pointer dereference` (panic recovered by Fiber) |
| `/api/translate` comma list or `all`, upstreams down | 200 | `[]` (failed engines dropped) |
| `/api/translate` comma list or `all` including `duckduckgo`, DDG down | **process exits** | Go panic in a goroutine (G1) |
| `POST /api/translate` with a JSON body | 400 | only query and form fields are read |
| `POST /api/translate` body > 4 MiB | 413 `Request Entity Too Large`, no CORS header | dart:io usually sees `Write failed` / broken pipe instead |
| `GET /api/tts` field missing | 400 | `engine, lang, text are required query strings.` |
| `GET /api/tts?engine=deepl` | 500 | `Engine does not exist and/or doesn't support TTS and/or has been disabled.` |
| `GET /api/tts` upstream down | 500 | `ErrTransport: Get "https://translate.google.com/translate_tts?...": Forbidden` |
| `GET /api/tts` request line > ~4 KiB | 431 `Request Header Fields Too Large`, no CORS header | dart:io usually sees `Connection reset by peer` |
| `POST /api/tts` | 405 | `Method Not Allowed` (GET only; the client uses GET) |
| `POST /api/image` with a non-PNG part type | 400 | `Invalid image, only png images are accepted` |
| `POST /api/image` without from/to | 400 | `from, to, engine are required arguments.` |
| `POST /api/image` without an `image` part | 500 | `there is no uploaded file associated with the given key` |
| `POST /api/image` not multipart | 500 | `request Content-Type has bad boundary or is not multipart/form-data` |
| `POST /api/image` with `engine=deepl` | (Google) | `engine` is ignored; it always goes to Google |
| `GET /api/nope`, wrong sub-path | 404 | `Cannot GET /sub/api/version` |
| `OPTIONS` on any API route | 405 (or the handler runs, for `All` routes) | no `Access-Control-Allow-Methods` / `-Headers` |

- **CORS:** `Access-Control-Allow-Origin: *` is present on every `/api/*`
  response tried: success, 400, 404, 405 and 500. It is missing only on the
  413 and 431 responses, which fasthttp produces before the middleware runs.
- **Preflight:** there is no preflight support. The web build works because
  every client request is CORS-simple:
  - plain GET;
  - form-urlencoded POST;
  - multipart POST;
  - no custom headers.
- **Compression:** JSON is gzipped (compress middleware), and dart:io decodes
  it.
- **Engine ids:** the server strips everything except `[A-Za-z0-9,]`, so
  `goo-gle!` is treated as `google`.

## Gaps and recommendations (priority order)

**G1: Critical. A multi-engine request that includes DuckDuckGo can kill the
Mozhi process.**
- When DuckDuckGo is unreachable, or its page no longer contains `vqd="..."`,
  `libmozhi.ddgVqdUpdate` dereferences a nil response or indexes a nil match.
  - In a single-engine request, Fiber's `recover` middleware catches the
    panic and turns it into a 500.
  - `TranslateAll` and `TranslateSome` run each engine in a goroutine, where
    nothing recovers the panic. The server exits with code 2.
- Seen live with `--destructive`: `Connection closed before full header was
  received`, and the next `/api/version` call failed.
- Our client sends exactly these requests:
  - `translateWithEngines(engines: [])` sends `engine=all`;
  - `TranslationRepository.compare()` batches 2 or more Mozhi engines into one
    comma-separated request.
- **Fix (translation_repository):** stop batching. Send one single-engine
  `translate()` per engine, in parallel. That avoids the crash, and every
  failing engine also gets its real error (see G6). If batching stays, at
  least never send `all` and leave `duckduckgo` out of batches.
- The bug is also worth reporting upstream.

**G2: High. A DeepL failure comes back as 200 with an empty translation.**
- DeepLX reports failures in its result (`Code`/`Message`) rather than as a
  Go error. Mozhi therefore answers `200` with `"translated-text": ""`.
- `MozhiApiClient.translate` returns this as a normal `MozhiTranslation`, so
  the app shows a blank result. In compare mode, `translateWithEngines`
  reports it as a success.
- **Fix (mozhi_api):** when `translatedText.trim()` is empty for non-blank
  input, throw `MozhiApiException('$engine returned an empty translation')`.
  It should be retryable, because DeepLX rate limits are per instance. Drop
  such entries from batch results as well.

**G3: High. DeepL advertises 6 target languages that its own validation
rejects.**
- `libmozhi` checks `to` against the engine's *source* list.
- DeepL's target list adds `en-us`, `en-gb`, `pt-br`, `pt-pt`, `zh-hans` and
  `zh-hant`. Each of these always fails with 500 `Target language code
  invalid`.
- Picking "English (American)" in the app therefore can never work.
- **Fix (translation_repository, `_mozhiLanguages`):** for target lists, map
  ids missing from the engine's source list to their base code (`en-us` to
  `en`, which is already listed), or drop them. All other engines are
  unaffected: their target lists are subsets of their source lists.

**G4: Medium. Deterministic errors are HTTP 500, so the pool fails over on
them.**
- These all come back as 500, which `isRetryable` treats as retryable:
  - unknown engine;
  - invalid language code;
  - an engine without TTS;
  - `Engine X not supported or implemented`;
  - a missing image part.
- `MozhiPool` therefore tries every configured instance before giving up.
  The check showed 2 `/api/translate` calls for 2 instances for
  `to=xx`.
- **Fix (mozhi_api):** make `isRetryable` false for a 500 whose message
  matches one of these:
  - `/language code invalid/i`
  - `Engine does not exist`
  - `not supported or implemented`
  - `doesn't support TTS`
  - `required`
- Messages starting with `Post "`, `Get "`, `ErrTransport:`, `instance has
  been rate limited` or `runtime error:` should stay retryable.

**G5: Medium. Long TTS text exceeds fasthttp's 4 KiB header buffer.**
- `/api/tts` is GET-only and carries the text in the query string.
- The limit is about 3965 ASCII characters, or 440 CJK characters (each is
  9 bytes once URL-encoded).
- Above that the server sends 431 with no CORS header and closes the socket.
  dart:io usually reports `Connection reset by peer`, a *retryable* network
  error. So:
  - every instance is tried;
  - then the Google-to-Reverso fallback repeats the same failure.
- Google's own TTS endpoint accepts only about 200 characters per request
  anyway.
- **Fix (speech or repository):** split the text into chunks of about 200
  characters at sentence or word boundaries, then play or concatenate the MP3
  parts.
- The same shape applies to `/api/translate` bodies over 4 MiB (413 or
  broken pipe). Capping input in the UI is enough there.

**G6: Medium. Batch results drop failures silently.**
- With the upstreams down, a batch answers `200 []`.
- `compare()` then reports each engine as `MozhiApiException(network): Google
  returned no result.`. This loses the real cause, and the
  `statusCode == null` makes it look like a network problem.
- **Fix:** send single-engine requests (as for G1).

**G7: Low. DeepL and Reverso have no `auto` in their source lists.**
- `from=auto` returns 500 `Source language code invalid`.
- The app already handles this: `TranslateCubit._withLanguages` falls back to
  the engine's first source language when `auto` is not offered.
- Keep this in mind for any path that sends `auto` without consulting the
  list. For example, `detectLanguage` hard-codes Google, which is fine.

**G8: Low. Error text is raw Go output.**
- Upstream errors include the upstream URL and query, which for
  Yandex and MyMemory contain the user's text. Example: `Get
  "https://api.mymemory.translated.net/get?langpair=en-AU%7Cfr-BE&q=Hello+world":
  Forbidden`.
- DuckDuckGo failures read `runtime error: invalid memory address or nil
  pointer dereference`.
- **Fix (app):** for 5xx messages matching the patterns above, show a
  friendly "<instance> could not reach <engine>". Keep the raw text behind a
  details toggle, and never log it, because it contains user text.

**G9: Low. Image validation looks only at the declared part type.**
- The server never inspects the bytes, and the client always declares
  `image/png`. JPEG bytes therefore pass the check and fail later.
- `TranslationRepository.translateImage` already rejects mime types other
  than PNG, and `lib/image_translate/data/image_encoder.dart` converts to
  PNG. Keep both.

**G10: Info. MyMemory reuses one id for two languages.**
- `mfi` is both "Malgwa" and "Wandala". `MozhiApiClient` keeps both entries.
  `mapMozhiLanguages` keeps the first, so Wandala cannot be picked.
- This is harmless.

### Doc corrections for `mozhi_api_client.dart` / models (no behaviour change)

- `/api/version` returns `"fiberversion": "2.52.12"`, without a `v` prefix.
  The doc comment in `MozhiVersion` shows `v2.52.5`.
- Most JSON responses *do* send `charset=utf-8`; only `/api/version` omits
  it. Decoding the bytes as UTF-8 stays correct.
- `/api/engines` leaves out `libre` unless `MOZHI_LIBRETRANSLATE_URL` is set.
- `/api/image` ignores `engine`.
- Validation errors are 500, not 4xx (see G4).
- The `MozhiPool` doc says "Non-retryable failures (4xx such as an
  unsupported language)". With the real server, an unsupported language is a
  500.

## Verified OK (no action)

- **Discovery:**
  - `getVersion`, `ping` (15 ms);
  - `normalizeBaseUrl("127.0.0.1:3123/api/")` gives `http://127.0.0.1:3123`;
  - `getEngines` drops `all`/`some` and sorts by display name.
- **Errors:** they map to `MozhiApiException` with the server's exact
  plain-text message and status:
  - 400: required fields;
  - 404: wrong sub-path, `Cannot GET /sub/api/version`;
  - 500: engine and language validation, upstream failures;
  - connection refused gives `statusCode: null` and is retryable.
- **Form encoding:** the POST form survives `&`, `=`, `+`, `%`, newlines,
  quotes and non-ASCII text. DeepL echoes `source_language=en
  target_language=fr`.
- **TTS:** `textToSpeech` uses GET, as the server requires. The repository's
  Google-to-Reverso fallback makes 2 calls and rethrows the Google error.
- **Image:** `translateImage` sends a multipart `image` part with type
  `image/png`. The server's PNG check passes, and its validation and upstream
  errors map correctly.
- **Failover:** with a dead first instance, `getEngines` succeeds through the
  second one, which becomes `activeInstance`.
- **gzip and UTF-8:** handled. Language items match the raw JSON one for one
  for all 7 engines, 14 lists in total.
