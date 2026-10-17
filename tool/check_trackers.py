#!/usr/bin/env python3
"""Scans APKs for trackers the way εxodus (https://exodus-privacy.eu.org)
does: every class in the APK's dex files is matched against the code
signatures of the trackers εxodus knows.

  python3 tool/check_trackers.py [--trackers FILE] APK...

The signatures come from εxodus' public API
(https://reports.exodus-privacy.eu.org/api/trackers), or from FILE (the
same JSON, e.g. saved earlier). Nothing about the APK is sent anywhere.

Exit status: 0 when no tracker is found, 1 when one is (each is listed with
the classes that matched), 2 on a usage or file error. When the API cannot
be reached (after retries) it prints a GitHub warning annotation and exits
0: tool/check_no_google.sh is the hard check for Google code; this scan
adds every other tracker εxodus knows.
"""

from __future__ import annotations

import argparse
import json
import re
import struct
import sys
import time
import urllib.error
import urllib.request
import zipfile

API = "https://reports.exodus-privacy.eu.org/api/trackers"
USER_AGENT = "Mozhi tracker check (+https://github.com/Aimdi/Mozhi)"


def uleb128(data: bytes, pos: int) -> tuple[int, int]:
    result = shift = 0
    while True:
        byte = data[pos]
        pos += 1
        result |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return result, pos
        shift += 7


def dex_types(data: bytes) -> list[str]:
    """The type descriptors (`Lcom/foo/Bar;`) of one dex file."""
    if data[:4] != b"dex\n":
        raise ValueError("not a dex file")
    string_ids_size, string_ids_off, type_ids_size, type_ids_off = struct.unpack_from(
        "<4I", data, 0x38
    )
    types = []
    for i in range(type_ids_size):
        (string_index,) = struct.unpack_from("<I", data, type_ids_off + 4 * i)
        if string_index >= string_ids_size:
            raise ValueError(f"type {i} names string {string_index}")
        (string_off,) = struct.unpack_from("<I", data, string_ids_off + 4 * string_index)
        _, start = uleb128(data, string_off)
        end = data.index(b"\0", start)
        types.append(data[start:end].decode("utf-8", errors="replace"))
    return types


def apk_classes(path: str) -> list[str]:
    """Every class of the APK as a dotted name (`com.foo.Bar`)."""
    classes = []
    with zipfile.ZipFile(path) as apk:
        for name in apk.namelist():
            if re.fullmatch(r"classes\d*\.dex", name):
                for descriptor in dex_types(apk.read(name)):
                    if descriptor.startswith("L") and descriptor.endswith(";"):
                        classes.append(descriptor[1:-1].replace("/", "."))
    return classes


def load_trackers(path: str | None) -> list[dict] | None:
    if path:
        with open(path, encoding="utf-8") as file:
            payload = json.load(file)
    else:
        payload = None
        for attempt in range(3):
            try:
                request = urllib.request.Request(API, headers={"User-Agent": USER_AGENT})
                with urllib.request.urlopen(request, timeout=30) as response:
                    payload = json.load(response)
                break
            except (urllib.error.URLError, TimeoutError, OSError, ValueError):
                time.sleep(3 * (attempt + 1))
        if payload is None:
            return None
    trackers = payload.get("trackers", payload) if isinstance(payload, dict) else payload
    if isinstance(trackers, dict):
        trackers = list(trackers.values())
    return trackers


def matches(trackers: list[dict], classes: list[str]) -> list[tuple[str, list[str]]]:
    found = []
    for tracker in trackers:
        signature = (tracker.get("code_signature") or "").strip()
        if not signature:
            continue
        pattern = re.compile(signature)
        hits = [c for c in classes if pattern.search(c)]
        if hits:
            found.append((tracker.get("name", "?"), hits))
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--trackers", help="εxodus trackers JSON instead of the API")
    parser.add_argument("apks", nargs="+")
    args = parser.parse_args()

    trackers = load_trackers(args.trackers)
    if trackers is None:
        print(
            f"::warning title=Tracker scan::εxodus' tracker list ({API}) could "
            "not be fetched; the APKs were not scanned for trackers."
        )
        return 0
    status = 0
    for apk in args.apks:
        try:
            classes = apk_classes(apk)
        except (OSError, ValueError, zipfile.BadZipFile, struct.error) as error:
            print(f"check_trackers: {apk}: {error}", file=sys.stderr)
            return 2
        found = matches(trackers, classes)
        if not found:
            print(
                f"check_trackers: OK: {apk}: {len(classes)} classes, none matches "
                f"the {len(trackers)} trackers εxodus knows"
            )
            continue
        status = 1
        for name, hits in found:
            shown = ", ".join(hits[:5]) + (" …" if len(hits) > 5 else "")
            print(f"::error title=Tracker in {apk}::{name}: {shown}")
    return status


if __name__ == "__main__":
    sys.exit(main())
