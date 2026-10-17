#!/usr/bin/env python3
"""Builds the text-recognition language catalog from Tesseract's tessdata_fast.

Usage:
    python3 packages/tesseract_ocr/tool/tessdata_catalog.py
        [--commit SHA] [--out PATH] [--cache DIR] [--jobs N] [--offline]

Writes ``packages/tesseract_ocr/assets/catalog.json``: the Tesseract
language data the app may download, one ``<code>.traineddata`` file per
language from https://github.com/tesseract-ocr/tessdata_fast (Apache-2.0),
pinned at one commit, with the exact URL on raw.githubusercontent.com, the
byte size and the SHA-256 of every file (the app verifies each download and
each imported file against them).

Which languages: those of the app's language catalogue
(packages/translation_repository, ``LanguageCatalog``) that tessdata_fast
has data for, mapped in ``LANGUAGES`` below (app codes -> Tesseract code).
Not included: the vertical CJK variants (``*_vert``), historical scripts
and fonts (``enm``, ``frm``, ``frk``, ``ita_old``, ``spa_old``,
``kat_old``, ``deu_latf``), the math/equation model (``equ``), the
Cyrillic Azerbaijani and Uzbek variants and Syriac (no app language), and
``osd`` (orientation and script detection needs Tesseract's legacy engine,
which libmozhi_tesseract does not include).

Files are downloaded once into ``--cache`` (default
``packages/tesseract_ocr/build/tessdata_cache/<commit>/``, ignored by git
like every build/ directory): a URL that names a commit never changes, so
re-runs only download what is missing. ``--offline`` fails instead of
downloading. The output is deterministic (sorted, no timestamps), so
regenerating at the same commit is a no-op.

To move to a newer tessdata_fast: ``git ls-remote
https://github.com/tesseract-ocr/tessdata_fast HEAD``, then run this script
with ``--commit <sha>`` and update DEFAULT_COMMIT. Needs only the Python 3.9+
standard library and HTTPS access to raw.githubusercontent.com.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
import re
import sys
import tempfile
import urllib.request
from pathlib import Path

PACKAGE_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUT = PACKAGE_ROOT / "assets/catalog.json"
DEFAULT_CACHE = PACKAGE_ROOT / "build/tessdata_cache"

REPOSITORY = "https://github.com/tesseract-ocr/tessdata_fast"
# `git ls-remote https://github.com/tesseract-ocr/tessdata_fast HEAD` on
# 2026-10-17 (the repository changes rarely; its last model update is from
# 2021).
DEFAULT_COMMIT = "87416418657359cb625c412a48b6e1d6d41c29bd"
RAW_URL = "https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/{commit}/{name}"

SCHEMA_VERSION = 1
CHUNK = 1 << 20

# Tesseract code -> (English name, app language codes it reads, best first).
# App codes are those of LanguageCatalog (packages/translation_repository);
# regional variants (en-GB, pt-BR, ar-EG, ...) resolve to their base
# language (TessdataCatalog.forAppLanguage), so only base codes are listed,
# plus the explicit script of languages written in more than one (a code
# with a script subtag only matches that script: ms-Arab, Jawi, is not
# read with the Latin Malay data). A Chinese variety reads with the data of
# the script it is written in.
LANGUAGES: dict[str, tuple[str, list[str]]] = {
    "afr": ("Afrikaans", ["af"]),
    "amh": ("Amharic", ["am"]),
    "ara": ("Arabic", ["ar"]),
    "asm": ("Assamese", ["as"]),
    "aze": ("Azerbaijani", ["az", "az-Latn"]),
    "bel": ("Belarusian", ["be"]),
    "ben": ("Bengali", ["bn"]),
    "bod": ("Tibetan", ["bo"]),
    "bos": ("Bosnian", ["bs"]),
    "bre": ("Breton", ["br"]),
    "bul": ("Bulgarian", ["bg"]),
    "cat": ("Catalan", ["ca"]),
    "ceb": ("Cebuano", ["ceb"]),
    "ces": ("Czech", ["cs"]),
    "chi_sim": ("Chinese (Simplified)", ["zh-CN", "wuu"]),
    "chi_tra": ("Chinese (Traditional)", ["zh-TW", "yue", "lzh"]),
    "chr": ("Cherokee", ["chr"]),
    "cos": ("Corsican", ["co"]),
    "cym": ("Welsh", ["cy"]),
    "dan": ("Danish", ["da"]),
    "deu": ("German", ["de"]),
    "div": ("Dhivehi", ["dv"]),
    "dzo": ("Dzongkha", ["dz"]),
    "ell": ("Greek", ["el"]),
    "eng": ("English", ["en"]),
    "epo": ("Esperanto", ["eo"]),
    "est": ("Estonian", ["et"]),
    "eus": ("Basque", ["eu"]),
    "fao": ("Faroese", ["fo"]),
    "fas": ("Persian", ["fa", "fa-AF"]),
    "fil": ("Filipino", ["tl"]),
    "fin": ("Finnish", ["fi"]),
    "fra": ("French", ["fr"]),
    "fry": ("Frisian", ["fy"]),
    "gla": ("Scottish Gaelic", ["gd"]),
    "gle": ("Irish", ["ga"]),
    "glg": ("Galician", ["gl"]),
    "grc": ("Ancient Greek", ["grc"]),
    "guj": ("Gujarati", ["gu"]),
    "hat": ("Haitian Creole", ["ht"]),
    "heb": ("Hebrew", ["he"]),
    "hin": ("Hindi", ["hi"]),
    "hrv": ("Croatian", ["hr"]),
    "hun": ("Hungarian", ["hu"]),
    "hye": ("Armenian", ["hy"]),
    "iku": ("Inuktitut", ["iu"]),
    "ind": ("Indonesian", ["id"]),
    "isl": ("Icelandic", ["is"]),
    "ita": ("Italian", ["it"]),
    "jav": ("Javanese", ["jv"]),
    "jpn": ("Japanese", ["ja"]),
    "kan": ("Kannada", ["kn"]),
    "kat": ("Georgian", ["ka"]),
    "kaz": ("Kazakh", ["kk"]),
    "khm": ("Khmer", ["km"]),
    "kir": ("Kyrgyz", ["ky"]),
    "kmr": ("Kurdish (Kurmanji)", ["ku", "ku-Latn"]),
    "kor": ("Korean", ["ko"]),
    "lao": ("Lao", ["lo"]),
    "lat": ("Latin", ["la"]),
    "lav": ("Latvian", ["lv"]),
    "lit": ("Lithuanian", ["lt"]),
    "ltz": ("Luxembourgish", ["lb"]),
    "mal": ("Malayalam", ["ml"]),
    "mar": ("Marathi", ["mr"]),
    "mkd": ("Macedonian", ["mk"]),
    "mlt": ("Maltese", ["mt"]),
    "mon": ("Mongolian", ["mn"]),
    "mri": ("Maori", ["mi"]),
    "msa": ("Malay", ["ms", "ms-Latn"]),
    "mya": ("Burmese", ["my"]),
    "nep": ("Nepali", ["ne"]),
    "nld": ("Dutch", ["nl"]),
    "nor": ("Norwegian", ["no", "nn"]),
    "oci": ("Occitan", ["oc"]),
    "ori": ("Odia (Oriya)", ["or"]),
    "pan": ("Punjabi (Gurmukhi)", ["pa", "pa-Guru"]),
    "pol": ("Polish", ["pl"]),
    "por": ("Portuguese", ["pt"]),
    "pus": ("Pashto", ["ps"]),
    "que": ("Quechua", ["qu"]),
    "ron": ("Romanian", ["ro"]),
    "rus": ("Russian", ["ru"]),
    "san": ("Sanskrit", ["sa"]),
    "sin": ("Sinhala", ["si"]),
    "slk": ("Slovak", ["sk"]),
    "slv": ("Slovenian", ["sl"]),
    "snd": ("Sindhi", ["sd"]),
    "spa": ("Spanish", ["es"]),
    "sqi": ("Albanian", ["sq"]),
    "srp": ("Serbian", ["sr", "sr-Cyrl"]),
    "srp_latn": ("Serbian (Latin)", ["sr-Latn"]),
    "sun": ("Sundanese", ["su"]),
    "swa": ("Swahili", ["sw"]),
    "swe": ("Swedish", ["sv"]),
    "tam": ("Tamil", ["ta"]),
    "tat": ("Tatar", ["tt"]),
    "tel": ("Telugu", ["te"]),
    "tgk": ("Tajik", ["tg"]),
    "tha": ("Thai", ["th"]),
    "tir": ("Tigrinya", ["ti"]),
    "ton": ("Tongan", ["to"]),
    "tur": ("Turkish", ["tr"]),
    "uig": ("Uyghur", ["ug"]),
    "ukr": ("Ukrainian", ["uk"]),
    "urd": ("Urdu", ["ur"]),
    "uzb": ("Uzbek", ["uz", "uz-Latn"]),
    "vie": ("Vietnamese", ["vi"]),
    "yid": ("Yiddish", ["yi"]),
    "yor": ("Yoruba", ["yo"]),
}

CODE = re.compile(r"^[a-z]{3}(_[a-z]{3,4})?$")


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def fetch(url: str, destination: Path) -> None:
    """Downloads url to destination atomically (a temporary file, renamed)."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request(url, headers={"User-Agent": "mozhi-tessdata-catalog"})
    with urllib.request.urlopen(request, timeout=120) as response:
        if response.status != 200:
            raise RuntimeError(f"HTTP {response.status} for {url}")
        fd, temporary = tempfile.mkstemp(dir=destination.parent, prefix=".part-")
        try:
            with os.fdopen(fd, "wb") as out:
                while chunk := response.read(CHUNK):
                    out.write(chunk)
            os.replace(temporary, destination)
        except BaseException:
            os.unlink(temporary)
            raise


def describe(path: Path) -> tuple[int, str]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as f:
        while chunk := f.read(CHUNK):
            digest.update(chunk)
            size += len(chunk)
    return size, digest.hexdigest()


def is_traineddata(path: Path) -> bool:
    """A traineddata file starts with its table of contents: a little-endian
    int32 entry count, then that many int64 offsets. Rejects e.g. an HTML
    error page saved instead of the file."""
    with path.open("rb") as f:
        header = f.read(4)
    if len(header) != 4:
        return False
    count = int.from_bytes(header, "little", signed=True)
    return 0 < count < 64


def entry(code: str, commit: str, cache: Path, offline: bool) -> dict:
    name, app_languages = LANGUAGES[code]
    file_name = f"{code}.traineddata"
    url = RAW_URL.format(commit=commit, name=file_name)
    cached = cache / file_name
    if not cached.exists():
        if offline:
            raise RuntimeError(f"{file_name} is not in {cache} (--offline)")
        log(f"downloading {url}")
        fetch(url, cached)
    if not is_traineddata(cached):
        cached.unlink()
        raise RuntimeError(f"{url} is not a traineddata file")
    size, sha256 = describe(cached)
    return {
        "code": code,
        "name": name,
        "languages": app_languages,
        "url": url,
        "size": size,
        "sha256": sha256,
    }


def build(commit: str, cache: Path, jobs: int, offline: bool) -> dict:
    for code, (_, app_languages) in LANGUAGES.items():
        if not CODE.match(code):
            raise SystemExit(f"invalid Tesseract code {code!r}")
        if not app_languages:
            raise SystemExit(f"{code} has no app languages")
    owners: dict[str, str] = {}
    for code, (_, app_languages) in LANGUAGES.items():
        for app in app_languages:
            key = app.lower()
            if key in owners:
                raise SystemExit(f"{app} is mapped to {owners[key]} and {code}")
            owners[key] = code

    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        entries = list(pool.map(lambda code: entry(code, commit, cache, offline), sorted(LANGUAGES)))
    total = sum(item["size"] for item in entries)
    log(f"{len(entries)} languages, {total} bytes ({total / 1e6:.1f} MB) in total")
    return {
        "schemaVersion": SCHEMA_VERSION,
        "source": REPOSITORY,
        "commit": commit,
        "license": "Apache-2.0 (tesseract-ocr/tessdata_fast)",
        "languages": entries,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--commit", default=DEFAULT_COMMIT, help="tessdata_fast commit to pin")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--cache", type=Path, default=DEFAULT_CACHE)
    parser.add_argument("--jobs", type=int, default=6)
    parser.add_argument("--offline", action="store_true", help="never download")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.commit):
        parser.error("--commit must be a full 40-character commit hash")

    catalog = build(args.commit, args.cache / args.commit, args.jobs, args.offline)
    text = json.dumps(catalog, indent=1, ensure_ascii=False) + "\n"
    args.out.parent.mkdir(parents=True, exist_ok=True)
    if args.out.exists() and args.out.read_text(encoding="utf-8") == text:
        log(f"{args.out} is up to date")
        return 0
    args.out.write_text(text, encoding="utf-8")
    log(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
