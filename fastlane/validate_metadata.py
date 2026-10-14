#!/usr/bin/env python3
"""Validate the store listing metadata in fastlane/metadata/android.

The layout is the one shared by fastlane supply (Google Play) and F-Droid:

    fastlane/metadata/android/<locale>/
        title.txt              <= 30 chars (Play; F-Droid allows 50)
        short_description.txt  <= 80 chars
        full_description.txt   <= 4000 chars
        changelogs/<versionCode>.txt  <= 500 chars
        images/icon.png        512x512 PNG
        images/phoneScreenshots/*.png|jpg

Lengths are counted in Unicode code points after stripping surrounding
whitespace, the way both stores count them.

Usage:  python3 fastlane/validate_metadata.py [--strict]

Exits with status 1 if any error is found. Google Play image rules that
F-Droid does not have (aspect ratio at most 2:1, at most 8 screenshots) are
reported as warnings, or as errors with --strict.
"""

from __future__ import annotations

import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
META = ROOT / "fastlane" / "metadata" / "android"
PUBSPEC = ROOT / "pubspec.yaml"

LIMITS = {
    "title.txt": 30,
    "short_description.txt": 80,
    "full_description.txt": 4000,
}
CHANGELOG_LIMIT = 500
SCREENSHOT_DIRS = (
    "phoneScreenshots",
    "sevenInchScreenshots",
    "tenInchScreenshots",
    "tvScreenshots",
    "wearScreenshots",
)
# Google Play listing languages use these codes; F-Droid accepts them too.
LOCALE_RE = re.compile(r"^[a-z]{2,3}(-[A-Z]{2}|-[0-9]{3}|-[A-Za-z]{4})?$")
# Flutter's --split-per-abi adds 1000 * ABI code to the version code.
ABI_OFFSETS = {"armeabi-v7a": 1000, "arm64-v8a": 2000, "x86_64": 4000}

errors: list[str] = []
warnings: list[str] = []


def image_size(path: Path) -> tuple[int, int] | None:
    data = path.read_bytes()
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return struct.unpack(">II", data[16:24])
    if data[:2] == b"\xff\xd8":  # JPEG: walk the segments to the SOF marker.
        i = 2
        while i + 9 < len(data):
            if data[i] != 0xFF:
                i += 1
                continue
            marker = data[i + 1]
            length = struct.unpack(">H", data[i + 2 : i + 4])[0]
            if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
                h, w = struct.unpack(">HH", data[i + 5 : i + 9])
                return w, h
            i += 2 + length
    return None


def read_text(path: Path) -> str | None:
    raw = path.read_bytes()
    if raw.startswith(b"\xef\xbb\xbf"):
        errors.append(f"{rel(path)}: starts with a UTF-8 BOM")
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        errors.append(f"{rel(path)}: not valid UTF-8")
        return None


def rel(path: Path) -> str:
    return str(path.relative_to(ROOT))


def check_text(path: Path, limit: int) -> None:
    text = read_text(path)
    if text is None:
        return
    body = text.strip()
    n = len(body)
    if n == 0:
        errors.append(f"{rel(path)}: empty")
    elif n > limit:
        errors.append(f"{rel(path)}: {n} chars > {limit}")
    if path.name in ("title.txt", "short_description.txt") and "\n" in body:
        errors.append(f"{rel(path)}: must be a single line")
    if path.name == "short_description.txt" and body.endswith("."):
        warnings.append(f"{rel(path)}: F-Droid recommends no trailing full stop")
    if re.search(r"<[a-zA-Z/][^>]*>", body):
        warnings.append(f"{rel(path)}: contains HTML-like tags (plain text expected)")
    print(f"  {path.name:<24} {n:>5} / {limit}")


def current_version_code() -> int | None:
    match = re.search(r"^version:\s*[^+\s]+\+(\d+)", PUBSPEC.read_text(), re.M)
    return int(match.group(1)) if match else None


def check_images(locale_dir: Path, strict: bool) -> None:
    images = locale_dir / "images"
    if not images.is_dir():
        return
    icon = images / "icon.png"
    if icon.exists():
        size = image_size(icon)
        if size != (512, 512):
            errors.append(f"{rel(icon)}: {size}, expected 512x512 PNG")
    play = errors if strict else warnings
    for sub in SCREENSHOT_DIRS:
        folder = images / sub
        if not folder.is_dir():
            continue
        shots = sorted(p for p in folder.iterdir() if p.is_file())
        if len(shots) > 8:
            play.append(f"{rel(folder)}: {len(shots)} screenshots, Play allows 8")
        for shot in shots:
            size = image_size(shot)
            if size is None:
                errors.append(f"{rel(shot)}: not a PNG or JPEG")
                continue
            w, h = size
            if shot.suffix.lower() == ".png" and shot.read_bytes()[25] in (4, 6):
                play.append(f"{rel(shot)}: has an alpha channel (Play wants 24-bit PNG)")
            if min(w, h) < 320 or max(w, h) > 3840:
                errors.append(f"{rel(shot)}: {w}x{h}, sides must be 320-3840 px")
            if max(w, h) > 2 * min(w, h):
                play.append(
                    f"{rel(shot)}: {w}x{h} is taller than 2:1 "
                    "(Google Play rejects it; F-Droid is fine)"
                )
        print(f"  images/{sub:<17} {len(shots):>5} files")


def main() -> int:
    strict = "--strict" in sys.argv
    if not META.is_dir():
        print(f"missing {META}")
        return 1
    version_code = current_version_code()
    locales = sorted(p for p in META.iterdir() if p.is_dir())
    if not any(p.name == "en-US" for p in locales):
        errors.append("en-US (the default locale) is missing")
    for locale_dir in locales:
        print(locale_dir.name)
        if not LOCALE_RE.match(locale_dir.name):
            errors.append(f"{rel(locale_dir)}: unexpected locale code")
        for name, limit in LIMITS.items():
            path = locale_dir / name
            if path.exists():
                check_text(path, limit)
            elif name != "title.txt" or locale_dir.name == "en-US":
                errors.append(f"{rel(path)}: missing")
        changelogs = locale_dir / "changelogs"
        if changelogs.is_dir():
            for log in sorted(changelogs.glob("*.txt")):
                if not log.stem.isdigit():
                    errors.append(f"{rel(log)}: name must be <versionCode>.txt")
                check_text(log, CHANGELOG_LIMIT)
        if version_code is not None and locale_dir.name == "en-US":
            if not (changelogs / f"{version_code}.txt").exists():
                errors.append(
                    f"{rel(changelogs)}/{version_code}.txt missing "
                    "(versionCode from pubspec.yaml)"
                )
            split = [
                str(version_code + off)
                for off in ABI_OFFSETS.values()
                if not (changelogs / f"{version_code + off}.txt").exists()
            ]
            if split:
                warnings.append(
                    "no changelogs for split-per-ABI version codes "
                    f"{', '.join(split)}; fine if F-Droid builds one APK "
                    f"with versionCode {version_code} (see docs/store/README.md)"
                )
        check_images(locale_dir, strict)

    for w in warnings:
        print(f"WARNING: {w}")
    for e in errors:
        print(f"ERROR: {e}")
    print("OK" if not errors else f"{len(errors)} error(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
