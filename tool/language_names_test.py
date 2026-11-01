#!/usr/bin/env python3
"""Tests tool/language_names.py on a tiny CLDR tree and catalogue (no
network).

  python3 tool/language_names_test.py
"""

from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

TOOL = Path(__file__).resolve().parent / "language_names.py"
sys.path.insert(0, str(TOOL.parent))

import language_names as names  # noqa: E402

CATALOG = """
abstract final class LanguageCatalog {
  static const _languages = <Language>[
    Language(code: 'af', name: 'Afrikaans', nativeName: 'Afrikaans'),
    Language(code: 'zh-CN', name: 'Chinese (Simplified)', nativeName: 'x'),
    Language(code: 'en', name: 'English', nativeName: 'English'),
    Language(
      code: 'en-GB',
      name: 'English (UK)',
      nativeName: 'English (UK)',
    ),
    Language(code: 'fr', name: 'French', nativeName: 'Français'),
    Language(code: 'quc', name: "K'iche'", nativeName: 'Kʼicheʼ'),
    Language(code: 'pa', name: 'Punjabi (Gurmukhi)', nativeName: 'x'),
    Language(code: 'sr-Latn', name: 'Serbian (Latin)', nativeName: 'x'),
    Language(code: 'es-419', name: 'Spanish (Latin America)'),
    Language(code: 'tl', name: 'Filipino', nativeName: 'Filipino'),
    Language(code: 'xx', name: 'Unknownese', nativeName: 'x'),
  ];
}
"""

LOCALES = {
    "de": {
        "pattern": "{0} ({1})",
        "languages": {
            "af": "Afrikaans",
            "en": "Englisch",
            "en-GB": "Britisches Englisch",
            "es": "Spanisch",
            "fil": "Filipino",
            "fr": "Französisch",
            "pa": "Punjabi",
            "quc": "K’iche’",
            "sr": "Serbisch",
            "zh": "Chinesisch",
            "zh-Hans": "Chinesisch (vereinfacht)",
        },
        "scripts": {"Guru": "Gurmukhi", "Latn": "Lateinisch"},
        "territories": {"GB": "Vereinigtes Königreich", "419": "Lateinamerika"},
    },
    "fr": {
        "pattern": "{0} ({1})",
        "languages": {
            "en": "anglais",
            "es": "espagnol",
            "fr": "français",
            "sr": "serbe",
            "zh": "chinois",
        },
        "scripts": {"Latn": "latin", "Hans": "simplifié"},
        "territories": {"GB": "Royaume-Uni"},
    },
    "tr": {
        "pattern": "{0} ({1})",
        "languages": {"en": "ingilizce"},
        "scripts": {},
        "territories": {},
    },
    "zh": {
        "pattern": "{0}（{1}）",
        "languages": {"en": "英语", "es": "西班牙语"},
        "scripts": {},
        "territories": {"419": "拉丁美洲"},
    },
}


def write_cldr(root: Path, locales: dict, version: str = "49") -> None:
    root.mkdir(parents=True)
    (root / "package.json").write_text(
        json.dumps({"version": f"{version}.0.0", "cldrVersion": version}),
        encoding="utf-8",
    )
    for locale, data in locales.items():
        directory = root / "main" / locale
        directory.mkdir(parents=True)

        def part(name: str, content: dict) -> None:
            body = {
                "main": {
                    locale: {
                        "identity": {"language": locale},
                        "localeDisplayNames": content,
                    }
                }
            }
            (directory / f"{name}.json").write_text(
                json.dumps(body, ensure_ascii=False), encoding="utf-8"
            )

        part("languages", {"languages": data["languages"]})
        part("scripts", {"scripts": data["scripts"]})
        part("territories", {"territories": data["territories"]})
        part(
            "localeDisplayNames",
            {"localeDisplayPattern": {"localePattern": data["pattern"]}},
        )


class LanguageNamesTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.dir = Path(self.temp.name)
        self.cldr = self.dir / "package"
        write_cldr(self.cldr, LOCALES)
        self.catalog = self.dir / "language_catalog.dart"
        self.catalog.write_text(CATALOG, encoding="utf-8")
        self.output = self.dir / "language_names_data.dart"
        self.locales = names.APP_LOCALES
        names.APP_LOCALES = tuple(LOCALES)
        self.addCleanup(setattr, names, "APP_LOCALES", self.locales)

    def run_tool(self, *args: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = names.main(list(args))
        return code, out.getvalue(), err.getvalue()

    def build(self) -> dict[str, dict[str, str]]:
        return names.build(self.cldr, names.read_catalog(self.catalog))

    def test_reads_codes_and_english_names_of_the_catalogue(self):
        catalog = names.read_catalog(self.catalog)
        self.assertEqual(catalog["en-GB"], "English (UK)")
        self.assertEqual(catalog["quc"], "K'iche'")
        self.assertEqual(catalog["es-419"], "Spanish (Latin America)")
        self.assertEqual(len(catalog), 11)

    def test_names_plain_codes_from_the_cldr_languages(self):
        table = self.build()
        self.assertEqual(table["de"]["en"], "Englisch")
        self.assertEqual(table["de"]["fr"], "Französisch")
        self.assertEqual(table["zh"]["en"], "英语")

    def test_maps_catalogue_codes_to_cldr_ones(self):
        table = self.build()
        self.assertEqual(table["de"]["zh-CN"], "Chinesisch (vereinfacht)")
        # No zh-Hans in French: Chinese with the script.
        self.assertEqual(table["fr"]["zh-CN"], "Chinois (simplifié)")

    def test_composes_regions_and_scripts_with_the_locale_pattern(self):
        table = self.build()
        # Not CLDR's "Britisches Englisch": next to Englisch, as in English.
        self.assertEqual(table["de"]["en-GB"], "Englisch (Vereinigtes Königreich)")
        self.assertEqual(table["de"]["es-419"], "Spanisch (Lateinamerika)")
        self.assertEqual(table["de"]["sr-Latn"], "Serbisch (Lateinisch)")
        self.assertEqual(table["zh"]["es-419"], "西班牙语（拉丁美洲）")

    def test_upper_cases_the_first_letter(self):
        table = self.build()
        self.assertEqual(table["fr"]["en"], "Anglais")
        self.assertEqual(table["fr"]["sr-Latn"], "Serbe (latin)")
        self.assertEqual(table["tr"]["en"], "İngilizce")
        self.assertEqual(names.capitalize("ijslands", "nl"), "IJslands")
        self.assertEqual(names.capitalize("英语", "zh"), "英语")
        self.assertEqual(names.capitalize("", "de"), "")

    def test_leaves_out_english_equal_and_missing_names(self):
        table = self.build()
        de = table["de"]
        # Same as English.
        self.assertNotIn("af", de)
        self.assertNotIn("tl", de)
        self.assertNotIn("pa", de)  # Punjabi (Gurmukhi)
        # CLDR lacks it, or a part of it.
        self.assertNotIn("xx", de)
        self.assertNotIn("es-419", table["fr"])
        self.assertNotIn("quc", table["fr"])

    def test_writes_a_dart_file_with_version_and_header(self):
        code, out, err = self.run_tool(
            str(self.cldr),
            "--catalog",
            str(self.catalog),
            "--output",
            str(self.output),
        )
        self.assertEqual(code, 0, err)
        self.assertIn("names of 11 languages in 4 app languages (CLDR 49)", out)
        dart = self.output.read_text(encoding="utf-8")
        self.assertTrue(dart.startswith("// Generated by `python3 tool/"))
        self.assertIn("Do not edit by hand.", dart)
        self.assertIn("Unicode License v3", dart)
        self.assertIn("const languageNamesCldrVersion = '49';", dart)
        # By code.
        self.assertIn(
            "  'de': {\n    'en': 'Englisch',\n"
            "    'en-GB': 'Englisch (Vereinigtes Königreich)',\n",
            dart,
        )
        self.assertIn("    'quc': 'K’iche’',\n", dart)
        self.assertIn("  'tr': {\n    'en': 'İngilizce',\n  },\n", dart)
        self.assertTrue(dart.endswith("};\n"))
        self.assertTrue(all(len(line) <= 80 for line in dart.splitlines()))

    def test_wraps_entries_longer_than_80_columns_as_dart_format_does(self):
        long = "Arabisch (Vereinigte Arabische Emirate und die ganze Golfregion Asiens)"
        dart = names.render(
            {"de": {"ar-AE": long, "en": "Englisch"}}, "49", "49.0.0"
        )
        self.assertIn(
            f"    'ar-AE':\n        '{long}',\n    'en': 'Englisch',\n", dart
        )

    def test_names_every_app_language_but_english(self):
        arb = TOOL.parent.parent / "lib" / "l10n" / "arb"
        locales = {
            path.stem.removeprefix("app_") for path in arb.glob("app_*.arb")
        }
        self.assertEqual(set(self.locales), locales - {"en"})

    def test_escapes_dart_strings(self):
        self.assertEqual(names.dart_string("a'b$c\\d"), "'a\\'b\\$c\\\\d'")

    def test_rejects_missing_inputs(self):
        code, _, err = self.run_tool(
            str(self.dir / "missing"),
            "--catalog",
            str(self.catalog),
            "--output",
            str(self.output),
        )
        self.assertEqual(code, 2)
        self.assertIn("cannot read", err)
        self.assertFalse(self.output.exists())

        empty = self.dir / "empty.dart"
        empty.write_text("// nothing\n", encoding="utf-8")
        code, _, err = self.run_tool(
            str(self.cldr), "--catalog", str(empty), "--output", str(self.output)
        )
        self.assertEqual(code, 2)
        self.assertIn("no Language(code", err)

    def test_rejects_a_locale_missing_from_cldr(self):
        names.APP_LOCALES = ("de", "ko")
        code, _, err = self.run_tool(
            str(self.cldr),
            "--catalog",
            str(self.catalog),
            "--output",
            str(self.output),
        )
        self.assertEqual(code, 2)
        self.assertIn("main/ko/languages.json", err)


if __name__ == "__main__":
    unittest.main()
