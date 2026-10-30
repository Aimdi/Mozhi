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
"""

from __future__ import annotations

import re
import struct
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
import zlib
from dataclasses import dataclass
from pathlib import Path

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


@dataclass(frozen=True)
class Node:
    text: str
    description: str
    cls: str
    bounds: tuple[int, int, int, int]
    clickable: bool
    focused: bool

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


class Device:
    def __init__(self, out: Path) -> None:
        self.out = out
        self.step = 0
        self.log: list[str] = []

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

    def note(self, message: str) -> None:
        print(message, flush=True)
        self.log.append(message)

    def dump(self) -> list[Node]:
        for _ in range(3):
            self.adb("shell", "uiautomator", "dump", "/sdcard/ui.xml", check=False)
            xml = self.adb("shell", "cat", "/sdcard/ui.xml", check=False)
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
        self.adb("shell", "uiautomator", "dump", "/sdcard/ui.xml", check=False)
        xml = self.adb("shell", "cat", "/sdcard/ui.xml", check=False)
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
        return bool(self.adb("shell", "pidof", PACKAGE, check=False).strip())

    def crashes(self) -> list[str]:
        return crash_lines(self.adb("logcat", "-d", check=False, timeout=60))

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
    the text field)."""
    regex = re.compile(RESULT, re.IGNORECASE | re.DOTALL)
    return any(
        regex.fullmatch(n.label.strip())
        for n in nodes
        if n.label and not n.cls.endswith("EditText")
    )


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
    device.adb(
        "shell", "am", "start", "-a", "android.intent.action.SEND",
        "-t", "text/plain",
        "--es", "android.intent.extra.TEXT", f"'{SENTENCE}'",
        "-p", PACKAGE,
    )
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
    if keyboard_shown(device.adb("shell", "dumpsys", "input_method", check=False)):
        device.adb("shell", "input", "keyevent", "4")
        time.sleep(1)


def store_screenshots(device: Device, folder: Path) -> list[str]:
    """Saves [STORE_SCREENS] in both [STORE_THEMES] into [folder]; returns
    the screenshots that are missing. Puts the screen size, the theme and
    the status bar back, whatever happens."""
    folder.mkdir(parents=True, exist_ok=True)
    missing: list[str] = []
    theme_before = night_mode(
        device.adb("shell", "cmd", "uimode", "night", check=False)
    )
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
        device.adb("shell", "wm", "size", "reset", check=False)
    return missing


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


def main(argv: list[str]) -> int:
    parsed = parse_args(argv)
    if parsed is None:
        print(__doc__)
        return 2
    apk, out, shots = parsed
    out.mkdir(parents=True, exist_ok=True)
    device = Device(out)
    failures: list[str] = []
    missing_shots: list[str] = []
    shots_taken = False
    route = ""
    try:
        device.adb("logcat", "-c", check=False)
        device.adb("install", "-r", str(apk), timeout=600)
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
    (out / "logcat.txt").write_text(
        device.adb("logcat", "-d", check=False, timeout=60), encoding="utf-8"
    )
    summary = [
        "### Android emulator smoke test",
        "",
        f"- Started and walked through the first run: "
        f"{'no' if failures else 'yes'}",
        f"- Translated “{SENTENCE}” into English: "
        f"{f'yes ({route})' if route else 'no'}",
        *([f"- Store screenshots: {shots_line}"] if shots is not None else []),
        "",
        "```text",
        *device.log,
        *failures,
        *missing_shots,
        "```",
    ]
    (out / "summary.md").write_text("\n".join(summary) + "\n", encoding="utf-8")
    print("\n".join(failures) if failures else "smoke test passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
