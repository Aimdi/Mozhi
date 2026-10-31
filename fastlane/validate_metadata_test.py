#!/usr/bin/env python3
"""Tests for validate_metadata.py on small listings in a temporary folder.

  python3 fastlane/validate_metadata_test.py
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

sys.path.insert(0, str(Path(__file__).resolve().parent))

import validate_metadata as vm  # noqa: E402

ENGLISH = {
    "title.txt": "Mozhi Translate",
    "short_description.txt": "Private translator",
    "full_description.txt": "Intro.\n\nPRIVATE\n• One\n• Two",
    "changelogs/1.txt": "First release.\n• Everything",
}
GERMAN = {
    "title.txt": "Mozhi Translate",
    "short_description.txt": "Privater Übersetzer",
    "full_description.txt": "Einleitung.\n\nPRIVAT\n• Eins\n• Zwei",
    "changelogs/1.txt": "Erste Version.\n• Alles",
}


def png(width: int, height: int, colour_type: int = 2) -> bytes:
    """A minimal PNG header (the validator reads only the IHDR)."""
    ihdr = struct.pack(">IIBBBBB", width, height, 8, colour_type, 0, 0, 0)
    chunk = b"IHDR" + ihdr
    crc = struct.pack(">I", zlib.crc32(chunk))
    return b"\x89PNG\r\n\x1a\n" + struct.pack(">I", len(ihdr)) + chunk + crc


class ListingTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "pubspec.yaml").write_text("name: mozhi\nversion: 0.1.0+1\n")
        self.arb("en")
        self.arb("de")
        self.locale("en-US", ENGLISH)
        self.locale("de-DE", GERMAN)
        self.graphic()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def arb(self, code: str) -> None:
        folder = self.root / "lib" / "l10n" / "arb"
        folder.mkdir(parents=True, exist_ok=True)
        (folder / f"app_{code}.arb").write_text("{}")

    def locale(self, name: str, files: dict[str, str]) -> None:
        for rel, text in files.items():
            self.write(f"{name}/{rel}", text)

    def write(self, rel: str, text: str | bytes) -> Path:
        path = self.root / "fastlane" / "metadata" / "android" / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(text, bytes):
            path.write_bytes(text)
        else:
            path.write_text(text + "\n", encoding="utf-8")
        return path

    def graphic(self) -> None:
        self.write("en-US/images/featureGraphic.png", png(1024, 500))

    def run_validator(self, strict: bool = False) -> vm.Validator:
        validator = vm.Validator(self.root, strict=strict)
        with contextlib.redirect_stdout(io.StringIO()):
            validator.run()
        return validator

    def assertError(self, validator: vm.Validator, fragment: str) -> None:
        self.assertTrue(
            any(fragment in e for e in validator.errors),
            f"no error with {fragment!r} in {validator.errors}",
        )


class CompleteListingTest(ListingTest):
    def test_a_complete_listing_passes(self):
        validator = self.run_validator(strict=True)

        self.assertEqual(validator.errors, [])

    def test_exit_status_follows_the_errors(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(vm.Validator(self.root).run(), 0)
            self.assertEqual(vm.main(["--root", str(self.root)]), 0)
            self.write("en-US/short_description.txt", "x" * 81)
            self.assertEqual(vm.main(["--root", str(self.root)]), 1)
            self.assertEqual(vm.main(["--root"]), 2)

    def test_every_app_language_needs_a_listing(self):
        self.arb("ja")

        self.assertError(self.run_validator(), "android/ja-JP: missing")

    def test_an_app_language_without_a_store_locale_is_reported(self):
        self.arb("xx")

        self.assertError(self.run_validator(), "app_xx.arb: no store locale")

    def test_every_app_language_maps_to_a_valid_store_locale(self):
        for locale in vm.APP_LOCALES.values():
            self.assertRegex(locale, vm.LOCALE_RE)
        self.assertEqual(vm.APP_LOCALES["en"], vm.DEFAULT_LOCALE)

    def test_the_repository_languages_all_have_a_store_locale(self):
        languages = vm.app_languages(vm.ROOT)

        self.assertIsNotNone(languages)
        self.assertEqual(
            [code for code in languages if code not in vm.APP_LOCALES], []
        )

    def test_an_app_language_needs_its_title(self):
        (self.root / "fastlane/metadata/android/de-DE/title.txt").unlink()

        self.assertError(self.run_validator(), "de-DE/title.txt: missing")

    def test_another_locale_may_leave_out_its_title(self):
        self.locale("fr-FR", {
            "short_description.txt": "Traducteur privé",
            "full_description.txt": "Intro FR.\n• Un\n• Deux",
        })

        self.assertEqual(self.run_validator().errors, [])

    def test_an_app_language_needs_the_current_changelog(self):
        (self.root / "pubspec.yaml").write_text("version: 0.2.0+2\n")
        self.write("en-US/changelogs/2.txt", "Second release.")

        validator = self.run_validator()

        self.assertError(validator, "de-DE/changelogs/2.txt: missing")
        self.assertFalse(any("en-US/changelogs/2.txt" in e for e in validator.errors))

    def test_the_default_locale_needs_the_current_changelog(self):
        (self.root / "pubspec.yaml").write_text("version: 0.2.0+2\n")

        self.assertError(self.run_validator(), "en-US/changelogs/2.txt: missing")

    def test_split_copies_that_en_us_has_are_required(self):
        self.write("en-US/changelogs/2001.txt", ENGLISH["changelogs/1.txt"])

        self.assertError(self.run_validator(), "de-DE/changelogs/2001.txt: missing")

    def test_missing_split_copies_are_only_a_warning(self):
        validator = self.run_validator()

        self.assertEqual(validator.errors, [])
        self.assertTrue(any("1001, 2001, 4001" in w for w in validator.warnings))

    def test_a_split_copy_must_match_its_changelog(self):
        self.write("de-DE/changelogs/1001.txt", "Etwas anderes.")

        self.assertError(self.run_validator(), "de-DE/changelogs/1001.txt: differs")

    def test_an_untranslated_text_is_an_error(self):
        self.write("de-DE/full_description.txt", ENGLISH["full_description.txt"])

        self.assertError(
            self.run_validator(), "de-DE/full_description.txt: same as en-US"
        )

    def test_the_title_may_stay_in_english(self):
        self.assertEqual(self.run_validator().errors, [])

    def test_another_number_of_bullets_is_a_warning(self):
        self.write("de-DE/full_description.txt", "Einleitung.\n• Eins")

        validator = self.run_validator()

        self.assertEqual(validator.errors, [])
        self.assertTrue(any("1 bullets, en-US has 2" in w for w in validator.warnings))

    def test_without_arb_files_only_en_us_is_required(self):
        for path in (self.root / "lib/l10n/arb").iterdir():
            path.unlink()
        (self.root / "lib/l10n/arb").rmdir()

        validator = self.run_validator()

        self.assertEqual(validator.errors, [])
        self.assertTrue(any("lib/l10n/arb not found" in w for w in validator.warnings))

    def test_a_missing_metadata_folder_fails(self):
        validator = vm.Validator(self.root / "nowhere")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(validator.run(), 1)


class TextRulesTest(ListingTest):
    def test_lengths_are_counted_in_code_points(self):
        self.write("de-DE/short_description.txt", "ü" * 80)
        self.assertEqual(self.run_validator().errors, [])

        self.write("de-DE/short_description.txt", "ü" * 81)
        self.assertError(self.run_validator(), "81 chars > 80")

    def test_changelogs_are_limited_to_500(self):
        self.write("de-DE/changelogs/1.txt", "x" * 501)

        self.assertError(self.run_validator(), "1.txt: 501 chars > 500")

    def test_single_line_fields_and_empty_files(self):
        self.write("de-DE/title.txt", "Mozhi\nTranslate")
        self.write("de-DE/short_description.txt", "")

        validator = self.run_validator()

        self.assertError(validator, "title.txt: must be a single line")
        self.assertError(validator, "short_description.txt: empty")

    def test_bom_and_invalid_utf8(self):
        self.write("de-DE/title.txt", "﻿Mozhi".encode())
        self.write("de-DE/short_description.txt", b"\xff\xfe")

        validator = self.run_validator()

        self.assertError(validator, "title.txt: starts with a UTF-8 BOM")
        self.assertError(validator, "short_description.txt: not valid UTF-8")

    def test_changelog_names_must_be_version_codes(self):
        self.write("de-DE/changelogs/latest.txt", "Neu")

        self.assertError(self.run_validator(), "name must be <versionCode>.txt")

    def test_unexpected_locale_codes(self):
        self.locale("german", GERMAN)

        self.assertError(self.run_validator(), "german: unexpected locale code")

    def test_html_and_a_trailing_full_stop_are_warnings(self):
        self.write("de-DE/short_description.txt", "Privat <b>und</b> frei.")

        validator = self.run_validator()

        self.assertEqual(validator.errors, [])
        self.assertTrue(any("HTML-like" in w for w in validator.warnings))
        self.assertTrue(any("full stop" in w for w in validator.warnings))


class ImageRulesTest(ListingTest):
    def test_play_rules_are_warnings_unless_strict(self):
        self.write("en-US/images/phoneScreenshots/01.png", png(1080, 2400))

        self.assertEqual(self.run_validator().errors, [])
        self.assertError(self.run_validator(strict=True), "taller than 2:1")

    def test_alpha_and_too_many_screenshots(self):
        for i in range(9):
            self.write(f"en-US/images/phoneScreenshots/{i}.png", png(1080, 2160, 6))

        validator = self.run_validator(strict=True)

        self.assertError(validator, "9 screenshots, Play allows 8")
        self.assertError(validator, "has an alpha channel")

    def test_sizes_of_screenshots_icon_and_graphic(self):
        self.write("en-US/images/phoneScreenshots/small.png", png(200, 300))
        self.write("en-US/images/phoneScreenshots/notes.txt", "not an image")
        self.write("en-US/images/icon.png", png(256, 256))
        self.write("en-US/images/featureGraphic.png", png(1000, 500))

        validator = self.run_validator()

        self.assertError(validator, "small.png: 200x300, sides must be 320-3840")
        self.assertError(validator, "notes.txt: not a PNG or JPEG")
        self.assertError(validator, "icon.png: (256, 256), expected 512x512")
        self.assertError(validator, "featureGraphic.png: (1000, 500)")

    def test_the_feature_graphic_is_required_for_play(self):
        images = self.root / "fastlane/metadata/android/en-US/images"
        (images / "featureGraphic.png").unlink()

        self.assertError(self.run_validator(strict=True), "featureGraphic.png: missing")

    def test_reads_jpeg_sizes(self):
        sof = b"\xff\xc0" + struct.pack(">HBHH", 17, 8, 500, 1024) + b"\x00" * 10
        jpeg = b"\xff\xd8" + b"\xff\xe0" + struct.pack(">H", 4) + b"\x00\x00" + sof
        path = self.write("en-US/images/featureGraphic.jpg", jpeg)

        self.assertEqual(vm.image_size(path), (1024, 500))
        self.assertFalse(vm.has_alpha(path))


class HelpersTest(unittest.TestCase):
    def test_split_base(self):
        self.assertEqual(vm.split_base(1001), 1)
        self.assertEqual(vm.split_base(2001), 1)
        self.assertEqual(vm.split_base(4999), 999)
        self.assertIsNone(vm.split_base(1))
        self.assertIsNone(vm.split_base(1000))

    def test_bullets(self):
        self.assertEqual(vm.bullets("Intro\n• a\n  • b\nnot • c"), 2)


class RepositoryListingTest(unittest.TestCase):
    def test_en_us_fits_and_leaves_room_for_translations(self):
        en = vm.ROOT / "fastlane" / "metadata" / "android" / "en-US"
        full = (en / "full_description.txt").read_text(encoding="utf-8").strip()
        short = (en / "short_description.txt").read_text(encoding="utf-8").strip()

        # Translations run longer than English: keep a quarter in reserve.
        self.assertLessEqual(len(full), 3200)
        self.assertLessEqual(len(short), 70)


if __name__ == "__main__":
    unittest.main()
