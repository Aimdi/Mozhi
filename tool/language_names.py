#!/usr/bin/env python3
"""Generates the names of the catalogue's languages in the app's languages.

  python3 tool/language_names.py CLDR_DIR \\
      [--catalog packages/translation_repository/lib/src/language_catalog.dart] \\
      [--output packages/translation_repository/lib/src/language_names_data.dart]

The language catalogue (`LanguageCatalog`) names every language in English
and in itself only, so a German UI would list "French" instead of
"Französisch". This script takes the names from Unicode CLDR, in the JSON
form of the npm package `cldr-localenames-full`, and writes them for every
catalogue code in each app language (APP_LOCALES) into a Dart file that the
app looks names up in (`languageDisplayName` in translation_repository).

CLDR_DIR is the extracted package (with `package.json` and
`main/<locale>/{languages,scripts,territories,localeDisplayNames}.json`),
e.g. for CLDR 49:

  mkdir -p /tmp/cldr && curl -sSL \\
    https://registry.npmjs.org/cldr-localenames-full/-/cldr-localenames-full-49.0.0.tgz \\
    | tar -xz -C /tmp/cldr
  python3 tool/language_names.py /tmp/cldr/package

How a catalogue code is named (`cldr_name`):

- RECIPES first: a CLDR language key (`tl` -> `fil`, `gom` -> `kok`,
  `zh-CN` -> `zh-Hans`) or a composition with a script (`pa` is Punjabi
  in Gurmukhi script, `ber` Tamazight in Tifinagh), tried in order;
- a plain code (`de`, `yue`) is its CLDR language name;
- a code with a script (`sr-Latn`) is "language (script)" and one with a
  region (`pt-BR`, `es-419`, `ar-EG`) "language (region)", with the
  locale's own pattern ("{0} ({1})", Chinese "{0}（{1}）"), like the
  catalogue's English names ("Portuguese (Brazil)") and so that variants
  sort next to their language.

A name CLDR lacks (or lacks a part of) is left out: the app shows the
English one. So are names equal to the English one ("Afrikaans" in German)
and English itself, whose UI shows the catalogue's own English names. The
first letter is upper-cased (CLDR writes "anglais", "inglés", "английский"
in running text; the app shows names on their own, as labels and list
entries); scripts without case are unchanged.

Licence: CLDR data is under the Unicode License v3; the app lists it with
its other notices (lib/app/third_party_licenses.dart).

Exit status: 0 on success, 2 on a usage or file error.

Tests: python3 tool/language_names_test.py
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CATALOG = (
    ROOT / "packages/translation_repository/lib/src/language_catalog.dart"
)
DEFAULT_OUTPUT = (
    ROOT / "packages/translation_repository/lib/src/language_names_data.dart"
)

# The app's UI languages but English (lib/l10n/arb/app_<locale>.arb).
APP_LOCALES = (
    "ar de es fr hi id it ja ko nl pl pt ru ta tr uk vi zh".split()
)

# Catalogue code -> how CLDR names it, alternatives in order: a CLDR
# language key, or (language key, "script" | "territory", subtag) for
# "language (script/region)".
RECIPES: dict[str, list] = {
    "zh-CN": ["zh-Hans", ("zh", "script", "Hans")],
    "zh-TW": ["zh-Hant", ("zh", "script", "Hant")],
    "fa-AF": ["fa-AF", "prs"],  # Dari
    "tl": ["fil"],  # Filipino
    "gom": ["gom", "kok"],  # Konkani
    "mni-Mtei": ["mni"],  # Meiteilon (Manipuri)
    "pa": [("pa", "script", "Guru")],  # Punjabi (Gurmukhi)
    "ber-Latn": ["zgh"],  # Tamazight
    "ber": [("zgh", "script", "Tfng")],  # Tamazight (Tifinagh)
    "ndc-ZW": ["ndc"],  # Ndau
}

_SCRIPT = re.compile(r"^[A-Z][a-z]{3}$")
_REGION = re.compile(r"^(?:[A-Z]{2}|[0-9]{3})$")

# `Language(code: 'xx', name: 'Xx'` in the catalogue (names with an
# apostrophe are in double quotes).
_ENTRY = re.compile(
    r"Language\(\s*code:\s*'([^']+)',\s*name:\s*(?:'([^']*)'|\"([^\"]*)\")"
)


class UsageError(Exception):
    """A missing or malformed input."""


def read_catalog(path: Path) -> dict[str, str]:
    """Catalogue code -> English name, in catalogue order."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise UsageError(f"cannot read {path}: {error}") from error
    entries = {}
    for match in _ENTRY.finditer(text):
        entries[match.group(1)] = match.group(2) or match.group(3) or ""
    if not entries:
        raise UsageError(f"no Language(code: ..., name: ...) in {path}")
    return entries


class Cldr:
    """The display names of one CLDR locale."""

    def __init__(self, root: Path, locale: str):
        def part(name: str) -> dict:
            path = root / "main" / locale / f"{name}.json"
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
                return data["main"][locale]["localeDisplayNames"]
            except (OSError, ValueError, KeyError) as error:
                raise UsageError(f"cannot read {path}: {error}") from error

        self.locale = locale
        self.languages: dict[str, str] = part("languages")["languages"]
        self.scripts: dict[str, str] = part("scripts")["scripts"]
        self.territories: dict[str, str] = part("territories")["territories"]
        self.pattern: str = part("localeDisplayNames")["localeDisplayPattern"][
            "localePattern"
        ]

    def compose(self, language: str, kind: str, subtag: str) -> str | None:
        """ "language (script/region)", or None when CLDR lacks a part."""
        base = self.languages.get(language)
        names = self.scripts if kind == "script" else self.territories
        qualifier = names.get(subtag)
        if base is None or qualifier is None:
            return None
        return self.pattern.replace("{0}", base).replace("{1}", qualifier)


def recipes_for(code: str) -> list:
    """How to name the catalogue [code], alternatives in order."""
    if code in RECIPES:
        return RECIPES[code]
    parts = code.split("-")
    if len(parts) == 1:
        return [code]
    if len(parts) == 2 and _SCRIPT.match(parts[1]):
        return [(parts[0], "script", parts[1])]
    if len(parts) == 2 and _REGION.match(parts[1]):
        return [(parts[0], "territory", parts[1])]
    return [code]


def cldr_name(cldr: Cldr, code: str) -> str | None:
    """The CLDR name of the catalogue [code] in [cldr]'s locale, or None."""
    for recipe in recipes_for(code):
        if isinstance(recipe, str):
            name = cldr.languages.get(recipe)
        else:
            name = cldr.compose(*recipe)
        if name:
            return name
    return None


def capitalize(name: str, locale: str) -> str:
    """[name] with its first letter in upper case ("anglais" -> "Anglais";
    Turkish "i" -> "İ", Dutch "ij" -> "IJ"); uncased scripts unchanged."""
    if not name or not name[0].islower():
        return name
    if locale == "tr" and name[0] == "i":
        return "İ" + name[1:]
    if locale == "nl" and name.startswith("ij"):
        return "IJ" + name[2:]
    first = name[0].upper()
    # A letter whose upper case is several letters ("ß") stays.
    return (first if len(first) == 1 else name[0]) + name[1:]


def build(root: Path, catalog: dict[str, str]) -> dict[str, dict[str, str]]:
    """App locale -> catalogue code -> name (only names that differ from
    the English one)."""
    table = {}
    for locale in APP_LOCALES:
        cldr = Cldr(root, locale)
        names = {}
        for code, english in catalog.items():
            name = cldr_name(cldr, code)
            if name is None:
                continue
            name = capitalize(name.strip(), locale)
            if name and name != english:
                names[code] = name
        table[locale] = names
    return table


def cldr_version(root: Path) -> tuple[str, str]:
    """(CLDR version, npm package version) from package.json."""
    path = root / "package.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return str(data["cldrVersion"]), str(data["version"])
    except (OSError, ValueError, KeyError) as error:
        raise UsageError(f"cannot read {path}: {error}") from error


def dart_string(text: str) -> str:
    """[text] as a single-quoted Dart string literal."""
    escaped = (
        text.replace("\\", "\\\\")
        .replace("'", "\\'")
        .replace("$", "\\$")
        .replace("\n", "\\n")
    )
    return f"'{escaped}'"


def _utf16_length(text: str) -> int:
    """Length as Dart (and `dart format`) counts it."""
    return len(text.encode("utf-16-le")) // 2


def render(
    table: dict[str, dict[str, str]],
    version: str,
    package_version: str,
) -> str:
    """The Dart file, formatted as `dart format` writes it."""
    lines = [
        "// Generated by `python3 tool/language_names.py`: the names of the",
        "// languages of LanguageCatalog in the app's languages (but English),",
        f"// from Unicode CLDR {version} (npm cldr-localenames-full"
        f" {package_version}),",
        "// under the Unicode License v3. Do not edit by hand.",
        "",
        "/// The Unicode CLDR release the language names come from.",
        f"const languageNamesCldrVersion = {dart_string(version)};",
        "",
        "/// Names of the catalogue's languages by app language, then by",
        "/// catalogue code, first letter upper-cased. A language whose name",
        "/// is its English one (or which CLDR does not name) is left out.",
        "const languageNamesData = <String, Map<String, String>>{",
    ]
    for locale, names in table.items():
        lines.append(f"  {dart_string(locale)}: {{")
        for code, name in sorted(names.items()):
            line = f"    {dart_string(code)}: {dart_string(name)},"
            if _utf16_length(line) > 80:
                lines.append(f"    {dart_string(code)}:")
                lines.append(f"        {dart_string(name)},")
            else:
                lines.append(line)
        lines.append("  },")
    lines.append("};")
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Write the catalogue's language names in the app "
        "languages from CLDR (cldr-localenames-full)."
    )
    parser.add_argument("cldr", type=Path, help="extracted npm package")
    parser.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args(argv)
    try:
        catalog = read_catalog(args.catalog)
        version, package_version = cldr_version(args.cldr)
        table = build(args.cldr, catalog)
        text = render(table, version, package_version)
        args.output.write_text(text, encoding="utf-8")
    except UsageError as error:
        print(f"language_names.py: {error}", file=sys.stderr)
        return 2
    except OSError as error:
        print(f"language_names.py: {error}", file=sys.stderr)
        return 2
    count = sum(len(names) for names in table.values())
    print(
        f"{args.output}: {count} names of {len(catalog)} languages in "
        f"{len(table)} app languages (CLDR {version})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
