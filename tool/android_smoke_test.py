#!/usr/bin/env python3
"""Tests for android_smoke.py's screen and log parsing and its store
screenshots (no device needed).

  python3 tool/android_smoke_test.py
"""

from __future__ import annotations

import contextlib
import io
import struct
import sys
import tempfile
import unittest
import zlib
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import android_smoke as smoke  # noqa: E402

DUMP = """<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>
<hierarchy rotation="0">
  <node index="0" text="" content-desc="" class="android.widget.FrameLayout"
        clickable="false" focused="false" bounds="[0,0][1080,2400]">
    <node index="0" text="" content-desc="Welcome to Mozhi"
          class="android.view.View" clickable="false" focused="false"
          bounds="[40,200][1040,320]" />
    <node index="1" text="" content-desc="Next" class="android.view.View"
          clickable="false" focused="false" bounds="[600,2200][1040,2300]" />
    <node index="2" text="" content-desc="Next" class="android.widget.Button"
          clickable="true" focused="false" bounds="[620,2210][1020,2290]" />
    <node index="3" text="Hello" content-desc="" class="android.widget.EditText"
          clickable="true" focused="true" bounds="[40,400][1040,700]" />
    <node index="4" text="Hidden" content-desc="" class="android.view.View"
          clickable="true" focused="false" bounds="[0,0][0,0]" />
  </node>
</hierarchy>
"""


class ParseNodesTest(unittest.TestCase):
    def test_reads_labels_classes_and_bounds(self):
        nodes = smoke.parse_nodes(DUMP)

        self.assertEqual(
            [n.label for n in nodes],
            ["", "Welcome to Mozhi", "Next", "Next", "Hello"],
        )
        box = nodes[4]
        self.assertTrue(box.cls.endswith("EditText"))
        self.assertTrue(box.focused)
        self.assertEqual(box.bounds, (40, 400, 1040, 700))
        self.assertEqual(box.center, (540, 550))

    def test_skips_nodes_without_a_size(self):
        self.assertNotIn("Hidden", [n.label for n in smoke.parse_nodes(DUMP)])

    def test_survives_a_broken_dump(self):
        self.assertEqual(smoke.parse_nodes("ERROR: null root node"), [])
        self.assertEqual(smoke.parse_nodes(""), [])


class FindTest(unittest.TestCase):
    def test_matches_the_whole_label_ignoring_case(self):
        nodes = smoke.parse_nodes(DUMP)

        self.assertEqual(smoke.find(nodes, "welcome to mozhi").label,
                         "Welcome to Mozhi")
        self.assertIsNone(smoke.find(nodes, "Welcome"))
        self.assertIsNone(smoke.find(nodes, "Start translating"))

    def test_prefers_a_clickable_match(self):
        node = smoke.find(smoke.parse_nodes(DUMP), "Next")

        self.assertTrue(node.clickable)
        self.assertEqual(node.cls, "android.widget.Button")


class TranslatedTest(unittest.TestCase):
    def node(self, label: str, cls: str = "android.view.View") -> smoke.Node:
        return smoke.Node(label, "", cls, (0, 0, 10, 10), False, False)

    def test_finds_the_english_translation_outside_the_text_field(self):
        self.assertTrue(smoke.translated([
            self.node(smoke.SENTENCE, "android.widget.EditText"),
            self.node("I'm looking for the station"),
        ]))

    def test_ignores_the_text_field_and_other_labels(self):
        self.assertFalse(smoke.translated([
            self.node("Looking for the station", "android.widget.EditText"),
            self.node("Translate"),
            self.node("Stationery"),
        ]))

    def test_the_input_box_is_the_first_text_field(self):
        nodes = smoke.parse_nodes(DUMP)

        self.assertEqual(smoke.input_box(nodes).text, "Hello")
        self.assertIsNone(smoke.input_box([]))

    def test_offers_prefer_the_offline_download(self):
        self.assertTrue(smoke.OFFERS[0][1].startswith("offline"))


class CrashLinesTest(unittest.TestCase):
    def test_finds_a_java_crash_of_the_app(self):
        log = "\n".join([
            "I/ActivityManager: Start proc 1234:io.github.aimdi.mozhi",
            "E/AndroidRuntime: FATAL EXCEPTION: main",
            "E/AndroidRuntime: Process: io.github.aimdi.mozhi, PID: 1234",
            "E/AndroidRuntime: java.lang.IllegalStateException: boom",
        ])

        lines = smoke.crash_lines(log)

        self.assertTrue(any("IllegalStateException" in l for l in lines))

    def test_finds_a_native_crash_and_an_anr(self):
        log = "\n".join([
            "F/libc: Fatal signal 11 (SIGSEGV), code 1 in tid 99 "
            "(1.ui), pid 98 (io.github.aimdi.mozhi)",
            "E/ActivityManager: ANR in io.github.aimdi.mozhi "
            "(io.github.aimdi.mozhi/.MainActivity)",
        ])

        self.assertEqual(len(smoke.crash_lines(log)), 2)

    def test_ignores_other_apps(self):
        log = "\n".join([
            "E/AndroidRuntime: FATAL EXCEPTION: main",
            "E/AndroidRuntime: Process: com.android.systemui, PID: 77",
            "F/libc: Fatal signal 6 (SIGABRT) in pid 88 (com.example)",
        ])

        self.assertEqual(smoke.crash_lines(log), [])


def raw_screen(width: int, height: int, header: int = 16, fmt: int = 1) -> bytes:
    """screencap's raw output: a header, then RGBA pixels (red = x,
    green = y, blue = 7, alpha = 255)."""
    head = struct.pack("<III", width, height, fmt) + b"\x00" * (header - 12)
    pixels = b"".join(
        bytes((x, y, 7, 255)) for y in range(height) for x in range(width)
    )
    return head + pixels


def png_pixels(png: bytes) -> tuple[int, int, int, bytes]:
    """Width, height, colour type and the unfiltered rows of a PNG made
    by raw_to_png (filter type 0 on every row)."""
    assert png.startswith(b"\x89PNG\r\n\x1a\n")
    width, height, _, colour = struct.unpack(">IIBB", png[16:26])
    pos, data = 8, b""
    while pos < len(png):
        (length,) = struct.unpack(">I", png[pos : pos + 4])
        kind = png[pos + 4 : pos + 8]
        body = png[pos + 4 : pos + 8 + length]
        (crc,) = struct.unpack(">I", png[pos + 8 + length : pos + 12 + length])
        assert zlib.crc32(body) == crc
        if kind == b"IDAT":
            data += png[pos + 8 : pos + 8 + length]
        pos += 12 + length
    rows = zlib.decompress(data)
    stride = width * 3 + 1
    assert all(rows[i * stride] == 0 for i in range(height))
    pixels = b"".join(rows[i * stride + 1 : (i + 1) * stride] for i in range(height))
    return width, height, colour, pixels


class ParseArgsTest(unittest.TestCase):
    def test_the_default_run_takes_two_arguments(self):
        self.assertEqual(
            smoke.parse_args(["app.apk", "smoke"]),
            (Path("app.apk"), Path("smoke"), None),
        )

    def test_screenshots_take_a_folder(self):
        expected = (Path("app.apk"), Path("smoke"), Path("shots"))

        self.assertEqual(
            smoke.parse_args(["app.apk", "smoke", "--screenshots", "shots"]), expected
        )
        self.assertEqual(
            smoke.parse_args(["--screenshots", "shots", "app.apk", "smoke"]), expected
        )
        self.assertEqual(
            smoke.parse_args(["app.apk", "--screenshots=shots", "smoke"]), expected
        )

    def test_rejects_other_arguments(self):
        for argv in (
            [],
            ["app.apk"],
            ["app.apk", "smoke", "extra"],
            ["app.apk", "smoke", "--screenshots"],
            ["app.apk", "smoke", "--screenshots="],
            ["app.apk", "smoke", "--screenshots", "a", "--screenshots", "b"],
            ["app.apk", "smoke", "--screenshots", "a", "--screenshots=b"],
        ):
            self.assertIsNone(smoke.parse_args(argv), argv)

    def test_main_prints_the_usage_for_wrong_arguments(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(smoke.main(["app.apk"]), 2)
        self.assertIn("--screenshots <dir>", out.getvalue())


class RawToPngTest(unittest.TestCase):
    def test_drops_the_alpha_channel(self):
        for header in (12, 16):
            png = smoke.raw_to_png(raw_screen(3, 2, header))

            width, height, colour, pixels = png_pixels(png)
            self.assertEqual((width, height, colour), (3, 2, 2))
            self.assertEqual(
                pixels,
                bytes((0, 0, 7, 1, 0, 7, 2, 0, 7, 0, 1, 7, 1, 1, 7, 2, 1, 7)),
            )

    def test_accepts_rgbx(self):
        self.assertIsNotNone(smoke.raw_to_png(raw_screen(2, 2, fmt=2)))

    def test_rejects_what_it_cannot_read(self):
        self.assertIsNone(smoke.raw_to_png(b""))
        self.assertIsNone(smoke.raw_to_png(b"\x89PNG\r\n\x1a\n" + b"\x00" * 40))
        self.assertIsNone(smoke.raw_to_png(raw_screen(2, 2, fmt=4)))
        self.assertIsNone(smoke.raw_to_png(raw_screen(2, 2)[:-1]))
        self.assertIsNone(smoke.raw_to_png(struct.pack("<III", 0, 0, 1)))


class StoreHelpersTest(unittest.TestCase):
    def test_keyboard_shown(self):
        self.assertTrue(smoke.keyboard_shown("  mInputShown=true mShowRequested=true"))
        self.assertTrue(smoke.keyboard_shown("isInputViewShown=true"))
        self.assertFalse(smoke.keyboard_shown("mInputShown=false"))
        self.assertFalse(smoke.keyboard_shown(""))

    def test_night_mode(self):
        self.assertEqual(smoke.night_mode("Night mode: yes"), "yes")
        self.assertEqual(smoke.night_mode("Night mode: auto\n"), "auto")
        self.assertEqual(smoke.night_mode("cmd: Can't find service"), "no")

    def test_names_follow_the_listing_order(self):
        self.assertEqual(
            smoke.store_name(1, "translate", "dark"), "01-translate-dark.png"
        )

    def test_screens_and_size_fit_the_listing(self):
        width, height = smoke.STORE_SIZE
        self.assertLessEqual(height, 2 * width)
        self.assertEqual(
            [screen for screen, _ in smoke.STORE_SCREENS],
            ["translate", "image", "documents", "conversation", "settings"],
        )
        self.assertNotIn("camera", "".join(link for _, link in smoke.STORE_SCREENS))
        # Play shows at most 8 per device type: the folder is a pool.
        self.assertEqual(len(smoke.STORE_SCREENS) * len(smoke.STORE_THEMES), 10)


class FakeDevice(smoke.Device):
    """Answers adb like an emulator, records the commands."""

    def __init__(self, out: Path) -> None:
        super().__init__(out)
        self.calls: list[tuple[str, ...]] = []
        self.raw = raw_screen(4, 8)
        self.png = b""
        self.keyboard = False
        self.fail_on: tuple[str, ...] | None = None
        self.nodes: list[smoke.Node] = []

    def adb(self, *args: str, check: bool = True, timeout: int = 120) -> str:
        self.calls.append(args)
        if self.fail_on is not None and args[: len(self.fail_on)] == self.fail_on:
            raise RuntimeError("adb failed")
        if args[:4] == ("shell", "cmd", "uimode", "night") and len(args) == 4:
            return "Night mode: no\n"
        if args[:3] == ("shell", "dumpsys", "input_method"):
            return f"mInputShown={'true' if self.keyboard else 'false'}"
        if args[:2] == ("shell", "pidof"):
            return "1234\n"
        return ""

    def wait_for(self, pattern: str, seconds: float) -> smoke.Node | None:
        return smoke.Node("Welcome", "", "android.view.View", (0, 0, 9, 9),
                          False, False)

    def note(self, message: str) -> None:
        self.log.append(message)

    def dump(self) -> list[smoke.Node]:
        return self.nodes

    def tap(self, node: smoke.Node) -> None:
        self.calls.append(("tap", node.label))

    def screencap(self, raw: bool = False) -> bytes:
        return self.raw if raw else self.png


@mock.patch.object(smoke.time, "sleep", lambda _: None)
class StoreScreenshotsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.folder = Path(self.tmp.name) / "store"
        self.device = FakeDevice(Path(self.tmp.name))

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def links(self) -> list[str]:
        return [c[c.index("-d") + 1] for c in self.device.calls if "-d" in c]

    def test_saves_every_screen_in_both_themes(self):
        missing = smoke.store_screenshots(self.device, self.folder)

        self.assertEqual(missing, [])
        names = sorted(p.name for p in self.folder.iterdir())
        self.assertEqual(len(names), 10)
        self.assertIn("01-translate-light.png", names)
        self.assertIn("05-settings-dark.png", names)
        width, height, colour, _ = png_pixels(
            (self.folder / "02-image-dark.png").read_bytes()
        )
        self.assertEqual((width, height, colour), (4, 8, 2))
        links = [link for _, link in smoke.STORE_SCREENS]
        self.assertEqual(self.links(), links + links)

    def test_switches_the_theme_and_puts_everything_back(self):
        smoke.store_screenshots(self.device, self.folder)

        calls = self.device.calls
        self.assertIn(("shell", "wm", "size", "1080x2160"), calls)
        night = [
            c[4]
            for c in calls
            if c[:4] == ("shell", "cmd", "uimode", "night") and len(c) == 5
        ]
        self.assertEqual(night, ["no", "yes", "no"])
        self.assertEqual(calls[-1], ("shell", "wm", "size", "reset"))
        self.assertIn("exit", calls[-2])
        self.assertTrue(any("clock" in c for c in calls))

    def test_puts_everything_back_when_adb_fails(self):
        self.device.fail_on = ("shell", "cmd", "uimode", "night", "yes")

        with self.assertRaises(RuntimeError):
            smoke.store_screenshots(self.device, self.folder)

        self.assertEqual(self.device.calls[-1], ("shell", "wm", "size", "reset"))
        self.assertEqual(len(list(self.folder.iterdir())), 5)

    def test_closes_the_keyboard_and_tips(self):
        self.device.keyboard = True
        self.device.nodes = [
            smoke.Node("Got it", "", "android.widget.Button", (0, 0, 9, 9),
                       True, False),
            smoke.Node("Close", "", "android.widget.Button", (0, 0, 9, 9),
                       True, False),
        ]

        smoke.store_screenshots(self.device, self.folder)

        calls = self.device.calls
        self.assertEqual(calls.count(("shell", "input", "keyevent", "4")), 10)
        self.assertEqual(calls.count(("tap", "Got it")), 10)
        self.assertNotIn(("tap", "Close"), calls)

    def test_falls_back_to_the_png_screencap(self):
        self.device.raw = b""
        self.device.png = b"\x89PNG fallback"

        self.assertEqual(smoke.store_screenshots(self.device, self.folder), [])
        self.assertEqual(
            (self.folder / "03-documents-light.png").read_bytes(), b"\x89PNG fallback"
        )

    def test_reports_missing_screenshots(self):
        self.device.raw = b""
        self.device.fail_on = (
            "shell", "am", "start", "-W", "-n", smoke.ACTIVITY,
            "-a", "android.intent.action.VIEW", "-d", "mozhi://settings",
        )

        missing = smoke.store_screenshots(self.device, self.folder)

        self.assertEqual(len(missing), 10)
        self.assertTrue(any("05-settings-light.png: adb failed" in m for m in missing))
        self.assertTrue(
            any("01-translate-dark.png: no screenshot" in m for m in missing)
        )
        self.assertEqual(list(self.folder.iterdir()), [])



@mock.patch.object(smoke.time, "sleep", lambda _: None)
@mock.patch.object(smoke, "Device", FakeDevice)
@mock.patch.object(smoke, "walk_first_run", lambda device: None)
@mock.patch.object(smoke, "translate", lambda device: "offline: downloaded French")
class MainTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def run_main(self, *extra: str) -> tuple[int, str]:
        with contextlib.redirect_stdout(io.StringIO()):
            code = smoke.main(["app.apk", str(self.root / "smoke"), *extra])
        return code, (self.root / "smoke" / "summary.md").read_text(encoding="utf-8")

    def test_the_default_run_takes_no_store_screenshots(self):
        code, summary = self.run_main()

        self.assertEqual(code, 0)
        self.assertIn("yes (offline: downloaded French)", summary)
        self.assertNotIn("Store screenshots", summary)
        self.assertNotIn("[store", summary)

    def test_screenshots_follow_the_smoke_test(self):
        shots = self.root / "store"

        code, summary = self.run_main("--screenshots", str(shots))

        self.assertEqual(code, 0)
        self.assertIn(f"- Store screenshots: 10 of 10 in {shots}", summary)
        self.assertEqual(len(list(shots.iterdir())), 10)

    def test_no_screenshots_after_a_failed_smoke_test(self):
        def fail(device):
            raise RuntimeError("the sentence did not reach the translate box")

        with mock.patch.object(smoke, "translate", fail):
            code, summary = self.run_main("--screenshots", str(self.root / "store"))

        self.assertEqual(code, 1)
        self.assertIn("- Store screenshots: not taken", summary)
        self.assertFalse((self.root / "store").exists())


if __name__ == "__main__":
    unittest.main()
