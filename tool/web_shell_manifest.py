#!/usr/bin/env python3
"""Lists a web build's files for its app shell service worker.

  python3 tool/web_shell_manifest.py BUILD_DIR

Run it on the output of `flutter build web`, after
tool/web_fallback_fonts.py (it lists what is in BUILD_DIR, fonts
included). It writes BUILD_DIR/mozhi_sw_manifest.json, every file of the
build with its size and SHA-256:

  {"schemaVersion": 1, "version": "<SHA-256 of the file list>",
   "files": [{"path": "main.dart.js", "size": 5471234, "sha256": "..."},
             {"path": "fallback_fonts/...woff2", ..., "lazy": true},
             {"path": "index.html", ..., "base": true}, ...]}

and stamps the version and the paths into BUILD_DIR/mozhi_sw.js (from
web/mozhi_sw.js): its SHELL_VERSION and SHELL_FILES lines. The worker
caches exactly these files (docs/self-hosting-mozhi.md); a build with
other files has another version, which the browser installs as an update.

- Left out: the worker and the manifest themselves, Flutter's deprecated
  `flutter_service_worker.js`, hidden files (`.last_build_id`), source
  maps (`*.map`) and debug symbols (`*.symbols`), and any model files put
  next to the app (`models/`, and folders below `bergamot/`, which holds
  only the offline engine's worker and WebAssembly files).
- Lazy (`"lazy": true`, kept when a page first loads them instead of at
  the install): the fallback fonts (`fallback_fonts/`, 22 MB, of which a
  page needs the fonts of the scripts it shows) and the renderer files no
  build of `_flutter.buildConfig` in flutter_bootstrap.js loads (the
  `skwasm`, `skwasm_heavy` and `wimp` renderers without a WebAssembly
  build of the app, and CanvasKit's experimental `webparagraph` variant).
- `index.html` is hashed with the value of its `<base href>` emptied
  (`"base": true`), so that changing it to serve the app from a sub-path
  keeps the manifest valid.

Running it again on the same build changes nothing. Exit status: 0 on
success, 2 on a usage or file error (no web build, a worker without the
lines to stamp).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import urllib.parse
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

MANIFEST = "mozhi_sw_manifest.json"
WORKER = "mozhi_sw.js"
BOOTSTRAP = "flutter_bootstrap.js"
SCHEMA = 1

# Never listed: the worker, its manifest and Flutter's old worker.
EXCLUDED_FILES = {WORKER, MANIFEST, "flutter_service_worker.js"}
EXCLUDED_SUFFIXES = (".map", ".symbols")
# Model mirrors next to the app (tool/mirror_models.py's `models/`).
EXCLUDED_DIRS = ("models/",)
ENGINE_DIR = "bergamot/"

LAZY_DIRS = ("fallback_fonts/", "canvaskit/webparagraph/")
# Renderer files only a WebAssembly (skwasm) build of the app loads.
SKWASM_FILES = re.compile(r"^canvaskit/(?:skwasm|skwasm_heavy|wimp)\.(?:js|wasm)$")

BUILD_CONFIG = re.compile(r"_flutter\.buildConfig\s*=\s*(\{.*?\})\s*;\s*$", re.M)
BASE_HREF = re.compile(r'<base\s+href="[^"]*"', re.I)
VERSION_LINE = re.compile(r"^const SHELL_VERSION = .*;$", re.M)
FILES_LINE = re.compile(r"^const SHELL_FILES = .*;$", re.M)
# The characters a browser keeps as they are in the path of a URL (the
# worker compares paths as requested).
URL_SAFE = "/-._~!$&'()*+,;=:@"


class SetupError(Exception):
    """A usage or file error (exit status 2)."""


@dataclass
class Result:
    """What [write] did."""

    version: str
    files: int
    precached_bytes: int
    lazy_bytes: int


def listed(path: str) -> bool:
    """Whether the build file at [path] (relative, POSIX) belongs in the
    manifest."""
    parts = PurePosixPath(path).parts
    if any(part.startswith(".") for part in parts):
        return False
    if path in EXCLUDED_FILES or path.endswith(EXCLUDED_SUFFIXES):
        return False
    if path.startswith(EXCLUDED_DIRS):
        return False
    # The engine's files sit directly in bergamot/; anything in a folder
    # below it is a model (the "This web server" mirror layout).
    if path.startswith(ENGINE_DIR) and "/" in path[len(ENGINE_DIR) :]:
        return False
    return True


def wasm_build(build: Path) -> bool:
    """Whether a build of `_flutter.buildConfig` uses the skwasm renderer
    (then its files are needed at once). True when the configuration
    cannot be read, so that nothing the app may need is left lazy."""
    try:
        script = (build / BOOTSTRAP).read_text(encoding="utf-8")
        match = BUILD_CONFIG.search(script)
        if match is None:
            return True
        builds = json.loads(match[1]).get("builds", [])
        return any(isinstance(b, dict) and b.get("renderer") == "skwasm" for b in builds)
    except (OSError, ValueError, AttributeError):
        return True


def lazy(path: str, *, skwasm: bool) -> bool:
    """Whether the worker keeps [path] only once a page loads it."""
    if path.startswith(LAZY_DIRS):
        return True
    return not skwasm and SKWASM_FILES.match(path) is not None


def without_base_href(data: bytes) -> bytes:
    """[data] (UTF-8 HTML) with the value of its first `<base href>`
    emptied, as the worker checks index.html."""
    text = data.decode("utf-8", errors="replace")
    return BASE_HREF.sub('<base href=""', text, count=1).encode("utf-8")


def entries(build: Path) -> list[dict]:
    """The manifest entries of the files of [build], sorted by path."""
    skwasm = wasm_build(build)
    files = []
    for file in sorted(build.rglob("*")):
        if not file.is_file():
            continue
        relative = file.relative_to(build).as_posix()
        if not listed(relative):
            continue
        data = file.read_bytes()
        entry: dict = {"path": urllib.parse.quote(relative, safe=URL_SAFE)}
        if relative == "index.html":
            data = without_base_href(data)
            entry["base"] = True
        entry["size"] = len(data)
        entry["sha256"] = hashlib.sha256(data).hexdigest()
        if lazy(relative, skwasm=skwasm):
            entry["lazy"] = True
        files.append(entry)
    return sorted(files, key=lambda entry: entry["path"])


def version_of(files: list[dict]) -> str:
    """The SHA-256 of the canonical JSON of [files]: changes with any file."""
    canonical = json.dumps(files, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def stamp(script: str, version: str, paths: list[str]) -> str:
    """[script] (web/mozhi_sw.js) with [version] and [paths] stamped."""
    if len(VERSION_LINE.findall(script)) != 1 or len(FILES_LINE.findall(script)) != 1:
        raise SetupError(
            f"{WORKER} has no single `const SHELL_VERSION = ...;` and "
            "`const SHELL_FILES = ...;` line: it must come from web/" + WORKER
        )
    script = VERSION_LINE.sub(lambda _: f"const SHELL_VERSION = {json.dumps(version)};", script)
    listing = json.dumps(paths, ensure_ascii=False, separators=(",", ":"))
    return FILES_LINE.sub(lambda _: f"const SHELL_FILES = {listing};", script)


def write(build: Path) -> Result:
    """Writes the manifest of [build] and stamps its worker."""
    if not (build / "index.html").is_file():
        raise SetupError(f"{build} is not a web build (no index.html)")
    worker = build / WORKER
    if not worker.is_file():
        raise SetupError(f"{worker} is missing: was {build} built from this repository's web/?")
    files = entries(build)
    if not any(entry["path"] == "index.html" for entry in files):
        raise SetupError(f"{build}/index.html is not listed")
    version = version_of(files)
    manifest = {"schemaVersion": SCHEMA, "version": version, "files": files}
    text = json.dumps(manifest, indent=1, sort_keys=True, ensure_ascii=False) + "\n"
    # Checked before anything is written.
    script = worker.read_text(encoding="utf-8")
    stamped = stamp(script, version, [entry["path"] for entry in files])
    (build / MANIFEST).write_text(text, encoding="utf-8")
    if stamped != script:
        worker.write_text(stamped, encoding="utf-8")
    return Result(
        version=version,
        files=len(files),
        precached_bytes=sum(entry["size"] for entry in files if not entry.get("lazy")),
        lazy_bytes=sum(entry["size"] for entry in files if entry.get("lazy")),
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="List a web build's files for its app shell service worker.",
    )
    parser.add_argument("build", type=Path, help="the output of `flutter build web`")
    args = parser.parse_args(argv)
    try:
        result = write(args.build)
    except SetupError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    print(
        f"App shell {result.version[:12]}: {result.files} files, "
        f"{result.precached_bytes / 1e6:.1f} MB kept at the install, "
        f"{result.lazy_bytes / 1e6:.1f} MB when first used ({args.build / MANIFEST})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
