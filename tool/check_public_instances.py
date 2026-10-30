#!/usr/bin/env python3
"""Checks that the public Mozhi instances built into the app still translate
(CI job "Check model downloads", and every week the workflow
.github/workflows/public-instances.yaml; needs the network).

  python3 tool/check_public_instances.py [--min-working N] [--text TEXT]

A new install translates online through these volunteer servers (the
list in packages/translation_repository/lib/src/models/mozhi_instance.dart,
`MozhiInstance.publicInstances`), with the Google engine by default and
failover to the next server. For every server this asks for its engines
(`GET /api/engines`) and translates one short sentence from English to
French with each engine the app knows (`POST /api/translate`, the way the
app sends text), then prints a table: which servers answer, which engines
translate there, and how long the default engine took.

A translation counts when the answer is JSON with a non-empty
`translated-text` that differs from the English. Nothing but the fixed test
sentence is sent.

On GitHub Actions the table also goes to the job summary, and each server
that no longer translates with the default engine gets a `::warning::`.

Exit status: 0 when at least --min-working servers (default 1) translate
with the default engine, 1 otherwise (a new install could not translate
online at all).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
INSTANCES = (
    REPO_ROOT / "packages/translation_repository/lib/src/models/mozhi_instance.dart"
)
USER_AGENT = "Mozhi instance check (+https://github.com/Aimdi/Mozhi)"
DEFAULT_ENGINE = "google"
# The engines the app offers from a Mozhi instance, in the order of its
# engine list; the check tries those an instance reports.
KNOWN_ENGINES = (
    "google",
    "deepl",
    "duckduckgo",
    "yandex",
    "mymemory",
    "reverso",
    "libre",
)
TEXT = "Good morning! Where is the train station?"
TIMEOUT = 20


@dataclass
class Result:
    url: str
    reachable: bool = False
    error: str = ""
    engines: list[str] = field(default_factory=list)
    translated: dict[str, str] = field(default_factory=dict)
    failed: dict[str, str] = field(default_factory=dict)
    default_seconds: float | None = None

    @property
    def default_works(self) -> bool:
        return DEFAULT_ENGINE in self.translated


def public_instances(source: Path = INSTANCES) -> list[str]:
    """The `url:` of every instance in `publicInstances`, in order."""
    text = source.read_text(encoding="utf-8")
    start = text.find("publicInstances")
    if start < 0:
        raise ValueError(f"no publicInstances in {source}")
    end = text.find("];", start)
    block = text[start:end]
    urls = re.findall(r"url:\s*'([^']+)'", block)
    if not urls:
        raise ValueError(f"no instance urls in {source}")
    return urls


def _request(url: str, data: dict[str, str] | None = None) -> tuple[int, bytes]:
    body = urllib.parse.urlencode(data).encode() if data is not None else None
    request = urllib.request.Request(
        url,
        data=body,
        method="POST" if data is not None else "GET",
        headers={
            "User-Agent": USER_AGENT,
            "Accept": "application/json",
            **(
                {"Content-Type": "application/x-www-form-urlencoded"}
                if data is not None
                else {}
            ),
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return response.status, response.read(1 << 20)
    except urllib.error.HTTPError as error:
        return error.code, error.read(4096)


def _short(error: object) -> str:
    message = str(error).strip().replace("\n", " ")
    return message[:80] + ("…" if len(message) > 80 else "")


def translation_of(body: bytes, text: str = TEXT) -> str | None:
    """The `translated-text` of a Mozhi answer when it is a translation of
    [text] (non-empty and not the text itself), else None."""
    try:
        data = json.loads(body)
    except (ValueError, UnicodeDecodeError):
        return None
    if isinstance(data, list):
        data = data[0] if data else None
    if not isinstance(data, dict):
        return None
    translated = data.get("translated-text")
    if not isinstance(translated, str):
        return None
    translated = translated.strip()
    if not translated or translated.casefold() == text.strip().casefold():
        return None
    return translated


def check_instance(url: str, text: str = TEXT) -> Result:
    result = Result(url)
    base = url.rstrip("/")
    try:
        status, body = _request(f"{base}/api/engines")
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        result.error = _short(getattr(error, "reason", error))
        return result
    if status != 200:
        result.error = f"engines: HTTP {status}"
        return result
    try:
        listed = json.loads(body)
    except ValueError:
        result.error = "engines: not JSON"
        return result
    if not isinstance(listed, dict):
        result.error = "engines: unexpected answer"
        return result
    result.reachable = True
    result.engines = [e for e in KNOWN_ENGINES if e in listed]
    for engine in result.engines:
        started = time.monotonic()
        try:
            status, body = _request(
                f"{base}/api/translate",
                {"engine": engine, "from": "en", "to": "fr", "text": text},
            )
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            result.failed[engine] = _short(getattr(error, "reason", error))
            continue
        translated = translation_of(body, text) if status == 200 else None
        if translated is None:
            result.failed[engine] = (
                f"HTTP {status}" if status != 200 else "no translation"
            )
            continue
        result.translated[engine] = translated
        if engine == DEFAULT_ENGINE:
            result.default_seconds = time.monotonic() - started
    return result


def table(results: list[Result]) -> str:
    lines = [
        f"| Server | {DEFAULT_ENGINE} | Time | Engines that translate | Failing |",
        "|---|---|---|---|---|",
    ]
    for r in results:
        host = urllib.parse.urlsplit(r.url).netloc
        if not r.reachable:
            lines.append(f"| {host} | ✗ | | | unreachable: {r.error} |")
            continue
        seconds = f"{r.default_seconds:.1f} s" if r.default_seconds else ""
        failing = ", ".join(f"{e} ({why})" for e, why in r.failed.items())
        lines.append(
            f"| {host} | {'✓' if r.default_works else '✗'} | {seconds} | "
            f"{', '.join(r.translated) or '–'} | {failing} |"
        )
    return "\n".join(lines)


def summary(results: list[Result]) -> str:
    working = sum(r.default_works for r in results)
    per_engine = {
        engine: sum(engine in r.translated for r in results)
        for engine in KNOWN_ENGINES
    }
    engines = ", ".join(f"{e} {n}" for e, n in per_engine.items())
    return (
        f"{working} of {len(results)} public instances translate with "
        f"{DEFAULT_ENGINE}; servers per engine: {engines}"
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--min-working", type=int, default=1)
    parser.add_argument("--text", default=TEXT)
    args = parser.parse_args(argv)

    urls = public_instances()
    with ThreadPoolExecutor(max_workers=6) as pool:
        results = list(pool.map(lambda u: check_instance(u, args.text), urls))

    report = f"{table(results)}\n\n{summary(results)}"
    print(report)
    if os.environ.get("GITHUB_ACTIONS") == "true":
        for r in results:
            if not r.default_works:
                why = r.error or r.failed.get(DEFAULT_ENGINE, "no engine")
                print(
                    f"::warning::{r.url} does not translate with "
                    f"{DEFAULT_ENGINE}: {why}"
                )
        step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
        if step_summary:
            with open(step_summary, "a", encoding="utf-8") as out:
                out.write(f"### Public Mozhi instances\n\n{report}\n")
    working = sum(r.default_works for r in results)
    return 0 if working >= args.min_working else 1


if __name__ == "__main__":
    sys.exit(main())
