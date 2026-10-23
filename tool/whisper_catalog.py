#!/usr/bin/env python3
"""Resolves the quantized Whisper models for the voice input catalogue
(packages/whisper_speech/assets/models.json) from Hugging Face.

  python3 tool/whisper_catalog.py resolve [--print | --write] [--only IDS]

The quantized files (whisper.cpp's `quantize` of OpenAI's weights,
published next to the F16 ones in https://huggingface.co/ggerganov/whisper.cpp)
are listed in SOURCES below. For each one this script

  1. pins the repository's current commit (`/api/models/<repo>/revision/main`),
  2. reads the file's size and SHA-256 from the commit's tree
     (`/api/models/<repo>/tree/<commit>`, the Git LFS `oid` and `size`),
  3. downloads the file (`/<repo>/resolve/<commit>/<file>`) and checks that
     size and SHA-256, computing the SHA-1 the catalogue also needs (the
     app checks both; Hugging Face publishes no SHA-1 of LFS files, and
     whisper.cpp's models/README.md only lists some, compared when known),

and prints the catalogue entries (`--print`, the default: the CI job "Check
model downloads" runs it, since only CI reaches Hugging Face) or merges them
into the catalogue (`--write`; entries in ORDER, the existing ones kept).
Nothing is invented: every number comes from Hugging Face or the file.

`minRamMb` (the app offers a model for download only on devices with at
least that much RAM, `WhisperCatalogModel.fitsMemory`) is ours: small needs
about 0.6 GB while it runs (4 GB phones), large-v3-turbo about 1 GB and a
fast CPU (8 GB flagships).

Exit status: 0 when every entry resolved, 1 when a file is missing or does
not match, 2 when Hugging Face could not be reached (after retries). Needs
only the Python 3.9+ standard library and HTTPS access to huggingface.co.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CATALOG = REPO_ROOT / "packages/whisper_speech/assets/models.json"
HUGGING_FACE = "https://huggingface.co"
REPOSITORY = "ggerganov/whisper.cpp"
REVISION = "main"
USER_AGENT = "Mozhi catalogue resolver (+https://github.com/Aimdi/Mozhi)"
ATTEMPTS = 3
RETRY_DELAY = 2.0
CHUNK = 1 << 20

# The quantized models, fastest first. `readmeSha1`: the SHA-1 in
# whisper.cpp v1.9.5's models/README.md ("Available models"), when listed.
SOURCES: list[dict] = [
    {
        "id": "base-q5_1",
        "file": "ggml-base-q5_1.bin",
        "multilingual": True,
        "parameters": 74000000,
    },
    {
        "id": "small-q5_1",
        "file": "ggml-small-q5_1.bin",
        "multilingual": True,
        "parameters": 244000000,
        "minRamMb": 3000,
    },
    {
        "id": "large-v3-turbo-q5_0",
        "file": "ggml-large-v3-turbo-q5_0.bin",
        "multilingual": True,
        "parameters": 809000000,
        "minRamMb": 7000,
        "readmeSha1": "e050f7970618a659205450ad97eb95a18d69c9ee",
    },
]

# Speech models in catalogue order (fastest first, most accurate last: the
# app uses the last installed one by default); others keep their places
# after these, the voice activity model last.
ORDER = ["tiny", "base-q5_1", "base", "small-q5_1", "large-v3-turbo-q5_0"]

PROVENANCE = (
    "Quantized models ({ids}): whisper.cpp's quantization of the same "
    "OpenAI weights (q5_1, q5_0), published in the same repository; url "
    "pinned to commit {commit}, size and sha256 from Hugging Face's API (the "
    "Git LFS object) and checked against the downloaded file, sha1 computed "
    "from it (tool/whisper_catalog.py resolve, in the CI job 'Check model "
    "downloads'; whisper.cpp's models/README.md SHA-1 compared where "
    "listed). minRamMb: the RAM below which the app does not offer the "
    "model (small: 4 GB phones, large-v3-turbo: 8 GB)."
)


class ResolveError(Exception):
    """A file is missing or does not match (exit status 1)."""


class Unreachable(Exception):
    """Hugging Face could not be reached (exit status 2)."""


def _open(url: str, timeout: float = 60):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    return urllib.request.urlopen(request, timeout=timeout)


def _retrying(what: str, action):
    """[action]() with retries on network and server errors; a 404 is a
    missing file (ResolveError)."""
    last = ""
    for attempt in range(ATTEMPTS):
        try:
            return action()
        except urllib.error.HTTPError as error:
            if error.code == 404:
                raise ResolveError(f"{what}: not found (404)") from error
            last = f"HTTP {error.code}"
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            last = str(error)
        if attempt + 1 < ATTEMPTS:
            time.sleep(RETRY_DELAY * (attempt + 1))
    raise Unreachable(f"{what}: {last}")


def _json(url: str):
    def fetch():
        with _open(url) as response:
            return json.loads(response.read().decode("utf-8"))

    return _retrying(url, fetch)


def pin_commit(base: str, repository: str, revision: str) -> str:
    """The commit [revision] of [repository] is at."""
    info = _json(f"{base}/api/models/{repository}/revision/{revision}")
    commit = info.get("sha") if isinstance(info, dict) else None
    if not isinstance(commit, str) or len(commit) != 40:
        raise ResolveError(f"{repository}@{revision}: no commit in {info!r}")
    return commit


def tree(base: str, repository: str, commit: str) -> dict[str, dict]:
    """The files at [commit] by path."""
    entries = _json(f"{base}/api/models/{repository}/tree/{commit}")
    if not isinstance(entries, list):
        raise ResolveError(f"{repository}@{commit}: unexpected tree {entries!r}")
    return {
        entry["path"]: entry
        for entry in entries
        if isinstance(entry, dict) and isinstance(entry.get("path"), str)
    }


def hash_download(url: str) -> tuple[int, str, str]:
    """(size, sha1, sha256) of the file at [url]."""

    def fetch():
        sha1 = hashlib.sha1()
        sha256 = hashlib.sha256()
        size = 0
        with _open(url, timeout=120) as response:
            while True:
                chunk = response.read(CHUNK)
                if not chunk:
                    break
                size += len(chunk)
                sha1.update(chunk)
                sha256.update(chunk)
        return size, sha1.hexdigest(), sha256.hexdigest()

    return _retrying(url, fetch)


def resolve_entry(
    source: dict, files: dict[str, dict], base: str, repository: str, commit: str
) -> dict:
    """The catalogue entry of [source] (WhisperCatalogModel.fromJson)."""
    name = source["file"]
    listed = files.get(name)
    if listed is None:
        raise ResolveError(f"{name}: not in {repository}@{commit}")
    lfs = listed.get("lfs") or {}
    sha256 = lfs.get("oid") or lfs.get("sha256")
    size = lfs.get("size", listed.get("size"))
    if not isinstance(sha256, str) or len(sha256) != 64:
        raise ResolveError(f"{name}: no SHA-256 in the tree ({listed!r})")
    if not isinstance(size, int) or size <= 0:
        raise ResolveError(f"{name}: no size in the tree ({listed!r})")
    quote = urllib.parse.quote
    path = f"{quote(repository)}/resolve/{commit}/{quote(name)}"
    served_size, sha1, served_sha256 = hash_download(f"{base}/{path}")
    if served_size != size:
        raise ResolveError(
            f"{name}: Hugging Face lists {size} bytes, the download has {served_size}"
        )
    if served_sha256 != sha256:
        raise ResolveError(
            f"{name}: Hugging Face lists sha256 {sha256}, the download has "
            f"{served_sha256}"
        )
    readme = source.get("readmeSha1")
    if readme and readme != sha1:
        raise ResolveError(
            f"{name}: whisper.cpp's models/README.md lists sha1 {readme}, the "
            f"download has {sha1}"
        )
    entry = {
        "id": source["id"],
        "name": name,
        "url": f"{HUGGING_FACE}/{path}",
        "size": size,
        "sha1": sha1,
        "sha256": sha256,
        "multilingual": source.get("multilingual", True),
        "parameters": source["parameters"],
    }
    if "minRamMb" in source:
        entry["minRamMb"] = source["minRamMb"]
    return entry


def resolve(
    only: set[str] | None = None,
    base: str = HUGGING_FACE,
    repository: str = REPOSITORY,
    revision: str = REVISION,
) -> tuple[str, list[dict]]:
    """(commit, entries) of SOURCES (or those in [only])."""
    sources = [s for s in SOURCES if only is None or s["id"] in only]
    if only is not None and len(sources) != len(only):
        unknown = sorted(only - {s["id"] for s in SOURCES})
        raise ResolveError(f"unknown model ids: {', '.join(unknown)}")
    commit = pin_commit(base, repository, revision)
    files = tree(base, repository, commit)
    return commit, [
        resolve_entry(source, files, base, repository, commit) for source in sources
    ]


def merge(catalog: dict, entries: list[dict], commit: str) -> dict:
    """[catalog] with [entries] added or replaced, in ORDER, and their
    provenance."""
    models = {model["id"]: model for model in catalog.get("models", [])}
    original = list(models)
    for entry in entries:
        models[entry["id"]] = entry

    def rank(model_id: str) -> tuple[int, int]:
        if models[model_id].get("kind") == "vad":
            return (2, 0)
        if model_id in ORDER:
            return (0, ORDER.index(model_id))
        position = original.index(model_id) if model_id in original else len(original)
        return (1, position)

    merged = dict(catalog)
    merged["models"] = [models[i] for i in sorted(models, key=rank)]
    provenance = [
        line
        for line in catalog.get("_provenance", [])
        if not line.startswith("Quantized models (")
    ]
    ids = [m["id"] for m in merged["models"] if m["id"] in {s["id"] for s in SOURCES}]
    if ids:
        provenance.append(PROVENANCE.format(ids=", ".join(ids), commit=commit))
    merged["_provenance"] = provenance
    return merged


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    run = commands.add_parser("resolve", help="resolve the quantized models")
    output = run.add_mutually_exclusive_group()
    output.add_argument(
        "--print", action="store_true", help="print the entries (default)"
    )
    output.add_argument(
        "--write", action="store_true", help="merge them into the catalogue"
    )
    run.add_argument("--only", help="model ids, comma-separated")
    run.add_argument("--catalog", type=Path, default=CATALOG)
    run.add_argument("--base-url", default=HUGGING_FACE, help="where to ask (tests)")
    args = parser.parse_args(argv)

    only = None
    if args.only:
        only = {part.strip() for part in args.only.split(",") if part.strip()}
    try:
        commit, entries = resolve(only, base=args.base_url.rstrip("/"))
    except ResolveError as error:
        print(f"MISMATCH     {error}", file=sys.stderr)
        return 1
    except Unreachable as error:
        print(f"UNREACHABLE  {error}", file=sys.stderr)
        return 2

    for entry in entries:
        print(
            f"OK           {entry['name']}: {entry['size']} bytes, sha256 "
            f"{entry['sha256']}, sha1 {entry['sha1']}",
            file=sys.stderr,
        )
    if args.write:
        catalog = json.loads(args.catalog.read_text(encoding="utf-8"))
        merged = merge(catalog, entries, commit)
        args.catalog.write_text(
            json.dumps(merged, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )
        print(f"Wrote {len(entries)} entries to {args.catalog}", file=sys.stderr)
    else:
        ids = ", ".join(entry["id"] for entry in entries)
        print(
            json.dumps(
                {
                    "_provenance": PROVENANCE.format(ids=ids, commit=commit),
                    "models": entries,
                },
                indent=2,
                ensure_ascii=False,
            )
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
