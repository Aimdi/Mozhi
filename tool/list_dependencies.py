#!/usr/bin/env python3
"""Lists Mozhi's direct dependencies and vendored native components.

Usage:
    python3 tool/list_dependencies.py            # print the Markdown tables
    python3 tool/list_dependencies.py --write    # update docs/dependencies.md
    python3 tool/list_dependencies.py --check    # exit 1 if it is out of date

Reads, without any network access:

  * the direct dependencies in ``pubspec.yaml`` and ``packages/*/pubspec.yaml``;
  * their resolved versions: a package's own ``pubspec.lock`` when it has
    one (they are git-ignored; ``bash .github/scripts/packages.sh get``
    creates them), otherwise the committed root ``pubspec.lock``;
  * each licence from the ``LICENSE`` file in the pub cache
    (``$PUB_CACHE`` or ``~/.pub-cache``, ``hosted/pub.dev/<pkg>-<ver>/``) or
    in the path package;
  * the Play-variant-only ML Kit dependency from ``tool/play_prepare.sh``;
  * the offline engine's submodules from ``.gitmodules``,
    ``packages/bergamot_translator/tool/fetch_native_deps.sh`` and the
    commits recorded in git, with the licence read from each checkout
    (``fetch_native_deps.sh`` must have run) and cross-checked against
    ``packages/bergamot_translator/native/THIRD_PARTY_NOTICES.md``.

The output is deterministic (sorted, no timestamps): the same lock files,
pub cache and submodule checkouts give the same tables. ``--write``
replaces the text between the ``BEGIN``/``END list_dependencies.py``
markers in docs/dependencies.md and leaves the rest of the page alone.
"Why" texts live in ``PURPOSE`` below; a dependency without one is
listed with "(undocumented)" so that a new dependency gets noticed.
Needs Python 3.9+ (standard library only) and ``git`` for the commits.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DOC = REPO_ROOT / "docs" / "dependencies.md"
BEGIN = "<!-- BEGIN list_dependencies.py (generated, do not edit by hand) -->"
END = "<!-- END list_dependencies.py -->"

ENGINE = Path("packages/bergamot_translator")
NATIVE = ENGINE / "native"
NOTICES = NATIVE / "THIRD_PARTY_NOTICES.md"
# Every package with native sources (git submodules under
# <package>/native/third_party), with the library it builds.
NATIVE_ENGINES = {
    ENGINE: "Offline translation (`libmozhi_bergamot.so`)",
    Path("packages/tesseract_ocr"): "Text recognition (`libmozhi_tesseract.so`)",
    Path("packages/whisper_speech"): "Offline voice input (`libmozhi_whisper.so`)",
}
FETCH_SCRIPT = ENGINE / "tool" / "fetch_native_deps.sh"
PLAY_SCRIPT = Path("tool/play_prepare.sh")
CI_WORKFLOW = Path(".github/workflows/main.yaml")

# Why each direct dependency is there. Keyed by package name (pub) or by the
# submodule path relative to its parent repository (native).
PURPOSE = {
    # App runtime.
    "audioplayers": "Plays the MP3 clips of Mozhi text-to-speech.",
    "bergamot_translator": "Offline translation (Mozilla Bergamot over dart:ffi).",
    "bloc": "State management (Cubits).",
    "cryptography": "AES-256-GCM encryption of the history.",
    "dynamic_color": "Material You colours from the wallpaper.",
    "equatable": "Value equality for states and models.",
    "file_picker": "Opens documents and subtitles to translate.",
    "flutter": "The UI framework.",
    "flutter_bloc": "Bloc widgets (BlocProvider, BlocBuilder).",
    "flutter_localizations": "Localised framework strings for the UI languages.",
    "flutter_secure_storage": "API keys, credentials and the history key in the platform keystore.",
    "flutter_tts": "Device text-to-speech voices.",
    "go_router": "Routing and deep links.",
    "http": "Every HTTP request (Mozhi, AI providers, DeepL, LibreTranslate, model downloads).",
    "image_picker": "Picks or takes a photo for image translation.",
    "intl": "Date and number formatting, generated localisations.",
    "llm_api": "Streaming clients for AI providers.",
    "material_ui": "Material 3 widgets (decoupled Material library).",
    "mozhi_api": "Client for the Mozhi REST API.",
    "package_info_plus": "App version on the About page (local only).",
    "path_provider": "App-private directory for the offline models.",
    "record": "16 kHz microphone audio for offline voice input (Android AudioRecord).",
    "share_plus": "Share sheet for translations, documents and exports.",
    "shared_preferences": "On-device store for settings and the (encrypted) history.",
    "speech_to_text": "Dictation through the system speech recogniser.",
    "tesseract_ocr": "On-device text recognition in photos (Tesseract over dart:ffi).",
    "translation_repository": "Domain models and the repository that unifies all engines.",
    "url_launcher": "Opens links in the browser (user taps only).",
    "whisper_speech": "Offline voice input (whisper.cpp over dart:ffi).",
    # Dev only.
    "bloc_lint": "Bloc lint rules.",
    "bloc_test": "Tests for Cubits.",
    "bloc_tools": "`bloc lint` command used by CI.",
    "flutter_test": "Widget and unit tests.",
    "mocktail": "Mocks in tests.",
    "test": "Dart unit tests.",
    "very_good_analysis": "Lint rules.",
    "build_runner": "Generates the CLI's version file.",
    "build_verify": "Checks the generated files are up to date.",
    "build_version": "Writes the version into the CLI.",
    # Packages.
    "args": "Command-line parsing (mozhi_cli).",
    "cli_completion": "Shell completion (mozhi_cli).",
    "collection": "Collection helpers.",
    "crypto": "SHA-256 checks of model downloads.",
    "ffi": "Native strings and memory for dart:ffi.",
    "google_mlkit_language_id": "ML Kit language ID. **No build uses it** (mlkit_translator is kept for reference).",
    "google_mlkit_translation": "ML Kit translation. **No build uses it** (mlkit_translator is kept for reference).",
    "http_parser": "Media types and multipart parsing (image upload).",
    "mason_logger": "Terminal output (mozhi_cli).",
    "meta": "Annotations (`@immutable`, `@visibleForTesting`).",
    "mt_api": "DeepL and LibreTranslate clients.",
    "path": "Path handling for the model store.",
    # Play variant.
    "google_mlkit_text_recognition": "On-device OCR for camera and image translation.",
    # Native (submodule paths).
    "packages/bergamot_translator/native/third_party/translations": "mozilla/translations; `inference/` is bergamot-translator and its Marian fork, the engine itself.",
    "packages/bergamot_translator/native/third_party/pcre2": "Regular expressions for ssplit (sentence splitting).",
    "packages/bergamot_translator/native/third_party/cld2": "Compact Language Detector 2: on-device language identification.",
    "packages/tesseract_ocr/native/third_party/tesseract": "Tesseract OCR: the LSTM text recognizer and layout analysis.",
    "packages/tesseract_ocr/native/third_party/leptonica": "Image processing for Tesseract (thresholding, scaling); no image codecs.",
    "packages/whisper_speech/native/third_party/whisper.cpp": "whisper.cpp and ggml: speech recognition on the CPU.",
    "inference/3rd_party/ssplit-cpp": "Sentence splitter.",
    "inference/marian-fork/src/3rd_party/sentencepiece": "Tokeniser (SentencePiece vocabularies).",
    "inference/marian-fork/src/3rd_party/intgemm": "int8 matrix multiply on x86_64.",
    "inference/marian-fork/src/3rd_party/ruy": "int8 matrix multiply on ARM, float everywhere.",
    "inference/marian-fork/src/3rd_party/simd_utils": "SSE intrinsics on NEON (ARM).",
    "third_party/cpuinfo": "CPU feature detection for ruy.",
}

SDK_LICENCE = "BSD-3-Clause"


# --------------------------------------------------------------------------
# A small YAML subset: block mappings and scalars, which is all pubspec.yaml
# and pubspec.lock use in the parts read here. List items are skipped.


def parse_yaml_mapping(text: str) -> dict:
    root: dict = {}
    stack: list[tuple[int, dict]] = [(-1, root)]
    for raw in text.splitlines():
        line = (
            raw.split(" #", 1)[0].rstrip() if not raw.lstrip().startswith("#") else ""
        )
        if not line.strip() or line.lstrip().startswith("- "):
            continue
        indent = len(line) - len(line.lstrip())
        match = re.match(r"^\s*([^:]+?):(?:\s+(.*))?$", line)
        if not match:
            continue
        key, value = match.group(1).strip().strip("\"'"), match.group(2)
        while stack and stack[-1][0] >= indent:
            stack.pop()
        parent = stack[-1][1]
        if value is None or value == "":
            child: dict = {}
            parent[key] = child
            stack.append((indent, child))
        else:
            parent[key] = value.strip().strip("\"'")
    return root


def read(path: Path) -> str:
    return (REPO_ROOT / path).read_text(encoding="utf-8")


# --------------------------------------------------------------------------
# Licences.


def detect_licence(text: str) -> str:
    t = " ".join(text.split()).lower()
    if "mozilla public license" in t and ("version 2.0" in t or "v. 2.0" in t):
        return "MPL-2.0"
    if "apache license" in t and "version 2.0" in t:
        return (
            "Apache-2.0 WITH LLVM-exception" if "llvm exceptions" in t else "Apache-2.0"
        )
    if "redistribution and use in source and binary forms" in t:
        three = (
            "neither the name" in t
            or "names of its contributors" in t
            or "name of the copyright holder" in t
            or "endorse or promote products" in t
        )
        return "BSD-3-Clause" if three else "BSD-2-Clause"
    if "permission is hereby granted, free of charge" in t:
        return "MIT"
    if "provided 'as-is'" in t and "altered source versions" in t:
        return "Zlib"
    if "gnu lesser general public license" in t:
        return "LGPL"
    if "gnu general public license" in t:
        return "GPL"
    return "unknown"


LICENCE_FILES = (
    "LICENSE",
    "LICENSE.md",
    "LICENSE.txt",
    "LICENCE",
    "LICENCE.md",
    "COPYING",
)


def licence_in(directory: Path) -> str | None:
    for name in LICENCE_FILES:
        path = directory / name
        if path.is_file():
            return detect_licence(path.read_text(encoding="utf-8", errors="replace"))
    return None


def pub_cache() -> Path:
    env = os.environ.get("PUB_CACHE")
    return Path(env) if env else Path.home() / ".pub-cache"


# --------------------------------------------------------------------------
# Pub dependencies.


@dataclass(frozen=True)
class Dep:
    name: str
    version: str
    licence: str
    source: str


def manifests() -> list[Path]:
    packages = sorted(
        p.parent.relative_to(REPO_ROOT)
        for p in (REPO_ROOT / "packages").glob("*/pubspec.yaml")
    )
    return [Path(".")] + packages


def flutter_version() -> str:
    match = re.search(
        r'^\s*FLUTTER_VERSION:\s*"?([^"\s]+)"?', read(CI_WORKFLOW), flags=re.MULTILINE
    )
    return match.group(1) if match else "?"


def lock_for(manifest: Path) -> dict:
    own = REPO_ROOT / manifest / "pubspec.lock"
    path = own if own.is_file() else REPO_ROOT / "pubspec.lock"
    return parse_yaml_mapping(path.read_text(encoding="utf-8")).get("packages", {})


def resolve(manifest: Path, name: str, spec) -> Dep:
    if isinstance(spec, dict) and "sdk" in spec:
        return Dep(name, f"Flutter {flutter_version()} (SDK)", SDK_LICENCE, "sdk")
    if isinstance(spec, dict) and "path" in spec:
        directory = (REPO_ROOT / manifest / spec["path"]).resolve()
        pubspec = parse_yaml_mapping(
            (directory / "pubspec.yaml").read_text(encoding="utf-8")
        )
        rel = directory.relative_to(REPO_ROOT).as_posix()
        return Dep(
            name,
            f"{pubspec.get('version', '?')} (`{rel}`)",
            licence_in(directory) or "unknown",
            "path",
        )
    entry = lock_for(manifest).get(name)
    if not isinstance(entry, dict) or "version" not in entry:
        return Dep(name, "unresolved (run pub get)", "?", "hosted")
    version = entry["version"]
    licence = licence_in(pub_cache() / "hosted" / "pub.dev" / f"{name}-{version}")
    return Dep(
        name,
        version,
        licence or "? (not in the pub cache)",
        entry.get("source", "hosted"),
    )


def direct_deps(manifest: Path) -> tuple[list[Dep], list[Dep]]:
    pubspec = parse_yaml_mapping(read(manifest / "pubspec.yaml"))
    runtime = [
        resolve(manifest, n, s)
        for n, s in sorted(pubspec.get("dependencies", {}).items())
    ]
    dev = [
        resolve(manifest, n, s)
        for n, s in sorted(pubspec.get("dev_dependencies", {}).items())
    ]
    return runtime, dev


def purpose(key: str) -> str:
    return PURPOSE.get(key, "(undocumented)")


def table(header: list[str], rows: list[list[str]]) -> list[str]:
    out = [
        "| " + " | ".join(header) + " |",
        "| " + " | ".join("---" for _ in header) + " |",
    ]
    out += [
        "| " + " | ".join(cell.replace("|", "\\|") for cell in row) + " |"
        for row in rows
    ]
    return out


def pub_sections() -> list[str]:
    out: list[str] = []
    root_runtime, root_dev = direct_deps(Path("."))
    out += ["### App (`pubspec.yaml`)", ""]
    out += table(
        ["Package", "Version", "Licence", "Why"],
        [[f"`{d.name}`", d.version, d.licence, purpose(d.name)] for d in root_runtime],
    )
    out += ["", "Dev dependencies (not shipped):", ""]
    out += table(
        ["Package", "Version", "Licence", "Why"],
        [[f"`{d.name}`", d.version, d.licence, purpose(d.name)] for d in root_dev],
    )

    # Packages: one row per dependency, deduplicated across packages.
    for kind in ("runtime", "dev"):
        rows: dict[str, dict] = {}
        for manifest in manifests()[1:]:
            runtime, dev = direct_deps(manifest)
            for dep in runtime if kind == "runtime" else dev:
                row = rows.setdefault(
                    dep.name, {"versions": {}, "licences": set(), "users": []}
                )
                row["versions"].setdefault(dep.version, []).append(manifest.name)
                row["licences"].add(dep.licence)
                row["users"].append(manifest.name)
        rendered = []
        for name in sorted(rows):
            row = rows[name]
            versions = row["versions"]
            if len(versions) == 1:
                version = next(iter(versions))
            else:
                version = "; ".join(
                    f"{v} ({', '.join(users)})" for v, users in sorted(versions.items())
                )
            rendered.append(
                [
                    f"`{name}`",
                    version,
                    " / ".join(sorted(row["licences"])),
                    ", ".join(row["users"]),
                    purpose(name),
                ]
            )
        if kind == "runtime":
            out += ["", "### Packages (`packages/*/pubspec.yaml`), runtime", ""]
        else:
            out += ["", "### Packages, dev dependencies (not shipped)", ""]
        out += table(["Package", "Version", "Licence", "Used by", "Why"], rendered)
    return out


def play_section() -> list[str]:
    script = read(PLAY_SCRIPT)
    plugin = re.search(r"^plugin_version=(\S+)", script, flags=re.MULTILINE)
    sdk = re.search(r"^mlkit_version=(\S+)", script, flags=re.MULTILINE)
    plugin_version = plugin.group(1) if plugin else "?"
    sdk_version = sdk.group(1) if sdk else "?"
    name = "google_mlkit_text_recognition"
    licence = licence_in(
        pub_cache() / "hosted" / "pub.dev" / f"{name}-{plugin_version}"
    )
    models = sorted(
        set(re.findall(r"com\.google\.mlkit:(text-recognition-[a-z]+)", script))
    )
    rows = [
        [
            f"`{name}`",
            plugin_version,
            f"{licence or '?'} (Dart wrapper)",
            purpose(name),
        ],
        [
            "`com.google.mlkit:text-recognition`",
            sdk_version,
            "**Proprietary** (ML Kit terms; sends usage metrics to Google)",
            "The OCR SDK the plugin pulls in, with Play services and data transport.",
        ],
    ]
    if models:
        rows.append(
            [
                ", ".join(f"`{m}`" for m in models),
                sdk_version,
                "**Proprietary** (ML Kit terms)",
                "Bundled script models (the plugin declares them compileOnly).",
            ]
        )
    return ["", "### Play variant only (`tool/play_prepare.sh`)", ""] + table(
        ["Dependency", "Version", "Licence", "Why"], rows
    )


# --------------------------------------------------------------------------
# Native engine.


def git(*args: str) -> str | None:
    try:
        result = subprocess.run(
            ["git", *args], cwd=REPO_ROOT, capture_output=True, text=True, check=True
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    return result.stdout.strip()


def gitlink(repo: Path, path: str) -> str | None:
    """The submodule commit recorded in [repo]'s index (= HEAD unless a
    submodule bump is staged)."""
    if not (REPO_ROOT / repo / ".git").exists():
        return None
    out = git("-C", str(repo), "ls-files", "--stage", "--", path)
    if not out:
        return None
    mode, sha = out.split("\t", 1)[0].split()[:2]
    return sha if mode == "160000" else None


def submodules() -> list[tuple[str, str]]:
    text = read(Path(".gitmodules"))
    found = []
    for block in re.split(r"^\[submodule ", text, flags=re.MULTILINE)[1:]:
        path = re.search(r"^\s*path\s*=\s*(\S+)", block, flags=re.MULTILINE)
        url = re.search(r"^\s*url\s*=\s*(\S+)", block, flags=re.MULTILINE)
        if path and url:
            found.append((path.group(1), url.group(1)))
    return sorted(found)


def nested_submodules() -> list[tuple[str, str]]:
    """(parent repo relative to the engine's translations dir, path) pairs
    that fetch_native_deps.sh initialises inside mozilla/translations."""
    script = read(FETCH_SCRIPT).replace("\\\n", " ")
    pairs = []
    for match in re.finditer(
        r'^update\s+"\$\{?translations\}?([^"]*)"\s+(.+)$', script, flags=re.MULTILINE
    ):
        parent = match.group(1).lstrip("/")
        for path in match.group(2).split():
            pairs.append((parent, path))
    return pairs


def notices(native: Path = NATIVE) -> list[tuple[str, str, str]]:
    path = native / "THIRD_PARTY_NOTICES.md"
    if not (REPO_ROOT / path).is_file():
        return []
    rows = []
    for line in read(path).splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) == 3 and cells[0] not in ("Component", "---"):
            rows.append((cells[0], cells[1], cells[2]))
    return rows


def native_dir_of(directory: Path) -> Path:
    """The `native/` directory of the engine package [directory] is in."""
    for package in NATIVE_ENGINES:
        if directory.is_relative_to(package / "native"):
            return package / "native"
    return NATIVE


def notice_for(directory: Path) -> str | None:
    """The licence the engine's THIRD_PARTY_NOTICES.md gives for a checkout.
    Its "Where" column holds a path suffix (`marian-fork/src/3rd_party/ruy`);
    the mozilla/translations row is listed by its `inference` directory."""
    native = native_dir_of(directory)
    full = directory.relative_to(native).as_posix()
    for _, where, licence in notices(native):
        match = re.match(r"`([^`]+)`", where)
        if not match:
            continue
        suffix = match.group(1)
        if (
            full == suffix
            or full.endswith("/" + suffix)
            or suffix == f"{full}/inference"
        ):
            return licence
    return None


def native_licence(directory: Path) -> str:
    detected = (
        licence_in(REPO_ROOT / directory) if (REPO_ROOT / directory).is_dir() else None
    )
    noticed = notice_for(directory)
    if detected is None:
        return (
            f"{noticed} (notices; not checked out)"
            if noticed
            else "? (not checked out)"
        )
    if noticed is None:
        return f"{detected} (**not in THIRD_PARTY_NOTICES.md**)"
    if not noticed.startswith(detected):
        return f"{detected} (notices say: {noticed})"
    return detected


def native_section() -> list[str]:
    out = []
    for package, title in NATIVE_ENGINES.items():
        out += engine_section(package, title)
    return out


def engine_section(package: Path, title: str) -> list[str]:
    rows = []
    prefix = (package / "native").as_posix() + "/"
    for path, url in submodules():
        if not path.startswith(prefix):
            continue
        sha = gitlink(Path("."), path) or "?"
        rows.append(
            [
                f"`{path.split('/')[-1]}`",
                url,
                f"`{sha[:12]}`",
                native_licence(Path(path)),
                purpose(path),
            ]
        )
    if not rows:
        return []
    translations = NATIVE / "third_party" / "translations"
    for parent, path in nested_submodules() if package == ENGINE else []:
        parent_dir = translations / parent if parent else translations
        sha = gitlink(parent_dir, path) or "? (run fetch_native_deps.sh)"
        rel = (parent_dir / path).relative_to(translations).as_posix()
        rows.append(
            [
                f"`{path.split('/')[-1]}`",
                f"`translations/{rel}`",
                f"`{sha[:12]}`" if not sha.startswith("?") else sha,
                native_licence(parent_dir / path),
                purpose(path),
            ]
        )
    out = ["", f"### {title}: submodules", ""]
    out += table(["Component", "Source", "Commit", "Licence", "Why"], rows)
    return out


# --------------------------------------------------------------------------


def generate() -> str:
    lines = [BEGIN, ""]
    lines += pub_sections()
    lines += play_section()
    lines += native_section()
    lines += ["", END]
    return "\n".join(lines) + "\n"


def splice(document: str, block: str) -> str:
    start = document.find(BEGIN)
    end = document.find(END)
    if start < 0 or end < start:
        raise SystemExit(
            f"{DOC.relative_to(REPO_ROOT)}: no {BEGIN!r} ... {END!r} markers"
        )
    end += len(END)
    if document[end : end + 1] == "\n":
        end += 1
    return document[:start] + block + document[end:]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    group = parser.add_mutually_exclusive_group()
    group.add_argument(
        "--write", action="store_true", help="update docs/dependencies.md"
    )
    group.add_argument(
        "--check", action="store_true", help="fail if docs/dependencies.md is stale"
    )
    args = parser.parse_args()

    block = generate()
    if not (args.write or args.check):
        sys.stdout.write(block)
        return 0
    document = DOC.read_text(encoding="utf-8")
    updated = splice(document, block)
    if args.check:
        if updated != document:
            print(
                f"{DOC.relative_to(REPO_ROOT)} is out of date: run python3 tool/list_dependencies.py --write"
            )
            return 1
        return 0
    if updated != document:
        DOC.write_text(updated, encoding="utf-8")
        print(f"updated {DOC.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
