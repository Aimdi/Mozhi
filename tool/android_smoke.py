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
"""

from __future__ import annotations

import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
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
        png = subprocess.run(
            ["adb", "exec-out", "screencap", "-p"],
            capture_output=True,
            timeout=60,
            check=False,
        ).stdout
        (self.out / f"{stem}.png").write_bytes(png)
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


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__)
        return 2
    apk, out = Path(argv[0]), Path(argv[1])
    out.mkdir(parents=True, exist_ok=True)
    device = Device(out)
    failures: list[str] = []
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
    crashes = device.crashes()
    if crashes:
        failures.append("Mozhi crashed:\n" + "\n".join(crashes))
    elif not device.alive():
        failures.append("Mozhi is no longer running")
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
        "",
        "```text",
        *device.log,
        *failures,
        "```",
    ]
    (out / "summary.md").write_text("\n".join(summary) + "\n", encoding="utf-8")
    print("\n".join(failures) if failures else "smoke test passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
