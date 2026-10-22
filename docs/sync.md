# Sync

Mozhi can keep your history, favorites, phrasebooks, practice progress,
presets and glossaries the same on your phone, your tablet and the web app,
through a folder on a **WebDAV server you control**: Nextcloud, ownCloud,
a Synology or other NAS, Apache, or `rclone serve webdav` on any computer.
There is no Mozhi account and no Mozhi server. Everything is encrypted on
the device with your **sync passphrase** before it leaves, so the server
only ever stores a file it can't read.

- [What you need](#what-you-need)
- [Set up the first device](#set-up-the-first-device)
- [Add another device](#add-another-device)
- [What is synced](#what-is-synced)
- [When it syncs](#when-it-syncs)
- [How it works](#how-it-works)
- [What the server sees](#what-the-server-sees)
- [Change or forget the passphrase](#change-or-forget-the-passphrase)
- [Turn sync off](#turn-sync-off)
- [Server setup](#server-setup)
- [The web app and CORS](#the-web-app-and-cors)
- [Troubleshooting](#troubleshooting)
- [Limits](#limits)

## What you need

- A WebDAV address, a user name and, preferably, an **app password**: a
  password made for Mozhi alone that you can revoke without changing your
  main one (Nextcloud: **Settings > Security > Devices & sessions >
  Create new app password**).
- A folder for Mozhi on that server. Mozhi creates it if it doesn't exist.
  Use one folder per person, the same on every device.
- `https://`. Plain `http://` only works for this device, your local
  network (`192.168.x.x`, `10.x.x.x`, `*.local`, a Tailscale name) and
  `.onion` addresses, like every other server in Mozhi. The server's
  certificate must be one your device trusts: the Android app does not
  accept self-signed certificates or private certificate authorities.
- A passphrase that every device will use. It can't be recovered: write
  it down. Four or more random words are a good choice; the strength hint
  is the same as for [backups](backup.md).

## Set up the first device

1. Open **Settings > Backup & sync** and tap **Set up sync**.
2. Enter the **WebDAV address**, your **user name**, the **app password**
   and the **folder** (`Mozhi` by default; `Apps/Mozhi` for a folder
   inside another one). For Nextcloud and ownCloud, the server's address
   (`https://cloud.example.org`) is enough: Mozhi finds
   `remote.php/dav/files/<user>/` itself.
3. Tap **Test connection**. Mozhi checks the address and the account
   without changing anything, and says whether the folder exists and
   whether another device already syncs there.
4. Choose a **sync passphrase** and repeat it, choose [what to
   sync](#what-is-synced), and tap **Turn on sync**. Mozhi creates the
   folder, encrypts your data and uploads it.

## Add another device

On the next phone, or in the web app: **Set up sync** with the **same
address, user name and folder** (an app password of its own is better:
you can revoke one device without the others). After **Test connection**
Mozhi says **Another device already syncs here** and asks for the **same
passphrase**. Your data on that device is **merged** with the synced data:
nothing is replaced, and what each device had ends up on both.

A wrong passphrase is refused (**That passphrase doesn't open the synced
data**), and nothing changes on the device or on the server.

## What is synced

**Settings > Backup & sync > What to sync** lists the parts, each device
choosing its own:

| Part | Synced by default | How copies are merged |
| --- | --- | --- |
| History and favorites | Yes | Per entry, the newer copy wins; a deletion (kept as a [deletion record](backup.md) for 180 days) wins over older copies |
| Phrasebooks | Yes | Per phrase, collection and note, the newer copy wins; deletions win over older copies |
| Practice progress | Yes | Per card, as the [practice](practice.md) section merges |
| Presets, Glossaries | Yes | New ones are added; each device keeps its own copy of one it already has (see [Limits](#limits)) |
| Settings | **No** | This device keeps its own settings and gets the AI providers, Mozhi instances and pinned languages it doesn't have yet |

The settings are left out unless you choose them: some only make sense on
one device (privacy mode, proxy, theme), and they change after every
translation (the last language pair). **API keys and passwords** travel
only when you sync the settings **and** turn on **Include API keys and
passwords**, which warns you first: they are encrypted like everything
else, but anyone who gets the sync file and your passphrase can use them.

What a device doesn't sync stays as it is in the sync file, so devices
with different choices don't erase each other's parts. Offline language
models, speech models, text recognition data and dictionaries are never
synced: download them on each device.

## When it syncs

- **Sync now**, whenever you tap it (also on mobile data).
- **At app start**, once the first screen is shown.
- **A minute after a change** (a translation, a favorite, a deleted entry,
  a new phrase...), restarted by every further change, and right away when
  you leave the app with a change waiting. When nothing synced has
  changed, nothing is sent: a change to something you don't sync costs no
  request at all.
- **Never in Offline only.** Sync is paused there (also **Sync now**), and
  resumes when you choose another privacy mode.
- **Sync on Wi-Fi only** (Android) keeps the automatic syncs off mobile
  data and metered Wi-Fi; **Sync now** still runs.

- After an error only you can fix (the server refuses the app password,
  the passphrase was changed elsewhere, a newer app version wrote the file),
  changes no longer start a sync until you fix it; each app start still
  tries once. This also keeps Nextcloud's protection against password
  guessing from locking your address out.

There is no background service: nothing syncs while the app is closed.

## How it works

The sync folder holds one file, `mozhi-sync.mozhibackup`: a snapshot of the
synced parts in the [backup format](backup.md#file-format), encrypted with
AES-256-GCM under a key derived from your passphrase with Argon2id. A sync:

1. reads the file (`GET`). When this device synced last and nothing changed
   here since, the request carries the file's ETag (`If-None-Match`) and an
   unchanged file costs one short `304 Not Modified`;
2. decrypts it and merges it into this device's data, part by part, with
   the rules above;
3. writes the merged data back, encrypted, unless the file holds it
   already: `PUT` with `If-Match` and the ETag it read, or with
   `If-None-Match: *` when there was no file yet. When another device wrote
   in between, the server refuses (`412 Precondition Failed`), and Mozhi
   reads the new file, merges again and retries, up to three times.

The **passphrase is never stored**. The key derived from it once (with the
salt and Argon2id parameters of the sync file, which every device reads
from the file's header) is kept in secure storage: the Android Keystore,
or in the web app the tab's session storage. The app password is kept
there too.

A device that finds the file encrypted with **another key** (the
passphrase was changed elsewhere), a file that **doesn't decrypt** (damaged
or changed on the server), or one written by a **newer version** of Mozhi
stops there: nothing changes on the device or on the server, and the sync
settings say what to do.

Requests appear as **Encrypted sync** in **Settings > Privacy & data >
Network activity**. They follow your [proxy](privacy.md#network) and the
app's network rules like every other request.

## What the server sees

The server, and whoever runs it or can read its disks or backups, sees:

- the file name `mozhi-sync.mozhibackup`, its size and when it changes;
- the file's readable header: the Argon2id parameters and salt, the
  AES-GCM nonce, when the snapshot was taken and the app version that
  wrote it;
- your user name, your devices' IP addresses and when they sync (as for
  any WebDAV client), and the app password, which the server checks.

It never sees what you translated, your favorites, phrasebooks, progress
or settings. Someone with the file can only try to guess the passphrase
offline, and Argon2id makes every guess slow (64 MiB and 3 passes when an
Android device created the file, 19 MiB and 2 passes for the web app):
pick a long passphrase. See [Security](security.md#data-on-the-device).

## Change or forget the passphrase

**Change sync passphrase** (on a device where sync works) encrypts the file
again with a key from the new passphrase and a new salt. Your other devices
then say **The sync passphrase was changed on another device** and ask for
the new one (**Enter the new passphrase**); until then they don't sync, and
they never overwrite the file.

A forgotten passphrase can't be recovered. On every device, **Turn off
sync**, delete the sync file (on the last device: **Also delete the sync
file from the server**, or in your server's file manager), and set sync up
again with a new passphrase. Each device's own data is kept and merged
again.

When the server no longer accepts the app password (you revoked it, or
Nextcloud asks for a new one), the sync settings show **Enter the app
password**. In the web app, which forgets the app password and the key
when its tab closes, **Unlock sync** asks for both again.

## Turn sync off

**Turn off sync** makes this device forget the server address, the app
password and the key. Your data stays on the device, and the sync file
stays on the server for your other devices. **Also delete the sync file
from the server** removes it first (do this on the last device: one that
still syncs writes it again).

**Settings > Privacy & data > Delete all local data** forgets the sync
setup, the app password and the key first, so nothing that is deleted next
reaches your other devices. It never contacts the server: the sync file
stays there.

## Server setup

### Nextcloud

- **WebDAV address**: `https://cloud.example.org` (Mozhi completes it), or
  the full address from **Files > Files settings > WebDAV**:
  `https://cloud.example.org/remote.php/dav/files/<user>/`.
- **App password**: **Settings > Security > Devices & sessions**. With
  two-factor authentication, an app password is the only way in.
- After several wrong passwords, Nextcloud's brute-force protection slows
  down or refuses requests for a while (**The server refuses requests for
  now**).
- The web app needs [CORS](#the-web-app-and-cors), which Nextcloud doesn't
  send for WebDAV by itself.

### ownCloud

ownCloud 10: as Nextcloud (`https://owncloud.example.org/remote.php/dav/files/<user>/`
or `.../remote.php/webdav/`), with an app password from **Settings >
Security**. ownCloud Infinite Scale (oCIS): the WebDAV address of your
personal space and an app token, as for any other WebDAV client.

### Synology and other NAS

Install **WebDAV Server** in the Package Center and turn on HTTPS (port
5006). The WebDAV address is `https://nas.example.org:5006/` followed by a
shared folder, for example `https://nas.example.org:5006/home/`, with
folder `Mozhi`. The NAS needs a certificate your devices trust (Let's
Encrypt in **Control Panel > Security > Certificate**); at home, plain
`http://192.168.1.20:5005/home/` works too. QNAP, TrueNAS and other NAS
work the same way with their WebDAV service.

### Apache

`mod_dav` with `mod_dav_fs` and Basic authentication over HTTPS, for
example:

```apache
Alias /dav /srv/dav
<Directory /srv/dav>
    Dav On
    AuthType Basic
    AuthName "WebDAV"
    AuthUserFile /etc/apache2/webdav.passwd
    Require valid-user
</Directory>
```

### rclone

`rclone serve webdav` shares any folder or rclone remote:

```sh
rclone serve webdav /srv/mozhi --addr :8080 --user alice --pass 'a long app password'
```

On your local network the app can use `http://192.168.1.10:8080/` directly;
elsewhere put HTTPS in front (for example the Caddy file below, or
`--cert` and `--key`). rclone ignores `If-Match` on uploads, so it can't stop
two devices that write in the same second: the second write replaces the
first. Each device keeps its own data, so its next sync merges it in
again; nothing is lost unless a device's data is deleted before that.

## The web app and CORS

A browser only lets the web app talk to a WebDAV server on another site
when the server allows it with **CORS** headers. The server must answer the
browser's `OPTIONS` preflight without authentication and send:

```text
Access-Control-Allow-Origin: https://<where you open the web app>
Access-Control-Allow-Methods: GET, PUT, DELETE, PROPFIND, MKCOL, OPTIONS
Access-Control-Allow-Headers: Authorization, Content-Type, Depth, If-Match, If-None-Match
Access-Control-Expose-Headers: ETag
```

When the browser blocks a request, it doesn't tell the app why, so Mozhi
says **The browser couldn't reach the server**: if the address is right,
the server lacks these headers. Without `Access-Control-Expose-Headers:
ETag`, sync still works: Mozhi reads the ETag with `PROPFIND` instead.

- **Any server: a reverse proxy.** [`deploy/webdav-cors.Caddyfile`](../deploy/webdav-cors.Caddyfile)
  puts Caddy (with automatic HTTPS) in front of your WebDAV server and adds
  exactly these headers for your web app's origin. With nginx in front of
  your server, add to its `server` block:

  ```nginx
  location / {
      if ($request_method = OPTIONS) {
          add_header Access-Control-Allow-Origin "https://app.example.org" always;
          add_header Access-Control-Allow-Methods "GET, PUT, DELETE, PROPFIND, MKCOL, OPTIONS" always;
          add_header Access-Control-Allow-Headers "Authorization, Content-Type, Depth, If-Match, If-None-Match" always;
          add_header Access-Control-Max-Age 600 always;
          return 204;
      }
      add_header Access-Control-Allow-Origin "https://app.example.org" always;
      add_header Access-Control-Expose-Headers "ETag" always;
      proxy_pass http://127.0.0.1:8080;   # your WebDAV server
  }
  ```

  For Nextcloud, add the same headers in the `location` that handles
  `/remote.php/dav/` (and answer `OPTIONS` there before it reaches PHP).
- **rclone**: `--allow-origin https://app.example.org` answers the
  preflight, but its list of allowed headers lacks `If-Match` and
  `If-None-Match`, so browsers refuse the uploads: use the reverse proxy.
- Name your web app's origin exactly (scheme, host and port, no path).
  `*` works too, since the app sends its credentials itself rather than as
  cookies, but there is no reason to allow other sites.

The web app forgets the app password and the key when its tab closes (its
secure storage is the tab's session storage): in a new tab, **Unlock sync**
asks for them again. Deriving the key takes a few seconds in a browser,
longer when an Android device created the sync file (its stronger Argon2id
parameters run as JavaScript).

## Troubleshooting

| Message | What to check |
| --- | --- |
| The server didn't accept the user name or app password | The user name (not the e-mail address, for most servers) and the app password; revoked app passwords stop working |
| This account may not use that folder | Permissions of the folder on the server, or a shared folder that is read-only |
| Nothing was found at that address | The WebDAV address: for Nextcloud `https://<server>/remote.php/dav/files/<user>/` |
| That address doesn't answer as a WebDAV server | You entered the web interface's address; use the WebDAV address |
| The server sends the app to another address | Enter the final address, with `https://` (Mozhi doesn't follow redirects, so your password never goes elsewhere) |
| The secure connection to the server failed | The certificate: expired, self-signed or for another name |
| Couldn't reach the server | Your connection, the address and the port; on the local network, that the device is on the same network |
| The browser couldn't reach the server | In the web app: [CORS](#the-web-app-and-cors) |
| Your storage on the server is full | Free space or raise the quota |
| Your devices synced at the same moment | Tap **Sync now** again |
| The sync passphrase was changed on another device | **Enter the new passphrase** |
| The sync file can't be decrypted | The file was damaged or changed on the server; restore it from the server's version history or a [backup](backup.md), or delete it and sync again |
| Another device synced with a newer version of Mozhi | Update the app on this device |

## Limits

- One file holds everything synced, so each change uploads the whole
  (compressed, encrypted) snapshot, usually tens to a few hundred
  kilobytes. Mozhi reads at most 64 MiB.
- **Presets, glossaries and settings** carry no change times yet: a new
  one reaches your other devices, but editing or deleting one does not (a
  deleted preset comes back from a device that still has it). Change them
  on each device, or sync them only from one.
- **Delete history automatically** works on each device alone: what it
  removes here isn't deleted on your other devices (and a sync brings it
  back until the next clean-up). Deleting entries yourself, or **Clear
  history**, does travel.
- Sync isn't instant: other devices pick changes up when they start, when
  something changes there, or on **Sync now**.
- No sharing between people: everyone who knows the folder's account and
  the passphrase sees everything in it.
