# Phone to phone

**Settings › Backup & sync › Phone to phone** moves your data (settings,
history, presets, glossaries and the other backup sections) or your offline
language packs from one phone to another over the same Wi-Fi network or a
phone's hotspot. It is end-to-end encrypted, needs no account, no server and
no internet, and works in the Android app only (a browser cannot listen on
the network). The code lives in `lib/pairing/`.

## Using it

1. On the phone that receives, open **Receive on this phone**. It shows a
   QR code and the same code as text (24 characters, for example
   `7K2Q-M9XA-3FHT-…`), valid for five minutes.
2. On the phone that sends, scan the QR code with the camera app (it opens
   the `mozhi://pair?code=…` link in Mozhi), or open **Send to another
   phone** and type or paste the code, then tap **Connect**. A link only
   fills in the code; nothing connects until you tap Connect.
3. Both phones show the same six-digit number. Check that they match: if
   they differ, stop, because someone may be in the middle.
4. The sending phone chooses what to send: **Your data** (the backup
   sections, without API keys and passwords unless you switch them on) and
   any of the offline languages and models on the phone: translation
   models, speech models and the speech detector, text recognition
   languages, dictionaries. **Share language packs** on the Offline
   languages screen opens the same screen with the packs selected.
5. The receiving phone sees the list, with what it already has and what its
   version of Mozhi cannot use, picks what to take, chooses **Merge with my
   data** or **Replace my data** for the data (as for a backup restore),
   and accepts or declines.
6. Both phones show the progress (the screen stays on) and then what became
   of each item. Leaving the screen on either phone stops the transfer.

## Protocol

The receiver listens with a `dart:io` `ServerSocket` on its private address
(the first of `localNetworkAddresses()`: Wi-Fi, then hotspot; another can be
picked) on a port the system chooses, for one connection, and shows the
code.

**The code** is 14 bytes in Crockford base32 plus a check character: the
receiver's IPv4 address (4 bytes), the port (2) and a one-time secret
(8 bytes, 64 bits, from `Random.secure`). The check character (a weighted
sum modulo 31) catches a mistyped character or two swapped neighbours.
`O`, `I` and `L` are read as `0`, `1`, `1`; case, spaces and dashes don't
matter.

**Key agreement** (`PairingHandshake`), in the clear, with fresh X25519 keys
on both sides:

| Step | From | Bytes |
| --- | --- | --- |
| 1 | sender | `MZP1`, SHA-256 of its public key (a commitment) |
| 2 | receiver | `MZP1`, its public key |
| 3 | sender | its public key (must match the commitment) |

Both compute the X25519 shared secret (all zeros, from a low-order key, is
refused) and derive 68 bytes with HKDF-SHA256: input key = shared secret ‖
code secret, salt = SHA-256(`mozhi-pair-1` ‖ commitment ‖ receiver key ‖
sender key), info = `mozhi pair keys`. That gives one AES-256 key per
direction and the six digits (a 32-bit number modulo 10⁶). The commitment
stops someone in the middle from choosing keys after seeing both phones'
keys, so they cannot steer both phones to the same six digits (one try in a
million).

**Frames** (`PairingChannel`): a 4-byte big-endian length, then that many
bytes of AES-256-GCM ciphertext and tag. The nonce is the frame's number in
its direction (4 zero bytes and a 64-bit counter), so a frame that is
changed, replayed, dropped or reordered fails to decrypt and ends the
connection. The plaintext is a type byte (1: a JSON message, 2: file data)
and at most 256 KiB; a longer length is refused before it is read. File data
goes in 64 KiB frames.

**Messages** (JSON objects with a type `t`):

| Message | From | Content |
| --- | --- | --- |
| `hello` | both | protocol version `v: 1`; the sender's is the first encrypted frame and proves it knows the code's secret |
| `offer` | sender | the items: kind, key, files (name, size, hashes as hints); the data item lists its sections and whether it holds secrets |
| `accept` / `decline` | receiver | the items and files it wants (from its own catalogue) |
| `file` + data | sender | each wanted file in order: item, name, size, then exactly that many bytes |
| `result` | receiver | per item, after installing it: `installed`, `damaged`, `noSpace`, `incompatible`, `failed` |
| `done` | both | the end; `cancel` stops at any time |

**Taking files.** The receiver never trusts the sender's descriptions: it
plans each item from its own bundled catalogue (Bergamot models: name,
decompressed size and SHA-256; Whisper: size, SHA-1 and SHA-256; Tesseract
and dictionaries: size and SHA-256), asks only for those files, writes each
into the app's cache folder (`<cache>/pairing/`) while checking its size and
hashes, and installs an item only when all of its files match, through each
manager's own import path (`BergamotModelManager.importFiles`,
`WhisperSpeech.importFiles`, `importOcrFiles`,
`DictionaryPacks.installFrom`), which checks them again before the atomic
install. File names come from the receiver's catalogue, never from the
sender. The data item is a `BackupSnapshot` as JSON (at most 64 MiB),
restored with `BackupRegistry.restore` and the chosen mode. The sender, in
turn, only reads the files it offered, whatever the receiver asks for.

**Limits and timeouts.** Only private IPv4 addresses (10/8, 172.16/12,
192.168/16) on both ends; anything else is closed at once (the sender
refuses a code for another address before connecting). One connection per
code; others are closed while it sets up. The key agreement and `hello`
must complete within 10 seconds. Three phones failing the secret burn the
code. A code works for five minutes. Waiting for the other person to choose
or accept: 10 minutes; between frames of a file: 30 seconds; for an item to
install: 10 minutes. At most 1,000 items, 32 files per item, 4 GiB per
file.

## Threat model

See [Security](security.md#phone-to-phone) for what this protects against
and its limits, and [Privacy](privacy.md#phone-to-phone) for what the other
phone gets.

## Follow-ups

- Resuming an interrupted transfer, and compressing the decompressed
  translation models on the way (they go across as installed, about 73 MB
  per language).
- AES-GCM runs in pure Dart on the UI isolate; a background isolate would
  keep long transfers smoother.
- An in-app QR scanner (camera frames and a decoder); today the system
  camera app opens the link.
