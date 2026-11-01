#!/usr/bin/env python3
"""Runs the release APK on an Android emulator the way a new user would
(CI job "Android emulator smoke test"; needs `adb` and a booted device).

  python3 tool/android_smoke.py <apk> <out-dir>

It installs the APK (no permission is granted up front), starts Mozhi,
walks through the first-run screens with their default choices, types a
French sentence into the translate box and follows what the app offers,
as a new user would: it downloads French for offline use when offered
(the private route: the translation then runs on the phone), else allows
sending the text **Once** (the online route). It saves a screenshot, the
screen's accessibility tree (uiautomator) and the log of every step in
<out-dir> for review.

It fails (exit 1) when Mozhi crashes or stops (a Java or native crash of
its process in logcat, or the process gone), when the first screen never
appears, or when the sentence can't be typed into the translate box.
Whether the sentence got translated depends on the downloads, the public
servers and the network, so that is reported (summary.md, with the route)
but does not fail the run.

  python3 tool/android_smoke.py <apk> <out-dir> --screenshots <dir>

also saves phone screenshots for the store listing in <dir> once the
smoke test is through: the translate screen (with the translation, when
there is one), the image screen (without the camera), documents,
conversation and settings, each in the light and the dark theme
(01-translate-light.png ... 05-settings-dark.png). The screen is set to
1080 x 2160 (2:1, the tallest Google Play takes), the status bar to the
system's demo mode (a fixed clock, full battery, no notifications), and
the PNGs are 24-bit without alpha, ready for
fastlane/metadata/android/<locale>/images/phoneScreenshots (see
docs/store/README.md). Screen size, theme and status bar are put back
afterwards. Missing screenshots are reported in summary.md and never fail
the run.

Then it goes through these flows, each one a step of its own that fails
the run (exit 1) when it does not work, with a screenshot and the screen's
labels of the moment it failed (<n>-<flow>-failed.png/.xml):

  offline-only  Settings > Privacy & data > Privacy mode: Offline only.
                Opens the translate tab (mozhi://translate) and shares a
                new French sentence; it must reach the translate box
                within 30 s, be translated, be labelled Offline, and
                Mozhi's uid must send and receive no byte meanwhile
                (`dumpsys netstats` counters).
  image         Shares tool/smoke_assets/french_sign.png (ACTION_SEND
                image/png, a MediaStore content URI) and accepts the text
                recognition download; the English text must appear.
  document      Shares a French .txt file (ACTION_SEND text/plain with
                EXTRA_STREAM) and translates it; the English text must
                appear on the result screen.
  cancel        Settings > Translation engines > Offline languages: starts
                downloading Greek, taps "Cancel downloading Greek"; the
                row must go back to Download, with no
                error.
  voice         Voice input on a phone without Google (the emulator image
                has no Google apps, hence usually no speech recognition
                service): allows the microphone (`pm grant`, as "Allow"
                would), opens the translate tab and taps Speak. The mic
                must answer within 30 s: offer the offline speech model
                with its size ("Download the speech model?", "Download
                (74.1 MB)"; closed with Not now, nothing is downloaded) or
                listen (an image with a recogniser); nothing at all, or an
                error, fails. The emulator runs without audio (-noaudio),
                so no speech is recognised here: the real transcription is
                tested in the job "Analyze and test".
  conversation-voice
                The same for the large microphone of the Conversation tab
                (mozhi://conversation, "Start conversation"): it must
                offer the offline speech model with its size (closed with
                Not now) or listen (a recogniser hears nothing here, so the
                conversation pauses with "Didn't hear anything"); nothing,
                an error, or a conversation still starting after 40 s
                fails.

For a failed flow it also saves the log of Mozhi's processes and of
Flutter since the flow started (<n>-<flow>-failed-logcat.txt; the last
lines go to the output too) and every text of the page, scrolled from top
to bottom (<n>-<flow>-failed-page.txt, printed too).

  --skip-offline-only, --skip-image, --skip-document, --skip-cancel,
  --skip-voice, --skip-conversation-voice

leave a flow out (to look into a flaky one without hiding the others; CI
runs them all). They run after the store screenshots, which keep showing
the app as a new user's first translation leaves it.

It is meant for a fresh emulator and refuses (exit 2) to run anywhere
else: unless `getprop ro.kernel.qemu` or `ro.boot.qemu` is 1 (an
emulator), when `pm list packages --user all` fails, or when Mozhi is
installed already for any user (the run would start from that device's
own data). On a real phone it still changes things, so it takes

  --allow-real-device

to run there (CI never needs it). Either way it leaves the device as it
found it: it reads only the log written since it started (it never clears
it), puts back an earlier screen size override, and deletes the image and
the document it pushed (and their MediaStore entries, where the shell may)
and its accessibility dumps. Mozhi itself stays installed.
"""

from __future__ import annotations

import ipaddress
import re
import struct
import subprocess
import sys
import time
import urllib.parse
import xml.etree.ElementTree as ET
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

PACKAGE = "io.github.aimdi.mozhi"
ACTIVITY = f"{PACKAGE}/.MainActivity"
# ASCII only and no "?": `adb shell input text` sends key events.
SENTENCE = "Bonjour je cherche la gare"
# The English translation ("I'm looking for the station").
RESULT = r".*\b(station|looking)\b.*"
# What the app offers, in the order a privacy-minded user would pick it.
OFFERS = (
    (r"Download French.*", "offline: downloaded French"),
    (r"Once", "online: allowed once"),
)
# The screens of the store screenshots (--screenshots), in listing order,
# and the deep link that opens each one (mozhi://image opens the image
# screen, never the camera).
STORE_SCREENS = (
    ("translate", "mozhi://translate"),
    ("image", "mozhi://image"),
    ("documents", "mozhi://documents"),
    ("conversation", "mozhi://conversation"),
    ("settings", "mozhi://settings"),
)
STORE_THEMES = ("light", "dark")
# Tips that may cover a screen; only these are tapped away (a plain
# "Close" could be the screen's own close button).
STORE_DISMISS = r"Got it|Dismiss|Not now"
# 2:1, the tallest aspect ratio Google Play accepts for screenshots.
STORE_SIZE = (1080, 2160)
# System UI demo mode: a tidy status bar for the listing.
DEMO_COMMANDS = (
    ("enter",),
    ("clock", "-e", "hhmm", "1000"),
    ("battery", "-e", "level", "100", "-e", "plugged", "false"),
    ("network", "-e", "wifi", "show", "-e", "level", "4"),
    ("network", "-e", "mobile", "hide"),
    ("notifications", "-e", "visible", "false"),
)

# The flows after the first translation (see the docstring): name (the
# --skip-<name> flag and the screenshots' prefix) and title. Each runs
# flow_<name with "_" for "-">(device).
FLOWS = (
    ("offline-only", "Offline only"),
    ("image", "Image translation offline"),
    ("document", "Document translation"),
    ("cancel", "Cancel an offline language download"),
    ("voice", "Voice input without Google"),
    ("conversation-voice", "Conversation voice input without Google"),
)
SHARE_ACTIVITY = f"{PACKAGE}/.ShareReceiverActivity"
ASSETS = Path(__file__).resolve().parent / "smoke_assets"

# Offline only: new French sentences (ASCII, no quote: see SENTENCE) and
# words of their English translation. The second is used when French had
# to be downloaded during the first, so that the measured one is clean.
OFFLINE_SENTENCES = (
    ("Le chat dort sur le lit", r"(?is).*\b(cat|bed)\b.*"),
    ("Mon frere aime la musique", r"(?is).*\b(brother|music)\b.*"),
)
PRIVACY_CATEGORY = r"(?s)Privacy & data\b.*"
OFFLINE_ONLY = r"(?s)Offline only\b.*"
# The output card's badge (OfflineEngineBadge: "Offline", tooltip
# "Translated on this device").
OFFLINE_BADGE = r"Offline|Translated on this device"

# Image: tool/smoke_assets/french_sign.png, 1200 x 520, black DejaVu Sans
# Bold 84 px on white (made with Pillow): "La maison est rouge." and
# "Le jardin est vert.".
IMAGE_ASSET = ASSETS / "french_sign.png"
IMAGE_REMOTE = "Pictures/mozhi-smoke-sign.png"
IMAGE_RESULT = r"(?is).*\b(house|garden)\b.*"
IMAGE_LOADED = (
    r"Remove image",
    r"(?s)Download .+ text recognition.*",
    r"(?s).*text recognition isn.t on this device.*",
    r"(?s)Which language is the text in\b.*",
    r"(?s)Text in the image\b.*",
)
IMAGE_EMPTY = r"(?s)Take or pick a photo\b.*"

# Document: French lines whose English words are not French words.
DOCUMENT_NAME = "mozhi-smoke-document.txt"
DOCUMENT_LINES = (
    "Le livre est sur la table.",
    "Nous mangeons du pain le matin.",
)
DOCUMENT_RESULT = r"(?is).*\b(book|bread|morning)\b.*"
DOCUMENT_LOADED = (r"Remove document", r"\d+ segments?")
DOCUMENT_EMPTY = r"(?s)Pick a document\b.*"

# Cancel: the smallest offline language with models in both directions in
# packages/bergamot_translator/assets/catalog.json (about 30 MB), so that
# its download takes long enough (Azerbaijani, the smallest, has English to
# Azerbaijani only).
CANCEL_LANGUAGE = "Greek"
ENGINES_CATEGORY = r"(?s)Translation engines\b.*"
# Translation engines' row that opens the offline languages ("Languages on
# this device", under the heading "Offline languages"); tapped as the
# clickable node that matches.
OFFLINE_LANGUAGES = r"(?s)(Languages on this device|Offline languages)\b.*"
# The offline languages page: its title (also the heading of the settings
# row), its header (offlineDownloadedCount) and its search field.
OFFLINE_TITLE = r"Offline languages"
OFFLINE_COUNT = r"(?s)(No languages downloaded|\d+ languages? downloaded)\b.*"
OFFLINE_SETTINGS_ROW = r"(?s)Languages on this device\b.*"
OFFLINE_SEARCH = r"(?s)Search languages\b.*"
# Words of the offline languages' error messages ("Couldn’t download …",
# "… isn’t enough space …").
CANCEL_ERRORS = r"(?is).*\b(couldn.t|can.t|failed|error|damaged|not enough)\b.*"
# The emulator console's slowest network profiles keep the download running
# while Cancel is looked for; "full" puts it back.
SLOW_NETWORK = "gsm"
# The emulator's Wi-Fi (netsim) doesn't follow the console's network speed,
# and a runner downloads 30 MB in a few seconds. So, as root, iptables lets
# in only so many HTTPS packets a second (about 30 KB/s) while Cancel is
# looked for: (table command, the rule), inserted in this order at the top
# of INPUT and deleted afterwards.
THROTTLE_RULES = (
    ("-p", "tcp", "--sport", "443", "-j", "DROP"),
    ("-p", "tcp", "--sport", "443", "-m", "limit", "--limit", "20/second",
     "--limit-burst", "40", "-j", "ACCEPT"),
)
THROTTLE_TABLES = ("iptables", "ip6tables")
THROTTLE_OK = "mozhi-throttle-ok"

# Offers every flow may accept: the "Download over mobile data?" dialog
# and first-time tips.
COMMON_OFFERS_PATTERNS = (
    (r"Download anyway", "download over mobile data"),
    (r"Got it", "close a tip"),
)


@dataclass(frozen=True)
class Node:
    text: str
    description: str
    cls: str
    bounds: tuple[int, int, int, int]
    clickable: bool
    focused: bool
    checkable: bool = False
    checked: bool = False
    enabled: bool = True

    @property
    def label(self) -> str:
        return self.text or self.description

    @property
    def center(self) -> tuple[int, int]:
        left, top, right, bottom = self.bounds
        return (left + right) // 2, (top + bottom) // 2


_BOUNDS = re.compile(r"\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]")


def parse_nodes(xml: str) -> list[Node]:
    """The nodes of a `uiautomator dump`, in document order (only those
    with a size on screen)."""
    try:
        root = ET.fromstring(xml)
    except ET.ParseError:
        return []
    nodes = []
    for element in root.iter("node"):
        match = _BOUNDS.fullmatch(element.get("bounds", ""))
        if not match:
            continue
        left, top, right, bottom = (int(v) for v in match.groups())
        if right <= left or bottom <= top:
            continue
        nodes.append(
            Node(
                text=element.get("text", ""),
                description=element.get("content-desc", ""),
                cls=element.get("class", ""),
                bounds=(left, top, right, bottom),
                clickable=element.get("clickable") == "true",
                focused=element.get("focused") == "true",
                checkable=element.get("checkable") == "true",
                checked=element.get("checked") == "true",
                enabled=element.get("enabled", "true") == "true",
            )
        )
    return nodes


def find(nodes: list[Node], pattern: str) -> Node | None:
    """The first node whose text or description matches [pattern] (a
    regular expression matched against the whole label, ignoring case);
    a clickable one wins over a plain one."""
    regex = re.compile(pattern, re.IGNORECASE | re.DOTALL)
    matches = [n for n in nodes if n.label and regex.fullmatch(n.label.strip())]
    clickable = [n for n in matches if n.clickable]
    return (clickable or matches or [None])[0]


def find_clickable(nodes: list[Node], pattern: str) -> Node | None:
    """Like [find], but only an enabled, clickable node (a button)."""
    node = find([n for n in nodes if n.clickable and n.enabled], pattern)
    return node


def labels_of(nodes: list[Node], limit: int = 600) -> str:
    """The labels on screen, for the log: "Settings | Privacy & data"."""
    labels = [" ".join(n.label.split()) for n in nodes if n.label.strip()]
    return " | ".join(labels)[:limit]


def screen_size(nodes: list[Node]) -> tuple[int, int]:
    """The screen's size as the dump's outermost bounds (1080 x 2400 when
    there is no node)."""
    if not nodes:
        return 1080, 2400
    return max(n.bounds[2] for n in nodes), max(n.bounds[3] for n in nodes)


def row_button(nodes: list[Node], row: Node, pattern: str) -> Node | None:
    """The button matching [pattern] in the list row [row] (a clickable
    node whose centre is within the row's height), as the "Download" pill
    of an offline language."""
    regex = re.compile(pattern, re.IGNORECASE | re.DOTALL)
    _, top, _, bottom = row.bounds
    for node in nodes:
        if node is row or not node.clickable or not node.label:
            continue
        if top <= node.center[1] <= bottom and regex.fullmatch(node.label.strip()):
            return node
    return None


def result_node(
    nodes: list[Node], pattern: str, exclude: Node | None = None
) -> Node | None:
    """The first node whose label matches [pattern] (a whole-label regular
    expression), other than [exclude] (the input box). Text fields count:
    Flutter's SelectableText, which shows translations, is an EditText for
    Android's accessibility."""
    regex = re.compile(pattern, re.IGNORECASE | re.DOTALL)
    return next(
        (
            n
            for n in nodes
            if n is not exclude and n.label and regex.fullmatch(n.label.strip())
        ),
        None,
    )


def offline_badge(nodes: list[Node], result: Node) -> Node | None:
    """The "Offline" badge of the translation [result]: a label line that
    is "Offline" or "Translated on this device", on the result itself (one
    merged node) or on a node from the result's top down."""
    regex = re.compile(OFFLINE_BADGE, re.IGNORECASE)
    for node in [result, *nodes]:
        if node is not result and node.bounds[1] < result.bounds[1]:
            continue
        if any(regex.fullmatch(line.strip()) for line in node.label.splitlines()):
            return node
    return None


def crash_lines(logcat: str, package: str = PACKAGE) -> list[str]:
    """Lines of [logcat] that report a crash of [package]: a Java
    exception that killed it, or a native signal in its process."""
    lines = logcat.splitlines()
    found = []
    for index, line in enumerate(lines):
        if "FATAL EXCEPTION" in line:
            following = "\n".join(lines[index : index + 3])
            if package in following:
                found.extend(lines[index : index + 12])
        elif re.search(r"Fatal signal \d+", line) and package in line:
            found.append(line)
        elif "ANR in " + package in line:
            found.append(line)
    return found


def package_uid(output: str, package: str = PACKAGE) -> int | None:
    """[package]'s uid from `cmd package list packages -U <package>`
    ("package:<package> uid:10190") or `dumpsys package <package>`
    ("userId=10190"); None when neither says."""
    for line in output.splitlines():
        parts = line.split()
        if parts and parts[0] == f"package:{package}":
            for part in parts[1:]:
                if part.startswith("uid:"):
                    value = part[4:].split(",")[0]
                    if value.isdigit():
                        return int(value)
    match = re.search(r"\buserId=(\d+)", output)
    return int(match.group(1)) if match else None


_NETSTATS_KEY = re.compile(r"\buid=(-?\d+)\s+set=(\S+)\s+tag=(0x[0-9a-fA-F]+)")
_NETSTATS_BUCKET = re.compile(r"\brb=(\d+)\b.*?\btb=(\d+)\b")
_NETSTATS_SECTION = re.compile(r"^[A-Za-z ]+ stats:$|^BPF\b|^mAppUidStatsMap")


def netstats_uid_bytes(dump: str, uid: int) -> int | None:
    """Bytes [uid] received and sent, by the "UID stats:" section of
    `dumpsys netstats --uid`: the sum of rb= and tb= of every bucket of
    every network and set (foreground, background) of its untagged totals
    (tag=0x0; tagged entries are parts of them). None when the dump has
    no such section."""
    lines = dump.splitlines()
    start = next(
        (i for i, line in enumerate(lines) if line.strip() == "UID stats:"), None
    )
    if start is None:
        return None
    total = 0
    counting = False
    for line in lines[start + 1 :]:
        if _NETSTATS_SECTION.match(line.strip()):
            break
        key = _NETSTATS_KEY.search(line)
        if key:
            counting = int(key.group(1)) == uid and int(key.group(3), 16) == 0
            continue
        bucket = _NETSTATS_BUCKET.search(line) if counting else None
        if bucket:
            total += int(bucket.group(1)) + int(bucket.group(2))
    return total


def bpf_uid_bytes(dump: str, uid: int) -> int | None:
    """Bytes [uid] received and sent, by the kernel's per-uid counters that
    `dumpsys netstats` prints under "mAppUidStatsMap:" (a header, then
    "<uid> <rxBytes> <rxPackets> <txBytes> <txPackets>" rows). 0 when the
    table has rows but none of [uid]; None when there is no such table
    (or it has no row it can read)."""
    lines = dump.splitlines()
    start = next(
        (i for i, line in enumerate(lines) if "mAppUidStatsMap" in line), None
    )
    if start is None:
        return None
    total = 0
    rows = 0
    for line in lines[start + 1 :]:
        stripped = line.strip()
        if not stripped or stripped.lower().startswith("uid"):
            continue
        match = re.fullmatch(r"(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)", stripped)
        if not match:
            break
        rows += 1
        if int(match.group(1)) == uid:
            total += int(match.group(2)) + int(match.group(4))
    return total if rows else None


def traffic_verdict(
    before: dict[str, int | None], after: dict[str, int | None]
) -> tuple[bool | None, str]:
    """Whether the app used the network between two readings of its byte
    counters (by source: "netstats", "bpf"): (True, why) when no trusted
    source moved, (False, why) when one did, (None, why) when no source
    can be trusted. A source is trusted when it was read both times and
    already counted bytes before (the first translation used the network,
    so a source that saw nothing is not reading this app's traffic)."""
    parts = []
    trusted = []
    for source in sorted(set(before) | set(after)):
        first, last = before.get(source), after.get(source)
        parts.append(f"{source} {first} -> {last}")
        if first is None or last is None:
            continue
        if first <= 0 and last <= 0:
            continue
        trusted.append(last - first)
    summary = ", ".join(parts) + " bytes"
    if not trusted:
        return None, f"no traffic counter could be trusted ({summary})"
    if any(delta != 0 for delta in trusted):
        return False, f"Mozhi's uid used the network ({summary})"
    return True, f"no byte sent or received ({summary})"


def _hex_address(value: str) -> str:
    """An address of /proc/net/tcp: 8 hex digits (IPv4) or 32 (IPv6),
    each 32-bit word in the kernel's (little endian) byte order."""
    raw = bytes.fromhex(value)
    words = b"".join(raw[i : i + 4][::-1] for i in range(0, len(raw), 4))
    if len(words) == 4:
        return str(ipaddress.IPv4Address(words))
    address = ipaddress.IPv6Address(words)
    return str(address.ipv4_mapped or address)


def uid_connections(table: str, uid: int) -> set[str]:
    """The remote addresses ("ip:port") of [uid]'s sockets in the text of
    /proc/net/tcp, tcp6, udp or udp6 (any mix): listening, unconnected
    and loopback sockets left out."""
    found = set()
    for line in table.splitlines():
        parts = line.split()
        if len(parts) < 8 or not re.fullmatch(r"\d+:", parts[0]):
            continue
        if parts[7] != str(uid) or ":" not in parts[2]:
            continue
        address, port = parts[2].split(":", 1)
        try:
            ip = _hex_address(address)
            number = int(port, 16)
        except ValueError:
            continue
        if number == 0 or ip in ("0.0.0.0", "::"):
            continue
        if ipaddress.ip_address(ip).is_loopback:
            continue
        found.add(f"[{ip}]:{number}" if ":" in ip else f"{ip}:{number}")
    return found


def content_rows(output: str) -> list[dict[str, str]]:
    """The rows of `content query` ("Row: 0 _id=31, _display_name=a.txt")
    as dictionaries."""
    rows = []
    for line in output.splitlines():
        match = re.match(r"\s*Row:\s*\d+\s+(.*)$", line)
        if not match:
            continue
        row = {}
        for part in re.split(r", (?=[A-Za-z_][A-Za-z0-9_]*=)", match.group(1)):
            key, _, value = part.partition("=")
            row[key.strip()] = value
        rows.append(row)
    return rows


def media_id(output: str, name: str) -> str | None:
    """The MediaStore id of the newest row named [name] in `content query`
    [output] (projection _id:_display_name)."""
    ids = [
        int(row["_id"])
        for row in content_rows(output)
        if row.get("_display_name") == name and row.get("_id", "").isdigit()
    ]
    return str(max(ids)) if ids else None


def stream_uris(identifier: str | None, collection: str, path: str) -> list[str]:
    """Content URIs another app could share the file at [path] (below the
    shared storage, e.g. "Pictures/a.png") with, best first: its MediaStore
    item in [collection] ("images/media", "downloads") and in the files
    table when [identifier] is known, then its document of the external
    storage provider."""
    uris = []
    if identifier is not None:
        uris.append(f"content://media/external/{collection}/{identifier}")
        uris.append(f"content://media/external/file/{identifier}")
    uris.append(
        "content://com.android.externalstorage.documents/document/"
        + urllib.parse.quote(f"primary:{path}", safe="")
    )
    return uris


def _shell_word(text: str) -> str:
    """[text] as one word of the device's shell (`adb shell` joins its
    arguments into one command line)."""
    if "'" in text:
        raise ValueError(f"no quote allowed in {text!r}")
    return f"'{text}'"


def share_text_args(text: str) -> list[str]:
    """`adb` arguments sharing [text] with Mozhi, as the share sheet does
    (ACTION_SEND text/plain to its share target)."""
    return [
        "shell", "am", "start", "-a", "android.intent.action.SEND",
        "-t", "text/plain",
        "--es", "android.intent.extra.TEXT", _shell_word(text),
        "-p", PACKAGE,
    ]


def share_stream_args(uri: str, mime: str) -> list[str]:
    """`adb` arguments sharing the file at the content [uri] with Mozhi's
    share target (ACTION_SEND [mime] with EXTRA_STREAM), allowed to read
    it. The URI is also the intent's data: Android grants the read
    permission for the data and the clip data of an intent, and `am`
    cannot set clip data."""
    return [
        "shell", "am", "start", "-n", SHARE_ACTIVITY,
        "-a", "android.intent.action.SEND",
        "-t", mime,
        "-d", _shell_word(uri),
        "--eu", "android.intent.extra.STREAM", _shell_word(uri),
        "--grant-read-uri-permission",
    ]


def am_failed(output: str) -> bool:
    """Whether `am start` [output] says the activity did not start."""
    return bool(re.search(r"\bError\b|Exception\b", output))


# Where uiautomator dumps the screen (deleted at the end).
UI_DUMP = "/sdcard/ui.xml"


def is_emulator(kernel_qemu: str, boot_qemu: str) -> bool:
    """Whether `getprop ro.kernel.qemu` / `ro.boot.qemu` say the device is
    an emulator (either is "1")."""
    return "1" in (kernel_qemu.strip(), boot_qemu.strip())


def installed_packages(output: str) -> set[str]:
    """The package names `pm list packages` [output] lists ("package:a.b",
    possibly with " uid:…" after it)."""
    names = set()
    for line in output.splitlines():
        line = line.strip()
        if line.startswith("package:"):
            name, *_ = line[len("package:"):].split() or [""]
            if name:
                names.add(name)
    return names


def size_override(output: str) -> str | None:
    """The override of `wm size` [output] ("Override size: 720x1280"), or
    None when the screen has its physical size."""
    match = re.search(r"Override size:\s*(\d+x\d+)", output)
    return match.group(1) if match else None


def log_start(output: str) -> str | None:
    """`logcat -t` time (seconds since the epoch, "1730000000.000") from
    `date +%s` [output], or None when that is not a number."""
    value = output.strip()
    return f"{value}.000" if value.isdigit() else None


class Device:
    def __init__(self, out: Path) -> None:
        self.out = out
        self.step = 0
        self.log: list[str] = []
        # Where the run's log starts (`logcat -t`); None: the whole log.
        self.log_since: str | None = None
        # What the run pushed: (path on the device, MediaStore uri or None).
        self.pushed: list[tuple[str, str | None]] = []

    def adb(self, *args: str, check: bool = True, timeout: int = 120) -> str:
        result = subprocess.run(
            ["adb", *args],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        if check and result.returncode != 0:
            raise RuntimeError(f"adb {' '.join(args)}: {result.stderr.strip()}")
        return result.stdout

    def shell_output(self, *args: str, timeout: int = 120) -> str:
        """adb's stdout and stderr together, whatever its exit code (`am`
        reports a refused intent on stderr)."""
        result = subprocess.run(
            ["adb", *args],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        return (result.stdout + result.stderr).strip()

    def swipe(self, up: bool = True) -> None:
        """Scrolls the screen by most of its height ([up]: towards the end
        of the page), near its right edge (off images that pan)."""
        width, height = screen_size(self.dump())
        x = width * 92 // 100
        start, end = height * 3 // 4, height // 3
        if not up:
            start, end = end, start
        self.adb(
            "shell", "input", "swipe", str(x), str(start), str(x), str(end), "400",
            check=False,
        )
        time.sleep(1.5)

    def note(self, message: str) -> None:
        print(message, flush=True)
        self.log.append(message)

    def dump(self) -> list[Node]:
        for _ in range(3):
            self.adb("shell", "uiautomator", "dump", UI_DUMP, check=False)
            xml = self.adb("shell", "cat", UI_DUMP, check=False)
            nodes = parse_nodes(xml)
            if nodes:
                return nodes
            time.sleep(1)
        return []

    def capture(self, name: str) -> list[Node]:
        """Saves a screenshot and the accessibility tree as step <n>."""
        self.step += 1
        stem = f"{self.step:02d}-{name}"
        (self.out / f"{stem}.png").write_bytes(self.screencap())
        self.adb("shell", "uiautomator", "dump", UI_DUMP, check=False)
        xml = self.adb("shell", "cat", UI_DUMP, check=False)
        (self.out / f"{stem}.xml").write_text(xml, encoding="utf-8")
        nodes = parse_nodes(xml)
        labels = [n.label for n in nodes if n.label]
        self.note(f"[{stem}] {' | '.join(labels)[:600]}")
        return nodes

    def tap(self, node: Node) -> None:
        x, y = node.center
        self.adb("shell", "input", "tap", str(x), str(y))
        time.sleep(1.5)

    def wait_for(self, pattern: str, seconds: float) -> Node | None:
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            node = find(self.dump(), pattern)
            if node is not None:
                return node
            time.sleep(2)
        return None

    def alive(self) -> bool:
        return bool(self.app_pids())

    def app_pids(self) -> set[str]:
        """The ids of Mozhi's running processes."""
        return set(self.adb("shell", "pidof", PACKAGE, check=False).split())

    def log_time(self) -> str | None:
        """The device's time now, as `logcat -t` takes it (see
        [log_start])."""
        return log_start(self.adb("shell", "date", "+%s", check=False))

    def logcat(self) -> str:
        """The log since the run started ([log_since]; all of it when that
        is unknown), read without clearing it."""
        since = ("-t", self.log_since) if self.log_since else ("-d",)
        return self.adb("logcat", *since, check=False, timeout=60)

    def crashes(self) -> list[str]:
        return crash_lines(self.logcat())

    def screencap(self, raw: bool = False) -> bytes:
        """The screen as a PNG, or with [raw] in screencap's raw format."""
        return subprocess.run(
            ["adb", "exec-out", "screencap", *([] if raw else ["-p"])],
            capture_output=True,
            timeout=60,
            check=False,
        ).stdout


def walk_first_run(device: Device) -> None:
    """Accepts every first-run screen's default choice."""
    for _ in range(10):
        nodes = device.dump()
        start = find(nodes, "Start translating")
        if start is not None:
            device.capture("first-run-last")
            device.tap(start)
            return
        following = find(nodes, "Next")
        if following is None:
            device.note("first run: no Next or Start translating button")
            return
        device.capture("first-run")
        device.tap(following)
    device.note("first run: still not done after 10 screens")


def input_box(nodes: list[Node]) -> Node | None:
    """The translate box (the first text field on screen)."""
    return next((n for n in nodes if n.cls.endswith("EditText")), None)


def translated(nodes: list[Node]) -> bool:
    """Whether an English translation of [SENTENCE] is on screen (outside
    the translate box; the translation itself may be a read-only text
    field, see [result_node])."""
    return result_node(nodes, RESULT, exclude=input_box(nodes)) is not None


def close_dialogs(device: Device) -> None:
    """Closes a dialog over the screen (keyboard shortcuts, tips)."""
    nodes = device.dump()
    close = find(nodes, "Close|Dismiss|Got it|OK")
    if close is not None and input_box(nodes) is None:
        device.tap(close)


def box_text(device: Device) -> str:
    box = input_box(device.dump())
    return box.text if box else ""


def enter_sentence(device: Device) -> str:
    """Gets [SENTENCE] into the translate box: typed after a tap on the box
    (twice at most), else shared to Mozhi as another app would. Returns how
    it got there; raises when neither worked."""
    for attempt in range(2):
        close_dialogs(device)
        nodes = device.dump()
        box = input_box(nodes)
        if box is None:
            device.note("no text field on screen")
            break
        device.note(
            f"text field {box.bounds} focused={box.focused} "
            f"text=“{box.text}”"
        )
        device.tap(box)
        time.sleep(1)
        device.adb("shell", "input", "text", SENTENCE.replace(" ", "%s"))
        time.sleep(2)
        if SENTENCE.split()[0] in box_text(device):
            return "typed"
        device.note(f"typing attempt {attempt + 1} did not reach the box")
        close_dialogs(device)
    device.adb(*share_text_args(SENTENCE))
    time.sleep(5)
    if SENTENCE.split()[0] in box_text(device):
        return "shared"
    raise RuntimeError("the sentence did not reach the translate box")


def translate(device: Device) -> str:
    """Puts [SENTENCE] into the translate box and follows the app's offers
    ([OFFERS]) for up to 4 minutes. Returns how it got translated, or ""
    when no translation appeared."""
    entered = enter_sentence(device)
    device.capture("entered")
    device.note(f"translate box ({entered}): “{box_text(device)}”")
    route = "as typed"
    taken: set[str] = set()
    deadline = time.monotonic() + 240
    idle = 0
    while time.monotonic() < deadline:
        nodes = device.dump()
        if translated(nodes):
            device.capture("translated")
            return route
        for pattern, name in OFFERS:
            offer = find(nodes, pattern)
            if offer is not None and pattern not in taken:
                taken.add(pattern)
                route = name
                device.note(f"tapping “{offer.label}” ({name})")
                device.tap(offer)
                device.capture("offer")
                break
        else:
            # On a small screen the result (or what it offers) can be below
            # the composer, as in the Terminal look: look further down, and
            # back at the top now and then.
            idle += 1
            if idle % 2 == 0:
                # A swipe on the keyboard types instead of scrolling.
                hide_keyboard(device)
            if idle % 6 == 0:
                device.swipe(up=False)
                device.swipe(up=False)
            elif idle % 2 == 0:
                device.swipe(up=True)
            time.sleep(3)
    device.capture("not-translated")
    return ""


def raw_to_png(raw: bytes) -> bytes | None:
    """A 24-bit PNG (no alpha, as Google Play wants) of `screencap`'s raw
    output: width, height and format (little endian), on newer Androids a
    colour space, then RGBA or RGBX pixels. None for anything else."""
    if len(raw) < 12:
        return None
    width, height, pixel_format = struct.unpack_from("<III", raw)
    size = width * height * 4
    header = len(raw) - size
    if not width or not height or header not in (12, 16) or pixel_format not in (1, 2):
        return None
    pixels = memoryview(raw)[header:]
    rgb = bytearray(width * height * 3)
    for channel in range(3):
        rgb[channel::3] = pixels[channel::4]
    stride = width * 3
    rows = b"".join(
        b"\x00" + rgb[y * stride : (y + 1) * stride] for y in range(height)
    )

    def chunk(kind: bytes, data: bytes) -> bytes:
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(rows, 6))
        + chunk(b"IEND", b"")
    )


def keyboard_shown(dumpsys: str) -> bool:
    """Whether `dumpsys input_method` says the keyboard is on screen."""
    pattern = r"\b(mInputShown|mIsInputViewShown|isInputViewShown)=true\b"
    return bool(re.search(pattern, dumpsys))


def night_mode(output: str) -> str:
    """The setting `cmd uimode night` reports ("Night mode: no" -> "no");
    "no" when it can't be read."""
    match = re.search(
        r"Night mode:\s*(yes|no|auto|custom_schedule|custom_bedtime)", output
    )
    return match.group(1) if match else "no"


def store_name(index: int, screen: str, theme: str) -> str:
    return f"{index:02d}-{screen}-{theme}.png"


def store_screenshot(device: Device, path: Path) -> str:
    """Saves the screen as a 24-bit PNG at [path]; returns "" or what went
    wrong."""
    png = raw_to_png(device.screencap(raw=True))
    if png is None:
        png = device.screencap()
        if not png.startswith(b"\x89PNG"):
            return f"{path.name}: no screenshot"
        device.note(f"{path.name}: raw screencap unreadable, saved with alpha")
    path.write_bytes(png)
    return ""


def show_screen(device: Device, link: str) -> None:
    """Opens [link] in Mozhi, closes tips over it and the keyboard."""
    device.adb(
        "shell", "am", "start", "-W", "-n", ACTIVITY,
        "-a", "android.intent.action.VIEW", "-d", link,
    )
    time.sleep(3)
    tip = find(device.dump(), STORE_DISMISS)
    if tip is not None:
        device.tap(tip)
    if hide_keyboard(device) and not in_front(device):
        # Back closed Mozhi after all: open the screen again.
        device.note(f"{link}: Back closed Mozhi, opening it again")
        device.adb(
            "shell", "am", "start", "-W", "-n", ACTIVITY,
            "-a", "android.intent.action.VIEW", "-d", link,
        )
        time.sleep(3)


def in_front(device: Device) -> bool:
    """Whether a window of Mozhi has the focus (`dumpsys window`)."""
    out = device.adb("shell", "dumpsys", "window", "windows", check=False)
    focus = re.search(r"mCurrentFocus=.*", out)
    return focus is None or PACKAGE in focus.group(0)


def store_screenshots(device: Device, folder: Path) -> list[str]:
    """Saves [STORE_SCREENS] in both [STORE_THEMES] into [folder]; returns
    the screenshots that are missing. Puts the screen size (an earlier
    override too), the theme and the status bar back, whatever happens."""
    folder.mkdir(parents=True, exist_ok=True)
    missing: list[str] = []
    theme_before = night_mode(
        device.adb("shell", "cmd", "uimode", "night", check=False)
    )
    demo_before = device.adb(
        "shell", "settings", "get", "global", "sysui_demo_allowed", check=False
    ).strip()
    size_before = size_override(device.adb("shell", "wm", "size", check=False))
    try:
        device.adb("shell", "wm", "size", "x".join(map(str, STORE_SIZE)), check=False)
        device.adb(
            "shell", "settings", "put", "global", "sysui_demo_allowed", "1",
            check=False,
        )
        for command, *extras in DEMO_COMMANDS:
            device.adb(
                "shell", "am", "broadcast", "-a", "com.android.systemui.demo",
                "-e", "command", command, *extras, check=False,
            )
        for theme in STORE_THEMES:
            device.adb(
                "shell", "cmd", "uimode", "night", "yes" if theme == "dark" else "no",
                check=False,
            )
            time.sleep(3)
            for index, (screen, link) in enumerate(STORE_SCREENS, start=1):
                name = store_name(index, screen, theme)
                try:
                    show_screen(device, link)
                    problem = store_screenshot(device, folder / name)
                except (RuntimeError, subprocess.TimeoutExpired) as error:
                    problem = f"{name}: {error}"
                if problem:
                    missing.append(problem)
                labels = [n.label for n in device.dump() if n.label]
                device.note(f"[store {name}] {' | '.join(labels)[:300]}")
    finally:
        device.adb("shell", "cmd", "uimode", "night", theme_before, check=False)
        device.adb(
            "shell", "am", "broadcast", "-a", "com.android.systemui.demo",
            "-e", "command", "exit", check=False,
        )
        device.adb(
            "shell", "wm", "size", size_before or "reset", check=False
        )
        if demo_before in ("", "null"):
            device.adb(
                "shell", "settings", "delete", "global", "sysui_demo_allowed",
                check=False,
            )
        else:
            device.adb(
                "shell", "settings", "put", "global", "sysui_demo_allowed",
                demo_before, check=False,
            )
    return missing


class StepFailed(Exception):
    """A step of a flow that did not work; the message says which step
    and what went wrong."""


class TimedOut(StepFailed):
    """What a step waited for did not come in time."""


@dataclass(frozen=True)
class Offer:
    """A button a flow taps when it shows up while waiting ([follow]):
    [pattern] (its whole label), [name] (for the log), not before [after]
    seconds of waiting."""

    pattern: str
    name: str
    after: float = 0.0


COMMON_OFFERS = tuple(Offer(p, n) for p, n in COMMON_OFFERS_PATTERNS)

Check = Callable[[list[Node]], "Node | None"]


def one_line(text: str) -> str:
    return " ".join(text.split())


def any_of(*patterns: str) -> Check:
    """A [Check] for the first node matching one of [patterns]."""

    def check(nodes: list[Node]) -> Node | None:
        for pattern in patterns:
            node = find(nodes, pattern)
            if node is not None:
                return node
        return None

    return check


def wait_until(device: Device, check: Check, seconds: float) -> Node | None:
    """The node [check] finds on screen within [seconds], or None."""
    deadline = time.monotonic() + seconds
    while True:
        node = check(device.dump())
        if node is not None or time.monotonic() >= deadline:
            return node
        time.sleep(2)


def follow(
    device: Device,
    step: str,
    done: Check,
    what: str,
    seconds: float,
    offers: tuple[Offer, ...] | list[Offer] = (),
    errors: str | None = None,
    poll: Callable[[], None] | None = None,
    scroll: bool = False,
) -> tuple[Node, list[str]]:
    """Waits up to [seconds] for [done] to find [what] on screen, tapping
    the [offers] that show up (enabled buttons; each at most twice, again
    when it is still there 12 s after the first tap). [poll] runs before
    every look at the screen; with [scroll], a page that shows nothing new
    is scrolled towards its end (and back to the top now and then).
    Returns the node found and the names of the offers tapped. Raises
    [StepFailed] when a label matches [errors] or on timeout."""
    start = time.monotonic()
    deadline = start + seconds
    tapped: dict[str, list[float]] = {}
    idle = 0
    while time.monotonic() < deadline:
        if poll is not None:
            poll()
        nodes = device.dump()
        found = done(nodes)
        if found is not None:
            return found, list(tapped)
        if errors is not None:
            bad = result_node(nodes, errors)
            if bad is not None:
                raise StepFailed(f"{step}: “{one_line(bad.label)}” on screen")
        now = time.monotonic()
        offer_node = None
        for offer in offers:
            times = tapped.get(offer.name, [])
            if now - start < offer.after or len(times) >= 2:
                continue
            if times and now - times[-1] < 12:
                continue
            offer_node = find_clickable(nodes, offer.pattern)
            if offer_node is not None:
                again = ", again" if times else ""
                device.note(
                    f"{step}: tapping “{one_line(offer_node.label)}” "
                    f"({offer.name}{again})"
                )
                device.tap(offer_node)
                tapped[offer.name] = [*times, time.monotonic()]
                break
        if offer_node is not None:
            idle = 0
            continue
        idle += 1
        if scroll and idle % 12 == 0:
            for _ in range(3):
                device.swipe(up=False)
        elif scroll and idle % 3 == 0:
            device.swipe(up=True)
        else:
            time.sleep(2)
    names = ", ".join(tapped) or "nothing"
    raise TimedOut(
        f"{step}: {what} did not appear within {seconds:.0f} s (tapped: {names})"
    )


def tap_until(
    device: Device, step: str, pattern: str, then: Check, seconds: float = 20
) -> Node:
    """Taps the button whose label matches [pattern] and waits for [then];
    taps it once more when nothing happened. Returns what [then] found;
    raises [StepFailed] when there is no such button or it led nowhere."""
    for attempt in (1, 2):
        button = wait_until(
            device, lambda nodes: find_clickable(nodes, pattern), seconds
        )
        if button is None:
            if attempt == 2:
                break
            raise StepFailed(f"{step}: no “{pattern}” button within {seconds:.0f} s")
        device.note(f"{step}: tapping “{one_line(button.label)}”")
        device.tap(button)
        result = wait_until(device, then, seconds)
        if result is not None:
            return result
        device.note(f"{step}: nothing happened, tapping again")
    raise StepFailed(f"{step}: tapping “{pattern}” twice led nowhere")


def scroll_to(
    device: Device,
    pattern: str,
    step: str,
    seconds: float = 15,
    swipes: int = 4,
    clickable: bool = False,
) -> Node:
    """The node matching [pattern] ([clickable]: a clickable one), waited
    for, then scrolled to (towards the end of the page, at most [swipes]
    times)."""
    look = (lambda nodes: find_clickable(nodes, pattern)) if clickable else any_of(pattern)
    node = wait_until(device, look, seconds)
    if node is None:
        node = scroll_find(device, look, swipes)
    if node is None:
        raise StepFailed(f"{step}: “{pattern}” is not on the page")
    return node


def scroll_find(device: Device, check: Check, swipes: int = 4) -> Node | None:
    """What [check] finds on screen, scrolling towards the end of the page
    (at most [swipes] times) until it does; None when it never does."""
    node = check(device.dump())
    for _ in range(swipes):
        if node is not None:
            return node
        device.swipe(up=True)
        node = check(device.dump())
    return node


def page_text(device: Device, swipes: int = 10) -> list[str]:
    """Every label of the page, from its top (scrolled back first) to its
    end: each screen's labels that the screen before did not show."""
    for _ in range(3):
        device.swipe(up=False)
    lines: list[str] = []
    previous: set[str] = set()
    for index in range(swipes + 1):
        labels = [one_line(n.label) for n in device.dump() if n.label.strip()]
        new = [label for label in labels if label not in previous]
        if index and not new:
            break
        lines.extend(new)
        previous = set(labels)
        if index < swipes:
            device.swipe(up=True)
    return lines


# Lines of `logcat -v threadtime`: date, time, pid, tid, level, tag.
LOGCAT_LINE = re.compile(
    r"^\d\d-\d\d\s+[\d:.]+\s+(\d+)\s+\d+\s+[VDIWEFAS]\s+(.*?)\s*: "
)


def app_log_lines(log: str, pids: set[str], package: str = PACKAGE) -> list[str]:
    """The lines of `logcat -v threadtime` [log] written by Mozhi's
    processes ([pids]) or by Flutter (tag `flutter`), and those that name
    [package] (the system's about its activities and processes)."""
    lines = []
    for line in log.splitlines():
        match = LOGCAT_LINE.match(line)
        if match and (match.group(1) in pids or match.group(2) == "flutter"):
            lines.append(line)
        elif package in line:
            lines.append(line)
    return lines


def save_failure_log(device: Device, name: str, since: str | None, shown: int = 40) -> None:
    """Saves Mozhi's and Flutter's log since [since] (the flow's start;
    the whole log when unknown) as <step>-<name>-failed-logcat.txt and
    prints its last [shown] lines."""
    since_args = ("-t", since) if since else ()
    log = device.adb(
        "logcat", "-d", "-v", "threadtime", *since_args, check=False, timeout=60
    )
    lines = app_log_lines(log, device.app_pids())
    path = device.out / f"{device.step:02d}-{name}-failed-logcat.txt"
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(
        f"--- {name}: the last {min(shown, len(lines))} of {len(lines)} lines of "
        f"Mozhi's log since the flow started (all in {path.name}):",
        flush=True,
    )
    for line in lines[-shown:]:
        print(line, flush=True)


def save_page_text(device: Device, name: str) -> None:
    """Saves and prints every text of the page on screen (see [page_text])
    as <step>-<name>-failed-page.txt."""
    lines = page_text(device)
    path = device.out / f"{device.step:02d}-{name}-failed-page.txt"
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"--- {name}: the page from top to bottom ({path.name}):", flush=True)
    for line in lines:
        print(f"  {line}", flush=True)


def hide_keyboard(device: Device) -> bool:
    """Closes the keyboard with Back; returns whether Back was pressed.
    `dumpsys input_method` can still report the keyboard of a field on a
    page that is gone, and Back on the first page closes Mozhi: so Back is
    only pressed while a text field on screen has the focus."""
    if not keyboard_shown(device.adb("shell", "dumpsys", "input_method", check=False)):
        return False
    if not any(n.focused and n.cls.endswith("EditText") for n in device.dump()):
        device.note("keyboard: reported as shown, but no text field has the focus")
        return False
    device.adb("shell", "input", "keyevent", "4", check=False)
    time.sleep(1)
    return True


def open_settings_page(
    device: Device, step: str, taps: tuple[str, ...], link: str, arrived: Check
) -> Node:
    """Opens Settings and taps through [taps] (row labels) as a user would;
    when that does not lead to the page ([arrived]), opens it with its
    deep link [link] instead. Returns what [arrived] found."""
    show_screen(device, "mozhi://settings")
    try:
        for index, pattern in enumerate(taps):
            scroll_to(device, pattern, step, clickable=True)
            following = any_of(taps[index + 1]) if index + 1 < len(taps) else arrived
            tap_until(device, step, pattern, following)
        page = wait_until(device, arrived, 15)
        if page is not None:
            return page
        device.note(f"{step}: the page did not open")
    except StepFailed as error:
        device.note(str(error))
    device.capture("settings-not-found")
    device.note(f"{step}: opening {link} instead")
    show_screen(device, link)
    page = wait_until(device, arrived, 30)
    if page is None:
        raise StepFailed(f"{step}: neither the settings nor {link} showed the page")
    return page


def app_uid(device: Device) -> int:
    uid = package_uid(
        device.adb("shell", "cmd", "package", "list", "packages", "-U", PACKAGE,
                   check=False)
    )
    if uid is None:
        uid = package_uid(device.adb("shell", "dumpsys", "package", PACKAGE,
                                     check=False))
    if uid is None:
        raise StepFailed("find Mozhi's uid: neither cmd package nor dumpsys said")
    return uid


def traffic(device: Device, uid: int, label: str) -> dict[str, int | None]:
    """[uid]'s byte counters now (see [traffic_verdict]); the dump is
    saved as netstats-<label>.txt."""
    device.adb("shell", "dumpsys", "netstats", "--poll", check=False, timeout=60)
    dump = device.adb("shell", "dumpsys", "netstats", "--uid", check=False,
                      timeout=60)
    (device.out / f"netstats-{label}.txt").write_text(dump, encoding="utf-8")
    reading = {
        "netstats": netstats_uid_bytes(dump, uid),
        "bpf": bpf_uid_bytes(dump, uid),
    }
    device.note(f"traffic of uid {uid} ({label}): {reading}")
    return reading


def sockets(device: Device) -> str:
    return device.adb(
        "shell", "cat", "/proc/net/tcp", "/proc/net/tcp6", "/proc/net/udp",
        "/proc/net/udp6", check=False,
    )


def shared_box(nodes: list[Node], sentence: str) -> Node | None:
    """The translate box when it holds [sentence]."""
    box = input_box(nodes)
    return box if box is not None and sentence in box.text else None


def brought_to_front(output: str) -> bool:
    """Whether `am start` [output] says Android only brought an existing
    task to the front (the intent was not delivered)."""
    return "brought to the front" in output


def flow_offline_only(device: Device) -> str:
    """Switches the privacy mode to Offline only, opens the translate tab
    (as a user could), shares a new French sentence, checks that it
    reaches the translate box and that it is translated on the device:
    labelled Offline, and not one byte to or from the network for Mozhi's
    uid meanwhile."""
    open_settings_page(
        device, "open Privacy & data", (PRIVACY_CATEGORY,),
        "mozhi://settings/privacy", any_of(OFFLINE_ONLY),
    )
    option = scroll_to(device, OFFLINE_ONLY, "find Offline only")
    if not option.checked:

        def selected(nodes: list[Node]) -> Node | None:
            node = find(nodes, OFFLINE_ONLY)
            return node if node and (node.checked or not node.checkable) else None

        option = tap_until(device, "choose Offline only", OFFLINE_ONLY, selected)
    if not option.checkable:
        device.note("Offline only: the option does not say whether it is chosen")
    device.capture("offline-only-chosen")
    uid = app_uid(device)
    for index, (sentence, pattern) in enumerate(OFFLINE_SENTENCES, start=1):
        step = f"translate “{sentence}” offline"
        # The translate tab in front, as a user could have it.
        show_screen(device, "mozhi://translate")
        before = traffic(device, uid, f"before-{index}")
        remote: set[str] = set()

        def watch() -> None:
            remote.update(uid_connections(sockets(device), uid))

        output = device.shell_output(*share_text_args(sentence))
        device.note(f"{step}: shared with Mozhi (am: {one_line(output)[:300] or 'no output'})")
        if am_failed(output):
            raise StepFailed(f"{step}: sharing was refused: {one_line(output)[:300]}")
        if wait_until(device, lambda nodes: shared_box(nodes, sentence), 30) is None:
            box = input_box(device.dump())
            shows = f"“{one_line(box.text)[:80]}”" if box else "no text field"
            why = (
                "; am only brought a task to the front, the intent was not delivered"
                if brought_to_front(output)
                else ""
            )
            raise StepFailed(
                f"{step}: the shared text did not reach the translate box "
                f"within 30 s (it shows {shows}){why}"
            )
        device.note(f"{step}: the shared text is in the translate box")
        result, tapped = follow(
            device,
            step,
            lambda nodes: result_node(nodes, pattern, exclude=input_box(nodes)),
            "the English translation",
            240,
            offers=(
                Offer(r"Download French.*", "download French"),
                *COMMON_OFFERS,
                Offer(r"Translate", "press Translate", after=20),
            ),
            poll=watch,
            scroll=True,
        )
        time.sleep(3)
        watch()
        device.capture(f"offline-only-translated-{index}")
        nodes = device.dump()
        after = traffic(device, uid, f"after-{index}")
        if "download French" in tapped and index < len(OFFLINE_SENTENCES):
            device.note(f"{step}: French was downloaded first; measuring again")
            continue
        result = result_node(nodes, pattern, exclude=input_box(nodes)) or result
        badge = offline_badge(nodes, result)
        if badge is None:
            raise StepFailed(
                f"{step}: the translation “{one_line(result.label)}” is not "
                "labelled Offline"
            )
        verdict, why = traffic_verdict(before, after)
        seen = f"; sockets seen: {', '.join(sorted(remote))}" if remote else ""
        if not verdict:
            raise StepFailed(f"check that nothing went over the network: {why}{seen}")
        return (
            f"“{one_line(result.label)[:80]}”, labelled "
            f"“{one_line(badge.label)[:40]}”; {why}{seen}"
        )
    raise StepFailed("translate offline: no sentence left")  # pragma: no cover


def push_shared_file(device: Device, local: Path, path: str, collection: str) -> list[str]:
    """Copies [local] to the shared storage at [path] (as another app's
    file) and returns the content URIs to share it with (see
    [stream_uris]), with its MediaStore id when MediaStore lists it."""
    remote = f"/sdcard/{path}"
    name = path.rsplit("/", 1)[-1]
    device.adb("push", str(local), remote, timeout=120)
    device.adb(
        "shell", "am", "broadcast", "-a",
        "android.intent.action.MEDIA_SCANNER_SCAN_FILE", "-d", f"file://{remote}",
        check=False,
    )
    identifier = None
    deadline = time.monotonic() + 30
    while identifier is None:
        for uri in (f"content://media/external/{collection}",
                    "content://media/external/file"):
            output = device.adb(
                "shell", "content", "query", "--uri", uri,
                "--projection", "_id:_display_name", check=False,
            )
            identifier = media_id(output, name)
            if identifier is not None:
                break
        if identifier is None:
            if time.monotonic() >= deadline:
                break
            time.sleep(2)
    device.note(f"{name}: MediaStore id {identifier}")
    device.pushed.append((
        remote,
        None if identifier is None
        else f"content://media/external/{collection}/{identifier}",
    ))
    return stream_uris(identifier, collection, path)


def clean_up(device: Device) -> None:
    """Deletes what the run left on the device: the files it pushed
    ([push_shared_file]) with their MediaStore entries (best effort: the
    shell may not be allowed to), and the accessibility dump. Never
    fails."""
    for remote, uri in device.pushed:
        try:
            if uri is not None:
                output = device.adb(
                    "shell", "content", "delete", "--uri", uri, check=False,
                    timeout=30,
                ).strip()
                if output:
                    device.note(f"clean up {uri}: {one_line(output)[:200]}")
            device.adb("shell", "rm", "-f", remote, check=False, timeout=30)
            # Drops a MediaStore entry left for the file now gone.
            device.adb(
                "shell", "am", "broadcast", "-a",
                "android.intent.action.MEDIA_SCANNER_SCAN_FILE", "-d",
                f"file://{remote}", check=False, timeout=30,
            )
            device.note(f"clean up: deleted {remote}")
        except (RuntimeError, subprocess.TimeoutExpired) as error:
            device.note(f"clean up {remote}: {error}")
    device.pushed.clear()
    try:
        device.adb("shell", "rm", "-f", UI_DUMP, check=False, timeout=30)
    except (RuntimeError, subprocess.TimeoutExpired):
        pass


def share_file(
    device: Device,
    flow: str,
    uris: list[str],
    mime: str,
    loaded: tuple[str, ...],
    empty: str,
) -> str:
    """Shares the file with Mozhi through the first of [uris] that gets it
    onto the screen ([loaded] labels; [empty]: the screen without a
    file). Returns that URI."""
    step = f"share the {mime} file"
    for uri in uris:
        output = device.shell_output(*share_stream_args(uri, mime))
        if am_failed(output):
            device.note(f"{step}: refused for {uri}: {one_line(output)[:300]}")
            continue
        device.note(f"{step}: shared {uri}")
        node = wait_until(device, any_of(*loaded, empty), 45)
        if node is not None and re.fullmatch(
            empty, node.label.strip(), re.IGNORECASE | re.DOTALL
        ):
            # The screen may show its empty state for a moment before it
            # reads the file.
            node = wait_until(device, any_of(*loaded), 10)
        if node is not None:
            return uri
        device.note(f"{step}: Mozhi did not show the file shared as {uri}")
        device.capture(f"{flow}-not-shared")
    raise StepFailed(f"{step}: Mozhi got the file through none of {', '.join(uris)}")


def flow_image(device: Device) -> str:
    """Shares a picture of French text, accepts the text recognition data
    download and checks that the English translation appears."""
    uris = push_shared_file(device, IMAGE_ASSET, IMAGE_REMOTE, "images/media")
    uri = share_file(device, "image", uris, "image/png", IMAGE_LOADED, IMAGE_EMPTY)
    device.capture("image-shared")
    result, tapped = follow(
        device,
        "translate the image",
        lambda nodes: result_node(nodes, IMAGE_RESULT),
        "the English text",
        360,
        offers=(
            Offer(r"Download .+ text recognition.*", "download text recognition"),
            *COMMON_OFFERS,
            Offer(r"Translate image", "press Translate image"),
        ),
        scroll=True,
    )
    device.capture("image-translated")
    return (
        f"shared as {uri}; “{one_line(result.label)[:80]}” "
        f"(tapped: {', '.join(tapped) or 'nothing'})"
    )


def flow_document(device: Device) -> str:
    """Shares a French .txt file, translates it and checks that the result
    screen shows English text."""
    local = device.out / DOCUMENT_NAME
    local.write_text("\n".join(DOCUMENT_LINES) + "\n", encoding="utf-8")
    uris = push_shared_file(device, local, f"Download/{DOCUMENT_NAME}", "downloads")
    uri = share_file(
        device, "document", uris, "text/plain", DOCUMENT_LOADED, DOCUMENT_EMPTY
    )
    device.capture("document-shared")
    tap_until(
        device,
        "translate the document",
        r"Translate",
        lambda nodes: any_of(
            r"(?s)Translating….*", r"Translation complete", r"Translate again"
        )(nodes) or result_node(nodes, DOCUMENT_RESULT),
    )
    result, _ = follow(
        device,
        "translate the document",
        lambda nodes: result_node(nodes, DOCUMENT_RESULT),
        "the English text",
        240,
        offers=COMMON_OFFERS,
        errors=r"(?s)Failed parts\b.*",
        scroll=True,
    )
    device.capture("document-translated")
    return f"shared as {uri}; “{one_line(result.label)[:80]}”"


def language_row(nodes: list[Node], language: str) -> Node | None:
    """The offline languages' row of [language]: a label whose first line
    is its name (not the search field, which holds the name too)."""
    for node in nodes:
        if node.cls.endswith("EditText") or not node.label.strip():
            continue
        if node.label.strip().splitlines()[0].strip() == language:
            return node
    return None


def download_button(nodes: list[Node], row: Node, language: str) -> Node:
    """The row's Download pill; when the row is one merged node, a tap
    target where the pill is (the row's end)."""
    button = row_button(nodes, row, rf"Download(\s+{re.escape(language)})?")
    if button is not None:
        return button
    left, top, right, bottom = row.bounds
    return Node("Download", "", "", (max(left, right - 220), top, right - 20, bottom),
                True, False)


def offline_page(nodes: list[Node]) -> Node | None:
    """What shows that the offline languages page is open: its header
    ("No languages downloaded", "2 languages downloaded"), its search
    field, its "Available to download" section, or its title while the
    settings row that opens it (whose heading is the same) is not on
    screen."""
    return (
        find(nodes, OFFLINE_COUNT)
        or find(nodes, OFFLINE_SEARCH)
        or input_box(nodes)
        or find(nodes, r"Available to download")
        or (find(nodes, OFFLINE_TITLE) if find(nodes, OFFLINE_SETTINGS_ROW) is None else None)
    )


def flow_cancel(device: Device) -> str:
    """Starts downloading [CANCEL_LANGUAGE] in Settings > Translation
    engines > Offline languages, cancels it and checks that the row is back
    to Download, with no error."""
    language = CANCEL_LANGUAGE
    cancel_label = rf"Cancel downloading {re.escape(language)}"
    errors = (
        rf"(?is)(?=.*\b{re.escape(language)}\b)"
        r".*\b(couldn.t|can.t|failed|error|damaged|not enough)\b.*"
    )

    open_settings_page(
        device, "open Offline languages", (ENGINES_CATEGORY, OFFLINE_LANGUAGES),
        "mozhi://settings/offline", offline_page,
    )
    search = scroll_find(
        device, lambda nodes: find(nodes, OFFLINE_SEARCH) or input_box(nodes)
    )
    if search is not None:
        device.tap(search)
        device.adb("shell", "input", "text", language)
        time.sleep(2)
        hide_keyboard(device)
    else:
        device.note(f"find {language}: no search field on the page")
    row = wait_until(device, lambda n: language_row(n, language), 15)
    if row is None:
        row = scroll_find(device, lambda n: language_row(n, language))
    if row is None:
        raise StepFailed(f"find {language}: it is not in the list")
    device.capture("cancel-before")
    nodes = device.dump()
    if row_button(nodes, row, r"Downloaded|Delete.*|Update"):
        raise StepFailed(f"find {language}: it is downloaded already")
    if re.search(r"Downloading|Stopping", row.label):
        raise StepFailed(f"find {language}: it is downloading already")
    slow = device.shell_output("emu", "network", "speed", SLOW_NETWORK, timeout=30)
    device.note(f"emulator network speed {SLOW_NETWORK}: {one_line(slow)[:200]}")
    throttled: list[str] = []
    try:
        throttled = throttle_https(device)
        cancel = None
        for attempt in (1, 2):
            nodes = device.dump()
            current = language_row(nodes, language) or row
            if attempt == 2 and row_button(nodes, current, r"Downloaded|Delete.*|Update"):
                how = ", ".join(throttled) or "not slowed: no root or no iptables"
                raise StepFailed(
                    f"download {language}: it finished before “Cancel downloading "
                    f"{language}” was seen (network {how})"
                )
            if attempt == 1 or not re.search(r"Downloading", current.label):
                button = download_button(nodes, current, language)
                again = " again" if attempt == 2 else ""
                device.note(
                    f"download {language}: tapping “{button.label}”{again} "
                    f"at {button.center}"
                )
                device.tap(button)
            try:
                cancel, _ = follow(
                    device,
                    f"download {language}",
                    lambda n: find_clickable(n, cancel_label),
                    f"“Cancel downloading {language}”",
                    15 * attempt,
                    offers=COMMON_OFFERS,
                    errors=errors,
                )
                break
            except TimedOut as error:
                if attempt == 2:
                    raise
                device.note(str(error))
        assert cancel is not None
        device.capture("cancel-downloading")
        device.note(f"cancel: tapping “{one_line(cancel.label)}”")
        device.tap(cancel)
        back, _ = follow(
            device,
            f"cancel downloading {language}",
            lambda n: cancelled_row(n, language),
            f"{language} without its download",
            90,
            offers=(Offer(cancel_label, "press Cancel again", 15),),
            errors=errors,
        )
    finally:
        unthrottle_https(device, throttled)
        device.shell_output("emu", "network", "speed", "full", timeout=30)
    # An error would come as a snack bar after the row has settled.
    time.sleep(3)
    device.capture("cancel-done")
    nodes = device.dump()
    bad = result_node(nodes, errors)
    if bad is not None:
        raise StepFailed(f"cancel: “{one_line(bad.label)}” on screen")
    current = cancelled_row(nodes, language)
    if current is None:
        raise StepFailed(f"cancel: {language}'s row is not back to Download")
    return f"{language}: “{one_line(current.label)[:80]}”, no error"


def throttle_https(device: Device) -> list[str]:
    """Slows HTTPS downloads on the device with [THROTTLE_RULES]; returns
    the tables that took them (none without root or iptables, noted)."""
    root = device.shell_output("root", timeout=60)
    device.shell_output("wait-for-device", timeout=60)
    uid = device.shell_output("shell", "id", "-u", timeout=30).strip()
    if uid != "0":
        device.note(f"slow HTTPS: no root ({one_line(root)[:120]})")
        return []
    done: list[str] = []
    for table in THROTTLE_TABLES:
        added: list[tuple[str, ...]] = []
        for rule in THROTTLE_RULES:
            # adb runs the line with the device's shell, so `&&` is its.
            out = device.shell_output(
                "shell", table, "-w", "-I", "INPUT", "1", *rule,
                "&&", "echo", THROTTLE_OK, timeout=30,
            )
            if THROTTLE_OK not in out:
                device.note(f"slow HTTPS: {table}: {one_line(out)[:160]}")
                break
            added.append(rule)
        if len(added) == len(THROTTLE_RULES):
            done.append(table)
        else:
            for rule in added:
                device.shell_output("shell", table, "-w", "-D", "INPUT", *rule,
                                    timeout=30)
    device.note(f"slow HTTPS: {', '.join(done) or 'no table took the rules'}")
    return done


def unthrottle_https(device: Device, tables: list[str]) -> None:
    """Deletes the rules [throttle_https] added to [tables]."""
    for table in tables:
        for rule in THROTTLE_RULES:
            device.shell_output("shell", table, "-w", "-D", "INPUT", *rule,
                                timeout=30)


def cancelled_row(nodes: list[Node], language: str) -> Node | None:
    """[language]'s row when its download has stopped and it is not
    downloaded (no Cancel, no "Downloading…" or "Stopping…"); raises
    [StepFailed] when it is downloaded."""
    if find(nodes, rf"Cancel downloading {re.escape(language)}") is not None:
        return None
    row = language_row(nodes, language)
    if row is None or re.search(r"Downloading|Stopping", row.label):
        return None
    if row_button(nodes, row, r"Downloaded|Delete.*|Update"):
        raise StepFailed(f"cancel: {language} finished downloading before Cancel")
    return row


# Voice input: the microphone of the translate box (VoiceInputButton's
# tooltip "Speak"), what it must lead to, and errors it must not show.
VOICE_MIC = r"Speak"
VOICE_OFFER = r"Download the speech model\?"
VOICE_DOWNLOAD = r"Download \([0-9.,]+ [KMG]B\)"
VOICE_LISTENING = r"Stop listening|Listening…"
VOICE_ERRORS = (
    r"(?s).*(Speech recognition isn’t available|Voice input failed|"
    r"Couldn’t use the microphone|Microphone access is off).*"
)


def flow_voice(device: Device) -> str:
    """Taps Speak on the translate tab with the microphone allowed; the
    offline speech model must be offered with its size (no recogniser,
    no model yet), or the recogniser must listen. See the docstring."""
    device.adb(
        "shell", "pm", "grant", PACKAGE, "android.permission.RECORD_AUDIO",
        check=False,
    )
    show_screen(device, "mozhi://translate")
    answer = any_of(VOICE_OFFER, VOICE_LISTENING, VOICE_ERRORS)
    found = tap_until(device, "tap Speak", VOICE_MIC, answer, seconds=30)
    nodes = device.capture("voice-answer")
    if re.fullmatch(VOICE_ERRORS, found.label.strip(), re.DOTALL):
        raise StepFailed(f"voice: “{one_line(found.label)}”")
    if find(nodes, VOICE_OFFER) is not None:
        download = wait_until(
            device, lambda nodes: find_clickable(nodes, VOICE_DOWNLOAD), 20
        )
        if download is None:
            raise StepFailed("voice: the model offer names no download size")
        not_now = find_clickable(device.dump(), r"Not now")
        if not_now is not None:
            device.tap(not_now)
        return f"no recogniser: offered “{one_line(download.label)}”"
    stop = find_clickable(nodes, VOICE_LISTENING)
    if stop is not None:
        device.tap(stop)
    return f"a recogniser listened (“{one_line(found.label)}”)"


# Conversation: the large microphone (ConversationSessionMic's label),
# what it may lead to and the errors it must not show.
CONVERSATION_MIC = r"Start conversation"
# The status while the conversation listens (or still starts).
CONVERSATION_LISTENING = r"(?s)Listening in .*"
# A recogniser listened and heard nothing (the emulator has no audio).
CONVERSATION_SILENCE = r"(?s)Didn.t hear anything\b.*"
CONVERSATION_ERRORS = (
    r"(?s).*(Speech recognition isn’t available|Voice input failed|"
    r"Couldn’t use the microphone|Microphone access is off|"
    r"There’s no speech recognition service|"
    r"Voice input needs the offline speech model).*"
)


def flow_conversation_voice(device: Device) -> str:
    """Taps the Conversation tab's large microphone with the microphone
    allowed; the offline speech model must be offered with its size, or
    a recogniser must listen. See the docstring."""
    device.adb(
        "shell", "pm", "grant", PACKAGE, "android.permission.RECORD_AUDIO",
        check=False,
    )
    show_screen(device, "mozhi://conversation")
    final = any_of(VOICE_OFFER, CONVERSATION_ERRORS, CONVERSATION_SILENCE)
    answer = any_of(VOICE_OFFER, CONVERSATION_ERRORS, CONVERSATION_SILENCE,
                    CONVERSATION_LISTENING)
    found = tap_until(
        device, "tap Start conversation", CONVERSATION_MIC, answer, seconds=30
    )
    if re.fullmatch(CONVERSATION_LISTENING, found.label.strip()):
        # Starting or listening: an offer, an error or the pause after
        # silence follows (a conversation that never gets further is the
        # microphone doing nothing).
        found = wait_until(device, final, 40)
        if found is None:
            raise StepFailed(
                "conversation-voice: still starting or listening after 40 s"
            )
    if re.fullmatch(CONVERSATION_ERRORS, found.label.strip(), re.DOTALL):
        # The failure's status may show a moment before the offer opens.
        found = wait_until(device, any_of(VOICE_OFFER), 4) or found
    nodes = device.capture("conversation-voice-answer")
    if re.fullmatch(CONVERSATION_ERRORS, found.label.strip(), re.DOTALL):
        raise StepFailed(f"conversation-voice: “{one_line(found.label)}”")
    if find(nodes, VOICE_OFFER) is not None:
        download = wait_until(
            device, lambda nodes: find_clickable(nodes, VOICE_DOWNLOAD), 20
        )
        if download is None:
            raise StepFailed(
                "conversation-voice: the model offer names no download size"
            )
        not_now = find_clickable(device.dump(), r"Not now")
        if not_now is not None:
            device.tap(not_now)
        return f"no recogniser: offered “{one_line(download.label)}”"
    return f"a recogniser listened (“{one_line(found.label)}”)"


@dataclass(frozen=True)
class FlowResult:
    name: str
    title: str
    status: str  # passed, failed, skipped, not run
    detail: str


def flow_function(name: str) -> Callable[[Device], str]:
    """flow_<name> (looked up when called, so tests can replace it)."""
    return globals()["flow_" + name.replace("-", "_")]


def run_flows(device: Device, skip: set[str]) -> list[FlowResult]:
    """Runs [FLOWS] but those in [skip], each on its own: a failure is
    recorded with a screenshot and what was on screen, and the next flow
    still runs."""
    results = []
    for name, title in FLOWS:
        if name in skip:
            device.note(f"=== {title}: skipped (--skip-{name})")
            results.append(FlowResult(name, title, "skipped", f"--skip-{name}"))
            continue
        device.note(f"=== {title} ({name})")
        started = time.monotonic()
        try:
            since = device.log_time()
        except (RuntimeError, OSError, subprocess.TimeoutExpired):
            since = None
        try:
            status, detail = "passed", flow_function(name)(device)
        except StepFailed as error:
            status, detail = "failed", str(error)
        except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
            status, detail = "failed", f"{type(error).__name__}: {error}"
        if status == "passed" and not device.alive():
            status, detail = "failed", "Mozhi is no longer running"
        if status == "failed":
            try:
                nodes = device.capture(f"{name}-failed")
            except (RuntimeError, OSError, subprocess.TimeoutExpired):
                nodes = []
            detail += f"\n  on screen: {labels_of(nodes, 500) or '(nothing readable)'}"
            for save in (
                lambda: save_failure_log(device, name, since),
                lambda: save_page_text(device, name),
            ):
                try:
                    save()
                except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
                    device.note(f"{name}: diagnostics incomplete: {error}")
        seconds = time.monotonic() - started
        device.note(f"=== {title}: {status} after {seconds:.0f} s: {detail}")
        results.append(FlowResult(name, title, status, detail))
    return results


def take_flag(argv: list[str], flag: str) -> tuple[list[str], bool]:
    """[argv] without [flag], and whether it held it."""
    rest = [arg for arg in argv if arg != flag]
    return rest, len(rest) != len(argv)


def device_problem(device: Device, allow_real_device: bool) -> str | None:
    """Why the smoke test must not run on the device (see the docstring),
    or None. Raises RuntimeError when adb fails."""
    if not allow_real_device:
        kernel = device.adb("shell", "getprop", "ro.kernel.qemu", check=False)
        boot = device.adb("shell", "getprop", "ro.boot.qemu", check=False)
        if not is_emulator(kernel, boot):
            return (
                "this is not an emulator (ro.kernel.qemu and ro.boot.qemu are "
                "not 1): run the smoke test on a fresh emulator, or pass "
                "--allow-real-device to run it on this phone anyway."
            )
    try:
        listed = device.adb(
            "shell", "pm", "list", "packages", "--user", "all", PACKAGE
        )
    except RuntimeError as error:
        return f"can't tell whether Mozhi is installed ({error})."
    if PACKAGE in installed_packages(listed):
        return (
            f"{PACKAGE} is already installed on this device: run the smoke "
            "test on a fresh emulator (it would use this device's own data)."
        )
    return None


def split_skips(argv: list[str]) -> tuple[list[str], set[str]] | None:
    """Takes the --skip-<flow> flags out of [argv]: (the other arguments,
    the flows to skip), or None for a --skip- flag of no flow."""
    names = {name for name, _ in FLOWS}
    rest: list[str] = []
    skip: set[str] = set()
    for arg in argv:
        if arg.startswith("--skip-"):
            name = arg[len("--skip-"):]
            if name not in names:
                return None
            skip.add(name)
        else:
            rest.append(arg)
    return rest, skip


def parse_args(argv: list[str]) -> tuple[Path, Path, Path | None] | None:
    """<apk> <out-dir> [--screenshots <dir>] (also --screenshots=<dir>), or
    None when that's not what [argv] holds."""
    rest: list[str] = []
    shots: Path | None = None
    args = iter(argv)
    for arg in args:
        if arg == "--screenshots":
            value = next(args, None)
            if value is None or shots is not None:
                return None
            shots = Path(value)
        elif arg.startswith("--screenshots="):
            if shots is not None or arg == "--screenshots=":
                return None
            shots = Path(arg.split("=", 1)[1])
        else:
            rest.append(arg)
    if len(rest) != 2:
        return None
    return Path(rest[0]), Path(rest[1]), shots


def flow_lines(results: list[FlowResult], ran: bool) -> list[str]:
    """The summary's line of each flow."""
    if not ran:
        return [f"- {title}: not run (the first run did not finish)"
                for _, title in FLOWS]
    lines = []
    for result in results:
        first = result.detail.splitlines()[0] if result.detail else ""
        lines.append(f"- {result.title}: {result.status}" + (f" ({first})" if first else ""))
    return lines


def main(argv: list[str]) -> int:
    argv, allow_real_device = take_flag(argv, "--allow-real-device")
    split = split_skips(argv)
    parsed = parse_args(split[0]) if split is not None else None
    if split is None or parsed is None:
        print(__doc__)
        return 2
    skip = split[1]
    apk, out, shots = parsed
    out.mkdir(parents=True, exist_ok=True)
    device = Device(out)
    failures: list[str] = []
    missing_shots: list[str] = []
    shots_taken = False
    route = ""
    # Meant for a fresh emulator (see the docstring).
    try:
        problem = device_problem(device, allow_real_device)
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        problem = f"adb failed: {error}"
    if problem is not None:
        print(f"Refusing to run: {problem}")
        return 2
    try:
        # The log from now on, without clearing the device's.
        device.log_since = log_start(
            device.adb("shell", "date", "+%s", check=False)
        )
        device.adb("install", str(apk), timeout=600)
        device.adb("shell", "am", "start", "-W", "-n", ACTIVITY)
        first = device.wait_for(r".+", 90)
        device.capture("start")
        if first is None:
            failures.append("no screen with text appeared within 90 s")
        else:
            walk_first_run(device)
            time.sleep(3)
            device.capture("translate-tab")
            route = translate(device)
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        failures.append(str(error))
    if shots is not None and not failures:
        if not route:
            device.note("store screenshots: the translate screen has no translation")
        try:
            missing_shots = store_screenshots(device, shots)
            shots_taken = True
        except (RuntimeError, subprocess.TimeoutExpired) as error:
            missing_shots = [f"store screenshots stopped: {error}"]
    flows_ran = not failures
    try:
        flow_results = run_flows(device, skip) if flows_ran else []
    finally:
        clean_up(device)
    flow_failures = [
        f"{r.title} ({r.name}) failed: {r.detail}"
        for r in flow_results
        if r.status == "failed"
    ]
    crashes = device.crashes()
    if crashes:
        failures.append("Mozhi crashed:\n" + "\n".join(crashes))
    elif not device.alive():
        failures.append("Mozhi is no longer running")
    total = len(STORE_SCREENS) * len(STORE_THEMES)
    shots_line = (
        f"{total - len(missing_shots)} of {total} in {shots}"
        if shots_taken
        else "not taken"
    )
    (out / "logcat.txt").write_text(device.logcat(), encoding="utf-8")
    summary = [
        "### Android emulator smoke test",
        "",
        f"- Started and walked through the first run: "
        f"{'no' if failures else 'yes'}",
        f"- Translated “{SENTENCE}” into English: "
        f"{f'yes ({route})' if route else 'no'}",
        *([f"- Store screenshots: {shots_line}"] if shots is not None else []),
        *flow_lines(flow_results, flows_ran),
        "",
        "```text",
        *device.log,
        *failures,
        *flow_failures,
        *missing_shots,
        "```",
    ]
    (out / "summary.md").write_text("\n".join(summary) + "\n", encoding="utf-8")
    problems = failures + flow_failures
    print("\n".join(problems) if problems else "smoke test passed")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
