# Phrasebook

Your favorites, grown into a real phrasebook: named collections such as
*Trip to Lisbon*, *Pharmacy* or *Work Japanese*, filled in one or two taps
from a translation, a history entry or a dictionary entry, and starter
phrasebooks for travellers from Wikivoyage. Everything is on the device
and works offline.

- [Using the phrasebook](#using-the-phrasebook)
- [Adding phrases](#adding-phrases)
- [CSV export and import](#csv-export-and-import)
- [Starter phrasebooks](#starter-phrasebooks)
- [Storage, backup and privacy](#storage-backup-and-privacy)
- [Data and licence](#data-and-licence)
- [Building starter phrasebooks](#building-starter-phrasebooks)
- [Pack format](#pack-format)
- [Code](#code)

## Using the phrasebook

Open it from **History > Favorites** (**Open phrasebook**, the bookmarks
button), from **More tools > Phrasebook** on the Translate tab, or with
the link `/phrasebook` (`/phrasebook?collection=favorites` opens a
collection).

- **Collections.** The list starts with **Favorites**: the hearts of your
  history, read from it (nothing is copied; un-starring a favorite in the
  history takes it out here too). Then **Your collections**, each with its
  languages (*English → Portuguese*, or *2 language pairs*) and its number
  of phrases, and the **Starter phrasebooks** you downloaded. **New
  collection** (the folder button) asks for a name. A collection's menu
  has **Rename**, **Move up** and **Move down** (you can also drag a row
  by its handle, or long-press it) and **Delete collection**, with
  **Undo**. Deleting a collection deletes the phrases that are in no other
  collection.
- **Phrases.** Each phrase shows its text, its translation, the
  pronunciation when it has one (starter phrasebooks) and your note. Under
  it: **Listen to the phrase**, **Listen to the translation** (a long press
  reads slowly), **Copy translation** and **Show full screen** (the
  translation in large type, to show to a waiter or a taxi driver; tap,
  Back or Escape closes it). **Phrase actions** (⋮) has **Copy phrase**,
  **Share** (the phrase and its translation), **Add note** / **Edit
  note**, **Copy to collection…**, **Move to collection…** and **Remove
  from collection** (in Favorites: **Remove from favorites**), with
  **Undo**.
- **One phrase, several collections.** Copying a phrase to another
  collection adds the same phrase there (a note shows in both); adding a
  phrase a collection already has adds nothing (*Already in Lisbon*). A
  phrase is deleted when it leaves its last collection. Favorites and
  starter phrases are copied into a collection as phrases of their own.
- **Search and sort.** The search finds the text, the translation, the
  note and the pronunciation. A collection with several language pairs
  has chips to show one. **Sort** lists the newest first (a starter
  phrasebook in its page's order, by section) or **A to Z**.
- **Layout.** On phones the collections and a collection's phrases are two
  screens (Back returns to the list). From 840 dp wide the list sits
  beside the selected collection.
- **Empty states** say what to do next: *Translate something*, **Import
  CSV**, or the heart for Favorites.

## Adding phrases

- **Translate tab.** **Add to phrasebook…** (the bookmark button beside
  the heart under a translation) asks which collection the translation
  goes into: the last one you used comes first, collections that already
  have it are ticked, and **New collection** makes one with the
  translation's languages. A snack bar confirms it, with **Open**.
- **History.** Every row's **More actions** (⋮, or a long press) has **Add
  to phrasebook…**, also among the screen reader's actions.
- **Dictionary.** **Add to phrasebook…** beside the entry's heart adds the
  word with its first translation into your target language (else the
  entry's one-line summary).
- A phrase's languages are real codes: a detected source language counts
  as the language it was detected as, and an undetected or custom one as
  *Unknown language*.

## CSV export and import

- **Export as CSV** (a collection's menu) writes the same kind of file as
  **History > Favorites > Export favorites**: Anki's header lines
  (`#separator:Comma`, `#html:false`), then one row per phrase with the
  phrase (front), its translation (back), the source and target language,
  the date and your note; RFC 4180 CSV in UTF-8 with a byte order mark.
  **Save as CSV** (a download in the web app) or **Share CSV**. The file
  isn't encrypted and stays on the device unless you share it. History's
  own **Export favorites** keeps its five columns.
- **Import CSV** (a collection's menu, or its empty state) reads a CSV or
  tab-separated file on the device: this app's exports, Anki's text
  exports (its `#separator:` header is followed; other `#` header lines are
  skipped) and spreadsheets' CSV (comma, semicolon or tab, found from the
  first line). The preview shows the first phrases as they'll be imported
  and lets you choose the **Phrase column** and the **Translation column**
  (*Column 2: Olá*), say whether **The first row is a header** (guessed
  when it reads like *Front, Back* or language names) and choose the
  **Language of the phrases** and **of the translations** (the
  collection's, to start with). Rows without a phrase or a translation are
  skipped, phrases the collection has already aren't added again, and
  at most 20,000 rows are read. A collection without languages takes the
  import's.

## Starter phrasebooks

**Starter phrasebooks** (the suitcase button, or **Get starter
phrasebooks** at the end of the list) offers Wikivoyage's phrasebooks:
the everyday phrases of its articles (*Basics*, *Problems*, *Numbers*,
*Time*, *Directions*, *Eating*, *Bars*, ...) with their pronunciation
guides.

- **Download** fetches one once (tens of KB) from your [model
  source](privacy.md#where-model-files-come-from): the project's GitHub
  release by default, or `<mirror>/phrasebooks/<id>.json.gz` on a mirror
  (then the release when the source falls back to the original
  publishers). Every file is checked against the size and SHA-256 the app
  ships with before it is kept, whichever server sent it; a file that
  doesn't match is discarded. GitHub's release downloads send no CORS
  headers, so **the web app needs a same-origin mirror**
  (`models/phrasebooks/` next to the app). Downloads appear in **Network
  activity** as model downloads, and nothing else is sent. Like every
  download of the app, it first checks the free space (a margin of at
  least 50 MB) and says how much is needed when the phone is full.
- A starter phrasebook is a **read-only collection**: open it, listen,
  copy, show full screen, and **Copy to collection…** to make a phrase
  your own (with its pronunciation). It is credited **From Wikivoyage · CC
  BY-SA 4.0**; tap the credit (or **About this phrasebook**) for the
  article, its revision, its authors and the licence. **Update** appears
  when the app's catalogue has a newer version; **Delete starter
  phrasebook** removes it.
- **Until the first release** of the data, the app's catalogue is empty
  and the sheet says that none are available in this version yet.

## Storage, backup and privacy

- Your collections, their phrases, your notes on favorites and the
  deletion records (below) are one document in the app's preferences,
  **encrypted with AES-256-GCM** the way the history is (its own 256-bit
  key, in secure storage on Android; next to the data in the browser's
  storage in the web app, which only keeps it from being read in plain
  text). If the key is missing (the app's secure storage was reset), the
  phrasebook is left untouched and the screen offers **Retry** or **Start
  a new phrasebook** (the old one is set aside on the device).
- Starter phrasebooks are public data and stored as downloaded (checked
  against their SHA-256 again when read).
- **Backups and sync** carry the `phrasebook` section (format version 1):
  the collections, their phrases, the notes on favorites and the deletion
  records, not the favorites themselves (the history's section has them)
  nor the starter phrasebooks (download them again). **Replace** makes the
  backup the phrasebook (one here that can't be read is set aside first,
  so a backup brings it back after the key was lost); **Merge** keeps the newer copy of each phrase,
  collection and note, keeps what only one side has, and lets a deletion
  win over older copies. Deleted phrases and collections, and phrases
  taken out of a collection, are remembered for 180 days (at most 5,000 of
  each) so that a merge does not bring them back; a collection keeps the
  phrases of both copies, less those the other copy took out since.
- **Delete all local data** deletes the phrasebook, its key and the
  starter phrasebooks.
- Nothing is sent anywhere, except a starter phrasebook download you ask
  for.

## Data and licence

Starter phrasebooks are made from the English **Wikivoyage**
(<https://www.wikivoyage.org/>) phrasebook articles, written by
Wikivoyage contributors and available under the **Creative Commons
Attribution-ShareAlike 4.0** licence
(<https://creativecommons.org/licenses/by-sa/4.0/>). The data is kept
apart from the MIT-licensed code: it is never bundled with the app, only
downloaded on request.

To meet the licence:

- every pack carries the credit (`source`, `sourceUrl`, the `revision`
  and `revisionUrl` it was made from, `authorsUrl`: the article's history,
  `license`, `licenseUrl`, `retrieved` and an `attribution` sentence) and
  the app shows it with links;
- the change is stated: articles are shortened to their phrase list (each
  phrase, its translation and pronunciation; markup, links and notes are
  removed);
- the packs themselves are shared under the same licence (the release
  says so). Phrases you copy into your own collections keep coming from
  Wikivoyage: an exported CSV of them is CC BY-SA 4.0 too.

## Building starter phrasebooks

`tool/phrasebooks.py` (Python 3, standard library only):

```sh
python3 tool/phrasebooks.py pages                      # languages and pages
python3 tool/phrasebooks.py fetch pt --revision 4567890 --output pt.page.json
python3 tool/phrasebooks.py build pt.page.json --language pt \
  --retrieved 2026-10-22 --output pt.json.gz --stats pt.stats.json
python3 tool/phrasebooks.py dump pt.json.gz
```

- `fetch` reads an article's wikitext from the MediaWiki API (at a pinned
  `--revision`, else the latest, whose number it records), with a
  descriptive User-Agent; `build` also takes a `.wikitext` file from a
  dump (`--title` and `--revision` say what it is).
- **Parsing.** It reads the article's **Phrase list** (everything after
  that heading; sections such as *Pronunciation guide*, *Grammar* or
  *Learning more* are skipped), using the nearest heading as a phrase's
  section. Phrases are Wikivoyage's definition-list lines, `; Hello. :
  Olá. (''oh-LAH'')`, with the foreign part also on the next `:` line,
  bullet lines `* English : Foreign`, and `{{phrasebook|English|Foreign|
  Pron}}`. The pronunciation is the italic group between parentheses at
  the end, or a plain Latin-script group after text in another script
  (`Спасибо (spah-SEE-bah)`). Links, bold and italics, templates
  (`{{lang|pt|Olá}}` keeps its text), references, comments and HTML are
  cleaned up; a colon in a time (`10:30`) or a URL doesn't split a line.
  Phrases longer than 300 characters and duplicates are left out, and a
  pack holds at most 3,000 phrases.
- Each phrase gets a stable id, the first 12 hex digits of the SHA-256 of
  its English and foreign text (the app's `s:<pack>:<id>`), so practice
  cards and copies survive a rebuild that doesn't change the phrase.
- Packs are reproducible (sorted JSON, gzip with mtime 0).
- `catalog --release TAG --base-url URL PACKS...` writes
  `phrasebook_catalog.json`, and `dart CATALOG` writes
  `lib/phrasebook/data/starter_catalog_data.dart` (the catalogue the app
  pins).
- **Tests**: `python3 tool/phrasebooks_test.py` builds packs from the
  hand-written articles in `tool/phrasebooks_fixtures/` (the real shape:
  banners, a pronunciation guide, the phrase list with level-3 and level-4
  sections, the two-line form, bullets, the template, links, references
  and comments; a Japanese one for romanizations) and an API response, and
  checks that `test/phrasebook/fixtures/pt_pack.json` (which the app's
  tests read) is still this tool's output.

**Publishing.** `.github/workflows/phrasebooks.yaml` runs only by hand
(**Actions > phrasebooks > Run workflow**): choose the languages and, to
pin them, their revisions (`pt=1234567,es=2345678`). The job tests the
tool, fetches each article (one at a time), builds the packs and
publishes a release named `phrasebooks-<date>` (a draft by default;
pre-release, never *latest*) with the packs, `phrasebook_catalog.json`,
`starter_catalog_data.dart` and `SHA256SUMS.txt`; the run's summary lists
each pack's revision, phrases, size and SHA-256. Publish the draft, then
commit `starter_catalog_data.dart` as
`lib/phrasebook/data/starter_catalog_data.dart`. Mirrors copy the packs to
`<mirror>/phrasebooks/`.

## Pack format

A pack (`<id>.json.gz`, at most 4 MB) is gzip'd UTF-8 JSON:

```json
{
  "format": "mozhi-phrasebook",
  "formatVersion": 1,
  "id": "pt",
  "language": "pt",
  "baseLanguage": "en",
  "name": "Portuguese",
  "title": "Portuguese phrasebook",
  "source": "Wikivoyage",
  "sourceUrl": "https://en.wikivoyage.org/wiki/Portuguese_phrasebook",
  "revision": 4567890,
  "revisionUrl": "https://en.wikivoyage.org/w/index.php?title=Portuguese_phrasebook&oldid=4567890",
  "authorsUrl": "https://en.wikivoyage.org/w/index.php?title=Portuguese_phrasebook&action=history",
  "license": "CC BY-SA 4.0",
  "licenseUrl": "https://creativecommons.org/licenses/by-sa/4.0/",
  "retrieved": "2026-10-22",
  "attribution": "From the Wikivoyage article “Portuguese phrasebook” …",
  "sections": [
    {
      "title": "Basics",
      "phrases": [
        {"id": "3f1c…", "text": "Hello.", "translation": "Olá.", "pronunciation": "oh-LAH"}
      ]
    }
  ]
}
```

`id` is the language of the translations, with the base language when it
isn't English (`pt-de`). The app refuses another `format`, a newer
`formatVersion`, a pack whose `id` isn't the catalogue's, and a pack
without phrases.

The catalogue (`phrasebook_catalog.json`, `schemaVersion` 1) lists every
pack with `id`, `language`, `baseLanguage`, `name`, `file`, `url`
(`https`, naming the file), `size`, `sha256`, `phrases`, `revision`,
`sourceUrl` and `license`, sorted by name.

## Code

- `lib/phrasebook/models/`: `Phrase`, `PhraseCollection`, `PhraseDraft`
  and the starter phrasebook models (the catalogue, a pack).
- `lib/phrasebook/data/`: `PhrasebookRepository` (storage, collections,
  phrases, merges), `PhrasebookFavorites` (the history's favorites),
  `StarterPhrasebooks` (downloads and storage), `PhrasebookBackupSection`,
  `collection_csv.dart` (export rows, import mapping) and
  `default_phrasebook.dart` (the app's instances and download URLs).
- `lib/phrasebook/cubit/`, `lib/phrasebook/view/`,
  `lib/phrasebook/widgets/`: the screen, the add sheet, the import dialog,
  the starter sheet and the buttons other screens show.
- `lib/history/data/phrasebook_csv.dart`: the CSV writer and reader.
- Practice ([Practice](practice.md)) reads phrases through
  `PhrasebookRepository` (`phrases()`, `phrase(id)`, `changes`).
