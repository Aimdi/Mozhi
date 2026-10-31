#!/usr/bin/env python3
"""Fetches what the real-transcription tests need into one directory.

  python3 packages/whisper_speech/tool/fetch_test_model.py [--out DIR]
      [--model ID] [--sample WAV]

  * the speech model ID (default `tiny`, "Fast": 77,691,713 bytes) of the
    app's catalogue (assets/models.json), downloaded from its `url`
    (Hugging Face) and checked against the catalogue's size, SHA-256 and
    SHA-1 before it is kept, as the app does; a file already there that
    matches is not downloaded again (CI restores it from a cache keyed by
    the SHA-256);
  * a copy of whisper.cpp's `samples/jfk.wav` (11 s of clear English
    speech, 16 kHz mono 16-bit PCM: "And so my fellow Americans, ask not
    what your country can do for you, ask what you can do for your
    country."; a US government recording, public domain), committed in the
    pinned whisper.cpp submodule (tool/fetch_native_deps.sh) at
    native/third_party/whisper.cpp/samples/jfk.wav, or the WAV given with
    --sample. Its format is checked.

DIR defaults to packages/whisper_speech/build/test_models, where the tests
look (test/helpers/native_library.dart: `ggml-<ID>.bin` is named as in the
catalogue, the sample `speech-en.wav`); WHISPER_SPEECH_MODEL and
WHISPER_SPEECH_SAMPLE override them there.

Exit status: 0 when both are in place, 1 when a file does not match (or the
sample is missing), 2 when the download failed after retries. Needs only
the Python 3.9+ standard library.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
import time
import urllib.error
import urllib.request
import wave
from pathlib import Path

PACKAGE = Path(__file__).resolve().parent.parent
CATALOG = PACKAGE / "assets/models.json"
DEFAULT_OUT = PACKAGE / "build/test_models"
DEFAULT_SAMPLE = PACKAGE / "native/third_party/whisper.cpp/samples/jfk.wav"
SAMPLE_NAME = "speech-en.wav"
USER_AGENT = "Mozhi test model fetcher (+https://github.com/Aimdi/Mozhi)"
ATTEMPTS = 3
RETRY_DELAY = 5.0
CHUNK = 1 << 20


class Mismatch(Exception):
    """A file is not the one the catalogue lists."""


def catalog_entry(model_id: str, catalog: Path = CATALOG) -> dict:
    """The catalogue entry of speech model [model_id]."""
    data = json.loads(catalog.read_text(encoding="utf-8"))
    for entry in data["models"]:
        if entry["id"] == model_id and entry.get("kind", "speech") != "vad":
            return entry
    raise SystemExit(f"error: no speech model {model_id!r} in {catalog}")


def digests(path: Path) -> tuple[int, str, str]:
    """Size, SHA-256 and SHA-1 of [path]."""
    sha256 = hashlib.sha256()
    sha1 = hashlib.sha1()
    size = 0
    with path.open("rb") as file:
        while chunk := file.read(CHUNK):
            size += len(chunk)
            sha256.update(chunk)
            sha1.update(chunk)
    return size, sha256.hexdigest(), sha1.hexdigest()


def check(path: Path, entry: dict) -> None:
    """Raises [Mismatch] unless [path] is the catalogue's file."""
    size, sha256, sha1 = digests(path)
    problems = []
    if size != entry["size"]:
        problems.append(f"size {size}, expected {entry['size']}")
    if "sha256" in entry and sha256 != entry["sha256"]:
        problems.append(f"SHA-256 {sha256}, expected {entry['sha256']}")
    if sha1 != entry["sha1"]:
        problems.append(f"SHA-1 {sha1}, expected {entry['sha1']}")
    if problems:
        raise Mismatch(f"{path.name}: " + "; ".join(problems))


def download(url: str, target: Path) -> None:
    """Downloads [url] to [target] (through a temporary file), retrying."""
    partial = target.with_name(target.name + ".part")
    for attempt in range(1, ATTEMPTS + 1):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(request, timeout=120) as response:
                with partial.open("wb") as file:
                    shutil.copyfileobj(response, file, CHUNK)
            partial.replace(target)
            return
        except (urllib.error.URLError, TimeoutError, ConnectionError) as error:
            partial.unlink(missing_ok=True)
            if attempt == ATTEMPTS:
                raise
            print(f"download failed ({error}); retrying", file=sys.stderr)
            time.sleep(RETRY_DELAY * attempt)


def fetch_model(entry: dict, out: Path, url: str | None = None) -> Path:
    """The catalogue's model file in [out], downloaded unless it is there."""
    target = out / entry["name"]
    if target.exists():
        try:
            check(target, entry)
            print(f"{target.name} is in place")
            return target
        except Mismatch as mismatch:
            print(f"{mismatch}: downloading it again", file=sys.stderr)
            target.unlink()
    download(url or entry["url"], target)
    try:
        check(target, entry)
    except Mismatch:
        target.unlink()
        raise
    print(f"downloaded {target.name} ({entry['size']:,} bytes, checked)")
    return target


def copy_sample(source: Path, out: Path) -> Path:
    """[source] as `speech-en.wav` in [out], after checking its format."""
    if not source.exists():
        raise Mismatch(
            f"{source} is missing (run tool/fetch_native_deps.sh first)"
        )
    with wave.open(str(source), "rb") as sample:
        format_ = (sample.getnchannels(), sample.getsampwidth(), sample.getframerate())
        seconds = sample.getnframes() / sample.getframerate()
    if format_ != (1, 2, 16000):
        raise Mismatch(f"{source.name} is {format_}, not 16 kHz mono 16-bit")
    target = out / SAMPLE_NAME
    shutil.copyfile(source, target)
    print(f"copied {source.name} ({seconds:.1f} s) to {target}")
    return target


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--model", default="tiny")
    parser.add_argument("--sample", type=Path, default=DEFAULT_SAMPLE)
    parser.add_argument("--catalog", type=Path, default=CATALOG, help=argparse.SUPPRESS)
    parser.add_argument("--url", help=argparse.SUPPRESS)  # Tests: a local server.
    args = parser.parse_args(argv)
    args.out.mkdir(parents=True, exist_ok=True)
    try:
        fetch_model(catalog_entry(args.model, args.catalog), args.out, args.url)
        copy_sample(args.sample, args.out)
    except Mismatch as mismatch:
        print(f"error: {mismatch}", file=sys.stderr)
        return 1
    except (urllib.error.URLError, TimeoutError, ConnectionError) as error:
        print(f"error: download failed: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
