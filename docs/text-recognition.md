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
   (the recommended method and the first choice when it is available;
   Mozhi's image translation through Google Translate is experimental and
   offered last), the photo is decoded on the phone, turned upright by its
   EXIF orientation (as the photo is shown), scaled to at most 2500 px on
   its long side and read by Tesseract in a background thread.
2. Tesseract reads with the data of the **source language** chosen above
   the image (German: `deu`). For **Detect language** it reads with the
   languages whose data is on the phone, at most three: your recent source
   languages and the app's language first, then English, then the others.
   Each extra language makes recognition slower and its mistakes likelier,
   so pick the language when you know it. When Tesseract is unsure of what
   it read (a mean confidence below 50 of 100), the result asks **Wrong
   language?** with **Choose the language of the text**.
3. Tesseract also says where the text is: its blocks, paragraphs, lines
   and words with their boxes, and for each paragraph the colours of the
   text and of the ground around it. A wrapped paragraph's lines are
   joined into running text (a word hyphenated at a line end is joined
   again; Chinese, Japanese or Thai lines are joined without a space; a
   line ending a sentence or starting a list item keeps its break), so a
   sentence is translated as one. Specks read as text (no letter or digit,
   or a very unsure one or two characters) are left out.
4. All the paragraphs are translated in **one request** with the engine
   you translate with, separated by blank lines, which every engine keeps
   (the on-device engine copies the whitespace between sentences exactly;
   AI models are asked to keep the formatting). The translation is split
   at the blank lines again, one part per paragraph. If an engine merged
   or split paragraphs anyway, the on-device engine translates each
   paragraph on its own (on the phone); a network engine gets no extra
   request: its translation is spread over the paragraphs by length.
5. The translation is drawn over the photo (**Overlay**, the default): each
   paragraph's box is filled with its ground colour (softened at the
   edges) and the translation is written in it at the largest size that
   fits, at most the original line height, wrapped within the box and
   never overflowing it (text that cannot fit ends with "…"), in the
   original text's colour when it contrasts enough (3:1) and else in black
   or white, aligned like the original, in the target language's direction
   and script. Tap a paragraph for the original and the translation with
   copy buttons; hold **Original** to compare; **Share image** and **Save
   image** render the photo with the overlay to a PNG at its resolution
   (at most 4096 px) on the phone. Screen readers find each paragraph as a
   button read as its translation, with the original as hint, in reading
   order. The overlay fades unless animations are turned off.
6. **Text** shows the plain photo with the recognised text below it: you
   can correct it and translate it again (the overlay stays while the text
   keeps its paragraphs, separated by blank lines).

Tesseract reads printed text: signs, menus, labels, documents and
screenshots. Handwriting, very stylised fonts, strongly curved or rotated
text and tiny print are read poorly or not at all. A slightly skewed photo
is fine (layout analysis straightens it and reports the angle), but text
turned sideways or upside down within the photo is not read: that needs
orientation detection (`osd`), which is not included. It reads with global
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
- **Settings > Translation engines > Offline languages > Text recognition**:
  every language, with its size, download, delete and **Import from files**.

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

To keep GitHub out of it, download the data from your own server instead:
**Settings > Translation engines > Model source > Custom mirror** serves
the same files from `<base>/tesseract/<code>.traineddata`, still checked
against the bundled checksums. See [Mirror the on-device models](self-hosting-mozhi.md#mirror-the-on-device-models).

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
- **Layout:** `mozhi_tesseract_recognize_layout()` runs the same passes as
  `mozhi_tesseract_recognize()` and returns the text with its blocks,
  paragraphs, lines and words (boxes, confidences, baselines, paragraph
  direction and alignment, block orientation and deskew angle) as JSON,
  from Tesseract's `ResultIterator`. Each paragraph's `background` and
  `foreground` are the median colours of the pixels in its box that
  Tesseract's thresholded image counts as ground and as text (the larger
  share is the ground, so light text on a dark sign works too). C API
  version 2 (`MOZHI_TESSERACT_ABI_VERSION`); `mozhi_tesseract_cli --layout`
  prints the JSON.
- **Dart:** `TesseractOcr` (recognition in a background isolate over
  `dart:ffi`, behind a conditional import so the web build has none;
  `layout: true` adds an `OcrLayout`),
  `TessdataManager` (download with `Range` resume, SHA-256 verification,
  atomic install, delete, import), `TessdataCatalog`
  (`assets/catalog.json`, generated by `tool/tessdata_catalog.py`; maps the
  app's language codes to Tesseract's).
- **App:** `lib/platform/text_recognition*.dart` creates the shared
  `TesseractTextRecognitionService`
  (`lib/image_translate/data/`), which `lib/platform/mlkit_bindings.dart`
  returns in the default build. It turns the `OcrLayout` into a
  `TextLayout` (`lib/image_translate/models/text_layout.dart`: joined
  lines, paragraph texts, the one-request text and how a translation is
  split back); `ImageTranslateCubit` translates it and
  `TranslatedImageOverlay`, `overlay_painting.dart` (text fitting,
  colours) and `overlay_export.dart` (PNG through the document
  translator's save and share helpers) draw it. A recognizer without
  language data can report a layout through `TextRecognitionLayout` (meant
  for the Play variant's ML Kit, which does not implement it yet). `planTextRecognition` picks the languages;
  missing data becomes an `OcrDataMissingException`, shown as the inline
  offer (`OcrLanguageOffer`, `OcrOfferCubit`). The management screen is
  `lib/offline/view/ocr_languages_page.dart`.
- **Licences:** [`packages/tesseract_ocr/native/THIRD_PARTY_NOTICES.md`](../packages/tesseract_ocr/native/THIRD_PARTY_NOTICES.md);
  the app's licences page lists Tesseract, Leptonica and the data.
