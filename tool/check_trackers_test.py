#!/usr/bin/env python3
"""Tests tool/check_trackers.py on synthetic APKs (no network).

  python3 tool/check_trackers_test.py
"""

from __future__ import annotations

import json
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

TOOL = Path(__file__).resolve().parent / "check_trackers.py"
sys.path.insert(0, str(TOOL.parent))

import check_trackers  # noqa: E402


def dex(descriptors: list[str]) -> bytes:
    """A minimal dex file whose type_ids name [descriptors]."""
    count = len(descriptors)
    string_ids_off = 0x70
    type_ids_off = string_ids_off + 4 * count
    data_off = type_ids_off + 4 * count
    strings = b""
    offsets = []
    for descriptor in descriptors:
        offsets.append(data_off + len(strings))
        encoded = descriptor.encode()
        assert len(encoded) < 0x80
        strings += bytes([len(encoded)]) + encoded + b"\0"
    header = bytearray(0x70)
    header[0:8] = b"dex\n035\0"
    struct.pack_into("<4I", header, 0x38, count, string_ids_off, count, type_ids_off)
    body = b"".join(struct.pack("<I", o) for o in offsets)
    body += b"".join(struct.pack("<I", i) for i in range(count))
    return bytes(header) + body + strings


TRACKERS = {
    "trackers": {
        "1": {"name": "Facebook Ads", "code_signature": "com.facebook.ads"},
        "2": {"name": "Firebase Analytics", "code_signature": "com.google.firebase.analytics"},
        "3": {"name": "No signature", "code_signature": ""},
    }
}


class CheckTrackersTest(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.root = Path(self.dir.name)
        self.trackers = self.root / "trackers.json"
        self.trackers.write_text(json.dumps(TRACKERS), encoding="utf-8")

    def tearDown(self) -> None:
        self.dir.cleanup()

    def apk(self, name: str, *dexes: list[str]) -> Path:
        path = self.root / name
        with zipfile.ZipFile(path, "w") as apk:
            for index, descriptors in enumerate(dexes):
                suffix = "" if index == 0 else str(index + 1)
                apk.writestr(f"classes{suffix}.dex", dex(descriptors))
            apk.writestr("AndroidManifest.xml", b"")
        return path

    def run_tool(self, *apks: Path) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, "-I", str(TOOL), "--trackers", str(self.trackers), *map(str, apks)],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_reads_every_dex(self) -> None:
        path = self.apk("multi.apk", ["Lio/a/A;", "I", "[Lio/a/A;"], ["Lio/b/B;"])
        self.assertEqual(check_trackers.apk_classes(str(path)), ["io.a.A", "io.b.B"])

    def test_clean_apk_passes(self) -> None:
        result = self.run_tool(self.apk("clean.apk", ["Lio/github/aimdi/mozhi/MainActivity;"]))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("none matches the 3 trackers", result.stdout)

    def test_tracker_fails_with_its_classes(self) -> None:
        result = self.run_tool(
            self.apk("clean.apk", ["Lio/a/A;"]),
            self.apk("ads.apk", ["Lcom/facebook/ads/AdView;", "Lio/a/A;"]),
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("Facebook Ads: com.facebook.ads.AdView", result.stdout)
        self.assertNotIn("Firebase", result.stdout)

    def test_bad_apk_is_an_error(self) -> None:
        bad = self.root / "bad.apk"
        bad.write_bytes(b"not a zip")
        self.assertEqual(self.run_tool(bad).returncode, 2)

    def test_list_format(self) -> None:
        listed = self.root / "list.json"
        listed.write_text(json.dumps(list(TRACKERS["trackers"].values())), encoding="utf-8")
        trackers = check_trackers.load_trackers(str(listed))
        self.assertEqual(len(trackers), 3)


if __name__ == "__main__":
    unittest.main(verbosity=1)
