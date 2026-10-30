#!/usr/bin/env python3
"""Checks that the downloadable data of the on-device engines is still
served as the bundled catalogues describe it (CI job "Check model
downloads"; needs the network).

  python3 tool/check_model_downloads.py [--only whisper|tessdata|bergamot]

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
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
WHISPER = REPO_ROOT / "packages/whisper_speech/assets/models.json"
TESSDATA = REPO_ROOT / "packages/tesseract_ocr/assets/catalog.json"
BERGAMOT = REPO_ROOT / "packages/bergamot_translator/assets/catalog.json"
USER_AGENT = "Mozhi model check (+https://github.com/Aimdi/Mozhi)"
ATTEMPTS = 3


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


def entries(only: str | None) -> list[tuple[str, str, int, str | None]]:
    found = []
    if only in (None, "whisper"):
        catalog = json.loads(WHISPER.read_text(encoding="utf-8"))
        for model in catalog["models"]:
            found.append(
                (
                    f"whisper/{model['name']}",
                    model["url"],
                    int(model["size"]),
                    model.get("sha256"),
                )
            )
    if only in (None, "tessdata"):
        catalog = json.loads(TESSDATA.read_text(encoding="utf-8"))
        for language in catalog["languages"]:
            found.append(
                (
                    f"tessdata/{language['code']}",
                    language["url"],
                    int(language["size"]),
                    None,
                )
            )
    if only in (None, "bergamot"):
        catalog = json.loads(BERGAMOT.read_text(encoding="utf-8"))
        for model in catalog["models"]:
            pair = f"{model['source']}-{model['target']}"
            for kind, file in sorted(model["files"].items()):
                found.append(
                    (
                        f"bergamot/{pair}/{kind}",
                        file["url"],
                        int(file["size"]),
                        None,
                    )
                )
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--only", choices=["whisper", "tessdata", "bergamot"])
    args = parser.parse_args()

    files = entries(args.only)
    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda f: check(*f), files))
    counts = {"ok": 0, "mismatch": 0, "unreachable": 0}
    for status, message in results:
        counts[status] += 1
        if status != "ok" or message.startswith("whisper/"):
            print(f"{status.upper():12} {message}")
    print(
        f"{counts['ok']} of {len(files)} sizes match, "
        f"{counts['mismatch']} differ, {counts['unreachable']} unreachable"
    )
    if counts["mismatch"]:
        return 1
    return 2 if counts["unreachable"] else 0


if __name__ == "__main__":
    sys.exit(main())
