# Text recognition (OCR)

Photo and camera translation can read the text of a picture **on the
phone**, with no Google code: the open-source **Tesseract** engine
(Apache-2.0) and its **tessdata_fast** language data. Only the recognised
text is then translated, with the engine you translate with (on the device
too when it is the offline engine). The picture itself never leaves the
phone. This is the **On-device text recognition** method of
**Translate image**, in the default build (GitHub releases, F-Droid, the
Play bundle); the optional [Play variant](contributing.md#build-variants)
uses Google ML Kit instead. The web app has no on-device recognition.

## How it works

1. You pick or take a photo. With **On-device text recognition** selected
   (the first choice when it is available), the photo is decoded on the
   phone, scaled to at most 2500 px on its long side and read by Tesseract
   in a background thread.
2. Tesseract reads with the data of the **source language** chosen above
   the image (German: `deu`). For **Detect language** it reads with the
   languages whose data is on the phone, at most three: your recent source
   languages and the app's language first, then English, then the others.
   Each extra language makes recognition slower and its mistakes likelier,
   so pick the language when you know it.
3. You can correct the recognised text and translate it again.

Tesseract reads printed text: signs, menus, labels, documents and
screenshots. Handwriting, very stylised fonts, strongly curved or rotated
text and tiny print are read poorly or not at all. It reads with global
(Otsu) thresholding first and, when that finds little confident text (for
example a shadow across the photo or uneven light), tries Sauvola's
adaptive thresholding and keeps the better result.

## Language data

Each language needs its data file (`<code>.traineddata`), downloaded once
**only when you ask**:

- On the image screen, when the data for the source language is missing:
  **Download German text recognition (1.5 MB)**. With **Detect language**
  and no data at all, the app asks which language the text is in and
  offers your language's data.
- **Settings > Offline languages > Text recognition**: every language,
  with its size, download, delete and **Import from files**.

**Download over Wi-Fi only** (on the Offline languages screen, shared with
the offline translation models) applies: on mobile data or a metered
network the app asks first.

110 languages are available, 311 MB in all; most are 1 to 4 MB (median
2.4 MB, from 0.4 MB for Persian or Cherokee to 12 MB for Sanskrit), for
example English 4.1 MB, German 1.5 MB, French 1.1 MB, Spanish 2.3 MB,
Chinese (Simplified) 2.5 MB, Japanese 2.5 MB, Korean 1.7 MB, Arabic 1.4 MB,
Hindi 1.1 MB, Russian 3.9 MB, Tamil 3.2 MB. They cover the app's languages
that tessdata_fast has data for:

Afrikaans, Albanian, Amharic, Ancient Greek, Arabic, Armenian, Assamese,
Azerbaijani, Basque, Belarusian, Bengali, Bosnian, Breton, Bulgarian,
Burmese, Catalan, Cebuano, Cherokee, Chinese (Simplified; also Wu),
Chinese (Traditional; also Cantonese and Classical Chinese), Corsican,
Croatian, Czech, Danish, Dhivehi, Dutch, Dzongkha, English, Esperanto,
Estonian, Faroese, Filipino, Finnish, French, Frisian, Galician, Georgian,
German, Greek, Gujarati, Haitian Creole, Hebrew, Hindi, Hungarian,
Icelandic, Indonesian, Inuktitut, Irish, Italian, Japanese, Javanese,
Kannada, Kazakh, Khmer, Korean, Kurdish (Kurmanji), Kyrgyz, Lao, Latin,
Latvian, Lithuanian, Luxembourgish, Macedonian, Malay (Latin script),
Malayalam, Maltese, Maori, Marathi, Mongolian, Nepali, Norwegian (also
Nynorsk), Occitan, Odia, Pashto, Persian (also Dari), Polish, Portuguese,
Punjabi (Gurmukhi), Quechua, Romanian, Russian, Sanskrit, Scottish Gaelic,
Serbian (Cyrillic and Latin), Sindhi, Sinhala, Slovak, Slovenian, Spanish,
Sundanese, Swahili, Swedish, Tajik, Tamil, Tatar, Telugu, Thai, Tibetan,
Tigrinya, Tongan, Turkish, Ukrainian, Urdu, Uyghur, Uzbek (Latin),
Vietnamese, Welsh, Yiddish, Yoruba.

Not included: vertical Chinese, Japanese and Korean (the horizontal data
reads most signs and menus), historical scripts, and orientation
detection (`osd`, which needs Tesseract's legacy engine). Languages
without data (for example Xhosa, or Malay in Jawi script) say so: choose
another method for them.

### Where the data comes from

From Tesseract's [tessdata_fast](https://github.com/tesseract-ocr/tessdata_fast)
repository on GitHub, pinned to one commit, through
`raw.githubusercontent.com`:

```
https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/87416418657359cb625c412a48b6e1d6d41c29bd/<code>.traineddata
```

GitHub is owned by Microsoft: as the host it sees your IP address, the time
and which files (so which languages) you download. Nothing else is sent: no
text, no picture, no identifiers or cookies. Every file is checked against
the size and SHA-256 checksum bundled with the app before it is used; an
interrupted download resumes where it stopped. The data is kept in the
app's private storage (`<app files>/tesseract/tessdata`), is not backed up,
and is removed with the app or by deleting the language.

### Import from files (no network)

To keep the phone offline (for example in **Offline only**), download the
files on another computer and import them:

1. Get the links: on **Text recognition**, tap a language (**Files for
   German** shows `deu.traineddata` with its link), or **Copy download
   link** on the image screen's offer.
2. Download the files (a browser, or `wget`), keep their names, and copy
   them to the phone (USB, SD card, a network share).
3. **Import from files** (on the image screen's offer or on **Text
   recognition**) and select them. Each file is checked against the
   bundled checksum; a renamed copy (`deu (1).traineddata`) is recognised
   by its size and checksum. A summary says what was installed, what was
   already there, which files are damaged and which are no recognition
   data. The import contacts nothing.

## For contributors

The engine is `packages/tesseract_ocr` (see its
[README](../packages/tesseract_ocr/README.md)):

- **Native:** `libmozhi_tesseract.so`, Tesseract 5.5.3 (LSTM recognizer
  only) and Leptonica 1.87.0 (no image codecs) as pinned shallow git
  submodules, built by `native/CMakeLists.txt` into one shared library
  that exports only the `mozhi_tesseract_*` C API (`native/src/`), with
  libc++ static and 16 KB pages; `android/build.gradle` builds it with the
  NDK for arm64-v8a, armeabi-v7a (NEON) and x86_64 (SSE4.1 kernels; AVX
  left out). Run `tool/fetch_native_deps.sh` (or the repository's
  `tool/fetch_native_deps.sh`) before an Android build. About 2-3 MB per
  ABI.
- **Dart:** `TesseractOcr` (recognition in a background isolate over
  `dart:ffi`, behind a conditional import so the web build has none),
  `TessdataManager` (download with `Range` resume, SHA-256 verification,
  atomic install, delete, import), `TessdataCatalog`
  (`assets/catalog.json`, generated by `tool/tessdata_catalog.py`; maps the
  app's language codes to Tesseract's).
- **App:** `lib/platform/text_recognition*.dart` creates the shared
  `TesseractTextRecognitionService`
  (`lib/image_translate/data/`), which `lib/platform/mlkit_bindings.dart`
  returns in the default build. `planTextRecognition` picks the languages;
  missing data becomes an `OcrDataMissingException`, shown as the inline
  offer (`OcrLanguageOffer`, `OcrOfferCubit`). The management screen is
  `lib/offline/view/ocr_languages_page.dart`.
- **Licences:** [`packages/tesseract_ocr/native/THIRD_PARTY_NOTICES.md`](../packages/tesseract_ocr/native/THIRD_PARTY_NOTICES.md);
  the app's licences page lists Tesseract, Leptonica and the data.
