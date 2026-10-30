#!/usr/bin/env python3
"""Validate the store listing metadata in fastlane/metadata/android.

The layout is the one shared by fastlane supply (Google Play) and F-Droid:

    fastlane/metadata/android/<locale>/
        title.txt              <= 30 chars (Play; F-Droid allows 50)
        short_description.txt  <= 80 chars
        full_description.txt   <= 4000 chars
        changelogs/<versionCode>.txt  <= 500 chars
        images/icon.png        512x512 PNG
        images/featureGraphic.png  1024x500 PNG/JPEG, no alpha (Play requires it)
        images/phoneScreenshots/*.png|jpg

Lengths are counted in Unicode code points after stripping surrounding
whitespace, the way both stores count them.

Every language the app is translated into (lib/l10n/arb/app_<code>.arb)
must have a complete listing in its store locale ([APP_LOCALES]): the
title, both descriptions and the changelog of the versionCode in
pubspec.yaml (with its split-per-ABI copies where en-US has them), and
none of its texts may be a copy of the English one. Split-per-ABI copies
of a changelog (N+1000, N+2000, N+4000) must match N.

Usage:  python3 fastlane/validate_metadata.py [--strict] [--root <repo>]

Exits with status 1 if any error is found. Google Play image rules that
F-Droid does not have (aspect ratio at most 2:1, at most 8 screenshots, a
1024x500 feature graphic without alpha in en-US) are reported as warnings,
or as errors with --strict.
"""

from __future__ import annotations

import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_LOCALE = "en-US"

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
# The app's languages (lib/l10n/arb/app_<code>.arb) and the Google Play
# listing language each one is listed in (fastlane supply's codes).
APP_LOCALES = {
    "en": "en-US",
    "ar": "ar",
    "de": "de-DE",
    "es": "es-ES",
    "fr": "fr-FR",
    "hi": "hi-IN",
    "id": "id",
    "it": "it-IT",
    "ja": "ja-JP",
    "ko": "ko-KR",
    "nl": "nl-NL",
    "pl": "pl-PL",
    "pt": "pt-BR",
    "ru": "ru-RU",
    "ta": "ta-IN",
    "tr": "tr-TR",
    "uk": "uk",
    "vi": "vi",
    "zh": "zh-CN",
}
_ARB_RE = re.compile(r"^app_([A-Za-z_]+)\.arb$")


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


def has_alpha(path: Path) -> bool:
    # PNG colour types 4 (grey + alpha) and 6 (RGBA); JPEG has no alpha.
    data = path.read_bytes()
    return data[:8] == b"\x89PNG\r\n\x1a\n" and data[25] in (4, 6)


def app_languages(root: Path) -> list[str] | None:
    """The app's languages, from lib/l10n/arb/app_<code>.arb (None when
    the folder is missing)."""
    arb = root / "lib" / "l10n" / "arb"
    if not arb.is_dir():
        return None
    return sorted(
        m.group(1) for p in arb.iterdir() if (m := _ARB_RE.match(p.name))
    )


def split_base(code: int) -> int | None:
    """The version code a split-per-ABI code was made from (2001 -> 1),
    or None for a plain code."""
    for offset in ABI_OFFSETS.values():
        base = code - offset
        if 0 < base < 1000:
            return base
    return None


def bullets(text: str) -> int:
    """The number of "•" lines of a description."""
    return sum(1 for line in text.splitlines() if line.lstrip().startswith("•"))


class Validator:
    def __init__(self, root: Path = ROOT, strict: bool = False) -> None:
        self.root = root
        self.meta = root / "fastlane" / "metadata" / "android"
        self.strict = strict
        self.errors: list[str] = []
        self.warnings: list[str] = []

    def rel(self, path: Path) -> str:
        return str(path.relative_to(self.root))

    def read_text(self, path: Path) -> str | None:
        raw = path.read_bytes()
        if raw.startswith(b"\xef\xbb\xbf"):
            self.errors.append(f"{self.rel(path)}: starts with a UTF-8 BOM")
        try:
            return raw.decode("utf-8-sig")
        except UnicodeDecodeError:
            self.errors.append(f"{self.rel(path)}: not valid UTF-8")
            return None

    @staticmethod
    def body(path: Path) -> str | None:
        """The trimmed text of [path] (None when missing or unreadable),
        without reporting anything."""
        if not path.is_file():
            return None
        try:
            return path.read_bytes().decode("utf-8-sig").strip()
        except UnicodeDecodeError:
            return None

    def check_text(self, path: Path, limit: int) -> None:
        text = self.read_text(path)
        if text is None:
            return
        body = text.strip()
        n = len(body)
        if n == 0:
            self.errors.append(f"{self.rel(path)}: empty")
        elif n > limit:
            self.errors.append(f"{self.rel(path)}: {n} chars > {limit}")
        if path.name in ("title.txt", "short_description.txt") and "\n" in body:
            self.errors.append(f"{self.rel(path)}: must be a single line")
        if path.name == "short_description.txt" and body.endswith("."):
            self.warnings.append(
                f"{self.rel(path)}: F-Droid recommends no trailing full stop"
            )
        if re.search(r"<[a-zA-Z/][^>]*>", body):
            self.warnings.append(
                f"{self.rel(path)}: contains HTML-like tags (plain text expected)"
            )
        print(f"  {path.name:<24} {n:>5} / {limit}")

    def current_version_code(self) -> int | None:
        pubspec = self.root / "pubspec.yaml"
        if not pubspec.is_file():
            return None
        match = re.search(r"^version:\s*[^+\s]+\+(\d+)", pubspec.read_text(), re.M)
        return int(match.group(1)) if match else None

    def required_locales(self) -> set[str]:
        """The store locales of the app's languages; reports app languages
        that have none."""
        languages = app_languages(self.root)
        if languages is None:
            self.warnings.append(
                "lib/l10n/arb not found: not checking that every app "
                "language has a listing"
            )
            return set()
        required = set()
        for code in languages:
            locale = APP_LOCALES.get(code)
            if locale is None:
                self.errors.append(
                    f"lib/l10n/arb/app_{code}.arb: no store locale for app "
                    f"language '{code}' (add it to APP_LOCALES in "
                    "fastlane/validate_metadata.py)"
                )
            else:
                required.add(locale)
        return required

    def check_complete(
        self, locale_dir: Path, version_code: int | None, default: Path
    ) -> None:
        """The listing of an app language: every file, the current
        changelog (and the split copies en-US has), nothing copied from
        en-US."""
        title = locale_dir / "title.txt"
        if not title.exists() and locale_dir != default:
            self.errors.append(f"{self.rel(title)}: missing")
        if version_code is not None:
            codes = [version_code] + [
                version_code + off
                for off in ABI_OFFSETS.values()
                if (default / "changelogs" / f"{version_code + off}.txt").exists()
            ]
            for code in codes:
                log = locale_dir / "changelogs" / f"{code}.txt"
                if not log.exists():
                    self.errors.append(
                        f"{self.rel(log)}: missing (versionCode {version_code} "
                        "from pubspec.yaml)"
                    )
        if locale_dir == default:
            return
        names = ["short_description.txt", "full_description.txt"]
        logs = locale_dir / "changelogs"
        if logs.is_dir():
            names += [f"changelogs/{p.name}" for p in sorted(logs.glob("*.txt"))]
        for name in names:
            mine = self.body(locale_dir / name)
            if mine and mine == self.body(default / name):
                self.errors.append(
                    f"{self.rel(locale_dir / name)}: same as {DEFAULT_LOCALE} "
                    "(not translated)"
                )
        mine = self.body(locale_dir / "full_description.txt")
        english = self.body(default / "full_description.txt")
        if mine and english and bullets(mine) != bullets(english):
            self.warnings.append(
                f"{self.rel(locale_dir / 'full_description.txt')}: "
                f"{bullets(mine)} bullets, {DEFAULT_LOCALE} has {bullets(english)}"
            )

    def check_split_copies(self, changelogs: Path) -> None:
        for log in sorted(changelogs.glob("*.txt")):
            if not log.stem.isdigit():
                continue
            base = split_base(int(log.stem))
            if base is None:
                continue
            original = changelogs / f"{base}.txt"
            if original.exists() and self.body(original) != self.body(log):
                self.errors.append(
                    f"{self.rel(log)}: differs from {base}.txt (the split-APK "
                    "copies must be the same changelog)"
                )

    def check_images(self, locale_dir: Path) -> None:
        images = locale_dir / "images"
        play = self.errors if self.strict else self.warnings
        graphics = [
            images / f"featureGraphic.{ext}"
            for ext in ("png", "jpg", "jpeg")
            if (images / f"featureGraphic.{ext}").exists()
        ]
        if not graphics and locale_dir.name == DEFAULT_LOCALE:
            play.append(
                f"{self.rel(images)}/featureGraphic.png: missing (Play requires it)"
            )
        for graphic in graphics:
            size = image_size(graphic)
            if size != (1024, 500):
                self.errors.append(f"{self.rel(graphic)}: {size}, expected 1024x500")
            if has_alpha(graphic):
                play.append(
                    f"{self.rel(graphic)}: has an alpha channel (Play rejects it)"
                )
            status = "ok" if size == (1024, 500) else size
            print(f"  images/{graphic.name:<17} {status}")
        if not images.is_dir():
            return
        icon = images / "icon.png"
        if icon.exists():
            size = image_size(icon)
            if size != (512, 512):
                self.errors.append(f"{self.rel(icon)}: {size}, expected 512x512 PNG")
        for sub in SCREENSHOT_DIRS:
            folder = images / sub
            if not folder.is_dir():
                continue
            shots = sorted(p for p in folder.iterdir() if p.is_file())
            if len(shots) > 8:
                play.append(
                    f"{self.rel(folder)}: {len(shots)} screenshots, Play allows 8"
                )
            for shot in shots:
                size = image_size(shot)
                if size is None:
                    self.errors.append(f"{self.rel(shot)}: not a PNG or JPEG")
                    continue
                w, h = size
                if has_alpha(shot):
                    play.append(
                        f"{self.rel(shot)}: has an alpha channel "
                        "(Play wants 24-bit PNG)"
                    )
                if min(w, h) < 320 or max(w, h) > 3840:
                    self.errors.append(
                        f"{self.rel(shot)}: {w}x{h}, sides must be 320-3840 px"
                    )
                if max(w, h) > 2 * min(w, h):
                    play.append(
                        f"{self.rel(shot)}: {w}x{h} is taller than 2:1 "
                        "(Google Play rejects it; F-Droid is fine)"
                    )
            print(f"  images/{sub:<17} {len(shots):>5} files")

    def run(self) -> int:
        """Checks everything, prints the report; 1 on errors, else 0."""
        if not self.meta.is_dir():
            self.errors.append(f"missing {self.rel(self.meta)}")
            print(f"missing {self.meta}")
            return 1
        version_code = self.current_version_code()
        default = self.meta / DEFAULT_LOCALE
        required = self.required_locales() | {DEFAULT_LOCALE}
        locales = sorted(p for p in self.meta.iterdir() if p.is_dir())
        present = {p.name for p in locales}
        for locale in sorted(required - present):
            if locale == DEFAULT_LOCALE:
                self.errors.append(f"{DEFAULT_LOCALE} (the default locale) is missing")
            else:
                self.errors.append(
                    f"{self.rel(self.meta / locale)}: missing (the app is "
                    "translated into this language)"
                )
        for locale_dir in locales:
            print(locale_dir.name)
            if not LOCALE_RE.match(locale_dir.name):
                self.errors.append(f"{self.rel(locale_dir)}: unexpected locale code")
            for name, limit in LIMITS.items():
                path = locale_dir / name
                if path.exists():
                    self.check_text(path, limit)
                elif name != "title.txt" or locale_dir.name == DEFAULT_LOCALE:
                    self.errors.append(f"{self.rel(path)}: missing")
            changelogs = locale_dir / "changelogs"
            if changelogs.is_dir():
                for log in sorted(changelogs.glob("*.txt")):
                    if not log.stem.isdigit():
                        self.errors.append(
                            f"{self.rel(log)}: name must be <versionCode>.txt"
                        )
                    self.check_text(log, CHANGELOG_LIMIT)
                self.check_split_copies(changelogs)
            if locale_dir.name in required:
                self.check_complete(locale_dir, version_code, default)
            if version_code is not None and locale_dir.name == DEFAULT_LOCALE:
                split = [
                    str(version_code + off)
                    for off in ABI_OFFSETS.values()
                    if not (changelogs / f"{version_code + off}.txt").exists()
                ]
                if split:
                    self.warnings.append(
                        "no changelogs for split-per-ABI version codes "
                        f"{', '.join(split)}; fine if F-Droid builds one APK "
                        f"with versionCode {version_code} (see docs/store/README.md)"
                    )
            self.check_images(locale_dir)

        for w in self.warnings:
            print(f"WARNING: {w}")
        for e in self.errors:
            print(f"ERROR: {e}")
        print("OK" if not self.errors else f"{len(self.errors)} error(s)")
        return 1 if self.errors else 0


def main(argv: list[str]) -> int:
    root = ROOT
    if "--root" in argv:
        index = argv.index("--root")
        if index + 1 >= len(argv):
            print(__doc__)
            return 2
        root = Path(argv[index + 1]).resolve()
    return Validator(root, strict="--strict" in argv).run()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
