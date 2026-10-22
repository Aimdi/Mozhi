#!/usr/bin/env python3
"""Mirrors the on-device model files of the app's catalogues into a plain
directory, for a self-hosted `/models/` (docs/self-hosting-mozhi.md).

  python3 tool/mirror_models.py OUT [filters] [--list | --verify]

  # Everything (about 3 GB): every translation direction, both Whisper
  # models and the voice activity model, every Tesseract language.
  python3 tool/mirror_models.py /srv/mozhi/models

  # German, French and Japanese only (both directions with English, and
  # their text recognition data), plus the Fast speech model.
  python3 tool/mirror_models.py /srv/mozhi/models \\
      --languages de,fr,ja --whisper tiny,silero-vad

It reads the catalogues the app ships (exactly the files it can ask for):

  bergamot   packages/bergamot_translator/assets/catalog.json (Mozilla)
  whisper    packages/whisper_speech/assets/models.json (Hugging Face)
  tesseract  packages/tesseract_ocr/assets/catalog.json (GitHub)
  dictionary lib/dictionary/data/dictionary_catalog_data.dart (the
             dictionary packs of a GitHub release; empty until the first
             one, see docs/dictionary-packs.md)
  phrasebook lib/phrasebook/data/starter_catalog_data.dart (the starter
             phrasebooks of a GitHub release; empty until the first one,
             see docs/phrasebook.md)

and writes the layout the app downloads from (`bergamotMirrorUrl`,
`whisperMirrorUrl`, `tessdataMirrorUrl`, `dictionaryPackDownloadUrls`,
`starterPhrasebookUrls` in the packages and the app), each file as
published under its original name:

  OUT/bergamot/<source>-<target>/<version>/<name>.gz
  OUT/whisper/<name>
  OUT/tesseract/<code>.traineddata
  OUT/dictionary/<id>.mzd
  OUT/phrasebooks/<id>.json.gz

Point the app at the directory's URL (Settings > Translation engines >
Model source > Custom mirror, e.g. https://example.org/models/; the web
app served from the same server finds `models/` next to itself).

Every file is checked against the catalogue's size and SHA-256 (and the
Whisper SHA-1) before it is moved into place, the same checks the app
makes, so the mirror never needs to be trusted. Interrupted downloads
resume (`<file>.part`, HTTP Range). Files already in place and verified
are skipped; a known file that does not match (an older version) is
replaced. Files the catalogues do not list are never deleted, so a mirror
can serve several app versions.

Filters (combined: a file is mirrored when its kind is selected and it
matches the filters of its kind):
  --only KINDS        bergamot,whisper,tesseract,dictionary,phrasebook
                      (default: all)
  --languages CODES   Bergamot: the directions to and from English of
                      these languages (Mozilla codes, e.g. de, zh_hant;
                      `en` alone selects nothing); Tesseract: the data
                      reading these app languages (de, zh-TW, sr-Latn; a
                      language matches its primary subtag too);
                      dictionary and phrasebook: the packs of these app
                      languages (by primary subtag: pt-BR selects pt)
  --pairs PAIRS       Bergamot directions, e.g. en-de,de-en
  --whisper IDS       Whisper model ids (tiny, base, silero-vad); the
                      models are multilingual, so --languages keeps them
  --tesseract CODES   Tesseract codes (deu, chi_sim)
  --dictionaries IDS  dictionary pack ids (es, en)
  --phrasebooks IDS   starter phrasebook ids (pt, pt-de)

Modes: --list prints the selected files and their total size without
downloading; --verify checks the files already in OUT (no network).

Exit status: 0 when every selected file is in place and verified, 1 when
one could not be downloaded or did not match, 2 for invalid arguments or
catalogues.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from http.client import HTTPException
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
BERGAMOT = REPO_ROOT / "packages/bergamot_translator/assets/catalog.json"
WHISPER = REPO_ROOT / "packages/whisper_speech/assets/models.json"
TESSERACT = REPO_ROOT / "packages/tesseract_ocr/assets/catalog.json"
DICTIONARY = REPO_ROOT / "lib/dictionary/data/dictionary_catalog_data.dart"
PHRASEBOOK = REPO_ROOT / "lib/phrasebook/data/starter_catalog_data.dart"
KINDS = ("bergamot", "whisper", "tesseract", "dictionary", "phrasebook")
USER_AGENT = "Mozhi model mirror (+https://github.com/Aimdi/Mozhi)"
ATTEMPTS = 3
RETRY_DELAY = 1.0
TIMEOUT = 60
CHUNK = 1 << 16

_SAFE_NAME = re.compile(r"^[A-Za-z0-9._-]{1,200}$")
_MODEL_LANGUAGE = re.compile(r"^[a-z]{2,3}(_[a-z]{2,8})?$")
_TESSERACT_CODE = re.compile(r"^[a-z]{3}(_[a-z]{3,4})?$")
_PACK_ID = re.compile(r"^[a-z]{2,3}(-[a-z0-9]{2,8})*$")
_HEX = re.compile(r"^[0-9a-f]+$")


class CatalogError(Exception):
    """A catalogue is not what the app would accept."""


@dataclass(frozen=True)
class MirrorFile:
    """One file of a catalogue and where it goes in the mirror."""

    kind: str
    path: str  # relative to the mirror root, with "/" separators
    url: str
    size: int
    sha256: str
    sha1: str | None = None
    label: str = ""


@dataclass
class Report:
    downloaded: list[str] = field(default_factory=list)
    skipped: list[str] = field(default_factory=list)
    failed: list[tuple[str, str]] = field(default_factory=list)


def _safe(segment: str, what: str) -> str:
    if not _SAFE_NAME.match(segment) or segment.startswith("."):
        raise CatalogError(f"unsafe {what}: {segment!r}")
    return segment


def _hex(value: object, length: int, what: str) -> str:
    if not isinstance(value, str) or len(value) != length or not _HEX.match(value):
        raise CatalogError(f"invalid {what}: {value!r}")
    return value


def _size(value: object, what: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        raise CatalogError(f"invalid size of {what}: {value!r}")
    return value


def _last_segment(url: str) -> str:
    return urllib.parse.urlsplit(url).path.rsplit("/", 1)[-1]


def bergamot_files(catalog: dict) -> list[MirrorFile]:
    """The files of the Bergamot catalogue (`bergamotMirrorUrl` layout)."""
    files = []
    for model in catalog.get("models", []):
        source, target = model.get("source"), model.get("target")
        for code in (source, target):
            if not isinstance(code, str) or not _MODEL_LANGUAGE.match(code):
                raise CatalogError(f"invalid language code: {code!r}")
        pair = f"{source}-{target}"
        version = _safe(str(model.get("version", "")), f"version of {pair}")
        for kind, entry in sorted(model.get("files", {}).items()):
            url = entry.get("url", "")
            name = _safe(_last_segment(url), f"file name of {pair} {kind}")
            files.append(
                MirrorFile(
                    kind="bergamot",
                    path=f"bergamot/{pair}/{version}/{name}",
                    url=url,
                    size=_size(entry.get("size"), name),
                    sha256=_hex(entry.get("sha256"), 64, f"SHA-256 of {name}"),
                    label=pair,
                )
            )
    return files


def whisper_files(catalog: dict) -> list[MirrorFile]:
    """The files of the Whisper catalogue (`whisperMirrorUrl` layout)."""
    files = []
    for model in catalog.get("models", []):
        name = _safe(str(model.get("name", "")), "Whisper file name")
        sha256 = model.get("sha256")
        if sha256 is None:
            raise CatalogError(f"{name} has no SHA-256 to check a mirror with")
        files.append(
            MirrorFile(
                kind="whisper",
                path=f"whisper/{name}",
                url=model.get("url", ""),
                size=_size(model.get("size"), name),
                sha256=_hex(sha256, 64, f"SHA-256 of {name}"),
                sha1=_hex(model.get("sha1"), 40, f"SHA-1 of {name}"),
                label=str(model.get("id", "")),
            )
        )
    return files


def tesseract_files(catalog: dict) -> list[MirrorFile]:
    """The files of the Tesseract catalogue (`tessdataMirrorUrl` layout)."""
    files = []
    for language in catalog.get("languages", []):
        code = language.get("code")
        if not isinstance(code, str) or not _TESSERACT_CODE.match(code):
            raise CatalogError(f"invalid Tesseract code: {code!r}")
        name = f"{code}.traineddata"
        if _last_segment(language.get("url", "")) != name:
            raise CatalogError(f"the URL of {code} must name {name}")
        files.append(
            MirrorFile(
                kind="tesseract",
                path=f"tesseract/{name}",
                url=language["url"],
                size=_size(language.get("size"), name),
                sha256=_hex(language.get("sha256"), 64, f"SHA-256 of {name}"),
                label=code,
            )
        )
    return files


def dictionary_files(catalog: dict) -> list[MirrorFile]:
    """The packs of the dictionary catalogue (`dictionaryPackDownloadUrls`
    layout: `dictionary/<id>.mzd`)."""
    files = []
    for pack in catalog.get("packs", []):
        pack_id = pack.get("id")
        if not isinstance(pack_id, str) or not _PACK_ID.match(pack_id):
            raise CatalogError(f"invalid dictionary pack id: {pack_id!r}")
        name = f"{pack_id}.mzd"
        if _last_segment(pack.get("url", "")) != name:
            raise CatalogError(f"the URL of dictionary {pack_id} must name {name}")
        files.append(
            MirrorFile(
                kind="dictionary",
                path=f"dictionary/{name}",
                url=pack["url"],
                size=_size(pack.get("size"), name),
                sha256=_hex(pack.get("sha256"), 64, f"SHA-256 of {name}"),
                label=pack_id,
            )
        )
    return files


def phrasebook_files(catalog: dict) -> list[MirrorFile]:
    """The packs of the starter phrasebook catalogue (`starterPhrasebookUrls`
    layout: `phrasebooks/<id>.json.gz`)."""
    files = []
    for pack in catalog.get("packs", []):
        pack_id = pack.get("id")
        if not isinstance(pack_id, str) or not _PACK_ID.match(pack_id):
            raise CatalogError(f"invalid phrasebook id: {pack_id!r}")
        name = f"{pack_id}.json.gz"
        if _last_segment(pack.get("url", "")) != name:
            raise CatalogError(f"the URL of phrasebook {pack_id} must name {name}")
        files.append(
            MirrorFile(
                kind="phrasebook",
                path=f"phrasebooks/{name}",
                url=pack["url"],
                size=_size(pack.get("size"), name),
                sha256=_hex(pack.get("sha256"), 64, f"SHA-256 of {name}"),
                label=pack_id,
            )
        )
    return files


def read_dictionary_catalog(path: Path) -> dict:
    """The dictionary (or starter phrasebook) catalogue: the JSON file
    itself, or the Dart file the app bundles it in (`... = '''...'''`,
    with `\\` and `\\$` escaped, written by tool/dictionary_packs.py and
    tool/phrasebooks.py)."""
    text = path.read_text(encoding="utf-8")
    if path.suffix != ".dart":
        return json.loads(text)
    parts = text.split("'''")
    if len(parts) < 3:
        raise ValueError("no catalogue string")
    return json.loads(re.sub(r"\\(.)", r"\1", parts[1], flags=re.S))


def _codes(text: str | None) -> set[str] | None:
    if text is None:
        return None
    return {code.strip() for code in text.split(",") if code.strip()}


def _app_key(code: str) -> str:
    return code.strip().replace("_", "-").lower()


def select(args: argparse.Namespace, catalogs: dict[str, dict]) -> list[MirrorFile]:
    """The files the filters in [args] select from [catalogs]."""
    kinds = _codes(args.only) or set(KINDS)
    unknown = kinds - set(KINDS)
    if unknown:
        raise CatalogError(f"unknown kind(s): {', '.join(sorted(unknown))}")
    languages = _codes(args.languages)
    pairs = _codes(args.pairs)
    whisper = _codes(args.whisper)
    tesseract = _codes(args.tesseract)
    selected: list[MirrorFile] = []

    if "bergamot" in kinds:
        wanted = {code.replace("-", "_").lower() for code in languages or ()}
        for model in catalogs["bergamot"].get("models", []):
            pair = f"{model.get('source')}-{model.get('target')}"
            if pairs is not None or languages is not None:
                by_pair = pairs is not None and pair in pairs
                codes = {model.get("source"), model.get("target")} - {"en"}
                by_language = bool(codes & wanted)
                if not (by_pair or by_language):
                    continue
            selected += bergamot_files({"models": [model]})

    if "whisper" in kinds:
        for model in catalogs["whisper"].get("models", []):
            if whisper is not None and model.get("id") not in whisper:
                continue
            selected += whisper_files({"models": [model]})

    if "tesseract" in kinds:
        app = {_app_key(code) for code in languages or ()}
        for language in catalogs["tesseract"].get("languages", []):
            if tesseract is not None or languages is not None:
                by_code = tesseract is not None and language.get("code") in tesseract
                reads = {_app_key(code) for code in language.get("languages", [])}
                primaries = {code.split("-")[0] for code in reads}
                by_language = bool(app & reads) or bool(
                    {code for code in app if "-" not in code} & primaries
                )
                if not (by_code or (languages is not None and by_language)):
                    continue
            selected += tesseract_files({"languages": [language]})

    if "dictionary" in kinds:
        dictionaries = _codes(args.dictionaries)
        app = {_app_key(code).split("-")[0] for code in languages or ()}
        for pack in catalogs["dictionary"].get("packs", []):
            if dictionaries is not None or languages is not None:
                by_id = dictionaries is not None and pack.get("id") in dictionaries
                primary = _app_key(str(pack.get("language", ""))).split("-")[0]
                if not (by_id or primary in app):
                    continue
            selected += dictionary_files({"packs": [pack]})

    if "phrasebook" in kinds:
        phrasebooks = _codes(args.phrasebooks)
        app = {_app_key(code).split("-")[0] for code in languages or ()}
        for pack in catalogs["phrasebook"].get("packs", []):
            if phrasebooks is not None or languages is not None:
                by_id = phrasebooks is not None and pack.get("id") in phrasebooks
                primary = _app_key(str(pack.get("language", ""))).split("-")[0]
                if not (by_id or primary in app):
                    continue
            selected += phrasebook_files({"packs": [pack]})

    paths = [file.path for file in selected]
    if len(paths) != len(set(paths)):
        raise CatalogError("two catalogue files map to the same mirror path")
    return selected


def _fingerprint(path: Path, with_sha1: bool) -> tuple[int, str, str | None]:
    sha256 = hashlib.sha256()
    sha1 = hashlib.sha1() if with_sha1 else None
    size = 0
    with path.open("rb") as handle:
        while chunk := handle.read(CHUNK):
            size += len(chunk)
            sha256.update(chunk)
            if sha1:
                sha1.update(chunk)
    return size, sha256.hexdigest(), sha1.hexdigest() if sha1 else None


def matches(path: Path, file: MirrorFile) -> bool:
    """Whether [path] is [file]: its size and checksums."""
    try:
        if path.stat().st_size != file.size:
            return False
        size, sha256, sha1 = _fingerprint(path, file.sha1 is not None)
    except OSError:
        return False
    return size == file.size and sha256 == file.sha256 and sha1 == file.sha1


def _target(root: Path, file: MirrorFile) -> Path:
    target = root.joinpath(*file.path.split("/"))
    # The names were checked; this guards the layout itself.
    if root.resolve() not in target.resolve().parents:
        raise CatalogError(f"{file.path} is outside the mirror")
    return target


def download(root: Path, file: MirrorFile, log=print) -> str:
    """Puts [file] in place under [root]: "skipped" when it already is,
    "downloaded" otherwise. Raises OSError / ValueError when it could not be
    downloaded or did not match (the partial file is kept for resuming
    after a broken connection, discarded after a mismatch)."""
    target = _target(root, file)
    if matches(target, file):
        return "skipped"
    target.parent.mkdir(parents=True, exist_ok=True)
    part = target.with_name(target.name + ".part")
    last_error: Exception | None = None
    for attempt in range(ATTEMPTS):
        try:
            _fetch(file, part)
            break
        except ValueError:
            # More bytes than the catalogue says: not the file.
            part.unlink(missing_ok=True)
            raise
        except (OSError, HTTPException) as error:
            if isinstance(error, urllib.error.HTTPError) and error.code < 500:
                raise
            last_error = error
            if attempt + 1 < ATTEMPTS:
                log(f"  retrying {file.path}: {error!r}")
                time.sleep(RETRY_DELAY * 2**attempt)
    else:
        raise OSError(f"{file.url}: {last_error!r}")
    if not matches(part, file):
        size, sha256, _ = _fingerprint(part, False)
        part.unlink(missing_ok=True)
        raise ValueError(
            f"got {size} bytes with SHA-256 {sha256}, expected {file.size} "
            f"bytes with SHA-256 {file.sha256}"
        )
    os.replace(part, target)
    return "downloaded"


def _fetch(file: MirrorFile, part: Path) -> None:
    """Downloads [file] into [part], resuming what is already there."""
    existing = part.stat().st_size if part.exists() else 0
    if existing > file.size:
        part.unlink()
        existing = 0
    if existing == file.size:
        return
    headers = {"User-Agent": USER_AGENT}
    if existing:
        headers["Range"] = f"bytes={existing}-"
    request = urllib.request.Request(file.url, headers=headers)
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        resumed = existing > 0 and response.status == 206
        received = existing if resumed else 0
        with part.open("ab" if resumed else "wb") as out:
            while chunk := response.read(CHUNK):
                received += len(chunk)
                if received > file.size:
                    raise ValueError(f"more than {file.size} bytes")
                out.write(chunk)
    if received < file.size:
        # A connection closed early: keep the part and resume it.
        raise ConnectionError(f"connection closed after {received} bytes")


def human(size: float) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if size < 1000 or unit == "GB":
            return f"{size:.0f} {unit}" if unit == "B" else f"{size:.1f} {unit}"
        size /= 1000
    return f"{size:.1f} GB"  # pragma: no cover


def load_catalogs(args: argparse.Namespace) -> dict[str, dict]:
    catalogs = {}
    for kind, path in (
        ("bergamot", args.bergamot_catalog),
        ("whisper", args.whisper_catalog),
        ("tesseract", args.tesseract_catalog),
    ):
        try:
            catalogs[kind] = json.loads(Path(path).read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            raise CatalogError(f"cannot read {path}: {error}") from error
    for kind, path in (
        ("dictionary", args.dictionary_catalog),
        ("phrasebook", args.phrasebook_catalog),
    ):
        try:
            catalogs[kind] = read_dictionary_catalog(Path(path))
        except (OSError, ValueError) as error:
            raise CatalogError(f"cannot read {path}: {error}") from error
    return catalogs


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description="Mirror the app's on-device model files (see the module "
        "docstring).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    result.add_argument("out", type=Path, help="the mirror directory")
    result.add_argument(
        "--only", help="kinds: bergamot,whisper,tesseract,dictionary,phrasebook"
    )
    result.add_argument("--languages", help="language codes, e.g. de,fr,ja")
    result.add_argument("--pairs", help="Bergamot directions, e.g. en-de,de-en")
    result.add_argument("--whisper", help="Whisper ids, e.g. tiny,silero-vad")
    result.add_argument("--tesseract", help="Tesseract codes, e.g. deu,chi_sim")
    result.add_argument("--dictionaries", help="dictionary pack ids, e.g. es,en")
    result.add_argument("--phrasebooks", help="phrasebook ids, e.g. pt,pt-de")
    mode = result.add_mutually_exclusive_group()
    mode.add_argument("--list", action="store_true", help="only list the files")
    mode.add_argument(
        "--verify", action="store_true", help="only check the files in OUT"
    )
    result.add_argument("--jobs", type=int, default=4, help="parallel downloads")
    result.add_argument("--bergamot-catalog", default=str(BERGAMOT))
    result.add_argument("--whisper-catalog", default=str(WHISPER))
    result.add_argument("--tesseract-catalog", default=str(TESSERACT))
    result.add_argument(
        "--dictionary-catalog",
        default=str(DICTIONARY),
        help="dictionary_catalog.json or the app's Dart file",
    )
    result.add_argument(
        "--phrasebook-catalog",
        default=str(PHRASEBOOK),
        help="phrasebook_catalog.json or the app's Dart file",
    )
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        files = select(args, load_catalogs(args))
    except CatalogError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    total = sum(file.size for file in files)
    root: Path = args.out
    print(f"{len(files)} file(s), {human(total)}")

    if args.list:
        for file in files:
            print(f"{file.path}\t{file.size}\t{file.url}")
        return 0

    if args.verify:
        bad = [file for file in files if not matches(_target(root, file), file)]
        for file in bad:
            state = "damaged" if _target(root, file).exists() else "missing"
            print(f"  {state}: {file.path}")
        print("all verified" if not bad else f"{len(bad)} file(s) not in place")
        return 1 if bad else 0

    root.mkdir(parents=True, exist_ok=True)
    report = Report()

    def run(file: MirrorFile) -> None:
        try:
            outcome = download(root, file)
        except (OSError, ValueError, HTTPException) as error:
            report.failed.append((file.path, str(error)))
            print(f"  FAILED {file.path}: {error}")
            return
        if outcome == "skipped":
            report.skipped.append(file.path)
        else:
            report.downloaded.append(file.path)
            print(f"  {file.path} ({human(file.size)})")

    with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        list(pool.map(run, files))
    print(
        f"{len(report.downloaded)} downloaded, {len(report.skipped)} already "
        f"in place, {len(report.failed)} failed"
    )
    return 1 if report.failed else 0


if __name__ == "__main__":
    sys.exit(main())
