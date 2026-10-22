# Backup and restore

A Mozhi backup is **one encrypted file** that holds what you would hate to
lose: your history and favorites, presets, glossaries and settings. Only
your passphrase opens it. There is no Mozhi account and no server: the
file is made on your device and you decide where it goes (another phone, a
computer, a USB stick, a Syncthing folder or a cloud folder of your choice).
It works the same on Android and in the web app, and a backup made in one
restores in the other.

Sync and phone-to-phone transfer use the same format and the same parts
([Sync](sync.md), [Phone to phone](pairing.md)).

- [What's in a backup](#whats-in-a-backup)
- [Making a backup](#making-a-backup)
- [Restoring](#restoring)
- [The passphrase](#the-passphrase)
- [What a backup protects, and from whom](#what-a-backup-protects-and-from-whom)
- [File format](#file-format)

## What's in a backup

| Part | What it holds |
| --- | --- |
| **History and favorites** | Your translations and dictionary look-ups, favorites included, and a record of the entries you deleted (so that merging another copy doesn't bring them back, see below) |
| **Presets** | Your translation presets and which one is the default |
| **Glossaries** | Your saved glossaries and their terms |
| **Settings** | Everything under Settings: engines and instances, AI providers (without their keys), languages, privacy choices, appearance |
| **API keys and passwords** | Only when you turn on **Include API keys and passwords**: the API keys and custom headers of your AI and translation providers, and the user names and passwords of instance addresses (`https://user:password@host`). Off by default |
| **Phrasebook**, **Practice progress** | Your phrasebook collections and flashcard progress, in versions that have them |

You choose which parts go into a backup, and later which parts to restore.

**Not in a backup**, because they can be downloaded again or don't matter
elsewhere: offline language models, voice input models, offline
dictionaries and text recognition data (download them again under
**Offline languages**), read-aloud and voice input preferences, usage
counters, cached engine and language lists, the network activity log, and
the history's on-device encryption key (the backup has its own).

**Deleted entries.** When you delete a history entry (or clear the
history, or un-star an entry that was kept only as a favorite), Mozhi
keeps a small record of it: the entry's id and when it was deleted, never
its text. These records travel with backups and sync so that merging
another copy of your history doesn't bring deleted entries back. They are
kept for 180 days, at most the newest 10,000, encrypted on the device like
the history, and removed by **Delete all local data**. Entries removed by
the size limit or by **Delete history automatically** leave no record:
each device keeps its own limits.

## Making a backup

1. Open **Settings > Backup & sync** and tap **Back up now**.
2. Choose what to include. **Include API keys and passwords** stays off
   unless you turn it on; Mozhi then warns you that anyone who has the file
   and finds out the passphrase can use your keys (which may cost you
   money) and sign in to your servers.
3. Enter a passphrase twice. A hint below the field says how strong it is
   (from its length and number of words only; nothing is looked up).
   Mozhi needs at least 8 characters.
4. Tap **Create backup**. On Android the system's save dialog asks where to
   save `mozhi-<date>.mozhibackup`; in the web app the browser downloads
   it.

**Back up now** shows when you last made a backup on this device. Mozhi
stores only that date: never the passphrase, never the key.

Keep the file somewhere other than the phone it came from, and keep the
passphrase somewhere safe: nobody can recover it for you.

**Export history** (under **Privacy & data**) still copies or shares the
history as plain JSON, and says that it isn't encrypted; its sheet points to
the encrypted backup instead.

## Restoring

1. Open **Settings > Backup & sync** and tap **Restore from a backup**.
2. **Choose file** and pick a `.mozhibackup` file. Mozhi shows when it was
   made and by which version, which it can read without the passphrase.
3. Enter the passphrase and tap **Unlock**. A wrong passphrase, or a file
   that was damaged or changed, gives one clear error: **Wrong passphrase,
   or the file is damaged.** (the two can't be told apart; see below).
4. Mozhi lists what the backup holds, part by part, with how many items
   each has and whether it includes API keys and passwords. Uncheck what
   you don't want. Parts that this version of Mozhi doesn't know (from a
   newer version) are named and left out.
5. Tap **Merge with my data** or **Replace my data**. The result says
   what changed, for example "History and favorites: 135 now, 120 before".

**Merge with my data** keeps what is on this device and adds what is only
in the backup:

- **History and favorites:** entries are matched by id; of an entry on both
  sides the newer copy stays (the one starred or changed last), and an
  entry deleted on either side stays deleted unless it changed after it
  was deleted. Two look-ups of the same word become one. **Delete history
  automatically** then applies as usual.
- **Presets** and **glossaries:** yours stay as they are, and the backup's
  presets and glossaries that you don't have are added. They carry no
  dates, so a preset you edited on both devices keeps this device's
  version, and one you deleted here comes back if the backup still has it.
- **Settings:** this device's settings stay, privacy choices included; the
  AI providers, Mozhi instances and pinned languages you don't have are
  added, and the backup's API keys fill in keys missing here.

**Replace my data** makes each chosen part exactly what the backup holds:
history and favorites (with their deletion records), presets, glossaries
and settings. Two things are kept: setup stays finished, and a provider or
instance keeps this device's key or password when the backup has none for
it. Replacing your history leaves no deletion records for what was here
before, so another device you sync with keeps its entries.

Restored API keys and passwords go to secure storage, exactly like keys
you type in the settings. A changed HTTP proxy applies after a restart.

## The passphrase

Whoever has a backup file can try passphrases on their own computer, as
fast as their hardware allows. Argon2id (below) makes each try slow and
memory-hungry, but only a long passphrase makes guessing hopeless:

- Use **four or more random words** (for example picked with dice from a
  word list), or a long sentence that isn't a quote or a song lyric. Mozhi
  calls a passphrase **Strong** from four words and 16 characters, or 24
  characters.
- Don't reuse a password you use elsewhere.
- Write it down and keep it apart from the file. Without the passphrase the
  backup can't be opened, by you or by anyone else.

## What a backup protects, and from whom

- **Someone who gets the file** (a lost USB stick, a cloud folder that
  leaks, a shared computer) sees only that it is a Mozhi backup, when it
  was made, by which version, and how large it is. Everything else is
  encrypted. They can try to guess the passphrase offline; with four or
  more random words that is out of reach.
- **Someone who changes the file** can't make Mozhi restore anything
  else: every byte, the readable header included, is covered by the
  encryption's authentication tag, so any change fails exactly like a
  wrong passphrase.
- **A file from someone else** (or a newer, unknown format) is refused
  before anything is restored. A backup you restore can only change the
  parts you choose; settings from it take effect as if you had typed them,
  so restore only backups you made.
- **Out of scope:** malware on your device, and someone who knows your
  passphrase. Backups never leave your device by themselves: Mozhi sends
  nothing anywhere when it makes or restores one.

## File format

A `.mozhibackup` file is, in order:

| Bytes | What |
| --- | --- |
| 8 | The magic `MOZHIBAK` (ASCII) |
| 1 | The format byte, `1` |
| 2 | The header length *n*, big-endian |
| *n* | The header: UTF-8 JSON (below) |
| rest | AES-256-GCM: the ciphertext, then the 16-byte tag |

The header:

```json
{
  "kdf": {
    "algorithm": "argon2id",
    "version": 19,
    "memoryKiB": 65536,
    "iterations": 3,
    "parallelism": 1
  },
  "salt": "<16 random bytes, base64>",
  "cipher": "aes-256-gcm",
  "nonce": "<12 random bytes, base64>",
  "compression": "gzip",
  "createdAt": "2026-10-22T13:05:00.000Z",
  "appVersion": "1.4.0+12"
}
```

- **Key:** Argon2id (RFC 9106, version 0x13) of the passphrase's UTF-8
  bytes, exactly as typed, with the file's random salt and the header's
  parameters, 32 bytes long. A new salt and nonce are drawn for every
  file.
- **Encryption:** AES-256-GCM with the header's nonce. The associated data
  is everything before the ciphertext (magic, format byte, length and
  header), so the header can't be changed without the tag failing.
- **Plaintext:** gzip of the UTF-8 JSON of the snapshot:

  ```json
  {
    "format": "mozhi-backup",
    "formatVersion": 1,
    "createdAt": "2026-10-22T13:05:00.000Z",
    "appVersion": "1.4.0+12",
    "sections": {
      "history": {"version": 1, "data": {"entries": [], "tombstones": []}},
      "presets": {"version": 1, "data": {"version": 1, "presets": []}},
      "glossaries": {"version": 1, "data": {"version": 1, "glossaries": []}},
      "settings": {"version": 1, "data": {"settings": {}, "secrets": {}}}
    }
  }
  ```

  Each part (`sections`) has its own version, so a newer app can read every
  older part and refuses a part newer than it knows. `secrets` is only
  there when API keys and passwords were included.
- **Versions:** a file with a format byte above 1, or a snapshot with a
  `formatVersion` above 1, is refused with "made by a newer version of
  Mozhi". Unknown header fields are ignored.
- **Bounds:** files over 64 MiB, a header over 4 KiB, Argon2id asking for
  more than 256 MiB, 16 passes or 8 lanes, and data that decompresses to
  more than 128 MiB are refused, so a crafted file can't exhaust the
  device.

**Argon2id parameters.** Backups made on Android use 64 MiB, 3 passes and
one lane (RFC 9106's second recommendation, with one lane). In the web app
Argon2id runs as JavaScript, about five times slower: 64 MiB and 3 passes
took 4.4 s on a 2.1 GHz server core (more than 10 s on a mid-range phone's
browser), so web backups use 19 MiB, 2 passes and one lane (OWASP's
minimum for Argon2id), measured at 0.8 s there (about 2 s on a mid-range
phone). Every file records its parameters, so each opens anywhere; opening
an Android backup in the web app takes those few seconds longer. On
Android the work runs in a background isolate; in the web app Argon2id
pauses between blocks so the page stays responsive, and AES-GCM and gzip
are the browser's own (Web Crypto, `CompressionStream`).
