# Voice input

Tap the microphone next to the source text (or in conversation mode) and
speak: Mozhi turns your speech into text. Two recognizers can do that;
choose one in **Settings > Read aloud & voice > Voice input > Speech
recognition**.

| | System speech recognition (default) | Offline (Whisper) |
| --- | --- | --- |
| What runs | The recognizer your phone or browser provides. On most Android phones it is Google's | OpenAI's Whisper model on the phone itself, with [whisper.cpp](https://github.com/ggml-org/whisper.cpp) |
| Where your voice goes | Wherever that recognizer sends it, often to Google | Nowhere: it never leaves the phone |
| Needs | A recognizer on the device (de-Googled phones often have none) | A downloaded or imported model (57 MB to 547 MB, plus the 0.9 MB speech detector); Android only |
| Text appears | While you speak | Phrase by phrase while you speak, as soon as you pause (with the speech detector); else when you stop (a "Transcribing…" ring shows meanwhile) |
| Languages | Whatever the recognizer supports on your device | 99 languages ([list](#languages)) |

## System speech recognition

The phone's own speech service (`SpeechRecognizer` on Android, the browser's
speech recognition in the web app). Mozhi does not control where it sends
your voice: on most Android phones it is Google's service, which may
process it on Google's servers. **Prefer on-device speech recognition**
asks it to stay on the phone (Android 12 and later), but that is only a
request: where the phone has no on-device recognizer, Android may still use
the online one. That is why **Offline only** never uses it (see
[below](#privacy-modes)).

## Offline (Whisper)

Whisper recognises speech on the phone, phrase by phrase:

1. Tap the microphone and speak. The ring around it follows your voice.
2. Each time you pause (about half a second), the phrase you just said is
   transcribed while you go on speaking, and its text appears in the source
   field.
3. Tap again to stop, or just stop talking: recording ends after 3 seconds
   of silence, and after a minute at most. Only the last phrase is left to
   transcribe then (a "Transcribing…" ring shows meanwhile); tapping the
   microphone while it transcribes cancels.
4. The text is added to the source field (or sent, in conversation mode).

Phrases are found by a **speech detector**: Silero VAD (MIT License), a
small neural network that whisper.cpp runs on the phone and that hears
speech, not loudness, so a fan, traffic or music do not count as talking.
It is downloaded with the speech model (0.9 MB). Without it (a model
installed before the detector existed: **Transcribe** offers to download
it), loudness decides when you stopped, recording ends after 30 seconds
at most (the length Whisper reads at once) and everything is transcribed
in one go after you stop.

It listens in the source language you picked. With **Detect language**
Whisper detects the language itself, phrase by phrase (less reliable on a
word or two: pick the language when you can). A recording without speech
is not transcribed at all, so silence does not turn into made-up words.

For a lecture, a tour or a meeting, use **Transcribe** (the translate
screen's **More tools**, or the Conversation tab's menu): it listens for as
long as you like and keeps a rolling transcript, one paragraph per phrase
with its time, optionally translated (see
[Transcribe](features.md#transcribe)). It always uses Whisper on Android,
because the system recognizer stops after every pause.

### Models

Download one in **Settings > Read aloud & voice > Voice input > Offline speech
models**. All are multilingual (99 languages); with several installed, tap
the one to use (without a choice, the most accurate installed one is used).

| Model | Whisper model | Download | SHA-1 | Notes |
| --- | --- | --- | --- | --- |
| **Fast** | `tiny` (39 M parameters) | 75 MiB (`ggml-tiny.bin`, 77,691,713 bytes) | `bd577a113a864445d4c299885e0cb97d4ba92b5f` | Quick, also on older phones; makes more mistakes, especially with accents, names and less common languages |
| **Better (compact)** | `base`, quantized (q5_1) | about 57 MiB (`ggml-base-q5_1.bin`) | in the app's catalogue | The same model as Better in less than half the space, about as accurate; faster on newer phones ([Speed](#speed)) |
| **Better** | `base` (74 M parameters) | 142 MiB (`ggml-base.bin`, 147,951,465 bytes) | `465707469ff3a37a2b9b8d8f89f2f99de7299dac` | Noticeably more accurate than Fast, about two to three times slower |
| **Best** | `small` (244 M parameters), quantized (q5_1) | about 181 MiB (`ggml-small-q5_1.bin`) | in the app's catalogue | Clearly more accurate, especially in less common languages; about three times slower than Better. Offered on phones with 4 GB of RAM or more |
| **Large** | `large-v3-turbo` (809 M parameters), quantized (q5_0) | 547 MiB (`ggml-large-v3-turbo-q5_0.bin`) | `e050f7970618a659205450ad97eb95a18d69c9ee` | Close to Whisper's best; for fast phones with 8 GB of RAM or more (offered only there) |
| Speech detector | Silero VAD v6.2.0 | 0.9 MB (`ggml-silero-v6.2.0.bin`, 885,098 bytes) | `470e5d9d094ddba2f0a512cecc3732a252188abd` | Comes with any model; deleted with the last one |

Better (compact), Best and Large are copies of OpenAI's weights quantized
by the whisper.cpp project (smaller numbers for the weights, a little less
precise). They appear in the app once its catalogue lists their exact sizes
and checksums, which are taken from Hugging Face (see
[For contributors](#for-contributors)). A phone with too little memory for
Best or Large (or an Android Go phone) is not offered them: while it
transcribes, Best needs about 0.6 GB and Large about 1 GB. A model you
imported or installed stays listed, so you can use or delete it.

Quality notes: Whisper is strongest in widely spoken languages (English,
Spanish, German, French, ...) and much weaker in languages with little
training data. Fast and Better are small versions of Whisper, so they are
less accurate than cloud recognizers, may mix up similar languages with
**Detect language**, and write Chinese in simplified or traditional
characters unpredictably. Transcribing takes a few seconds; the longer the
recording, the longer it takes.

### Speed

Whisper runs on the phone's processor. Mozhi ships the engine three times
for 64-bit ARM phones and uses the fastest one the phone runs, without any
setting:

| Engine build | Used on | What it adds |
| --- | --- | --- |
| Baseline | Every 64-bit ARM phone (Cortex-A53 and later) | NEON |
| Dot product | Phones whose cores are all Cortex-A55/A75 or newer (most mid-range and flagship phones from 2019 on, for example Snapdragon 845 and 855, Google Tensor and G2, most Dimensity chips; budget chips with Cortex-A53 or A73 cores keep the baseline) | Int8 dot products (the quantized models) and half-precision arithmetic (the others) |
| Int8 matrix | Phones with ARMv9 cores (from 2022: Snapdragon 8 Gen 1 and later, Google Tensor G3 and later, Dimensity 9000 and later) | The above and int8 matrix multiplication |

A build is used only if every core of the processor supports it (some
phones mix cores of different generations); if it cannot be loaded, the
baseline is. If a faster build ever stopped the app (a phone that reports
processor features it doesn't really have), Mozhi notices it at the next
start and tries that build once more (Android may have closed the app for
another reason, such as low memory); if it stops the app a second time in
a row, Mozhi turns it off for good and uses the baseline. **Settings >
Read aloud & voice > Voice input** names the build in use (**Engine
build: i8mm**, `dotprod` or `baseline`, and why when a faster one was
turned off), for support. The quantized models (Better (compact), Best, Large) gain the
most. The aim is transcriptions about 1.5 to 3 times faster on such phones;
phone measurements are still to come. On a desktop x86-64 processor (a Xeon
with AVX-512), a build for that processor runs Fast's 30-second window about
7 times faster than the portable baseline (0.6 s instead of 4.5 s, two
threads; that baseline is what x86_64 Android devices, emulators and
Chromebooks use).

### Where the models come from

The models are OpenAI's Whisper weights (MIT License) converted to the
format whisper.cpp reads by the whisper.cpp project, downloaded from
**Hugging Face** ([huggingface.co/ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp));
the speech detector is Silero VAD (MIT License, Silero Team) converted by
the whisper.cpp project too ([huggingface.co/ggml-org/whisper-vad](https://huggingface.co/ggml-org/whisper-vad)):

- `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin`
- `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin`
- `https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin`

They come from the model source in **Settings > Translation engines >
Model source**: the publishers (Hugging Face, by default), this web server,
or a mirror of your own (see
[Mirror the on-device models](self-hosting-mozhi.md#mirror-the-on-device-models));
a mirror needs no trust, as every file is checked as described below.

A model is downloaded only when you tap its download button. Mozhi first
checks that the phone has room for it: its size plus a margin of 5 % (at
least 50 MB); otherwise nothing is downloaded and the settings say how
much is needed (**Not enough free space for Best: needs 231 MB, 120 MB
free.**). With **Download over Wi-Fi only** on (the setting on **Settings >
Translation engines > Offline languages**, on by default) Mozhi then asks
on mobile data or a metered network. An interrupted download resumes where
it stopped (and only needs room for the rest). Every file is checked
against its size, the SHA-1 published by whisper.cpp and its SHA-256 (all
bundled with the app) before it is used, in the background so the app
stays smooth, and installed in one step, so a model is either complete or
absent. Hugging Face (or the mirror)
sees your IP address and which model you download, nothing else (see
[Privacy](privacy.md)).

### Import from files

To install a model without the app going online (for example in
**Offline only**), download `ggml-tiny.bin` or `ggml-base.bin` (and
`ggml-silero-v6.2.0.bin`, the speech detector) from the links above on
another device (**Copy download links** copies the links), copy the files
to the phone and choose **Import from files**. Renamed copies are
recognised by their size and checksum; damaged files are refused. The
picked files are only read, never changed: Mozhi reads them where they
are (Android's document picker) and copies each one once, straight into
the models folder, after checking its name, size and the free space (no
copy in the app's cache first).

### Languages

Afrikaans, Albanian, Amharic, Arabic, Armenian, Assamese, Azerbaijani,
Bashkir, Basque, Belarusian, Bengali, Bosnian, Breton, Bulgarian, Catalan,
Chinese, Croatian, Czech, Danish, Dutch, English, Estonian, Faroese,
Finnish, French, Galician, Georgian, German, Greek, Gujarati, Haitian
Creole, Hausa, Hawaiian, Hebrew, Hindi, Hungarian, Icelandic, Indonesian,
Italian, Japanese, Javanese, Kannada, Kazakh, Khmer, Korean, Lao, Latin,
Latvian, Lingala, Lithuanian, Luxembourgish, Macedonian, Malagasy, Malay,
Malayalam, Maltese, Maori, Marathi, Mongolian, Myanmar (Burmese), Nepali,
Norwegian, Norwegian Nynorsk, Occitan, Pashto, Persian, Polish,
Portuguese, Punjabi, Romanian, Russian, Sanskrit, Serbian, Shona, Sindhi,
Sinhala, Slovak, Slovenian, Somali, Spanish, Sundanese, Swahili, Swedish,
Tagalog (Filipino), Tajik, Tamil, Tatar, Telugu, Thai, Tibetan, Turkish,
Turkmen, Ukrainian, Urdu, Uzbek, Vietnamese, Welsh, Yiddish and Yoruba.

For other source languages (Cantonese, for example), Whisper detects the
language.

## Privacy modes

| Privacy mode | Voice input uses |
| --- | --- |
| **Online**, **Offline first** | The recognizer you chose. With **System speech recognition** on a phone without any recognizer, Whisper is used automatically when a model is installed |
| **Offline only** | Whisper only, whatever you chose: the system recognizer is never used, because it may send your voice to Google (Android cannot promise on-device recognition). Without a model, the microphone explains how to get one; in the web app there is no voice input in this mode |

**Settings > Read aloud & voice > Voice input** says so when Offline only is
on.

## Good to know

- **Web app:** only the browser's speech recognition; Whisper runs in the
  Android app only.
- **Supported phones:** Whisper runs on 64-bit ARM and x86_64 Android
  devices and on 32-bit ARM devices with NEON and VFPv4 (almost all of
  them); elsewhere the offline option is not offered. Newer 64-bit ARM
  phones get a faster build of the engine automatically ([Speed](#speed)).
- **Storage:** the models are kept in the app's private storage (not in
  backups) until you delete them; **Delete all local data** removes them
  too.
- **Microphone:** Whisper records with Android's own `AudioRecord` (no
  Google code); the recording stays in memory, phrase by phrase, and each
  phrase is dropped once it is transcribed.

## When the mic doesn't start

- **A ring spins on the mic:** voice input is starting. Some Android
  recognisers never tell the app which languages they support; after a
  few seconds the app starts listening anyway and asks for the language
  you chose (German as `de-DE`). Tap the mic again to cancel.
- **The mic is crossed out:** voice input can't be used right now. Tap it
  to see why: the microphone permission was denied (tap again to be asked
  once more, or allow it in Android's app settings), or the phone has no
  speech recognition service (common without Google apps). Then use
  **Download model** to get the offline Whisper model
  (**Settings > Read aloud & voice > Voice input**); it works on every
  supported phone.

## For contributors

The engine is the `packages/whisper_speech` package: whisper.cpp v1.9.5 as a
pinned submodule, built into `libmozhi_whisper.so` with ggml's CPU backend
only (on arm64-v8a also `libmozhi_whisper_dotprod.so`,
`armv8.2-a+dotprod+fp16`, and `libmozhi_whisper_i8mm.so`,
`armv8.6-a+dotprod+fp16+i8mm`: Dart reads `/proc/cpuinfo`
(`ArmCpuFeatures`, a feature counts when every core lists it), loads the
best one and falls back to the baseline when it does not open or reports
another ABI version; see the package README's "CPU variants"; a
`CpuVariantGuard` writes `whisper_cpu_variant.<role>.marker` in the support
directory while a faster build is probed and runs its first transcription
or speech detection, one marker per engine isolate; a marker of a process
that died, found at the next start, counts as a crash of the build in
`whisper_cpu_variants.json` (once per dead process, however many of its
isolates left one), and the build is turned off for good after
`CpuVariantGuard.crashLimit` (2) crashes in a row with no successful first
computation in between, which clears the count. One crash isn't enough:
the process may have been killed for another reason (the low-memory
killer, a force stop, a reboot for an update), which would turn a working
build off for good, while a build the CPU really can't run dies with an
illegal instruction on every try, so the second chance costs such a phone
one extra crash at most. Only the guarded library names are read from the
JSON, and a damaged or oversized file counts as empty and is written
again; `whisperEngineBuild()` names the build for the settings),
the model catalogue (the speech models and the `kind: vad` entry),
the verified model manager and the Dart FFI engine in a background isolate,
with Silero VAD (`mozhi_whisper_vad_*`) in another isolate so it keeps up
with the microphone while a phrase is transcribed. See its
[README](../packages/whisper_speech/README.md) for the native build and the
tests. In the app, `WhisperSpeechRecognizerAdapter` (`lib/voice/offline/`)
plugs Whisper into `SpeechInputService`, which picks the recognizer for
each session. With the speech detector, `PhraseTranscriber` classifies the
microphone 32 ms at a time (`SileroSpeechClassifier`, falling back to
`LoudnessSpeechClassifier`), `UtteranceSegmenter` cuts phrases at 400 ms
pauses (with 200 ms of padding, dropping blips under 160 ms, at most 25 s
each) and each phrase is transcribed as soon as it is cut; the text so far
arrives as partial results. Transcribe (`lib/transcribe/`) uses the same
pipeline without the end-of-utterance stop.

The quantized models' catalogue entries come from
`tool/whisper_catalog.py resolve`: it pins Hugging Face's current commit,
takes each file's size and SHA-256 from its API, downloads the file to
compute the SHA-1 (and compares whisper.cpp's README SHA-1 where it lists
one) and prints the entries with their `minRamMb` (3000 for Best, 7000 for
Large: below that RAM, `WhisperCatalogModel.fitsMemory` keeps the app from
offering them; `OfflineSpeech.fits` with `DeviceMemory`). Only CI reaches
Hugging Face, so the job "Check model downloads" prints them for a
maintainer to add (`resolve --write` merges them in catalogue order where
Hugging Face is reachable); `tool/whisper_catalog_test.py` tests it against
a local fixture server. `GGML_CPU_REPACK` stays off: ggml repacks Q4, Q8
and K-quant weights, not q5_0/q5_1 (on x86-64 the two builds measured the
same with a q5_1 model).
