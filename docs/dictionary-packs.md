# Offline dictionary packs

The Dictionary tab and the panel under short translations can answer from
**dictionary packs** on the device: definitions, part of speech,
pronunciation (IPA), examples, synonyms, related words, a short etymology
and translations, from Wiktionary. A pack is downloaded once; every look-up
then runs on the device, without a network and without an AI provider, and
nothing is sent anywhere. The AI entry becomes an optional **More detail**.

- [Using packs in the app](#using-packs-in-the-app)
- [Data and licence](#data-and-licence)
- [Building packs](#building-packs)
- [Publishing a release](#publishing-a-release)
- [Pack format](#pack-format)
- [Catalogue](#catalogue)
- [Limits and next steps](#limits-and-next-steps)

## Using packs in the app

- **Settings > Offline languages > Dictionaries** lists the packs of the
  app's catalogue with their sizes. Download, update or delete them there;
  the **Download over Wi-Fi only** choice of the offline languages applies
  (on mobile data the app asks first). The Dictionary tab offers **Get
  dictionaries** when it has neither a pack nor an AI provider, or no pack
  for the word's language.
- **Downloads** come from the model source (**Settings > Translation
  engines > Model source**, also on **Offline languages**): the GitHub
  release by default, or
  `<mirror>/dictionary/<id>.mzd` on a mirror (the same layout as
  `bergamot/`, `whisper/` and `tesseract/`; a self-hosted web app serves
  them from `models/dictionary/` next to the app). Every file is checked
  against the size and SHA-256 the app ships with before it is installed,
  whichever server sends it, so a mirror is not trusted with anything.
  GitHub's release downloads send no CORS headers, so **the web app needs
  a same-origin mirror** for packs: the release's web zip does not carry
  them (they are too large), and on a server whose `models/dictionary/`
  has no `index.json` (written by `tool/mirror_models.py`) the
  Dictionaries screen says *This web server doesn't host the downloads*
  once, with **Import from files** and a link to
  [mirroring](self-hosting-mozhi.md#mirror-the-on-device-models), instead
  of offering downloads that would fail. Before a download (or a pack received
  from another phone) the app checks the free space: the pack's size plus
  a margin of 5 %, at least 50 MB (in a browser, what its storage quota
  leaves); without enough room nothing is downloaded and the screen says
  how much is needed.
- **Import from files** (on the Dictionaries screen, Android and the web
  app): installs packs downloaded by hand (`<id>.mzd`, from the catalogue's
  URLs), without any request. A file is matched by its name (any case) or,
  renamed, by its size and then its SHA-256, and installed with the checks
  of a download; a pack already installed in that version is not read
  again. A summary lists what was installed, already there, damaged (a
  checksum mismatch) or failed, and the files that matched no pack
  (`DictionaryPacks.importFiles`).
- **Storage**: app files on Android (`<support>/dictionary/<id>.mzd`, not
  backed up, removed with the app); the origin private file system (OPFS)
  in a browser (Chrome, Edge, Firefox, Safari 26). A browser without OPFS
  says so on the Dictionaries screen.
- **Look-ups** use the pack of the word's language, or every installed pack
  while the language is detected (the closest match wins: the word as
  written, then the same but for case, then accents, then an inflected
  form). Case and accents don't matter (`Cafe` finds `café`), and an
  inflected form finds its lemma (`went` shows `go`, saying so). When the
  packs don't have the word, the dictionary asks the AI provider as before;
  without one, it suggests words of the packs that start alike.
- **Definitions in English**: every pack of the current release explains
  its words in English (its catalogue entry's `glossLanguage`, `en`, from
  the English Wiktionary), and says so: under each pack on the
  Dictionaries screen and in an entry's credit line, with the language's
  name in the app's language.
- **Credit**: entries from a pack are labelled **From Wiktionary · CC BY-SA
  4.0 · Definitions in English** instead of **AI-generated**; the label opens the attribution (who
  wrote the data, where it comes from, what was changed, the date) with
  links to the licence and the source.
- **Translate**: the panel under a translation of one to three words shows
  the packs' definitions when the engine returned none.

The app reads a pack lazily: opening one reads its header, its key
directory and its block table (a few hundred KB for a large language); a
look-up then reads and decompresses one key block and the entry blocks it
needs (64 KB each), keeping the last eight in memory per pack.

Code: `packages/translation_repository/lib/src/dictionary_packs/` (format,
reader, writer, catalogue and the `OfflineDictionary` contract, pure Dart),
`lib/dictionary/data/` (downloads, storage, the bundled catalogue),
`lib/offline/view/dictionary_packs_page.dart` (the Dictionaries screen),
`lib/dictionary/` and `lib/translate/widgets/short_query_panel.dart` (the
look-ups).

## Data and licence

Packs are made from **Wiktionary** (<https://www.wiktionary.org/>), written
by its contributors and available under the **Creative Commons
Attribution-ShareAlike 4.0** licence
(<https://creativecommons.org/licenses/by-sa/4.0/>) and the GNU Free
Documentation License, as extracted by **wiktextract**
(<https://github.com/tatuylonen/wiktextract>) and published by
**kaikki.org**. The data is kept apart from the MIT-licensed code: it is
never bundled with the app, only downloaded on request.

To meet the licence:

- every pack carries the credit in its header (`attribution`, `source`,
  `sourceUrl`, `license`, `licenseUrl`, `snapshot`), and the app shows it
  with every entry from a pack;
- the changes are stated: entries are shortened to what the app shows (see
  below) and inflected forms point to their lemma;
- the packs themselves are shared under the same licence (the release says
  so).

## Building packs

`tool/dictionary_packs.py` (Python 3, standard library only) turns
wiktextract's JSONL for one language (as kaikki.org publishes it, `.jsonl`
or `.jsonl.gz`) into a pack:

```sh
python3 tool/dictionary_packs.py build kaikki.org-dictionary-Spanish.jsonl \
  --language es --lang-code es --snapshot 2026-10-15 --output es.mzd
```

It keeps, per entry (one headword and part of speech): the first IPA, up
to 12 senses (the gloss, qualifiers such as *informal, US*, up to two
usage examples or short quotations with their translations, the word a
form-of sense points to), up to 12 synonyms and related words (antonyms,
derived and related terms), a 300-character etymology and up to four
translations per sense into the target languages (`--targets`, default:
the app's offline languages and a few more, with Wiktionary's codes mapped
to the app's: `cmn` → `zh`, `nb` → `no`, ...). It drops inflection tables,
head templates, categories, audio and everything else. An entry that is
only a form of another word the data has (`went`: *simple past of go*)
becomes a lookup key of that word instead; a form whose lemma is missing
keeps its entry. Inflected forms of the `forms` lists (up to 64 per entry,
without table and template rows) become lookup keys too. Limits are
options (`--max-senses`, `--max-examples`, `--max-translations`,
`--max-forms`).

It prints the sizes (entries, keys, raw and compressed entry and index
data, the pack and its SHA-256) and writes them as JSON with `--stats`.
Builds are reproducible: the same input and options give the same bytes.

Other commands:

- `catalog --release TAG --base-url URL PACKS...` writes
  `dictionary_catalog.json`;
- `dart CATALOG` writes `lib/dictionary/data/dictionary_catalog_data.dart`
  (the catalogue the app pins);
- `kaikki-url LANGUAGE` prints where the release job downloads a language;
- `dump PACK [WORD...]` prints a pack's metadata and looks words up, as
  the app would.

**Sizes** of the release `dictionary-packs-2026-10-31` (the download, in
MB; the job's summary lists them for every release):

| Pack | MB | Pack | MB | Pack | MB | Pack | MB |
| --- | ---: | --- | ---: | --- | ---: | --- | ---: |
| Hindi `hi` | 3.1 | Arabic `ar` | 6.1 | Portuguese `pt` | 8.3 | German `de` | 15.5 |
| Korean `ko` | 4.5 | Swedish `sv` | 6.3 | Spanish `es` | 11.4 | Chinese `zh` | 16.1 |
| Greek `el` | 4.6 | Dutch `nl` | 6.4 | Japanese `ja` | 11.4 | Polish `pl` | 16.2 |
| Czech `cs` | 5.4 | Ukrainian `uk` | 6.7 | Italian `it` | 11.5 | Finnish `fi` | 42.6 |
| Turkish `tr` | 5.4 | French `fr` | 8.1 | Russian `ru` | 12.6 | English `en` | 114.6 |

About 317 MB for all 20. The key index is a small part of a pack; most of
it is entries (English also carries its translation tables).

**Tests**: `python3 tool/dictionary_packs_test.py` builds packs from the
hand-written extracts in `tool/dictionary_packs_fixtures/` (the same JSONL
shape as kaikki.org's: senses, glosses, tags, examples, sounds, forms,
translations, form-of entries, broken lines). The Dart reader's tests read
`packages/translation_repository/test/fixtures/dictionary_packs/en.mzd`, a
pack this tool built (zlib-compressed, folded with Python's Unicode
tables), and the Python test fails when the tool would now build different
content: run `python3 tool/dictionary_packs_test.py --update` after
changing the format or the fixture.

## Publishing a release

`.github/workflows/dictionary_packs.yaml` runs only by hand (**Actions >
dictionary packs > Run workflow**), by the repository owner:

1. Choose the languages (app codes; each needs its kaikki.org name in
   `KAIKKI_NAMES`), the date of the data (default: today) and, to pin the
   sources, their SHA-256 (`es=<sha256>,de=<sha256>`, from an earlier
   run's `sources.txt`: a download that differs fails). kaikki.org
   publishes only its latest extraction, so the run records the SHA-256 of
   every file it used.
2. The job tests the tool, downloads each language's JSONL from kaikki.org
   (one runner per language), builds the packs and publishes a release
   named `dictionary-packs-<date>` (a draft by default; pre-release, never
   *latest*) with the packs, `dictionary_catalog.json`,
   `dictionary_catalog_data.dart`, `sources.txt` and `SHA256SUMS.txt`, with
   the `GITHUB_TOKEN`. The run's summary lists every pack's entries, keys,
   size and SHA-256.
3. Publish the draft, then commit the catalogue into the app:
   `dictionary_catalog_data.dart` as
   `lib/dictionary/data/dictionary_catalog_data.dart` (or run
   `python3 tool/dictionary_packs.py dart dictionary_catalog.json`). Until
   then the app's catalogue is empty and the Dictionaries screen says that
   no dictionaries are available yet.

Mirrors copy the packs to `<mirror>/dictionary/` with the rest of the
models.

## Pack format

Format 1, little-endian. A pack (`.mzd`) is:

| Bytes | Content |
| --- | --- |
| 0-7 | `MOZHIDCT` |
| 8-9 | format version (1) |
| 10-11 | reserved (0) |
| 12-15 | length *M* of the metadata |
| 16 to 16+*M* | metadata, UTF-8 JSON |
| the rest | the data section |

The **metadata** has `format`, `language` (of the words), `glossLanguage`
(of the definitions), `name`, `source`, `sourceUrl`, `extractor`,
`snapshot`, `license`, `licenseUrl`, `attribution`, `targets` (languages
of the translations), `entries`, `keys`, `blockSize` (65536), `fold`,
`layout` (`directory` and `blocks`: offset and length in the data
section), `dataLength` and `sha256` (of the data section). The data
section holds, in order:

1. **Entry blocks**: gzip members of at most `blockSize` uncompressed bytes
   (a larger entry gets a block of its own), each a run of entries as a
   varint length and UTF-8 JSON. Entries are numbered from 0 in key order.
2. **Key blocks**: gzip members of at most `blockSize` bytes holding the
   lookup keys sorted by their UTF-8 bytes, front coded (each key as the
   number of bytes it shares with the previous key of its block, then the
   rest; the first key of a block is whole), each followed by its display
   form (the headword or form as written; empty when it equals the key)
   and its references: entry number × 2 for an entry it is the headword
   of, × 2 + 1 for an entry it is an inflected form of (headwords first, at
   most 32).
3. **Directory**: the number of key blocks, then per block its offset,
   length and first key.
4. **Block table**: the number of entry blocks, then per block its offset,
   length and first entry number.

Numbers in the directory, the table and the blocks are unsigned LEB128
varints.

**Keys** are folded per code point through the `fold` table (Unicode case
folding, canonical decomposition without the combining diacritics
U+0300-U+036F, recomposition; curly apostrophes become `'`), then spaces
are collapsed. The table covers every character the pack's words use, in
each case, so a reader folds a query exactly as the builder did without
Unicode tables of its own, also on the web.

An **entry** is a JSON object: `w` word, `p` part of speech, `i` IPA, `s`
senses (`g` gloss, `q` qualifiers, `x` examples as `[text, translation]`,
`o` the word it is a form of), `y` synonyms, `r` related words, `e`
etymology, `t` translations by language code as `[word, sense]` (sense -1:
the whole entry). Empty fields are left out; readers ignore fields they
don't know.

A new incompatible layout gets a new format version; readers refuse
versions they don't know.

## Catalogue

`dictionary_catalog.json` (schema 1):

```json
{
  "schemaVersion": 1,
  "release": "dictionary-packs-2026-10-22",
  "source": "https://github.com/Aimdi/Mozhi/releases/tag/dictionary-packs-2026-10-22",
  "packs": [
    {
      "id": "es",
      "language": "es",
      "glossLanguage": "en",
      "name": "Spanish",
      "file": "es.mzd",
      "url": "https://github.com/Aimdi/Mozhi/releases/download/dictionary-packs-2026-10-22/es.mzd",
      "size": 12345678,
      "sha256": "…",
      "entries": 123456,
      "snapshot": "2026-10-15",
      "license": "CC BY-SA 4.0",
      "source": "Wiktionary"
    }
  ]
}
```

URLs must be `https` and name the file; `id` is also the installed file's
name.

## Limits and next steps

- English Wiktionary's glosses are in English: a Spanish pack defines
  Spanish words in English, whatever the app's language. Other editions
  (German, French, ...) are extracted by kaikki.org too; a pack of them
  sets `glossLanguage` and gets its own id.
- Downloads restart from the beginning when interrupted (no `Range`
  resume).
- Bilingual pairs from WikDict and example sentences from Tatoeba would
  fit the same format (more `t` and `x` data).
