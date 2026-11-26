#!/usr/bin/env python3
"""Checks that the downloadable data of the on-device engines is still
served as the bundled catalogues describe it (CI job "Check model
downloads"; needs the network).

  python3 tool/check_model_downloads.py [--only whisper|tessdata|bergamot|llm]
  python3 tool/check_model_downloads.py --mirror https://example.org/models/ [--only ...] [--all-catalog]

For every file it asks the server for the size (HEAD, following redirects;
nothing is downloaded) and compares it with the catalogue, because the app
rejects a download whose size or checksum differs:

  whisper   packages/whisper_speech/assets/models.json (Hugging Face; its
            first answer also carries the file's SHA-256, compared with the
            catalogue's `sha256`)
  tessdata  packages/tesseract_ocr/assets/catalog.json
            (raw.githubusercontent.com, pinned commit)
  bergamot  packages/bergamot_translator/assets/catalog.json (the offline
            languages: Firefox Translations on Mozilla's Google Cloud
            Storage bucket; every file of every language pair)
  llm       packages/llama_engine/assets/models.json (Hugging Face, pinned
            commit; GGUF and optional mmproj vision projector files)

With `--mirror URL`, checks a self-hosted mirror built by `tool/mirror_models.py`:
by default it reads `<URL>/<folder>/index.json` for each selected kind and checks
every advertised item's files (since mirrors often host a subset of languages);
with `--all-catalog` it checks every file of the selected catalogues directly
against the mirror layout.

The checksums themselves are not re-checked here: the Whisper SHA-1s come
from whisper.cpp's pinned models/README.md, the tessdata SHA-256s from the
files at the pinned commit (packages/tesseract_ocr/tool/tessdata_catalog.py).

Exit status: 0 when every size matches, 1 when one differs or a file is
missing, 2 when a server could not be reached (after retries).
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
WHISPER = REPO_ROOT / "packages/whisper_speech/assets/models.json"
TESSDATA = REPO_ROOT / "packages/tesseract_ocr/assets/catalog.json"
BERGAMOT = REPO_ROOT / "packages/bergamot_translator/assets/catalog.json"
LLM = REPO_ROOT / "packages/llama_engine/assets/models.json"
USER_AGENT = "Mozhi model check (+https://github.com/Aimdi/Mozhi)"
ATTEMPTS = 3

MIRROR_FOLDERS = {
    "whisper": "whisper",
    "tessdata": "tesseract",
    "bergamot": "bergamot",
    "llm": "llm",
}

MIRROR_INDEX_KINDS = {
    "whisper": "whisper",
    "tessdata": "tesseract",
    "bergamot": "bergamot",
    "llm": "llm",
}


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):  # noqa: D102
        return None


def head(url: str) -> tuple[int | None, dict[str, str]]:
    """The final size (Content-Length after redirects) of [url] and the
    headers of the first answer (Hugging Face puts X-Linked-* there)."""
    request = urllib.request.Request(
        url, method="HEAD", headers={"User-Agent": USER_AGENT}
    )
    first: dict[str, str] = {}
    try:
        with urllib.request.build_opener(_NoRedirect).open(request, timeout=30) as r:
            first = {k.lower(): v for k, v in r.headers.items()}
    except urllib.error.HTTPError as error:
        if error.code not in (301, 302, 303, 307, 308):
            raise
        first = {k.lower(): v for k, v in error.headers.items()}
    with urllib.request.urlopen(request, timeout=30) as response:
        length = response.headers.get("Content-Length")
    return (int(length) if length is not None else None), first


def check(
    name: str, url: str, size: int, sha256: str | None = None
) -> tuple[str, str]:
    """("ok" | "mismatch" | "unreachable", message) for one file."""
    last_error = ""
    for attempt in range(ATTEMPTS):
        try:
            served, first = head(url)
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return "mismatch", f"{name}: missing (404) at {url}"
            last_error = f"HTTP {error.code}"
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            last_error = str(error)
        else:
            extra = ""
            served_sha256 = first.get("x-linked-etag", "").strip('"') or None
            if served_sha256:
                extra = f" (sha256 {served_sha256})"
            if sha256 and served_sha256 and served_sha256 != sha256:
                return "mismatch", (
                    f"{name}: the catalogue says sha256 {sha256}, the "
                    f"server {served_sha256} ({url})"
                )
            if served is None:
                linked = first.get("x-linked-size")
                served = int(linked) if linked else None
            if served == size:
                return "ok", f"{name}: {size} bytes{extra}"
            return "mismatch", (
                f"{name}: the catalogue says {size} bytes, the server "
                f"{served} ({url})"
            )
        time.sleep(2 * (attempt + 1))
    return "unreachable", f"{name}: {last_error} ({url})"


def _last_segment(url: str) -> str:
    return urllib.parse.urlsplit(url).path.rsplit("/", 1)[-1]


def _mirror_url(mirror: str, relative_path: str) -> str:
    base = mirror.rstrip("/") + "/"
    return urllib.parse.urljoin(base, relative_path.lstrip("/"))


def fetch_json(url: str) -> tuple[str, dict | str]:
    """Fetches and parses JSON from [url]. Returns ('ok', data) | ('missing'|'mismatch'|'unreachable', message)."""
    request = urllib.request.Request(
        url, method="GET", headers={"User-Agent": USER_AGENT}
    )
    last_error = ""
    for attempt in range(ATTEMPTS):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                body = response.read().decode("utf-8")
            data = json.loads(body)
            if not isinstance(data, dict):
                return "mismatch", f"{url}: expected JSON object"
            return "ok", data
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return "missing", f"{url}: missing (404)"
            last_error = f"HTTP {error.code}"
        except (json.JSONDecodeError, UnicodeDecodeError) as error:
            return "mismatch", f"{url}: invalid JSON ({error})"
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            last_error = str(error)
        time.sleep(2 * (attempt + 1))
    return "unreachable", f"{url}: {last_error}"


def _catalog_items(kind: str) -> dict[str, list[tuple[str, str, str, int, str | None]]]:
    """Returns item_id -> list of (label, upstream_url, mirror_rel_path, size, sha256)."""
    items: dict[str, list[tuple[str, str, str, int, str | None]]] = {}
    if kind == "whisper":
        catalog = json.loads(WHISPER.read_text(encoding="utf-8"))
        for model in catalog["models"]:
            item_id = str(model.get("id", model["name"]))
            items.setdefault(item_id, []).append(
                (
                    f"whisper/{model['name']}",
                    model["url"],
                    f"whisper/{model['name']}",
                    int(model["size"]),
                    model.get("sha256"),
                )
            )
    elif kind == "tessdata":
        catalog = json.loads(TESSDATA.read_text(encoding="utf-8"))
        for language in catalog["languages"]:
            code = language["code"]
            items.setdefault(code, []).append(
                (
                    f"tessdata/{code}",
                    language["url"],
                    f"tesseract/{code}.traineddata",
                    int(language["size"]),
                    None,
                )
            )
    elif kind == "bergamot":
        catalog = json.loads(BERGAMOT.read_text(encoding="utf-8"))
        for model in catalog["models"]:
            pair = f"{model['source']}-{model['target']}"
            version = str(model.get("version", ""))
            for file_kind, file in sorted(model["files"].items()):
                name = _last_segment(file["url"])
                items.setdefault(pair, []).append(
                    (
                        f"bergamot/{pair}/{file_kind}",
                        file["url"],
                        f"bergamot/{pair}/{version}/{name}",
                        int(file["size"]),
                        None,
                    )
                )
    elif kind == "llm":
        catalog = json.loads(LLM.read_text(encoding="utf-8"))
        for model in catalog["models"]:
            item_id = str(model["id"])
            items.setdefault(item_id, []).append(
                (
                    f"llm/{model['name']}",
                    model["url"],
                    f"llm/{model['name']}",
                    int(model["size"]),
                    model.get("sha256"),
                )
            )
            mmproj = model.get("mmproj")
            if isinstance(mmproj, dict):
                items[item_id].append(
                    (
                        f"llm/{mmproj['name']}",
                        mmproj["url"],
                        f"llm/{mmproj['name']}",
                        int(mmproj["size"]),
                        mmproj.get("sha256"),
                    )
                )
    return items


def entries(
    only: str | None,
    *,
    mirror: str | None = None,
    all_catalog: bool = False,
) -> tuple[list[tuple[str, str, int, str | None]], list[tuple[str, str]]]:
    """Returns (files_to_check, pre_errors) where pre_errors are (status, msg)."""
    kinds = [only] if only else ["whisper", "tessdata", "bergamot", "llm"]
    found: list[tuple[str, str, int, str | None]] = []
    errors: list[tuple[str, str]] = []

    for kind in kinds:
        by_item = _catalog_items(kind)
        if mirror is None:
            for item_files in by_item.values():
                for label, upstream_url, _, size, sha256 in item_files:
                    found.append((label, upstream_url, size, sha256))
            continue

        if all_catalog:
            for item_files in by_item.values():
                for label, _, rel_path, size, _ in item_files:
                    found.append((label, _mirror_url(mirror, rel_path), size, None))
            continue

        index_url = _mirror_url(mirror, f"{MIRROR_FOLDERS[kind]}/index.json")
        status, payload = fetch_json(index_url)
        if status == "missing":
            # A partial mirror may simply not host this kind; only fail if explicitly requested.
            if only is not None:
                errors.append(("mismatch", f"{kind}/index.json: missing (404) at {index_url}"))
            continue
        if status != "ok":
            errors.append((status, str(payload)))
            continue
        assert isinstance(payload, dict)
        schema = payload.get("schemaVersion")
        expected_kind = MIRROR_INDEX_KINDS[kind]
        index_kind = payload.get("kind")
        advertised = payload.get("items")
        if schema != 1 or index_kind != expected_kind or not isinstance(advertised, list):
            errors.append(
                (
                    "mismatch",
                    f"{kind}/index.json: unexpected schema/kind/items at {index_url}",
                )
            )
            continue
        for item_id in advertised:
            if not isinstance(item_id, str) or item_id not in by_item:
                errors.append(
                    (
                        "mismatch",
                        f"{kind}/index.json: unknown catalogue item {item_id!r}",
                    )
                )
                continue
            for label, _, rel_path, size, _ in by_item[item_id]:
                found.append((label, _mirror_url(mirror, rel_path), size, None))

    return found, errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument(
        "--only", choices=["whisper", "tessdata", "bergamot", "llm"]
    )
    parser.add_argument(
        "--mirror",
        help="Base URL of a self-hosted mirror (e.g. https://example.org/models/)",
    )
    parser.add_argument(
        "--all-catalog",
        action="store_true",
        help="With --mirror, check every catalogue file instead of only items listed in index.json",
    )
    args = parser.parse_args(argv)

    files, pre_errors = entries(
        args.only, mirror=args.mirror, all_catalog=args.all_catalog
    )
    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda f: check(*f), files))
    results = pre_errors + results
    counts = {"ok": 0, "mismatch": 0, "unreachable": 0}
    for status, message in results:
        counts[status] += 1
        if status != "ok" or message.startswith(("whisper/", "llm/")):
            print(f"{status.upper():12} {message}")
    total = len(results)
    print(
        f"{counts['ok']} of {total} sizes match, "
        f"{counts['mismatch']} differ, {counts['unreachable']} unreachable"
    )
    if counts["mismatch"]:
        return 1
    return 2 if counts["unreachable"] else 0


if __name__ == "__main__":
    sys.exit(main())
