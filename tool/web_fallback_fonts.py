#!/usr/bin/env python3
"""Self-hosts the fonts the Flutter web engine would fetch from Google.

  python3 tool/web_fallback_fonts.py BUILD_DIR [--cache DIR] [--offline]
  python3 tool/web_fallback_fonts.py --list

CanvasKit draws text with Roboto and, for characters Roboto lacks (CJK,
Indic and Arabic scripts, emoji, symbols...), with Noto fonts it downloads
when they are first needed, from `fontFallbackBaseUrl`
(https://fonts.gstatic.com/s/ by default). Every page load therefore tells
Google the user's IP address, and the scripts they read.

This script copies every one of those fonts into BUILD_DIR (the output of
`flutter build web`) under `fallback_fonts/`, at the same relative paths as
on fonts.gstatic.com, and then

- sets `mozhiSelfHostedFonts` in BUILD_DIR/flutter_bootstrap.js (from
  web/flutter_bootstrap.js), which points `fontFallbackBaseUrl` at
  `fallback_fonts/`, and
- removes https://fonts.gstatic.com from the Content Security Policy of
  BUILD_DIR/index.html.

The font list is read from the engine sources of the Flutter SDK that
builds the app (`bin/cache/flutter_web_sdk`, found through --flutter-root,
$FLUTTER_ROOT or the `flutter` on the PATH), so it always matches that
Flutter version. Flutter 3.47.7 asks for 725 files, 21.8 MB in all (the
browser only fetches the ones a page needs). Downloads are kept in --cache
(default build/web_fallback_fonts_cache) and reused; --offline uses only
that cache. Every file must be a font of its type (checked by its magic
bytes) and at most 8 MB.

Without this step a web build keeps fetching the fonts from Google, as
before. Running it again on the same build changes nothing.

Exit status: 0 on success, 1 when a font cannot be fetched or is invalid,
2 on a usage or file error (an SDK without the font data, a build without
the markers this script patches).
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CACHE = ROOT / "build" / "web_fallback_fonts_cache"
GSTATIC = "https://fonts.gstatic.com/s/"
OUTPUT_DIR = "fallback_fonts"
MAX_BYTES = 8 * 1024 * 1024

# Engine sources (relative to the Flutter root) that name the fonts.
ENGINE_DIRS = (
    "bin/cache/flutter_web_sdk/lib/_engine/engine",
    "bin/cache/flutter_web_sdk/lib/ui/src/engine",
)
FALLBACK_DATA = "font_fallback_data.dart"
DEFAULT_FONT_SOURCES = (
    "canvaskit/fonts.dart",
    "skwasm/skwasm_impl/font_collection.dart",
)

NOTO_FONT = re.compile(r"NotoFont\(\s*'[^']*',\s*'([^']+)'", re.S)
DEFAULT_FONT = re.compile(r"\$\{configuration\.fontFallbackBaseUrl\}([^'\"]+)")
SAFE_PATH = re.compile(r"^[a-z0-9]+(?:/[A-Za-z0-9_-][A-Za-z0-9_.-]*)+\.(woff2|woff|ttf|otf)$")
MAGIC = {
    "woff2": (b"wOF2",),
    "woff": (b"wOFF",),
    "ttf": (b"\x00\x01\x00\x00", b"true"),
    "otf": (b"OTTO",),
}

BOOTSTRAP = "flutter_bootstrap.js"
BOOTSTRAP_OFF = "const mozhiSelfHostedFonts = false;"
BOOTSTRAP_ON = "const mozhiSelfHostedFonts = true;"
CSP_META = re.compile(r'(<meta\s+http-equiv="Content-Security-Policy"\s+content=")([^"]*)(")', re.I)
GSTATIC_SOURCE = re.compile(r"\s+https://fonts\.gstatic\.com(?=[\s;]|$)")


class FontError(Exception):
    """A font that cannot be fetched or is not a font (exit status 1)."""


class SetupError(Exception):
    """A usage or file error (exit status 2)."""


@dataclass
class Result:
    """What [mirror] did."""

    fonts: int
    total_bytes: int
    downloaded: int


def flutter_root(explicit: str | None = None) -> Path:
    """The Flutter SDK: [explicit], else $FLUTTER_ROOT, else the one of the
    `flutter` on the PATH."""
    if explicit:
        return Path(explicit)
    if os.environ.get("FLUTTER_ROOT"):
        return Path(os.environ["FLUTTER_ROOT"])
    flutter = shutil.which("flutter")
    if not flutter:
        raise SetupError("Flutter not found: pass --flutter-root or set FLUTTER_ROOT")
    return Path(flutter).resolve().parent.parent


def font_paths(root: Path) -> list[str]:
    """Every font file the web engine of the Flutter SDK at [root] may fetch
    from `fontFallbackBaseUrl`, as paths relative to it: the Noto fallback
    fonts and the default font (Roboto), without duplicates."""
    engine = next((root / d for d in ENGINE_DIRS if (root / d / FALLBACK_DATA).is_file()), None)
    if engine is None:
        raise SetupError(f"No {FALLBACK_DATA} in the Flutter SDK at {root} (run `flutter precache --web`)")
    paths = NOTO_FONT.findall((engine / FALLBACK_DATA).read_text(encoding="utf-8"))
    if not paths:
        raise SetupError(f"No fonts found in {engine / FALLBACK_DATA}: has its format changed?")
    defaults = [
        path
        for source in DEFAULT_FONT_SOURCES
        if (engine / source).is_file()
        for path in DEFAULT_FONT.findall((engine / source).read_text(encoding="utf-8"))
    ]
    if not defaults:
        raise SetupError(f"The default font (Roboto) was not found in {engine}: has its format changed?")
    unique = list(dict.fromkeys(defaults + paths))
    for path in unique:
        if not SAFE_PATH.match(path) or ".." in path.split("/"):
            raise SetupError(f"Unexpected font path in the engine sources: {path!r}")
    return unique


def check_font(path: str, data: bytes) -> None:
    """Raises [FontError] unless [data] looks like the font [path] names."""
    extension = path.rsplit(".", 1)[1]
    if not data:
        raise FontError(f"{path}: empty")
    if len(data) > MAX_BYTES:
        raise FontError(f"{path}: {len(data)} bytes, more than {MAX_BYTES}")
    if not data.startswith(MAGIC[extension]):
        raise FontError(f"{path}: not a {extension} font")


def download(path: str, attempts: int = 3) -> bytes:
    """[path] from fonts.gstatic.com, with retries for network errors."""
    url = GSTATIC + path
    for attempt in range(1, attempts + 1):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "Mozhi build"})
            with urllib.request.urlopen(request, timeout=60) as response:
                return response.read(MAX_BYTES + 1)
        except urllib.error.HTTPError as error:
            if error.code < 500 or attempt == attempts:
                raise FontError(f"{url}: HTTP {error.code}") from error
        except (urllib.error.URLError, OSError) as error:
            if attempt == attempts:
                raise FontError(f"{url}: {error}") from error
        time.sleep(attempt)
    raise AssertionError("unreachable")


def fetch_into_cache(
    path: str,
    cache: Path,
    *,
    offline: bool,
    fetch: Callable[[str], bytes],
) -> bool:
    """Makes sure [cache] holds a valid copy of [path]; returns whether it
    was downloaded."""
    target = cache / path
    if target.is_file():
        try:
            check_font(path, target.read_bytes())
            return False
        except FontError:
            target.unlink()
    if offline:
        raise FontError(f"{path}: not in the cache {cache} (--offline)")
    data = fetch(path)
    check_font(path, data)
    target.parent.mkdir(parents=True, exist_ok=True)
    partial = target.with_name(target.name + ".part")
    partial.write_bytes(data)
    os.replace(partial, target)
    return True


def patch_build(build: Path) -> None:
    """Points the engine at the copied fonts and drops fonts.gstatic.com
    from the Content Security Policy. Idempotent."""
    bootstrap = build / BOOTSTRAP
    if not bootstrap.is_file():
        raise SetupError(f"{bootstrap} is missing: is {build} a web build?")
    script = bootstrap.read_text(encoding="utf-8")
    if BOOTSTRAP_OFF in script:
        bootstrap.write_text(script.replace(BOOTSTRAP_OFF, BOOTSTRAP_ON), encoding="utf-8")
    elif BOOTSTRAP_ON not in script:
        raise SetupError(f"{bootstrap} has no `{BOOTSTRAP_OFF}`: it must come from web/{BOOTSTRAP}")
    index = build / "index.html"
    if not index.is_file():
        raise SetupError(f"{index} is missing: is {build} a web build?")
    html = index.read_text(encoding="utf-8")
    if not CSP_META.search(html):
        raise SetupError(f"{index} has no Content Security Policy")
    index.write_text(
        CSP_META.sub(lambda m: m[1] + strip_gstatic(m[2]) + m[3], html),
        encoding="utf-8",
    )


def strip_gstatic(policy: str) -> str:
    """[policy] without https://fonts.gstatic.com in its font-src."""
    directives = [d.strip() for d in policy.split(";")]
    return "; ".join(
        GSTATIC_SOURCE.sub("", d) if d.split(" ", 1)[0] == "font-src" else d for d in directives
    )


def mirror(
    build: Path,
    paths: list[str],
    *,
    cache: Path = DEFAULT_CACHE,
    offline: bool = False,
    fetch: Callable[[str], bytes] = download,
    workers: int = 8,
) -> Result:
    """Copies the fonts at [paths] into [build]/fallback_fonts (through
    [cache]) and patches [build] ([patch_build])."""
    if not (build / "index.html").is_file():
        raise SetupError(f"{build} is not a web build (no index.html)")
    cache.mkdir(parents=True, exist_ok=True)
    with ThreadPoolExecutor(max_workers=workers) as pool:
        downloaded = list(
            pool.map(lambda path: fetch_into_cache(path, cache, offline=offline, fetch=fetch), paths)
        )
    output = build / OUTPUT_DIR
    total = 0
    for path in paths:
        target = output / path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(cache / path, target)
        total += target.stat().st_size
    patch_build(build)
    return Result(fonts=len(paths), total_bytes=total, downloaded=sum(downloaded))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Copy the Flutter web engine's fallback fonts into a web build.",
    )
    parser.add_argument("build", nargs="?", type=Path, help="the output of `flutter build web`")
    parser.add_argument("--cache", type=Path, default=DEFAULT_CACHE, help="where downloads are kept")
    parser.add_argument("--offline", action="store_true", help="use only the cache")
    parser.add_argument("--flutter-root", help="the Flutter SDK (default: $FLUTTER_ROOT or `flutter`)")
    parser.add_argument("--list", action="store_true", help="print the font paths and exit")
    args = parser.parse_args(argv)
    try:
        paths = font_paths(flutter_root(args.flutter_root))
        if args.list:
            print("\n".join(paths))
            return 0
        if args.build is None:
            parser.error("BUILD_DIR is required unless --list is given")
        result = mirror(args.build, paths, cache=args.cache, offline=args.offline)
    except SetupError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    except FontError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(
        f"Self-hosted {result.fonts} fallback fonts ({result.total_bytes / 1e6:.1f} MB, "
        f"{result.downloaded} downloaded) in {args.build / OUTPUT_DIR}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
