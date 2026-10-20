# Voice input

Tap the microphone next to the source text (or in conversation mode) and
speak: Mozhi turns your speech into text. Two recognizers can do that;
choose one in **Settings > Voice input > Speech recognition**.

| | System speech recognition (default) | Offline (Whisper) |
| --- | --- | --- |
| What runs | The recognizer your phone or browser provides. On most Android phones it is Google's | OpenAI's Whisper model on the phone itself, with [whisper.cpp](https://github.com/ggml-org/whisper.cpp) |
| Where your voice goes | Wherever that recognizer sends it, often to Google | Nowhere: it never leaves the phone |
| Needs | A recognizer on the device (de-Googled phones often have none) | A downloaded or imported model (75 or 142 MB); Android only |
| Text appears | While you speak | When you stop (a "Transcribing…" ring shows meanwhile) |
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

Whisper recognises speech on the phone after you stop talking:

1. Tap the microphone and speak. The ring around it follows your voice.
2. Tap again to stop, or just stop talking: recording ends after 3 seconds
   of silence, and after 30 seconds at most (the length Whisper reads at
   once). Tapping the microphone while it transcribes cancels.
3. The text is added to the source field (or sent, in conversation mode).

It listens in the source language you picked. With **Detect language**
Whisper detects the language itself (less reliable on a word or two:
pick the language when you can). A recording without speech is not
transcribed at all, so silence does not turn into made-up words.

### Models

Download one in **Settings > Voice input > Offline speech models**. Both
are multilingual (99 languages); with both installed, tap the one to use.

| Model | Whisper model | Download | SHA-1 | Notes |
| --- | --- | --- | --- | --- |
| **Fast** | `tiny` (39 M parameters) | 75 MiB (`ggml-tiny.bin`, 77,691,713 bytes) | `bd577a113a864445d4c299885e0cb97d4ba92b5f` | Quick, also on older phones; makes more mistakes, especially with accents, names and less common languages |
| **Better** | `base` (74 M parameters) | 142 MiB (`ggml-base.bin`, 147,951,465 bytes) | `465707469ff3a37a2b9b8d8f89f2f99de7299dac` | Noticeably more accurate, about two to three times slower |

Quality notes: Whisper is strongest in widely spoken languages (English,
Spanish, German, French, ...) and much weaker in languages with little
training data. Both models are small versions of Whisper, so they are less
accurate than cloud recognizers, may mix up similar languages with
**Detect language**, and write Chinese in simplified or traditional
characters unpredictably. Transcribing takes a few seconds; the longer the
recording, the longer it takes.

### Where the models come from

The models are OpenAI's Whisper weights (MIT License) converted to the
format whisper.cpp reads by the whisper.cpp project, downloaded from
**Hugging Face** ([huggingface.co/ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp)):

- `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin`
- `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin`

A model is downloaded only when you tap its download button. With
**Download over Wi-Fi only** on (the setting on **Settings > Offline
languages**, on by default) Mozhi asks first on mobile data or a metered
network. An interrupted download resumes where it stopped. Every file is
checked against its size and the SHA-1 published by whisper.cpp (bundled
with the app) before it is used, and installed in one step, so a model is
either complete or absent. Hugging Face sees your IP address and which
model you download, nothing else (see [Privacy](privacy.md)).

### Import from files

To install a model without the app going online (for example in
**Offline only**), download `ggml-tiny.bin` or `ggml-base.bin` from the
links above on another device (**Copy download links** copies them), copy
the file to the phone and choose **Import from files**. Renamed copies are
recognised by their size and checksum; damaged files are refused. The
picked files are only read, never changed.

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

**Settings > Voice input** says so when Offline only is on.

## Good to know

- **Web app:** only the browser's speech recognition; Whisper runs in the
  Android app only.
- **Supported phones:** Whisper runs on 64-bit ARM and x86_64 Android
  devices and on 32-bit ARM devices with NEON and VFPv4 (almost all of
  them); elsewhere the offline option is not offered.
- **Storage:** the models are kept in the app's private storage (not in
  backups) until you delete them; **Delete all local data** removes them
  too.
- **Microphone:** Whisper records with Android's own `AudioRecord` (no
  Google code); the recording stays in memory and is dropped after
  transcription.

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
  (**Settings > Voice input**); it works on every supported phone.

## For contributors

The engine is the `packages/whisper_speech` package: whisper.cpp v1.9.5 as a
pinned submodule, built into `libmozhi_whisper.so` with ggml's CPU backend
only, the model catalogue, the verified model manager and the Dart FFI
engine in a background isolate. See its
[README](../packages/whisper_speech/README.md) for the native build and the
tests. In the app, `WhisperSpeechRecognizerAdapter` (`lib/voice/offline/`)
plugs Whisper into `SpeechInputService`, which picks the recognizer for
each session.
