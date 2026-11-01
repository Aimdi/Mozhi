# mozhi (command line)

Translate from the terminal with self-hosted [Mozhi](https://codeberg.org/aryak/mozhi)
instances (Google, DeepL, Yandex, Reverso, LibreTranslate, MyMemory,
DuckDuckGo) and AI providers (OpenAI-compatible APIs, Anthropic, Gemini and
Ollama, including local models), with Kagi Translate style controls:
formality, style, reading level, context and glossaries.

It is a companion to the [Mozhi app](../../README.md) and uses the same
`translation_repository` package, so engines, languages and prompts behave
the same way. Nothing is sent anywhere except to the instance or provider you
pick; there is no telemetry and no update check.

## Install

Requires the Dart SDK (3.13 or later).

```sh
# From a clone of the repository
dart pub global activate --source path packages/mozhi_cli
mozhi --help

# Or build a standalone binary
cd packages/mozhi_cli
dart compile exe bin/mozhi.dart -o mozhi
```

Shell completion is never installed behind your back. To set it up, run
`mozhi install-completion-files` once (bash, zsh and fish).

## Translate

```sh
# Text as arguments; the source language is detected
mozhi translate "Bonjour le monde" --to en
# Hello world

# Or piped in (stdin), with another engine
echo "Guten Morgen" | mozhi translate --to ja --engine deepl

# Language codes or English names both work
mozhi translate -f Japanese -t pt-BR "おはようございます"

# Pick an instance for one call
mozhi translate -i https://mozhi.adminforge.de -t de "See you tomorrow"
```

On a terminal a short summary is printed to stderr after the translation
(detected language, engine, instance, time). Piped output only contains the
translation, so `mozhi translate -t fr < notes.txt > notes.fr.txt` works as
expected.

### Compare engines

```sh
# Every engine the Mozhi instance offers, side by side
mozhi translate --compare --to es "How are you?"

# Or just the ones you name (AI engines included)
mozhi translate -c -e google -e deepl -e ai:claude -t es "How are you?"
```

### AI translation

Add a provider once (see [AI providers](#ai-providers)), then:

```sh
mozhi translate --engine ai --to de "See you tomorrow"     # first provider
mozhi translate -e ai:claude -t fr --formality more "Can you send me the file?"
mozhi translate -e ai -t en --style literal --reading-level a2 < article.txt
mozhi translate -e ai -t es --context "message to my landlord" "The heating is broken"
mozhi translate -e ai -t de -g "cloud=Cloud" -g "server=Server" "Our cloud server is down"
mozhi translate -e ai -t "Pirate speak" "Where is the treasure?"   # free-form targets
```

| Option | Values |
| --- | --- |
| `--formality` | `automatic`, `more`, `less`, `prefer-more`, `prefer-less` |
| `--style` | `natural`, `literal` |
| `--reading-level` | `standard`, `a1`, `a2`, `b1`, `b2`, `c1`, `c2` (CEFR) |
| `--context` | free text describing the situation or audience |
| `-g`, `--glossary` | `term=translation`, repeatable |
| `--glossary-file` | one `term=translation` (or tab-separated) entry per line, `#` comments |
| `--instructions` | one-off instruction, e.g. `"Keep it under 10 words"` |

AI output streams to the terminal as it is generated (`--no-stream` turns
that off); when piped, only the final, cleaned-up text is printed.

### JSON

Every listing and translation command takes `--json`:

```sh
mozhi translate --json -t en "Hola" | jq -r .text
mozhi translate --json -t ja "Good morning"   # includes transliterations, word choices, synonyms
mozhi translate --compare --json -t de "Hello" | jq '.[] | select(.ok) | .text'
```

## Proofread (AI)

```sh
mozhi proofread "Their going to the libary tomorow."
mozhi proofread --style email --level comprehensive < draft.txt
mozhi proofread --tone diplomatic "Your plan won't work."
mozhi proofread -q < draft.txt > fixed.txt      # corrected text only
```

## Detect a language

```sh
mozhi detect "Dobrý den"            # cs	Czech (via the Mozhi instance)
mozhi detect -e ai "Zdravo, kako si?"
```

## Engines, languages and instances

```sh
mozhi engines                        # Mozhi engines of the instance + AI providers
mozhi languages --engine deepl       # target languages
mozhi languages --engine google --source chin   # filtered source languages
mozhi instances list                 # public instances (and your configured one)
mozhi instances ping                 # translation speed table, fastest first
mozhi instances ping https://translate.example.org --timeout 5
mozhi instances ping --engine deepl  # test another Mozhi engine
```

Without a configured instance, translations go to the public instances in
order and fail over to the next one when an instance is down.

`instances ping` translates the word "Hello" (and nothing else) from English
to French on each instance, with the configured Mozhi engine or Google, and
times it: a server that answers but doesn't translate with that engine is
listed as `doesn't translate`, not as fast.

## Configuration

Settings live in `$XDG_CONFIG_HOME/mozhi/config.json` (by default
`~/.config/mozhi/config.json`; `%APPDATA%\mozhi\config.json` on Windows). Use
`--config <file>` or `MOZHI_CONFIG` to choose another file.

```sh
mozhi config show
mozhi config set instance https://mozhi.example.org
mozhi config set engine deepl
mozhi config set target de
mozhi config set source auto
mozhi config unset instance
mozhi config path
```

### AI providers

```sh
# Local models (no key needed)
mozhi config providers add --preset ollama --model gemma3 --default
mozhi config providers add --preset lmstudio           # picks the loaded model

# Hosted models: keep the key in an environment variable...
mozhi config providers add --preset anthropic --api-key-env ANTHROPIC_API_KEY
# ...or store it in the config file (read from stdin, or typed at a hidden prompt)
pass show openai | mozhi config providers add --preset openai --api-key-stdin

# Any OpenAI-compatible server
mozhi config providers add --protocol openai --name vLLM \
  --base-url http://gpu.lan:8000/v1 --model qwen3

mozhi config providers list
mozhi config providers test claude
mozhi config providers models ollama
mozhi config providers remove claude
```

Presets: `openai`, `anthropic`, `gemini`, `openrouter`, `groq`, `deepseek`,
`mistral`, `xai`, `together`, `ollama`, `lmstudio`, `llamacpp`, `custom`
(see `mozhi config providers add --help`).

The configuration file is written atomically and, on Linux and macOS,
restricted to its owner (mode `0600`, directory `0700`) before any key is
written. `mozhi config show` warns if the permissions were loosened, and API
keys are never printed (not even with `--verbose`).

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success |
| 64 | Usage error: unknown option, missing text, unsupported language, ... |
| 66 | A file given on the command line (e.g. `--glossary-file`) cannot be read |
| 69 | The Mozhi instance or AI provider failed or could not be reached |
| 70 | Internal error (run with `--verbose` for a stack trace) |
| 78 | The configuration file is invalid or cannot be written |

Errors are printed to stderr together with a hint on how to fix them, e.g.

```text
$ mozhi translate -e yandex -t de "Hello"
Mozhi instance error (HTTP 500) from mozhi.example.org: Engine does not exist or has been disabled.
This engine is disabled on the instance; list the available ones with: mozhi engines
```

## Development

```sh
cd packages/mozhi_cli
dart pub get
dart analyze
very_good test --coverage
dart run bin/mozhi.dart translate "Hallo Welt" -t en
```

Commands live in `lib/src/commands/`; they talk to the network only through
`TranslationRepository` and to the terminal through `Logger` and `Console`,
which the tests replace with mocks.
