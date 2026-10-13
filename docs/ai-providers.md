# AI providers

Mozhi can translate with large language models (LLMs), the same way Kagi
Translate does: natural, context-aware translations with options for tone and
reading level, custom styles, alternatives, word insights, explanations and a
dictionary. You bring the model: a cloud API with your own key, or a model
running on your own computer.

- [How it works](#how-it-works)
- [Adding a provider](#adding-a-provider)
- [Cloud providers](#cloud-providers)
- [What it costs](#what-it-costs)
- [Local models](#local-models)
- [Which local model?](#which-local-model)
- [Privacy: local vs cloud](#privacy-local-vs-cloud)
- [Troubleshooting](#troubleshooting)

## How it works

- The app talks to the provider **directly** from your device. There is no
  Mozhi server in between, no account and no proxy.
- Four API types are supported: **OpenAI-compatible** (also used by most other
  providers and local servers), **Anthropic**, **Google Gemini** and the
  native **Ollama** API. Answers are streamed, so text appears as it is
  written.
- API keys are kept in the platform's secure storage (the Android Keystore,
  the Apple Keychain, or the equivalent on other platforms; the web app uses
  the browser's storage for the site) and sent only to the provider they
  belong to. They are never written to the settings file or to exports.
- The text to translate is marked as data in the prompt, so models treat
  instructions hidden in it ("ignore the above and...") as text to translate
  rather than as commands.
- Reasoning ("thinking") output of models that produce it is hidden; you only
  see the translation.
- Extras (alternatives, insights, explanations, dictionary, refinement
  suggestions) are separate requests, made only when you open them.
  **Instant translate with AI** is off by default because every pause in
  typing would cost a request; turn it on under **Settings** if you like.

## Adding a provider

1. **Settings > AI providers > Add provider**, then choose a preset.
2. Fill in the editor:

   | Field | Notes |
   | --- | --- |
   | Name | Shown in the engine list, e.g. "Claude" or "Home GPU". |
   | Provider type | Set by the preset; change it only for custom servers. |
   | Base URL | Set by the preset. For local servers replace `localhost` with the computer's LAN address. |
   | API key | Required by cloud providers; optional for local servers. **Get an API key** opens the provider's key page. |
   | Model | The preset suggests one. **Browse models** lists what your key or server offers. |
   | Reasoning effort | For models that think before answering: **Low** is fastest and is the right choice for translation. |
   | Temperature | Leave it on the model's default unless you know you want something else. Not shown for Anthropic, whose current models don't accept it. |
   | Supports images | Turn on for vision models to translate photos and screenshots with them. |

3. **Test connection** sends "Hello, world!" for translation into French and
   shows the answer. Then **Save**.
4. Choose the model with the engine button on the Translate tab. Several
   providers can be enabled at once; switch between them per translation, or
   compare them side by side.

Providers on your own machine or network are marked **Local** in the engine
list; the others are marked **Cloud**. If you enter a plain `http://` address
that is not on your local network, the editor warns you that your text and
API key would travel unencrypted.

## Cloud providers

| Preset | Base URL | Default model | Get a key |
| --- | --- | --- | --- |
| OpenAI | `https://api.openai.com/v1` | `gpt-5-mini` | [platform.openai.com/api-keys](https://platform.openai.com/api-keys) |
| Anthropic | `https://api.anthropic.com/v1` | `claude-opus-5-5` | [console.anthropic.com/settings/keys](https://console.anthropic.com/settings/keys) |
| Google Gemini | `https://generativelanguage.googleapis.com/v1beta` | `gemini-flash-latest` | [aistudio.google.com/apikey](https://aistudio.google.com/apikey) |
| OpenRouter | `https://openrouter.ai/api/v1` | `openrouter/auto` | [openrouter.ai/keys](https://openrouter.ai/keys) |
| Groq | `https://api.groq.com/openai/v1` | `openai/gpt-oss-120b` | [console.groq.com/keys](https://console.groq.com/keys) |
| DeepSeek | `https://api.deepseek.com/v1` | `deepseek-chat` | [platform.deepseek.com/api_keys](https://platform.deepseek.com/api_keys) |
| Mistral AI | `https://api.mistral.ai/v1` | `mistral-large-latest` | [console.mistral.ai/api-keys](https://console.mistral.ai/api-keys) |
| xAI | `https://api.x.ai/v1` | `grok-4` | [console.x.ai](https://console.x.ai) |
| Together AI | `https://api.together.xyz/v1` | `meta-llama/Llama-3.3-70B-Instruct-Turbo` | [api.together.ai/settings/api-keys](https://api.together.ai/settings/api-keys) |

Model names change often. If a default stops working, use **Browse models**.
Prices change too; check each provider's pricing page before relying on the
notes below.

### OpenAI

GPT models. `gpt-5-mini` (default) is a good balance of quality, speed and
price for translation; `gpt-5` is stronger and slower, `gpt-5-nano` cheaper.
The preset sets reasoning effort to **Low** for speed. API usage is billed
separately from a ChatGPT subscription and needs prepaid credit.

### Anthropic (Claude)

- `claude-opus-5-5` (default): the strongest Claude model, excellent at
  nuance, idioms and tone.
- `claude-sonnet-5-5`: about half the price of Opus, still very good.
- `claude-haiku-5-5`: by far the cheapest and fastest; fine for everyday
  translation.

The preset sets **Reasoning effort** to **Low**, which keeps translations fast
and cheap (Claude Opus 5.5 would otherwise default to medium); raise it for
difficult literary text or for **Explain**. Mozhi never sends a temperature to
Anthropic, since current Claude models don't accept one. Billing is prepaid
credit in the Anthropic Console. The web app works with Anthropic too.

### Google Gemini

`gemini-flash-latest` (default) is fast and inexpensive and handles a very
wide range of languages; `gemini-pro-latest` is stronger, and
`gemini-flash-lite-latest` cheaper still. Keys come from Google AI Studio,
which has a free tier with rate limits. Note that on the free tier Google may
use your prompts to improve its products (see the
[Gemini API terms](https://ai.google.dev/gemini-api/terms)); a billed project
avoids this.

### OpenRouter

One key and one bill for hundreds of models from many providers, including
Claude, GPT, Gemini, Llama, Qwen and DeepSeek. Use `vendor/model` names
(`anthropic/claude-sonnet-5-5`, `openai/gpt-5-mini`, ...) or keep
`openrouter/auto` and let OpenRouter choose. Model prices are passed through,
with a small fee when you buy credits. Some models are offered for free with
tight rate limits; free endpoints may log prompts, so check the model's page.

### Groq

Very fast inference of open models on Groq's own hardware: translations
appear almost instantly. The default is `openai/gpt-oss-120b`;
`openai/gpt-oss-20b` and `llama-3.3-70b-versatile` are alternatives. There is
a free tier with rate limits.

### DeepSeek

Inexpensive and particularly strong in Chinese. `deepseek-chat` (default) is
the fast model; `deepseek-reasoner` thinks first, which is slower and rarely
needed for translation. DeepSeek processes data in China; see its privacy
policy.

### Mistral AI

European (French) provider. `mistral-large-latest` (default) is the strongest
model, `mistral-medium-latest` and `mistral-small-latest` cheaper. Mistral
offers a free experimentation plan with rate limits.

### xAI

Grok models (`grok-4` by default). Billed per use from prepaid credit.

### Together AI

Hosted open models such as Llama, Qwen and DeepSeek, with pay-as-you-go
pricing. Use the full model id shown in Together's model list, e.g.
`meta-llama/Llama-3.3-70B-Instruct-Turbo`.

### Anything else

**Custom (OpenAI-compatible)** works with any server that implements
`/v1/chat/completions` with a Bearer key: Fireworks, Cerebras, LiteLLM,
LocalAI, Jan, vLLM and so on. Enter the base URL up to and
including `/v1` and, if needed, a key.

## What it costs

Cloud AI is billed per token (roughly ¾ of an English word). A translation
costs the instructions (a few hundred tokens) plus your text, and the
translation itself as output; models that reason also bill their thinking as
output.

As an example, translating a 100-word paragraph is about 1,000 input tokens
and 300 output tokens. With Anthropic's prices as of October 2026 that is:

| Model | Price per million tokens (input / output) | One paragraph |
| --- | --- | --- |
| `claude-opus-5-5` | $4 / $20 | about 1 cent |
| `claude-sonnet-5-5` | $2 / $10 | about 0.5 cents |
| `claude-haiku-5-5` | $0.10 / $0.50 | about 0.03 cents |

Other providers' small and mid-sized models are in the same range as the
cheaper rows. What adds up:

- **Instant translate with AI** sends a request every time you pause typing.
- **Compare mode** runs every selected engine at once.
- **Extras** (insights, alternatives, explain, dictionary, suggestions) are one
  request each; Insights, once switched on, reloads for every translation.
- Higher **reasoning effort** means more thinking tokens.

Mozhi engines, offline models and local AI cost nothing per request.

## Local models

A model on your own computer keeps your text entirely on hardware you control
and costs nothing per translation. The app connects to it over your network,
so the computer must be on and reachable.

**The one rule:** on a phone or tablet, `localhost` is the phone itself. Use
the computer's LAN address, such as `http://192.168.1.20:11434`, and make the
server listen on the network instead of only on `localhost`. Allow the port in
the computer's firewall if needed. On the computer itself (desktop app),
`localhost` works.

Find the computer's address with `ipconfig` (Windows), `ipconfig getifaddr
en0` (macOS) or `ip -4 addr` (Linux).

> Local servers usually have no password: anyone on your network can use
> them. That's fine at home; on shared networks keep them on `localhost`, use
> a VPN such as WireGuard or Tailscale, or put them behind a reverse proxy
> that checks an API key (see `deploy/Caddyfile`).

### Ollama

[Ollama](https://ollama.com) is the easiest way to run models locally. Use the
**Ollama** preset; it speaks Ollama's native API, so the base URL has **no**
`/v1`: `http://<computer-ip>:11434`.

1. Install Ollama and download a model, e.g. `ollama pull translategemma:4b`
   or `ollama pull gemma3:12b`.
2. Make it listen on the network by setting `OLLAMA_HOST=0.0.0.0`:
   - **Linux (systemd):** `sudo systemctl edit ollama.service`, add

     ```ini
     [Service]
     Environment="OLLAMA_HOST=0.0.0.0"
     ```

     then `sudo systemctl restart ollama`.
   - **macOS:** `launchctl setenv OLLAMA_HOST "0.0.0.0"`, then quit and
     reopen the Ollama app.
   - **Windows:** add a user environment variable `OLLAMA_HOST` with value
     `0.0.0.0` (Settings > System > About > Advanced system settings >
     Environment Variables), then quit Ollama from the tray and start it
     again.
   - **Manually:** `OLLAMA_HOST=0.0.0.0 ollama serve`.
   - **Docker:** `docker compose --profile ai up -d` in
     [`deploy/`](../deploy/README.md) does this for you.
3. In the app, add the Ollama preset with `http://<computer-ip>:11434` and pick
   the model with **Browse models**.

For the **web app**, the browser also needs permission: set `OLLAMA_ORIGINS`
to the web app's origin (e.g. `https://translate.example.com`) or `*`, the
same way as `OLLAMA_HOST`. The native apps don't need this.

Tips: the first request after a model was unloaded takes a few seconds while
it loads; `OLLAMA_KEEP_ALIVE=30m` keeps it in memory longer. Long texts need a
larger context window than some Ollama versions use by default; set
`OLLAMA_CONTEXT_LENGTH=8192` or more.

### LM Studio

[LM Studio](https://lmstudio.ai) is a desktop app with a model browser and an
OpenAI-compatible server.

1. Download a model in LM Studio.
2. Open the **Developer** tab, start the server (port **1234** by default)
   and, in its settings, turn on **Serve on Local Network**. For the web app
   also turn on **Enable CORS**.
3. In Mozhi, use the **LM Studio** preset with base URL
   `http://<computer-ip>:1234/v1` and pick the model with **Browse models**.

### llama.cpp server

`llama-server` from [llama.cpp](https://github.com/ggml-org/llama.cpp) serves a
GGUF model with an OpenAI-compatible API:

```sh
llama-server -m model.gguf --host 0.0.0.0 --port 8080 --jinja -c 8192 -ngl 99
# or let it download a model from Hugging Face:
llama-server -hf ggml-org/gemma-3-12b-it-GGUF --host 0.0.0.0 --port 8080 --jinja
```

`--host 0.0.0.0` makes it reachable from your phone, `-c` sets the context
size and `-ngl 99` offloads all layers to the GPU. Add `--api-key <key>` to
require a key (enter the same key in the app). Use the **llama.cpp server**
preset with `http://<computer-ip>:8080/v1`.

### vLLM

[vLLM](https://docs.vllm.ai) is a high-throughput server for NVIDIA and AMD
GPUs, good for a shared household or team server:

```sh
vllm serve Qwen/Qwen3-14B --host 0.0.0.0 --port 8000 --api-key <key>
```

Use the **Custom (OpenAI-compatible)** preset with
`http://<server-ip>:8000/v1`, the key, and the model name exactly as passed to
`vllm serve`.

## Which local model?

There are two kinds of models to choose from:

- **Translation-specialised models**, such as Tencent's **Hy-MT2** and
  Google's **TranslateGemma**, are trained to do one thing: translate. They
  are excellent for their size and fast. They ignore most of the translation
  options and do not produce the extras (alternatives, insights, explanations,
  dictionary, proofreading), because those need a model that follows general
  instructions and writes structured answers.
- **General instruction models**, such as **Qwen3** and **Gemma 3**, translate
  well from about 12B parameters and also handle every Kagi-style extra, the
  options, custom styles like *Pirate speak*, and the Proofread tab.

A practical setup is a translation model for everyday use plus a general model
as a second provider for when you want extras. When your main engine is a
Mozhi engine, extras use the model chosen under **Settings > AI assistant for
insights**.

| Your hardware | Translation model | General model (extras) |
| --- | --- | --- |
| No GPU, or ≤ 6 GB VRAM; 8 GB RAM | `Hy-MT2-1.8B`, `translategemma:4b` | `gemma3:4b`, `qwen3:4b` (extras work, less reliably) |
| 8-12 GB VRAM (e.g. RTX 3060/4060, Apple M-series with 16 GB) | `Hy-MT2-7B`, `translategemma:12b` | `gemma3:12b`, `qwen3:14b` |
| 24 GB+ VRAM (e.g. RTX 3090/4090, Apple M-series with 32 GB+) | `translategemma:27b` | `gemma3:27b`, `qwen3:32b` |

Notes:

- Names with a colon are Ollama tags (`ollama pull translategemma:12b`).
  `translategemma:12b` is about an 8 GB download; on an 8 GB card a little of
  it runs on the CPU, which is slower but works. `translategemma:27b` is
  about 17 GB.
- **Hy-MT2** (Apache 2.0, 33 languages) is published by Tencent on Hugging
  Face, including GGUF builds such as `tencent/Hy-MT2-7B-GGUF` for llama.cpp
  and LM Studio. Some of its quantisations need a recent llama.cpp, and the
  model card lists recommended sampling settings.
- **TranslateGemma** (4B, 12B and 27B, built on Gemma 3) covers 55 languages
  and can read text in images, so you can turn on **Supports images** for
  it.
- On Apple Silicon, unified memory counts as VRAM (leave a few GB for the
  system). Without a GPU, small models still run at a usable speed on a
  modern CPU.
- Qwen3 models think before answering by default. The app hides the thinking,
  but it makes translations slower; Gemma 3 answers directly.
- The 4-bit quantisations (`Q4_K_M`, Ollama's default) are the usual sweet
  spot. Use `Q8_0` if you have memory to spare.

## Privacy: local vs cloud

| | Local model | Cloud provider |
| --- | --- | --- |
| Who receives your text | Only your computer | The provider (and, with OpenRouter, the provider it routes to) |
| Stored or used for training | Never leaves your hardware | Depends on the provider's terms; most paid APIs don't train on API data by default, some free tiers do |
| Works offline / on a plane | Yes, if the server is on the same network (e.g. a laptop hotspot) | No |
| Account or key | None | Required |
| Cost | Hardware and electricity | Per token |
| Quality | Very good at 12B+ for common languages; specialised models are excellent | Best for rare languages, literary text and long documents |

Whatever you choose, the app itself sends nothing anywhere else; see
[Privacy](privacy.md).

## Troubleshooting

**"The AI provider rejected the request"** (401/403): the API key is wrong,
expired or has no credit left. Paste it again and use **Test connection**.

**"Model or endpoint not found"** (404): the model name is misspelled or not
available to your key, or the base URL is wrong. Use **Browse models**. Base
URLs of OpenAI-compatible servers end in `/v1`; Ollama's native URL does not.

**"Couldn't reach the AI provider"**: for local servers, check that the
server listens on `0.0.0.0` (not just `localhost`), that you used the
computer's LAN address, that the firewall allows the port, and that phone and
computer are on the same network. `curl http://<computer-ip>:11434/api/tags`
(Ollama) or `curl http://<computer-ip>:1234/v1/models` (LM Studio) from
another device tells you whether the server is reachable.

**The web app can't reach a local server**: the browser needs CORS permission
(`OLLAMA_ORIGINS`, LM Studio's **Enable CORS**), and a web app served over
`https` cannot call `http` addresses other than `localhost`.

**The first translation is slow**: the server is loading the model into
memory. Later requests are fast until it unloads the model again.

**Extras fail or return nonsense**: small or translation-only models struggle
with the structured answers extras need. Use a general model of 12B or more,
or a cloud model, for extras.

**"The model declined to translate this text"**: some models refuse content
they consider sensitive even when only asked to translate it. Try another
model.
