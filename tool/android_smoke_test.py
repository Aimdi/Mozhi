#!/usr/bin/env python3
"""Tests for android_smoke.py's screen and log parsing (no device needed).

  python3 tool/android_smoke_test.py
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

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


if __name__ == "__main__":
    unittest.main()
