#!/usr/bin/env python3
"""Builds the Bergamot offline-model catalog from Mozilla's model registry.

Usage:
    python3 tool/offline_catalog.py [--registry URL_OR_PATH] [--out PATH]
                                    [--cache PATH] [--jobs N] [--offline]

Reads Mozilla's Firefox Translations registry (``db/models.json`` in the
``moz-fx-translations-data--303e-prod-translations-data`` GCS bucket) and
writes ``packages/bergamot_translator/assets/catalog.json``, the list of
models the app may download, with exact URLs, byte sizes and SHA-256
checksums of every file.

Selection (one model per direction):
  * only models Mozilla ships in Firefox: ``releaseStatus`` "Release
    Android" (preferred: the mobile-sized model Firefox for Android uses) or
    "Release"; "Release Desktop" (larger desktop-only models), "Nightly" and
    unreleased (null) entries are skipped;
  * every file needs a path; anything else is reported and skipped.

Checksums: the registry only records the *uncompressed* SHA-256 and size of
the model file. The app verifies each download *before* gunzipping it, so
this script streams every file once (gzip bytes -> SHA-256 and size of the
download, gunzipped bytes -> SHA-256 and size of the installed file) and
cross-checks the registry's model hash and the server's MD5 (x-goog-hash).
Results are cached by URL in ``--cache`` (default
``packages/bergamot_translator/build/offline_catalog_cache.json``, ignored
by git like every build/ directory): registry paths contain a
unique training-run id, so a URL's content never changes and re-runs only
download new models. ``--offline`` fails instead of downloading.

The output is deterministic (sorted, no timestamps except the registry's
own ``generated``), so regenerating without registry changes is a no-op.
Needs only the Python 3.9+ standard library and HTTPS access to
storage.googleapis.com.
"""

from __future__ import annotations

import argparse
import base64
import concurrent.futures
import hashlib
import json
import os
import sys
import tempfile
import threading
import urllib.request
import zlib
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_REGISTRY = (
    "https://storage.googleapis.com/"
    "moz-fx-translations-data--303e-prod-translations-data/db/models.json"
)
DEFAULT_OUT = REPO_ROOT / "packages/bergamot_translator/assets/catalog.json"
DEFAULT_CACHE = REPO_ROOT / "packages/bergamot_translator/build/offline_catalog_cache.json"

SCHEMA_VERSION = 1
# Preferred first.
RELEASE_STATUSES = ("Release Android", "Release")
# Registry file kinds -> catalog file kinds (and what the app expects).
FILE_KINDS = {
    "model": "model",
    "lexicalShortlist": "lexicalShortlist",
    "vocab": "vocab",
    "srcVocab": "srcVocab",
    "trgVocab": "trgVocab",
}
CHUNK = 1 << 20


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def read_registry(source: str) -> dict:
    if source.startswith(("https://", "http://")):
        with urllib.request.urlopen(source, timeout=60) as response:
            return json.load(response)
    with open(source, encoding="utf-8") as handle:
        return json.load(handle)


def select_models(registry: dict) -> tuple[list[dict], list[str]]:
    """Returns (selected registry entries, human-readable skip notes)."""
    selected, notes = [], []
    for pair, entries in sorted(registry["models"].items()):
        by_status = {}
        for entry in entries:
            by_status.setdefault(entry.get("releaseStatus"), entry)
        chosen = next(
            (by_status[s] for s in RELEASE_STATUSES if s in by_status), None
        )
        if chosen is None:
            statuses = sorted(str(e.get("releaseStatus")) for e in entries)
            notes.append(f"{pair}: not released ({', '.join(statuses)})")
            continue
        files = chosen.get("files", {})
        has_vocab = "vocab" in files or {"srcVocab", "trgVocab"} <= set(files)
        if "model" not in files or "lexicalShortlist" not in files or not has_vocab:
            notes.append(f"{pair}: incomplete file list {sorted(files)}")
            continue
        unknown = set(files) - set(FILE_KINDS)
        if unknown:
            notes.append(f"{pair}: unknown file kinds {sorted(unknown)}")
            continue
        selected.append(chosen)
    return selected, notes


def run_id(entry: dict) -> str:
    """The training-run directory of the model: models/<pair>/<run>/..."""
    parts = entry["files"]["model"]["path"].split("/")
    if len(parts) < 4 or parts[0] != "models":
        raise ValueError(f"unexpected model path {entry['files']['model']['path']}")
    return parts[2]


class Cache:
    def __init__(self, path: Path):
        self.path = path
        self.lock = threading.Lock()
        try:
            self.data = json.loads(path.read_text(encoding="utf-8"))
        except (FileNotFoundError, ValueError):
            self.data = {}

    def get(self, url: str) -> dict | None:
        with self.lock:
            return self.data.get(url)

    def put(self, url: str, value: dict) -> None:
        with self.lock:
            self.data[url] = value
            self._save()

    def _save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=self.path.parent, prefix=".catalog-cache-")
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(self.data, handle, indent=1, sort_keys=True)
        os.replace(tmp, self.path)


def measure(url: str) -> dict:
    """Streams url once; returns sizes and SHA-256 of gzip and gunzipped."""
    request = urllib.request.Request(url, headers={"Accept-Encoding": "identity"})
    with urllib.request.urlopen(request, timeout=120) as response:
        md5_expected = None
        for part in response.headers.get_all("x-goog-hash") or []:
            for item in part.split(","):
                key, _, value = item.strip().partition("=")
                if key == "md5":
                    md5_expected = base64.b64decode(value + "=" * (-len(value) % 4)).hex()
        length = response.headers.get("Content-Length")
        sha, md5, raw_sha = hashlib.sha256(), hashlib.md5(), hashlib.sha256()
        size = raw_size = 0
        inflater = zlib.decompressobj(16 + zlib.MAX_WBITS)
        while True:
            chunk = response.read(CHUNK)
            if not chunk:
                break
            size += len(chunk)
            sha.update(chunk)
            md5.update(chunk)
            data = inflater.decompress(chunk)
            raw_size += len(data)
            raw_sha.update(data)
        tail = inflater.flush()
        raw_size += len(tail)
        raw_sha.update(tail)
        if not inflater.eof:
            raise ValueError(f"{url}: truncated gzip stream")
    if length is not None and int(length) != size:
        raise ValueError(f"{url}: got {size} bytes, Content-Length {length}")
    if md5_expected is not None and md5_expected != md5.hexdigest():
        raise ValueError(f"{url}: MD5 mismatch with x-goog-hash")
    return {
        "size": size,
        "sha256": sha.hexdigest(),
        "uncompressedSize": raw_size,
        "uncompressedSha256": raw_sha.hexdigest(),
    }


def describe_file(base_url: str, kind: str, info: dict, cache: Cache, offline: bool) -> dict:
    url = f"{base_url}/{info['path']}"
    measured = cache.get(url)
    if measured is None:
        if offline:
            raise RuntimeError(f"{url} is not cached and --offline was given")
        log(f"  downloading {url}")
        measured = measure(url)
        cache.put(url, measured)
    expected_hash = info.get("uncompressedHash")
    if expected_hash and expected_hash != measured["uncompressedSha256"]:
        raise ValueError(f"{url}: uncompressed SHA-256 differs from the registry")
    expected_size = info.get("uncompressedSize")
    if expected_size and expected_size != measured["uncompressedSize"]:
        raise ValueError(f"{url}: uncompressed size differs from the registry")
    name = info["path"].rsplit("/", 1)[-1]
    if not name.endswith(".gz"):
        raise ValueError(f"{url}: expected a .gz file")
    # Fixed key order: fresh and cached measurements serialise identically.
    return {
        "name": name[: -len(".gz")],
        "url": url,
        "size": measured["size"],
        "sha256": measured["sha256"],
        "uncompressedSize": measured["uncompressedSize"],
        "uncompressedSha256": measured["uncompressedSha256"],
    }


def build(registry: dict, cache: Cache, jobs: int, offline: bool, source: str) -> dict:
    base_url = registry["baseUrl"].rstrip("/")
    selected, notes = select_models(registry)
    for note in notes:
        log(f"skip {note}")

    tasks = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        for entry in selected:
            for kind, info in entry["files"].items():
                key = (entry["sourceLanguage"], entry["targetLanguage"], kind)
                tasks[key] = pool.submit(
                    describe_file, base_url, FILE_KINDS[kind], info, cache, offline
                )
        files = {key: future.result() for key, future in tasks.items()}

    models = []
    for entry in selected:
        source_lang, target_lang = entry["sourceLanguage"], entry["targetLanguage"]
        model_files = {
            FILE_KINDS[kind]: files[(source_lang, target_lang, kind)]
            for kind in sorted(entry["files"])
        }
        models.append(
            {
                "source": source_lang,
                "target": target_lang,
                "version": run_id(entry),
                "architecture": entry.get("architecture"),
                "releaseStatus": entry.get("releaseStatus"),
                "files": model_files,
            }
        )
    models.sort(key=lambda m: (m["source"], m["target"]))
    return {
        "schemaVersion": SCHEMA_VERSION,
        # A local copy (--registry path) is recorded as the public URL.
        "registry": source if source.startswith("https://") else DEFAULT_REGISTRY,
        "registryGenerated": registry.get("generated"),
        "license": "Models: Mozilla Public License 2.0 (Firefox Translations)",
        "models": models,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--registry", default=DEFAULT_REGISTRY)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--cache", type=Path, default=DEFAULT_CACHE)
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()

    registry = read_registry(args.registry)
    catalog = build(registry, Cache(args.cache), args.jobs, args.offline, args.registry)
    text = json.dumps(catalog, indent=1, ensure_ascii=False) + "\n"
    args.out.parent.mkdir(parents=True, exist_ok=True)
    if args.out.exists() and args.out.read_text(encoding="utf-8") == text:
        log(f"{args.out} is up to date ({len(catalog['models'])} models)")
        return 0
    args.out.write_text(text, encoding="utf-8")
    total = sum(f["size"] for m in catalog["models"] for f in m["files"].values())
    log(f"wrote {args.out}: {len(catalog['models'])} models, {total / 1e9:.2f} GB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
