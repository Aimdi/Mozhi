#!/usr/bin/env python3
"""Tests for android_smoke.py's screen and log parsing and its store
screenshots (no device needed).

  python3 tool/android_smoke_test.py
"""

from __future__ import annotations

import contextlib
import io
import re
import struct
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
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

    def refused(self, answers, *extra):
        """main's exit code, what it printed and the adb calls it made on a
        device answering [answers] (argument prefix -> output, or an
        exception to raise)."""
        calls = []

        def adb(self, *args, check=True, timeout=120):
            calls.append(args)
            for prefix, answer in answers.items():
                if args[: len(prefix)] == prefix:
                    if isinstance(answer, Exception):
                        raise answer
                    return answer
            return ""

        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            smoke.Device, "adb", adb
        ), redirect_stdout(io.StringIO()) as out:
            code = smoke.main(["app.apk", tmp, *extra])
        self.assertFalse(any(c[:1] == ("install",) for c in calls))
        self.assertFalse(any(c[:2] == ("logcat", "-c") for c in calls))
        return code, out.getvalue(), calls

    EMULATOR = {("shell", "getprop", "ro.boot.qemu"): "1\n"}

    def test_main_refuses_a_device_where_mozhi_is_installed(self):
        code, out, calls = self.refused({
            **self.EMULATOR,
            ("shell", "pm", "list"):
                f"package:{smoke.PACKAGE} uid:10123\npackage:com.other\n",
        })
        self.assertEqual(code, 2)
        self.assertIn("already installed", out)
        # For every user, not only the first.
        self.assertIn(
            ("shell", "pm", "list", "packages", "--user", "all", smoke.PACKAGE),
            calls,
        )

    def test_main_refuses_when_it_cannot_list_the_packages(self):
        code, out, _ = self.refused({
            **self.EMULATOR,
            ("shell", "pm", "list"): RuntimeError("adb shell pm list: Unknown option"),
        })
        self.assertEqual(code, 2)
        self.assertIn("can't tell whether Mozhi is installed", out)

    def test_main_refuses_a_real_device_unless_allowed(self):
        code, out, _ = self.refused({("shell", "getprop"): "0\n"})
        self.assertEqual(code, 2)
        self.assertIn("not an emulator", out)
        self.assertIn("--allow-real-device", out)

        # Allowed, the other checks still apply.
        code, out, calls = self.refused(
            {("shell", "pm", "list"): f"package:{smoke.PACKAGE}\n"},
            "--allow-real-device",
        )
        self.assertEqual(code, 2)
        self.assertIn("already installed", out)
        self.assertFalse(any(c[:2] == ("shell", "getprop") for c in calls))

    def test_main_refuses_without_a_device(self):
        code, out, _ = self.refused({
            ("shell", "getprop"): RuntimeError("adb: no devices/emulators found"),
        })
        self.assertEqual(code, 2)
        self.assertIn("no devices", out)

    def test_device_checks(self):
        self.assertTrue(smoke.is_emulator("1\n", ""))
        self.assertTrue(smoke.is_emulator("", "1"))
        self.assertFalse(smoke.is_emulator("", ""))
        self.assertFalse(smoke.is_emulator("0", "10"))
        self.assertEqual(
            smoke.installed_packages("package:a.b uid:1\npackage:\nnoise\n package:c\n"),
            {"a.b", "c"},
        )
        self.assertEqual(
            smoke.size_override("Physical size: 1080x2400\nOverride size: 720x1280\n"),
            "720x1280",
        )
        self.assertIsNone(smoke.size_override("Physical size: 1080x2400\n"))
        self.assertEqual(smoke.log_start("1730000000\n"), "1730000000.000")
        self.assertIsNone(smoke.log_start("date: bad format"))

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
    """Answers adb like an emulator, records the commands. [last] is the
    one made last."""

    last: "FakeDevice | None" = None
    # What the next one answers (set before main makes it).
    qemu = ("", "1")
    packages = "package:com.android.settings\n"
    size = "Physical size: 1080x2400\n"

    def __init__(self, out: Path) -> None:
        super().__init__(out)
        FakeDevice.last = self
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
        if args == ("shell", "getprop", "ro.kernel.qemu"):
            return self.qemu[0] + "\n"
        if args == ("shell", "getprop", "ro.boot.qemu"):
            return self.qemu[1] + "\n"
        if args[:3] == ("shell", "pm", "list"):
            return self.packages
        if args == ("shell", "date", "+%s"):
            return "1730000000\n"
        if args == ("shell", "wm", "size"):
            return self.size
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
        self.assertIn(("shell", "wm", "size", "reset"), calls)
        self.assertEqual(
            calls[-1],
            ("shell", "settings", "delete", "global", "sysui_demo_allowed"),
        )
        self.assertIn("exit", calls[-3])
        self.assertTrue(any("clock" in c for c in calls))

    def test_puts_back_an_earlier_screen_size_override(self):
        self.device.size = "Physical size: 1080x2400\nOverride size: 720x1280\n"

        smoke.store_screenshots(self.device, self.folder)

        self.assertIn(("shell", "wm", "size", "720x1280"), self.device.calls)
        self.assertNotIn(("shell", "wm", "size", "reset"), self.device.calls)

    def test_puts_everything_back_when_adb_fails(self):
        self.device.fail_on = ("shell", "cmd", "uimode", "night", "yes")

        with self.assertRaises(RuntimeError):
            smoke.store_screenshots(self.device, self.folder)

        self.assertIn(("shell", "wm", "size", "reset"), self.device.calls)
        self.assertEqual(
            self.device.calls[-1],
            ("shell", "settings", "delete", "global", "sysui_demo_allowed"),
        )
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
@mock.patch.object(smoke, "flow_offline_only", lambda device: "no byte")
@mock.patch.object(smoke, "flow_image", lambda device: "the house")
@mock.patch.object(smoke, "flow_document", lambda device: "the book")
@mock.patch.object(smoke, "flow_cancel", lambda device: "back to Download")
@mock.patch.object(smoke, "flow_voice", lambda device: "offered the model")
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

    def test_reads_the_log_since_it_started_and_never_clears_it(self):
        code, _ = self.run_main()

        self.assertEqual(code, 0)
        calls = FakeDevice.last.calls
        self.assertFalse(any(c[:2] == ("logcat", "-c") for c in calls))
        self.assertIn(("logcat", "-t", "1730000000.000"), calls)
        self.assertFalse(any(c == ("logcat", "-d") for c in calls))
        # The date is read before the app is installed.
        self.assertLess(calls.index(("shell", "date", "+%s")),
                        next(i for i, c in enumerate(calls) if c[0] == "install"))

    def test_cleans_up_after_the_flows(self):
        def image(device):
            device.pushed.append(("/sdcard/Pictures/mozhi-smoke-sign.png",
                                  "content://media/external/images/media/42"))
            return "the house"

        with mock.patch.object(smoke, "flow_image", image):
            code, _ = self.run_main()

        self.assertEqual(code, 0)
        calls = FakeDevice.last.calls
        self.assertIn(("shell", "content", "delete", "--uri",
                       "content://media/external/images/media/42"), calls)
        self.assertIn(("shell", "rm", "-f", "/sdcard/Pictures/mozhi-smoke-sign.png"),
                      calls)
        self.assertIn(("shell", "rm", "-f", smoke.UI_DUMP), calls)

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



    def test_runs_the_flows_after_the_screenshots_and_reports_each(self):
        shots = self.root / "store"

        code, summary = self.run_main("--screenshots", str(shots))

        self.assertEqual(code, 0)
        self.assertIn("- Offline only: passed (no byte)", summary)
        self.assertIn("- Image translation offline: passed (the house)", summary)
        self.assertIn("- Document translation: passed (the book)", summary)
        self.assertIn(
            "- Cancel an offline language download: passed (back to Download)",
            summary,
        )
        self.assertLess(summary.index("[store"), summary.index("=== Offline only"))

    def test_a_failing_flow_fails_the_run_and_the_others_still_run(self):
        def fail(device):
            raise smoke.StepFailed("share the image/png file: refused")

        with mock.patch.object(smoke, "flow_image", fail):
            code, summary = self.run_main()

        self.assertEqual(code, 1)
        self.assertIn(
            "- Image translation offline: failed "
            "(share the image/png file: refused)",
            summary,
        )
        self.assertIn("Image translation offline (image) failed:", summary)
        self.assertIn("on screen:", summary)
        self.assertIn("- Cancel an offline language download: passed", summary)
        self.assertIn("- Started and walked through the first run: yes", summary)
        self.assertTrue((self.root / "smoke").glob("*-image-failed.png"))

    def test_skip_flags_leave_flows_out(self):
        code, summary = self.run_main("--skip-image", "--skip-cancel")

        self.assertEqual(code, 0)
        self.assertIn("- Image translation offline: skipped (--skip-image)", summary)
        self.assertIn(
            "- Cancel an offline language download: skipped (--skip-cancel)",
            summary,
        )
        self.assertIn("- Offline only: passed", summary)

    def test_flows_do_not_run_after_a_failed_first_run(self):
        def fail(device):
            raise RuntimeError("the sentence did not reach the translate box")

        with mock.patch.object(smoke, "translate", fail):
            code, summary = self.run_main()

        self.assertEqual(code, 1)
        self.assertIn(
            "- Offline only: not run (the first run did not finish)", summary
        )
        self.assertNotIn("=== Offline only", summary)

    def test_unknown_skip_flags_print_the_usage(self):
        with contextlib.redirect_stdout(io.StringIO()) as out:
            code = smoke.main(["app.apk", str(self.root / "smoke"), "--skip-ocr"])
        self.assertEqual(code, 2)
        self.assertIn("--skip-offline-only", out.getvalue())


def node(label="", cls="android.view.View", bounds=(0, 0, 100, 100), clickable=False,
         checkable=False, checked=False, enabled=True, text=True):
    return smoke.Node(label if text else "", "" if text else label, cls, bounds,
                      clickable, False, checkable, checked, enabled)


class ScreenHelpersTest(unittest.TestCase):
    def test_parse_nodes_reads_checked_and_enabled(self):
        xml = (
            '<hierarchy><node text="Offline only" content-desc="" '
            'class="android.view.View" checkable="true" checked="true" '
            'enabled="false" clickable="true" bounds="[0,0][10,10]" />'
            '<node text="Plain" class="x" bounds="[0,0][10,10]" /></hierarchy>'
        )
        first, second = smoke.parse_nodes(xml)

        self.assertTrue(first.checkable and first.checked)
        self.assertFalse(first.enabled)
        self.assertTrue(second.enabled)
        self.assertFalse(second.checkable or second.checked)

    def test_find_clickable_skips_plain_and_disabled_nodes(self):
        nodes = [
            node("Translate image"),
            node("Translate image", clickable=True, enabled=False),
        ]
        self.assertIsNone(smoke.find_clickable(nodes, "Translate image"))
        nodes.append(node("Translate image", clickable=True))
        self.assertIs(smoke.find_clickable(nodes, "Translate image"), nodes[2])

    def test_labels_of_and_screen_size(self):
        nodes = [node("Privacy &\ndata", bounds=(0, 0, 1080, 2400)), node(""),
                 node("Offline only")]
        self.assertEqual(smoke.labels_of(nodes), "Privacy & data | Offline only")
        self.assertEqual(smoke.labels_of(nodes, 5), "Priva")
        self.assertEqual(smoke.screen_size(nodes), (1080, 2400))
        self.assertEqual(smoke.screen_size([]), (1080, 2400))

    def test_row_button_is_the_button_within_the_row(self):
        row = node("Azerbaijani\n25 MB download", bounds=(0, 500, 1080, 650))
        other = node("Download", bounds=(800, 700, 1000, 780), clickable=True)
        pill = node("Download", bounds=(800, 540, 1000, 610), clickable=True)
        plain = node("Download", bounds=(800, 540, 1000, 610))

        self.assertIs(smoke.row_button([row, other, plain, pill], row, "Download"), pill)
        self.assertIsNone(smoke.row_button([row, other], row, "Download"))

    def test_result_node_counts_read_only_text_fields_but_not_the_input(self):
        box = node("Le chat dort sur le lit", "android.widget.EditText")
        output = node("The cat sleeps on the bed", "android.widget.EditText")
        pattern = smoke.OFFLINE_SENTENCES[0][1]

        self.assertIs(smoke.result_node([box, output], pattern, exclude=box), output)
        self.assertIsNone(smoke.result_node([box], pattern, exclude=box))
        self.assertIsNone(
            smoke.result_node([node("Category: bedding")], pattern)
        )

    def test_translated_accepts_a_selectable_translation(self):
        self.assertTrue(smoke.translated([
            node(smoke.SENTENCE, "android.widget.EditText"),
            node("I'm looking for the station", "android.widget.EditText"),
        ]))

    def test_offline_badge_below_or_on_the_translation(self):
        result = node("The cat sleeps", bounds=(0, 500, 1080, 700))
        above = node("Offline", bounds=(0, 100, 200, 150))
        below = node("Offline", bounds=(0, 720, 200, 780))
        merged = node("The cat sleeps\nOffline", bounds=(0, 500, 1080, 700))

        self.assertIs(smoke.offline_badge([above, result, below], result), below)
        self.assertIsNone(smoke.offline_badge([above, result], result))
        self.assertIs(smoke.offline_badge([merged], merged), merged)
        tooltip = node("Translated on this device", bounds=(0, 720, 9, 780))
        self.assertIs(smoke.offline_badge([result, tooltip], result), tooltip)
        self.assertIsNone(
            smoke.offline_badge([result, node("Works offline", bounds=(0, 800, 9, 900))],
                                result)
        )

    def test_language_row_skips_the_search_field(self):
        search = node("Azerbaijani", "android.widget.EditText")
        row = node("Azerbaijani\nAzərbaycan dili · 25 MB download")
        self.assertIs(smoke.language_row([search, node("Albanian"), row],
                                         "Azerbaijani"), row)
        self.assertIsNone(smoke.language_row([search], "Azerbaijani"))

    def test_download_button_falls_back_to_the_row_end(self):
        row = node("Azerbaijani", bounds=(0, 500, 1080, 650))
        pill = node("Download", bounds=(800, 540, 1000, 610), clickable=True)

        self.assertIs(smoke.download_button([row, pill], row, "Azerbaijani"), pill)
        target = smoke.download_button([row], row, "Azerbaijani")
        self.assertEqual(target.bounds, (860, 500, 1060, 650))
        self.assertEqual(target.label, "Download")

    def test_cancelled_row(self):
        row = node("Azerbaijani\n25 MB download", bounds=(0, 500, 1080, 650))
        cancel = node("Cancel downloading Azerbaijani", bounds=(900, 540, 1000, 610),
                      clickable=True)
        busy = node("Azerbaijani\nDownloading… 3%", bounds=(0, 500, 1080, 650))
        done = node("Downloaded", bounds=(800, 540, 1000, 610), clickable=True)

        self.assertIs(smoke.cancelled_row([row], "Azerbaijani"), row)
        self.assertIsNone(smoke.cancelled_row([row, cancel], "Azerbaijani"))
        self.assertIsNone(smoke.cancelled_row([busy], "Azerbaijani"))
        self.assertIsNone(smoke.cancelled_row([], "Azerbaijani"))
        with self.assertRaisesRegex(smoke.StepFailed, "finished downloading"):
            smoke.cancelled_row([row, done], "Azerbaijani")


NETSTATS = """Active interfaces:
  iface=wlan0 ident=[{type=WIFI, metered=false}]
Dev stats:
  Pending bytes: 0
  History since boot:
  ident=[{type=WIFI}] uid=-1 set=ALL tag=0x0
    NetworkStatsHistory: bucketDuration=3600
      st=1700000000 rb=999999 rp=9 tb=999999 tp=9 op=0
UID stats:
  Pending bytes: 1234
  History since boot:
  ident=[{type=WIFI, ratType=COMBINED, wifiNetworkKey="AndroidWifi", metered=false, defaultNetwork=true, oemManaged=OEM_NONE, subId=-1}] uid=10190 set=DEFAULT tag=0x0
    NetworkStatsHistory: bucketDuration=7200
      st=1700000000 rb=1000 rp=10 tb=200 tp=5 op=0
      st=1700007200 rb=30 rp=1 tb=4 tp=1 op=0
  ident=[{type=MOBILE, metered=true}] uid=10190 set=FOREGROUND tag=0x0
    NetworkStatsHistory: bucketDuration=7200
      st=1700000000 rb=5 rp=1 tb=1 tp=1 op=0
  ident=[{type=WIFI}] uid=10190 set=DEFAULT tag=0x2a
    NetworkStatsHistory: bucketDuration=7200
      st=1700000000 rb=700 rp=1 tb=700 tp=1 op=0
  ident=[{type=WIFI}] uid=10191 set=DEFAULT tag=0x0
    NetworkStatsHistory: bucketDuration=7200
      st=1700000000 rb=77 rp=1 tb=77 tp=1 op=0
UID tag stats:
  History since boot:
  ident=[{type=WIFI}] uid=10190 set=DEFAULT tag=0x0
    NetworkStatsHistory: bucketDuration=7200
      st=1700000000 rb=88888 rp=1 tb=88888 tp=1 op=0
BPF map content:
  mAppUidStatsMap:
    uid rxBytes rxPackets txBytes txPackets
    1000 50 1 60 1
    10190 4000 20 500 10
    10191 1 1 1 1
  mStatsMapA:
    ifaceIndex ifaceName tag_hex uid_int cnt_set rxBytes rxPackets txBytes txPackets
"""


class TrafficTest(unittest.TestCase):
    def test_package_uid(self):
        self.assertEqual(
            smoke.package_uid(f"package:{smoke.PACKAGE} uid:10190\n"), 10190
        )
        self.assertEqual(
            smoke.package_uid(f"package:{smoke.PACKAGE} uid:10190,10191\n"), 10190
        )
        self.assertEqual(
            smoke.package_uid("Packages:\n  Package [x] (1):\n    userId=10123\n"),
            10123,
        )
        self.assertIsNone(smoke.package_uid("package:io.other uid:1\n"))
        self.assertIsNone(smoke.package_uid(""))

    def test_netstats_sums_the_untagged_totals_of_the_uid(self):
        self.assertEqual(smoke.netstats_uid_bytes(NETSTATS, 10190), 1000 + 200 + 34 + 6)
        self.assertEqual(smoke.netstats_uid_bytes(NETSTATS, 10191), 154)
        self.assertEqual(smoke.netstats_uid_bytes(NETSTATS, 4242), 0)
        self.assertIsNone(smoke.netstats_uid_bytes("Dev stats:\n", 10190))

    def test_bpf_counters(self):
        self.assertEqual(smoke.bpf_uid_bytes(NETSTATS, 10190), 4500)
        self.assertEqual(smoke.bpf_uid_bytes(NETSTATS, 4242), 0)
        self.assertIsNone(smoke.bpf_uid_bytes("UID stats:\n", 10190))
        self.assertIsNone(
            smoke.bpf_uid_bytes("  mAppUidStatsMap:\n    uid rxBytes\n  other:\n", 1)
        )

    def test_verdict(self):
        same = {"netstats": 1240, "bpf": 4500}
        ok, why = smoke.traffic_verdict(same, dict(same))
        self.assertTrue(ok)
        self.assertIn("bpf 4500 -> 4500", why)

        ok, why = smoke.traffic_verdict(same, {"netstats": 1240, "bpf": 4800})
        self.assertFalse(ok)
        self.assertIn("used the network", why)

        # A source that never saw this app's earlier traffic is not trusted.
        ok, _ = smoke.traffic_verdict(
            {"netstats": 0, "bpf": 4500}, {"netstats": 0, "bpf": 4500}
        )
        self.assertTrue(ok)
        ok, why = smoke.traffic_verdict(
            {"netstats": None, "bpf": 0}, {"netstats": None, "bpf": 0}
        )
        self.assertIsNone(ok)
        self.assertIn("no traffic counter could be trusted", why)
        ok, _ = smoke.traffic_verdict(
            {"netstats": 0, "bpf": None}, {"netstats": 300, "bpf": None}
        )
        self.assertFalse(ok)


PROC_NET = """  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:13AD 00000000:0000 0A 00000000:00000000 00:00000000 00000000 10190        0 1 1
   1: 0F02000A:A1B2 2E3A0B8E:01BB 01 00000000:00000000 00:00000000 00000000 10190        0 2 1
   2: 0F02000A:A1B3 0100007F:1F90 01 00000000:00000000 00:00000000 00000000 10190        0 3 1
   3: 0F02000A:A1B4 2E3A0B8E:01BB 01 00000000:00000000 00:00000000 00000000 10191        0 4 1
  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000000000000000000000000000:0035 00000000000000000000000000000000:0000 07 00000000:00000000 00:00000000 00000000 10190 0 5
   1: 0000000000000000FFFF00000F02000A:B000 0000000000000000FFFF00000101A8C0:0050 01 00000000:00000000 00:00000000 00000000 10190 0 6
   2: 00000000000000000000000000000000:B001 B80D0120000000000000000001000000:01BB 01 00000000:00000000 00:00000000 00000000 10190 0 7
   3: 00000000000000000000000000000000:B002 00000000000000000000000001000000:0050 01 00000000:00000000 00:00000000 00000000 10190 0 8
cat: /proc/net/udp6: No such file or directory
"""


class ConnectionsTest(unittest.TestCase):
    def test_lists_the_remote_addresses_of_the_uid(self):
        self.assertEqual(
            smoke.uid_connections(PROC_NET, 10190),
            {"142.11.58.46:443", "192.168.1.1:80", "[2001:db8::1]:443"},
        )
        self.assertEqual(smoke.uid_connections(PROC_NET, 10191), {"142.11.58.46:443"})
        self.assertEqual(smoke.uid_connections(PROC_NET, 1), set())
        self.assertEqual(smoke.uid_connections("1: zz:01 yy:02 01 a b c 5", 5), set())


class SharingTest(unittest.TestCase):
    def test_content_rows_and_media_id(self):
        output = (
            "Row: 0 _id=31, _display_name=old.png\n"
            "Row: 1 _id=40, _display_name=mozhi-smoke-sign.png\n"
            "Row: 2 _id=42, _display_name=mozhi-smoke-sign.png\n"
            "Row: 3 _id=NULL, _display_name=mozhi-smoke-sign.png\n"
            "Row: 4 _id=50, _display_name=a, b.txt\n"
        )
        rows = smoke.content_rows(output)

        self.assertEqual(rows[0], {"_id": "31", "_display_name": "old.png"})
        self.assertEqual(rows[4]["_display_name"], "a, b.txt")
        self.assertEqual(smoke.media_id(output, "mozhi-smoke-sign.png"), "42")
        self.assertIsNone(smoke.media_id("No result found.\n", "x.png"))

    def test_stream_uris(self):
        self.assertEqual(
            smoke.stream_uris("42", "images/media", "Pictures/mozhi-smoke-sign.png"),
            [
                "content://media/external/images/media/42",
                "content://media/external/file/42",
                "content://com.android.externalstorage.documents/document/"
                "primary%3APictures%2Fmozhi-smoke-sign.png",
            ],
        )
        self.assertEqual(len(smoke.stream_uris(None, "downloads", "Download/a.txt")), 1)

    def test_share_text_args(self):
        args = smoke.share_text_args("Le chat dort")

        self.assertEqual(args[:3], ["shell", "am", "start"])
        self.assertIn("'Le chat dort'", args)
        self.assertEqual(args[args.index("-p") + 1], smoke.PACKAGE)
        self.assertEqual(args[args.index("-t") + 1], "text/plain")
        with self.assertRaises(ValueError):
            smoke.share_text_args("l'eau")

    def test_share_stream_args_grant_the_uri_as_data_and_stream(self):
        uri = "content://media/external/images/media/42"
        args = smoke.share_stream_args(uri, "image/png")

        self.assertEqual(args[args.index("-n") + 1], smoke.SHARE_ACTIVITY)
        self.assertEqual(args[args.index("-a") + 1], "android.intent.action.SEND")
        self.assertEqual(args[args.index("-t") + 1], "image/png")
        self.assertEqual(args[args.index("-d") + 1], f"'{uri}'")
        self.assertEqual(
            args[args.index("--eu") + 1 : args.index("--eu") + 3],
            ["android.intent.extra.STREAM", f"'{uri}'"],
        )
        self.assertIn("--grant-read-uri-permission", args)

    def test_am_failed(self):
        self.assertTrue(smoke.am_failed(
            "Starting: Intent { act=android.intent.action.SEND }\n"
            "java.lang.SecurityException: Uid 2000 does not have permission to uri"
        ))
        self.assertTrue(smoke.am_failed("Error: Activity not started"))
        self.assertFalse(smoke.am_failed("Starting: Intent { act=SEND }"))

    def test_the_sign_is_a_readable_png(self):
        data = smoke.IMAGE_ASSET.read_bytes()

        self.assertTrue(data.startswith(b"\x89PNG\r\n\x1a\n"))
        width, height = struct.unpack(">II", data[16:24])
        self.assertEqual((width, height), (1200, 520))
        self.assertLess(len(data), 64 * 1024)

    def test_the_texts_translate_to_words_their_french_lacks(self):
        for french, pattern in [
            *smoke.OFFLINE_SENTENCES,
            (" ".join(smoke.DOCUMENT_LINES), smoke.DOCUMENT_RESULT),
            ("La maison est rouge. Le jardin est vert.", smoke.IMAGE_RESULT),
        ]:
            self.assertIsNone(re.fullmatch(pattern, french), french)
            self.assertNotIn("'", french)

    def test_split_skips(self):
        self.assertEqual(
            smoke.split_skips(["a.apk", "--skip-image", "out", "--skip-cancel"]),
            (["a.apk", "out"], {"image", "cancel"}),
        )
        self.assertEqual(smoke.split_skips(["a", "b"]), (["a", "b"], set()))
        self.assertIsNone(smoke.split_skips(["a", "b", "--skip-camera"]))
        self.assertEqual(
            sorted(f"--skip-{name}" for name, _ in smoke.FLOWS),
            ["--skip-cancel", "--skip-document", "--skip-image",
             "--skip-offline-only", "--skip-voice"],
        )
        for name, _ in smoke.FLOWS:
            self.assertTrue(callable(smoke.flow_function(name)))
            self.assertIn(f"--skip-{name}", smoke.__doc__)


class Clock:
    def __init__(self) -> None:
        self.now = 0.0

    def monotonic(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds


class ScreenDevice(FakeDevice):
    """A fake emulator whose screen changes on taps, swipes and adb
    commands: [screens] by name, [on_tap] (label pattern -> screen),
    [on_swipe] / [on_swipe_back] (screen -> the screen below / above it),
    [on_adb] (argument prefix -> (screen or None, output))."""

    def __init__(self, out: Path, clock: Clock) -> None:
        super().__init__(out)
        self.clock = clock
        self.screens: dict[str, list[smoke.Node]] = {}
        self.current = ""
        self.on_tap: dict[str, str] = {}
        self.on_swipe: dict[str, str] = {}
        self.on_swipe_back: dict[str, str] = {}
        self.on_adb: list[tuple[tuple[str, ...], str | None, str]] = []
        self.captured: list[str] = []

    def dump(self) -> list[smoke.Node]:
        self.clock.now += 1
        return self.screens.get(self.current, [])

    def tap(self, node: smoke.Node) -> None:
        self.calls.append(("tap", node.label))
        for pattern, target in self.on_tap.items():
            if re.fullmatch(pattern, node.label, re.DOTALL):
                self.current = target
                return

    def adb(self, *args: str, check: bool = True, timeout: int = 120) -> str:
        for prefix, target, output in self.on_adb:
            if args[: len(prefix)] == prefix:
                self.calls.append(args)
                if target is not None:
                    self.current = target
                return output
        return super().adb(*args, check=check, timeout=timeout)

    def shell_output(self, *args: str, timeout: int = 120) -> str:
        return self.adb(*args, timeout=timeout)

    def swipe(self, up: bool = True) -> None:
        self.calls.append(("swipe", up))
        self.clock.now += 1
        moves = self.on_swipe if up else self.on_swipe_back
        self.current = moves.get(self.current, self.current)

    def capture(self, name: str) -> list[smoke.Node]:
        self.captured.append(name)
        return self.dump()


class ClockTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.clock = Clock()
        patches = [
            mock.patch.object(smoke.time, "sleep", self.clock.sleep),
            mock.patch.object(smoke.time, "monotonic", self.clock.monotonic),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        self.device = ScreenDevice(Path(self.tmp.name), self.clock)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def link(self, link: str) -> tuple[str, ...]:
        return ("shell", "am", "start", "-W", "-n", smoke.ACTIVITY,
                "-a", "android.intent.action.VIEW", "-d", link)

    def taps(self) -> list[str]:
        return [c[1] for c in self.device.calls if c[0] == "tap"]


class FollowTest(ClockTestCase):
    def test_returns_what_it_waited_for(self):
        self.device.screens["done"] = [node("The house is red")]
        self.device.current = "done"

        found, tapped = smoke.follow(
            self.device, "step", lambda n: smoke.find(n, ".*house.*"), "it", 10
        )

        self.assertEqual(found.label, "The house is red")
        self.assertEqual(tapped, [])

    def test_taps_offers_and_once_more_when_nothing_happens(self):
        self.device.screens["offer"] = [
            node("Download French text recognition (1 MB)", clickable=True),
            node("Translate image", clickable=True),
        ]
        self.device.current = "offer"

        with self.assertRaises(smoke.TimedOut) as raised:
            smoke.follow(
                self.device, "translate", lambda n: None, "the English text", 60,
                offers=(smoke.Offer(r"Download .+ text recognition.*", "download"),
                        smoke.Offer(r"Translate image", "press", after=30)),
            )

        self.assertEqual(
            self.taps(),
            ["Download French text recognition (1 MB)"] * 2 + ["Translate image"] * 2,
        )
        message = str(raised.exception)
        self.assertIn("translate: the English text did not appear within 60 s", message)
        self.assertIn("tapped: download, press", message)

    def test_stops_on_an_error_on_screen(self):
        self.device.screens["error"] = [node("Couldn’t download Azerbaijani")]
        self.device.current = "error"

        with self.assertRaisesRegex(smoke.StepFailed, "Couldn’t download"):
            smoke.follow(self.device, "cancel", lambda n: None, "x", 60,
                         errors=r"(?s).*Couldn.t.*")

    def test_scrolls_down_then_back_up_and_polls(self):
        polls = []
        smoke_args = dict(scroll=True, poll=lambda: polls.append(1))
        with self.assertRaises(smoke.TimedOut):
            smoke.follow(self.device, "s", lambda n: None, "x", 60, **smoke_args)

        swipes = [c[1] for c in self.device.calls if c[0] == "swipe"]
        self.assertIn(True, swipes)
        self.assertIn(False, swipes)
        self.assertGreater(len(polls), 5)

    def test_tap_until_taps_again_once(self):
        self.device.screens["page"] = [node("Translate", clickable=True)]
        self.device.screens["busy"] = [node("Translating… 0 of 1 parts")]
        self.device.current = "page"

        with self.assertRaisesRegex(smoke.StepFailed, "twice led nowhere"):
            smoke.tap_until(self.device, "go", "Translate", lambda n: None)
        self.assertEqual(self.taps(), ["Translate", "Translate"])

        self.device.on_tap["Translate"] = "busy"
        found = smoke.tap_until(self.device, "go", "Translate",
                                smoke.any_of(r"Translating….*"))
        self.assertTrue(found.label.startswith("Translating"))

    def test_tap_until_without_the_button(self):
        with self.assertRaisesRegex(smoke.StepFailed, "no “Go” button"):
            smoke.tap_until(self.device, "go", "Go", lambda n: None)

    def test_scroll_to_gives_up_after_some_swipes(self):
        with self.assertRaisesRegex(smoke.StepFailed, "is not on the page"):
            smoke.scroll_to(self.device, "Offline only", "find")
        self.assertEqual(self.device.calls.count(("swipe", True)), 4)


class RunFlowsTest(ClockTestCase):
    def test_records_each_flow_and_its_screen_on_failure(self):
        self.device.screens["x"] = [node("Settings"), node("Privacy & data")]
        self.device.current = "x"

        def boom(device):
            raise RuntimeError("adb install: no device")

        with mock.patch.object(smoke, "flow_offline_only", lambda d: "fine"), \
                mock.patch.object(smoke, "flow_image", boom), \
                mock.patch.object(smoke, "flow_document", lambda d: "fine"):
            results = smoke.run_flows(self.device, {"cancel", "voice"})

        self.assertEqual([r.status for r in results],
                         ["passed", "failed", "passed", "skipped", "skipped"])
        self.assertIn("RuntimeError: adb install: no device", results[1].detail)
        self.assertIn("on screen: Settings | Privacy & data", results[1].detail)
        self.assertEqual(self.device.captured, ["image-failed"])

    def test_a_failed_flow_saves_the_app_log_and_the_whole_page(self):
        d = self.device
        d.screens = {
            "top": [node("Offline languages"), node("No languages downloaded")],
            "end": [node("No languages downloaded"), node("Azerbaijani\n25 MB")],
        }
        d.current = "end"
        d.on_swipe = {"top": "end"}
        d.on_swipe_back = {"end": "top"}
        log = "\n".join([
            "10-31 05:20:00.100  1234  1250 I flutter : Uncaught error",
            "10-31 05:20:00.200   555   560 I ActivityTaskManager: START u0 "
            f"{{act=android.intent.action.SEND pkg={smoke.PACKAGE}}}",
            "10-31 05:20:00.300   777   780 D other   : not ours",
            "10-31 05:20:00.400  1234  1251 W Mozhi   : engines still loading",
        ])
        d.on_adb.append((("logcat", "-d"), None, log))

        def fails(device):
            raise smoke.StepFailed("open Offline languages: no page")

        with mock.patch.object(smoke, "flow_cancel", fails), \
                redirect_stdout(io.StringIO()) as out:
            results = smoke.run_flows(
                d, {"offline-only", "image", "document", "voice"}
            )

        self.assertEqual(results[3].name, "cancel")
        self.assertEqual(results[3].status, "failed")
        self.assertIn(("logcat", "-d", "-v", "threadtime", "-t", "1730000000.000"),
                      d.calls)
        saved = (Path(self.tmp.name) / "00-cancel-failed-logcat.txt").read_text()
        self.assertIn("Uncaught error", saved)
        self.assertIn("START u0", saved)
        self.assertIn("engines still loading", saved)
        self.assertNotIn("not ours", saved)
        page = (Path(self.tmp.name) / "00-cancel-failed-page.txt").read_text()
        self.assertEqual(
            page.splitlines(),
            ["Offline languages", "No languages downloaded", "Azerbaijani 25 MB"],
        )
        printed = out.getvalue()
        self.assertIn("the last 3 of 3 lines of Mozhi's log", printed)
        self.assertIn("engines still loading", printed)
        self.assertIn("  Azerbaijani 25 MB", printed)

    def test_diagnostics_that_fail_do_not_stop_the_run(self):
        self.device.fail_on = ("logcat",)
        with mock.patch.object(smoke, "flow_cancel", lambda d: (_ for _ in ()).throw(
                smoke.StepFailed("boom"))), redirect_stdout(io.StringIO()):
            results = smoke.run_flows(
                self.device, {"offline-only", "image", "document", "voice"}
            )
        self.assertEqual(results[3].status, "failed")
        self.assertTrue(any("diagnostics incomplete" in line for line in self.device.log))

    def test_a_flow_that_leaves_mozhi_stopped_fails(self):
        self.device.on_adb.append((("shell", "pidof"), None, ""))
        with mock.patch.object(smoke, "flow_offline_only", lambda d: "fine"):
            results = smoke.run_flows(
                self.device, {"image", "document", "cancel", "voice"}
            )
        self.assertEqual(results[0].status, "failed")
        self.assertIn("Mozhi is no longer running", results[0].detail)

    def test_flow_lines(self):
        results = [smoke.FlowResult("image", "Image", "failed", "share: no\n  on screen: x")]
        self.assertEqual(smoke.flow_lines(results, True), ["- Image: failed (share: no)"])
        self.assertEqual(len(smoke.flow_lines([], False)), len(smoke.FLOWS))


class DiagnosticsTest(ClockTestCase):
    def test_app_log_lines_keep_the_app_flutter_and_its_name(self):
        log = "\n".join([
            "--------- beginning of main",
            "10-31 05:20:00.100  1234  1250 I flutter : hello",
            "10-31 05:20:00.200  4321  4322 I flutter : another engine",
            "10-31 05:20:00.300   555   560 W ActivityTaskManager: Activity not "
            f"started for {smoke.PACKAGE}",
            "10-31 05:20:00.400   777   780 D Other   : not ours",
            "10-31 05:20:00.500  1234  1251 E AndroidRuntime: boom",
        ])

        lines = smoke.app_log_lines(log, {"1234"})

        self.assertEqual(len(lines), 4)
        self.assertNotIn("not ours", "\n".join(lines))
        self.assertEqual(smoke.app_log_lines("", {"1"}), [])

    def test_page_text_reads_from_the_top_to_the_end(self):
        d = self.device
        d.screens = {
            "a": [node("Title"), node("One")],
            "b": [node("One"), node("Two")],
            "c": [node("Two"), node("Three\nlines")],
        }
        d.current = "b"
        d.on_swipe = {"a": "b", "b": "c"}
        d.on_swipe_back = {"c": "b", "b": "a"}

        self.assertEqual(smoke.page_text(d),
                         ["Title", "One", "Two", "Three lines"])
        self.assertEqual(d.calls.count(("swipe", False)), 3)

    def test_scroll_find_scrolls_until_it_finds(self):
        d = self.device
        d.screens = {"a": [node("Top")], "b": [node("Search languages")]}
        d.current = "a"
        d.on_swipe = {"a": "b"}

        found = smoke.scroll_find(d, smoke.any_of(smoke.OFFLINE_SEARCH))

        self.assertEqual(found.label, "Search languages")
        self.assertIsNone(smoke.scroll_find(d, smoke.any_of("Nothing"), swipes=2))


class OfflinePageTest(unittest.TestCase):
    def test_the_header_counts_the_downloaded_languages(self):
        for header in ("No languages downloaded", "1 language downloaded",
                       "12 languages downloaded"):
            self.assertEqual(smoke.offline_page([node(header)]).label, header)

    def test_the_title_counts_only_off_the_settings_page(self):
        settings = [
            node("Offline languages"),
            node("Languages on this device\nTranslate without internet using "
                 "on-device models", clickable=True),
        ]
        self.assertIsNone(smoke.offline_page(settings))
        page = [node("Offline languages"), node("Translations run on this phone")]
        self.assertEqual(smoke.offline_page(page).label, "Offline languages")

    def test_the_settings_row_has_either_label(self):
        self.assertIsNotNone(re.fullmatch(
            smoke.OFFLINE_LANGUAGES,
            "Languages on this device\nTranslate without internet using on-device "
            "models",
        ))
        self.assertIsNotNone(re.fullmatch(smoke.OFFLINE_LANGUAGES,
                                          "Offline languages\nDownload languages"))
        row = smoke.find_clickable(
            [node("Offline languages"),
             node("Languages on this device\nTranslate offline", clickable=True)],
            smoke.OFFLINE_LANGUAGES,
        )
        self.assertTrue(row.label.startswith("Languages on this device"))


def netstats(uid_bytes: int, bpf_bytes: int) -> str:
    return (
        "UID stats:\n  ident=[{type=WIFI}] uid=10190 set=DEFAULT tag=0x0\n"
        f"      st=1 rb={uid_bytes} rp=1 tb=0 tp=0 op=0\n"
        "  mAppUidStatsMap:\n    uid rxBytes rxPackets txBytes txPackets\n"
        f"    10190 {bpf_bytes} 1 0 0\n"
    )


class OfflineOnlyFlowTest(ClockTestCase):
    def setUp(self) -> None:
        super().setUp()
        d = self.device
        d.screens = {
            "settings": [node("Privacy & data\nPrivacy mode, history", clickable=True)],
            "privacy": [node("Offline only\nOnly on-device translation.",
                             clickable=True, checkable=True)],
            "privacy-on": [node("Offline only\nOnly on-device translation.",
                                clickable=True, checkable=True, checked=True)],
            "translated": [
                node("Le chat dort sur le lit", "android.widget.EditText",
                     bounds=(0, 200, 1080, 400)),
                node("The cat sleeps on the bed", "android.widget.EditText",
                     bounds=(0, 500, 1080, 700)),
                node("Offline", bounds=(0, 720, 200, 780)),
            ],
        }
        d.on_tap = {r"Privacy & data.*": "privacy", r"Offline only.*": "privacy-on"}
        self.counters = iter([netstats(500, 9000)] * 2)
        d.on_adb = [
            (self.link("mozhi://settings"), "settings", ""),
            (("shell", "cmd", "package"), None, f"package:{smoke.PACKAGE} uid:10190"),
            (("shell", "am", "start", "-a", "android.intent.action.SEND"),
             "translated", ""),
        ]
        self.patch = mock.patch.object(
            smoke, "traffic", lambda device, uid, label: self.reading(uid, label)
        )
        self.patch.start()
        self.addCleanup(self.patch.stop)
        self.readings = {"before-1": (500, 9000), "after-1": (500, 9000)}

    def reading(self, uid, label):
        self.assertEqual(uid, 10190)
        netstats_bytes, bpf = self.readings[label]
        return {"netstats": netstats_bytes, "bpf": bpf}

    def test_switches_to_offline_only_and_finds_no_traffic(self):
        detail = smoke.flow_offline_only(self.device)

        self.assertIn("“The cat sleeps on the bed”, labelled “Offline”", detail)
        self.assertIn("no byte sent or received", detail)
        self.assertEqual(self.taps(), ["Privacy & data\nPrivacy mode, history",
                                       "Offline only\nOnly on-device translation."])
        self.assertIn("offline-only-chosen", self.device.captured)

    def test_opens_the_translate_tab_before_sharing(self):
        smoke.flow_offline_only(self.device)

        calls = self.device.calls
        translate = calls.index(self.link("mozhi://translate"))
        share = next(i for i, c in enumerate(calls)
                     if c[:5] == ("shell", "am", "start", "-a",
                                  "android.intent.action.SEND"))
        self.assertLess(translate, share)
        self.assertIn(
            "translate “Le chat dort sur le lit” offline: the shared text is in "
            "the translate box", self.device.log)

    def test_fails_when_the_shared_text_does_not_reach_the_box(self):
        d = self.device
        d.screens["old"] = [
            node("Bonjour je cherche la gare", "android.widget.EditText",
                 bounds=(0, 200, 1080, 400)),
            node("Hello, I'm looking for the station", bounds=(0, 500, 1080, 700)),
        ]
        d.on_adb[2] = (
            ("shell", "am", "start", "-a", "android.intent.action.SEND"), "old",
            "Starting: Intent { act=android.intent.action.SEND }\n"
            "Warning: Activity not started, its current task has been brought to "
            "the front",
        )

        with self.assertRaises(smoke.StepFailed) as raised:
            smoke.flow_offline_only(d)

        message = str(raised.exception)
        self.assertIn("the shared text did not reach the translate box within 30 s",
                      message)
        self.assertIn("it shows “Bonjour je cherche la gare”", message)
        self.assertIn("brought a task to the front", message)
        self.assertNotIn("translation", message)
        self.assertLessEqual(self.clock.now, 60)

    def test_fails_when_sharing_is_refused(self):
        self.device.on_adb[2] = (
            ("shell", "am", "start", "-a", "android.intent.action.SEND"), None,
            "Error: Activity not started, unable to resolve Intent",
        )

        with self.assertRaisesRegex(smoke.StepFailed, "sharing was refused"):
            smoke.flow_offline_only(self.device)

    def test_fails_when_the_app_used_the_network(self):
        self.readings["after-1"] = (500, 9100)

        with self.assertRaisesRegex(smoke.StepFailed, "used the network"):
            smoke.flow_offline_only(self.device)

    def test_fails_without_the_offline_label(self):
        self.device.screens["translated"].pop()

        with self.assertRaisesRegex(smoke.StepFailed, "not labelled Offline"):
            smoke.flow_offline_only(self.device)

    def test_measures_again_after_downloading_french(self):
        d = self.device
        d.screens["offer"] = [
            node("Le chat dort sur le lit", "android.widget.EditText",
                 bounds=(0, 200, 1080, 400)),
            node("Download French (52 MB)", clickable=True),
        ]
        d.on_adb[2] = (("shell", "am", "start", "-a", "android.intent.action.SEND"),
                       "offer", "")
        d.on_tap[r"Download French.*"] = "translated"
        d.screens["translated-2"] = [
            node("Mon frere aime la musique", "android.widget.EditText",
                 bounds=(0, 200, 1080, 400)),
            node("My brother loves music\nOffline", bounds=(0, 500, 1080, 700)),
        ]
        self.readings.update({"after-1": (900, 60000), "before-2": (900, 60000),
                              "after-2": (900, 60000)})
        shares = []

        def share(*args, **kwargs):
            shares.append(args)
            d.current = "offer" if len(shares) == 1 else "translated-2"
            return ""

        with mock.patch.object(d, "adb", side_effect=lambda *a, **k: share(*a)
                               if a[:5] == ("shell", "am", "start", "-a",
                                            "android.intent.action.SEND")
                               else ScreenDevice.adb(d, *a, **k)):
            detail = smoke.flow_offline_only(d)

        self.assertEqual(len(shares), 2)
        self.assertIn("My brother loves music", detail)

    def test_opens_the_page_by_its_link_when_the_settings_differ(self):
        self.device.screens["settings"] = [node("General", clickable=True)]
        self.device.on_adb.append((self.link("mozhi://settings/privacy"), "privacy", ""))

        smoke.flow_offline_only(self.device)

        self.assertIn("settings-not-found", self.device.captured)


class SharedFileFlowsTest(ClockTestCase):
    def setUp(self) -> None:
        super().setUp()
        self.device.on_adb = [
            (("push",), None, ""),
            (("shell", "am", "broadcast"), None, ""),
            (("shell", "content", "query"), None,
             "Row: 0 _id=42, _display_name=mozhi-smoke-sign.png\n"
             f"Row: 1 _id=43, _display_name={smoke.DOCUMENT_NAME}\n"),
        ]

    def test_image(self):
        d = self.device
        d.screens = {
            "loaded": [node("Remove image", clickable=True),
                       node("Download French text recognition (1.1 MB)",
                            clickable=True)],
            "done": [node("Translation\nThe house is red. The garden is green.")],
        }
        d.on_adb.append((("shell", "am", "start", "-n", smoke.SHARE_ACTIVITY),
                         "loaded", "Starting: Intent"))
        d.on_tap[r"Download .*"] = "done"

        detail = smoke.flow_image(d)

        self.assertIn("shared as content://media/external/images/media/42", detail)
        self.assertIn("The house is red", detail)
        self.assertIn("download text recognition", detail)
        push = next(c for c in d.calls if c[0] == "push")
        self.assertEqual(push[1:], (str(smoke.IMAGE_ASSET),
                                    "/sdcard/Pictures/mozhi-smoke-sign.png"))

    def test_image_tries_the_next_uri_when_one_is_refused(self):
        d = self.device
        d.screens = {"empty": [node("Take or pick a photo")],
                     "done": [node("The house is red.")],
                     "loaded": [node("Remove image", clickable=True)]}
        outputs = iter([
            "java.lang.SecurityException: Uid 2000 does not have permission",
            "Starting: Intent",
            "Starting: Intent",
        ])
        screens = iter(["empty", "loaded"])

        def share(*args, timeout=120):
            output = next(outputs)
            if not smoke.am_failed(output):
                d.current = next(screens)
            return output

        d.on_tap = {}
        with mock.patch.object(d, "shell_output", share):
            d.screens["loaded"].append(node("The house is red."))
            detail = smoke.flow_image(d)

        self.assertIn("documents/document/primary%3APictures", detail)
        self.assertIn("image-not-shared", d.captured)

    def test_image_fails_when_no_uri_works(self):
        d = self.device
        with mock.patch.object(d, "shell_output",
                               lambda *a, **k: "Error: Activity not started"):
            with self.assertRaisesRegex(smoke.StepFailed, "got the file through none"):
                smoke.flow_image(d)

    def test_pushed_files_are_recorded_and_cleaned_up(self):
        smoke.push_shared_file(
            self.device, smoke.IMAGE_ASSET, smoke.IMAGE_REMOTE, "images/media"
        )
        self.device.on_adb[2] = (("shell", "content", "query"), None,
                                 "No result found.\n")
        smoke.push_shared_file(
            self.device, Path(self.tmp.name) / "doc.txt",
            f"Download/{smoke.DOCUMENT_NAME}", "downloads",
        )
        self.assertEqual(self.device.pushed, [
            ("/sdcard/Pictures/mozhi-smoke-sign.png",
             "content://media/external/images/media/42"),
            (f"/sdcard/Download/{smoke.DOCUMENT_NAME}", None),
        ])
        self.device.calls.clear()

        smoke.clean_up(self.device)

        calls = self.device.calls
        self.assertEqual(
            [c for c in calls if c[:3] == ("shell", "content", "delete")],
            [("shell", "content", "delete", "--uri",
              "content://media/external/images/media/42")],
        )
        self.assertIn(("shell", "rm", "-f", "/sdcard/Pictures/mozhi-smoke-sign.png"),
                      calls)
        self.assertIn(("shell", "rm", "-f", f"/sdcard/Download/{smoke.DOCUMENT_NAME}"),
                      calls)
        rescans = [c for c in calls if c[:3] == ("shell", "am", "broadcast")]
        self.assertEqual(len(rescans), 2)
        self.assertEqual(self.device.pushed, [])

    def test_clean_up_never_fails(self):
        self.device.pushed.append(("/sdcard/a.png", "content://media/x/1"))
        self.device.fail_on = ("shell", "rm")

        smoke.clean_up(self.device)

        self.assertTrue(any("clean up /sdcard/a.png: adb failed" in line
                            for line in self.device.log))

    def test_push_without_a_mediastore_row_shares_the_document_uri(self):
        self.device.on_adb[2] = (("shell", "content", "query"), None,
                                 "No result found.\n")

        uris = smoke.push_shared_file(
            self.device, smoke.IMAGE_ASSET, smoke.IMAGE_REMOTE, "images/media"
        )

        self.assertEqual(len(uris), 1)
        self.assertTrue(uris[0].startswith("content://com.android.externalstorage"))
        self.assertGreaterEqual(self.clock.now, 30)
        scan = next(c for c in self.device.calls if c[:3] == ("shell", "am", "broadcast"))
        self.assertIn("file:///sdcard/Pictures/mozhi-smoke-sign.png", scan)

    def test_document(self):
        d = self.device
        d.screens = {
            "loaded": [node("Remove document", clickable=True), node("2 segments"),
                       node("Translate", clickable=True)],
            "done": [node("Translation complete"),
                     node("The book is on the table.\nWe eat bread in the morning.",
                          "android.widget.EditText")],
        }
        d.on_adb.append((("shell", "am", "start", "-n", smoke.SHARE_ACTIVITY),
                         "loaded", "Starting: Intent"))
        d.on_tap["Translate"] = "done"

        detail = smoke.flow_document(d)

        self.assertIn("content://media/external/downloads/43", detail)
        self.assertIn("The book is on the table", detail)
        self.assertEqual(
            (Path(self.tmp.name) / smoke.DOCUMENT_NAME).read_text(encoding="utf-8"),
            "\n".join(smoke.DOCUMENT_LINES) + "\n",
        )

    def test_document_stops_on_failed_parts(self):
        d = self.device
        d.screens = {
            "loaded": [node("Remove document", clickable=True),
                       node("Translate", clickable=True)],
            "failed": [node("Translate again", clickable=True),
                       node("Failed parts\n1 part")],
        }
        d.on_adb.append((("shell", "am", "start", "-n", smoke.SHARE_ACTIVITY),
                         "loaded", "Starting: Intent"))
        d.on_tap["Translate"] = "failed"

        with self.assertRaisesRegex(smoke.StepFailed, "Failed parts"):
            smoke.flow_document(d)


class CancelFlowTest(ClockTestCase):
    def setUp(self) -> None:
        super().setUp()
        d = self.device
        row = (0, 900, 1080, 1050)
        pill = (800, 940, 1000, 1010)
        d.screens = {
            "settings": [node("Translation engines\nOffline languages, …",
                              clickable=True)],
            "engines": [node("Offline languages\nDownload languages",
                             clickable=True)],
            "offline": [
                node("", "android.widget.EditText", bounds=(0, 300, 1080, 400),
                     clickable=True),
                node("Greek\nΕλληνικά · 25 MB download", bounds=row),
                node("Download", bounds=pill, clickable=True),
            ],
            "downloading": [
                node("Greek\nDownloading… 3%", bounds=row),
                node("Cancel downloading Greek", bounds=pill, clickable=True),
            ],
        }
        d.on_tap = {
            r"Translation engines.*": "engines",
            r"Offline languages.*": "offline",
            r"Download": "downloading",
            r"Cancel downloading Greek": "offline",
        }
        d.on_adb = [(self.link("mozhi://settings"), "settings", ""),
                    (("emu",), None, "OK")]

    def test_starts_and_cancels_the_download(self):
        detail = smoke.flow_cancel(self.device)

        self.assertIn("Greek: “Greek Ελληνικά", detail)
        self.assertIn("no error", detail)
        calls = self.device.calls
        self.assertIn(("shell", "input", "text", "Greek"), calls)
        self.assertEqual(
            [c for c in calls if c[0] == "emu"],
            [("emu", "network", "speed", smoke.SLOW_NETWORK),
             ("emu", "network", "speed", "full")],
        )
        self.assertEqual(self.taps()[-2:], ["Download", "Cancel downloading Greek"])

    def test_opens_the_page_from_the_languages_row_and_scrolls(self):
        d = self.device
        d.screens["engines"] = [
            node("Offline languages"),
            node("Languages on this device\nTranslate without internet using "
                 "on-device models", clickable=True),
        ]
        # The page as it opens: its header, the search field below the fold.
        d.screens["offline-top"] = [
            node("Offline languages"),
            node("No languages downloaded"),
            node("Translations run on this phone, with Mozilla's models."),
        ]
        d.on_tap[r"Languages on this device.*"] = "offline-top"
        d.on_swipe = {"offline-top": "offline"}

        detail = smoke.flow_cancel(d)

        self.assertIn("no error", detail)
        self.assertNotIn("settings-not-found", d.captured)
        self.assertIn("Languages on this device\nTranslate without internet using "
                      "on-device models", self.taps())
        self.assertIn(("swipe", True), d.calls)
        self.assertIn(("shell", "input", "text", "Greek"), d.calls)

    def test_fails_on_an_error_and_restores_the_network(self):
        self.device.screens["offline-error"] = [
            *self.device.screens["offline"], node("Couldn’t download Greek")]
        self.device.on_tap["Cancel downloading Greek"] = "offline-error"

        with self.assertRaisesRegex(smoke.StepFailed, "Couldn’t download Greek"):
            smoke.flow_cancel(self.device)
        self.assertEqual(self.device.calls[-1][:4], ("emu", "network", "speed", "full"))

    def test_taps_download_again_when_it_did_not_start(self):
        d = self.device
        presses = []

        def tap(n):
            d.calls.append(("tap", n.label))
            if n.label == "Download":
                presses.append(1)
                if len(presses) == 2:
                    d.current = "downloading"
            elif n.label.startswith("Cancel"):
                d.current = "offline"
            elif n.label.startswith("Translation engines"):
                d.current = "engines"
            elif n.label.startswith("Offline languages"):
                d.current = "offline"

        with mock.patch.object(d, "tap", tap):
            smoke.flow_cancel(d)
        self.assertEqual(len(presses), 2)

    def test_refuses_a_language_already_downloaded(self):
        self.device.screens["offline"][2] = node(
            "Downloaded", bounds=(800, 940, 1000, 1010), clickable=True)

        with self.assertRaisesRegex(smoke.StepFailed, "downloaded already"):
            smoke.flow_cancel(self.device)

    def test_fails_when_the_language_is_missing(self):
        self.device.screens["offline"] = self.device.screens["offline"][:1]

        with self.assertRaisesRegex(smoke.StepFailed, "not in the list"):
            smoke.flow_cancel(self.device)



class VoiceFlowTest(ClockTestCase):
    def setUp(self) -> None:
        super().setUp()
        d = self.device
        d.screens = {
            "translate": [node("Speak", clickable=True)],
            "offer": [
                node("Download the speech model?"),
                node("This device has no speech recognition service. ..."),
                node("Other models", clickable=True),
                node("Not now", clickable=True),
                node("Download (74.1 MB)", clickable=True),
            ],
            "listening": [node("Stop listening", clickable=True)],
            "unavailable": [
                node("Speak", clickable=True),
                node("Speech recognition isn’t available on this device."),
            ],
        }
        d.on_adb.append(
            (self.link("mozhi://translate"), "translate", "Status: ok")
        )
        d.on_tap = {"Speak": "offer", "Not now": "translate",
                    "Stop listening": "translate"}

    def test_the_mic_offers_the_model_with_its_size(self):
        detail = smoke.flow_voice(self.device)

        self.assertIn("offered “Download (74.1 MB)”", detail)
        self.assertIn(("shell", "pm", "grant", smoke.PACKAGE,
                       "android.permission.RECORD_AUDIO"), self.device.calls)
        # Closed without downloading anything.
        self.assertEqual(self.taps(), ["Speak", "Not now"])
        self.assertIn("voice-answer", self.device.captured)

    def test_a_recogniser_that_listens_is_fine_too(self):
        self.device.on_tap["Speak"] = "listening"

        detail = smoke.flow_voice(self.device)

        self.assertIn("a recogniser listened", detail)
        self.assertEqual(self.taps(), ["Speak", "Stop listening"])

    def test_a_mic_that_does_nothing_fails(self):
        self.device.on_tap["Speak"] = "translate"

        with self.assertRaisesRegex(smoke.StepFailed, "tapping “Speak” twice"):
            smoke.flow_voice(self.device)

    def test_an_error_fails(self):
        self.device.on_tap["Speak"] = "unavailable"

        with self.assertRaisesRegex(smoke.StepFailed, "isn’t available"):
            smoke.flow_voice(self.device)

    def test_an_offer_without_a_size_fails(self):
        self.device.screens["offer"] = [node("Download the speech model?"),
                                        node("Not now", clickable=True)]

        with self.assertRaisesRegex(smoke.StepFailed, "no download size"):
            smoke.flow_voice(self.device)


if __name__ == "__main__":
    unittest.main()
