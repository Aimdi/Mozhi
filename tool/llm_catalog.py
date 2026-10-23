#!/usr/bin/env python3
"""Resolves and checks the catalogue of the on-device AI models
(packages/llama_engine/assets/models.json) from its sources
(tool/llm_catalog.json).

  python3 tool/llm_catalog.py resolve [--print]   # needs huggingface.co
  python3 tool/llm_catalog.py check               # needs huggingface.co
  python3 tool/llm_catalog.py validate            # offline

resolve   asks Hugging Face's API, for each model of the sources, for the
          commit its revision points at (/api/models/<repo>/revision/<rev>)
          and the files at that commit (/api/models/<repo>/tree/<commit>),
          takes the model's file (its `file`, else the one .gguf of its
          quantization, e.g. Q4_K_M) with its size and SHA-256 (the LFS
          object id) and writes models.json with URLs pinned to the commit
          (https://huggingface.co/<repo>/resolve/<commit>/<file>). A model
          with `candidates` takes the first repo that exists, is not gated
          or private and has the file. Sizes and checksums are never typed
          by hand. --print prints the catalogue instead of writing it (CI
          prints it to the log; it is then committed by hand).
          A model already in models.json keeps its file (name, URL, size,
          SHA-256) and provenance: a moved branch or another candidate repo
          never re-pins it silently. Its other fields follow the sources.
          The tool says CHANGED when Hugging Face now resolves another file
          (a GitHub warning in CI); --update <id> (repeatable) or
          --update-all takes the new one.
check     HEADs every URL of models.json (following redirects; nothing is
          downloaded) and compares the size and the SHA-256 Hugging Face
          sends (X-Linked-Etag) with the catalogue, because the app rejects
          any other file. An empty catalogue has nothing to check.
validate  checks the sources and models.json without the network: the same
          rules as the app's parser (LlamaCatalogModel.fromJson), language
          codes from the app's language catalogue.

Exit status: 0 on success; 1 when a model could not be resolved or a
served file differs; 2 for invalid sources or catalogues (or, for check, a
server that could not be reached after retries).
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
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SOURCES = REPO_ROOT / "tool/llm_catalog.json"
MODELS = REPO_ROOT / "packages/llama_engine/assets/models.json"
LANGUAGES = REPO_ROOT / "packages/translation_repository/lib/src/language_catalog.dart"
HUGGING_FACE = "https://huggingface.co"
USER_AGENT = "Mozhi model catalogue (+https://github.com/Aimdi/Mozhi)"
ATTEMPTS = 3
RETRY_DELAY = 2.0
TIMEOUT = 30
SCHEMA = 1

ROLES = ("translation", "assistant")
FAMILIES = ("hunyuan-dense", "gemma4", "qwen3")
PROMPT_PROFILES = ("auto", "general", "translateGemma", "hunyuanMt")
SAMPLING = {
    # key: (type, minimum, maximum)
    "temperature": (float, 0, 2),
    "topP": (float, 0, 1),
    "topK": (int, 0, 1000),
    "minP": (float, 0, 1),
    "repeatPenalty": (float, 0.5, 2),
}
# Keys of a source that are not copied into models.json.
SOURCE_ONLY = {"repo", "revision", "file", "candidates", "note"}
# The order of the keys of a models.json entry.
MODEL_KEYS = (
    "id",
    "name",
    "url",
    "size",
    "sha256",
    "role",
    "family",
    "promptProfile",
    "displayName",
    "parameters",
    "quantization",
    "contextSize",
    "minRamMb",
    "recommendedRamMb",
    "languages",
    "license",
    "licenseUrl",
    "sourceUrl",
    "sampling",
)

_ID = re.compile(r"^[a-z0-9][a-z0-9_.-]{0,47}$")
_NAME = re.compile(r"^[A-Za-z0-9._-]{1,200}$")
_REPO = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,95}/[A-Za-z0-9][A-Za-z0-9._-]{0,95}$")
_REVISION = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$")
_COMMIT = re.compile(r"^[0-9a-f]{40}$")
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_QUANTIZATION = re.compile(r"^[A-Za-z0-9_]{1,16}$")
_LICENSE = re.compile(r"^[A-Za-z0-9.+-]{1,64}$")
_LANGUAGE = re.compile(r"^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$")
_CONTROL = re.compile(r"[\x00-\x1f\x7f]")
_SHARD = re.compile(r"-\d{5}-of-\d{5}\.gguf$", re.IGNORECASE)
_LANGUAGE_CODE = re.compile(r"\bcode: '([^']+)'")


class CatalogError(Exception):
    """The sources or a catalogue break the rules of the app's parser."""


class ResolveError(Exception):
    """A model could not be resolved (no repo, no file, no checksum)."""


class NotFound(Exception):
    """Hugging Face answered 401, 403 or 404 (missing, gated or private)."""


# --- Validation ------------------------------------------------------------


def app_languages(path: Path = LANGUAGES) -> set[str]:
    """The language codes of the app's catalogue (`code: '...'` entries)."""
    try:
        codes = set(_LANGUAGE_CODE.findall(path.read_text(encoding="utf-8")))
    except OSError as error:
        raise CatalogError(f"cannot read {path}: {error}") from error
    if not codes:
        raise CatalogError(f"no language codes in {path}")
    return codes


def _https(value: object, what: str, insecure_ok: bool = False) -> str:
    url = urllib.parse.urlsplit(value) if isinstance(value, str) else None
    schemes = ("https", "http") if insecure_ok else ("https",)
    if (
        url is None
        or url.scheme not in schemes
        or not url.hostname
        or "@" in url.netloc
    ):
        raise CatalogError(f"{what} must be an https URL: {value!r}")
    return value  # type: ignore[return-value]


def _text(entry: dict, key: str, what: str, limit: int) -> str:
    value = entry.get(key)
    if not isinstance(value, str) or not value.strip():
        raise CatalogError(f"{what}: missing {key}")
    if len(value) > limit or _CONTROL.search(value):
        raise CatalogError(f"{what}: invalid {key}: {value!r}")
    return value


def _int(entry: dict, key: str, what: str) -> int:
    value = entry.get(key)
    if not isinstance(value, int) or isinstance(value, bool):
        raise CatalogError(f"{what}: invalid {key}: {value!r}")
    return value


def safe_file_name(name: object, what: str) -> str:
    if (
        not isinstance(name, str)
        or not _NAME.match(name)
        or name.startswith(".")
        or not name.lower().endswith(".gguf")
    ):
        raise CatalogError(f"{what}: unsafe file name (a .gguf file): {name!r}")
    return name


def validate_metadata(entry: dict, languages: set[str]) -> None:
    """Checks the fields a source and its models.json entry share, like
    LlamaCatalogModel.fromJson does."""
    model_id = entry.get("id")
    if not isinstance(model_id, str) or not _ID.match(model_id) or ".." in model_id:
        raise CatalogError(f"unsafe model id: {model_id!r}")
    what = model_id
    if entry.get("role") not in ROLES:
        raise CatalogError(f"{what}: unknown role {entry.get('role')!r}")
    if entry.get("family") not in FAMILIES:
        raise CatalogError(f"{what}: unknown family {entry.get('family')!r}")
    if entry.get("promptProfile") not in PROMPT_PROFILES:
        raise CatalogError(
            f"{what}: unknown prompt profile {entry.get('promptProfile')!r}"
        )
    _text(entry, "displayName", what, 64)
    _text(entry, "parameters", what, 32)
    quantization = entry.get("quantization")
    if not isinstance(quantization, str) or not _QUANTIZATION.match(quantization):
        raise CatalogError(f"{what}: invalid quantization")
    context = _int(entry, "contextSize", what)
    if not 256 <= context <= 131072:
        raise CatalogError(f"{what}: invalid contextSize {context}")
    minimum = _int(entry, "minRamMb", what)
    recommended = _int(entry, "recommendedRamMb", what)
    if minimum <= 0 or recommended < minimum:
        raise CatalogError(f"{what}: minRamMb must be > 0 and <= recommendedRamMb")
    codes = entry.get("languages", [])
    if not isinstance(codes, list):
        raise CatalogError(f"{what}: languages must be a list")
    for code in codes:
        if not isinstance(code, str) or not _LANGUAGE.match(code):
            raise CatalogError(f"{what}: invalid language code {code!r}")
        if code not in languages:
            raise CatalogError(f"{what}: {code!r} is not an app language code")
    if len(set(codes)) != len(codes):
        raise CatalogError(f"{what}: duplicate language codes")
    if entry["role"] == "translation" and not codes:
        raise CatalogError(f"{what}: a translation model needs languages")
    license_id = entry.get("license")
    if not isinstance(license_id, str) or not _LICENSE.match(license_id):
        raise CatalogError(f"{what}: invalid license {entry.get('license')!r}")
    _https(entry.get("licenseUrl"), f"{what}: licenseUrl")
    _https(entry.get("sourceUrl"), f"{what}: sourceUrl")
    sampling = entry.get("sampling", {})
    if not isinstance(sampling, dict):
        raise CatalogError(f"{what}: sampling must be an object")
    for key, value in sampling.items():
        if key not in SAMPLING:
            raise CatalogError(f"{what}: unknown sampling parameter {key!r}")
        kind, low, high = SAMPLING[key]
        number = isinstance(value, (int, float)) and not isinstance(value, bool)
        if kind is int and not isinstance(value, int):
            number = False
        if not number or not low <= value <= high:
            raise CatalogError(f"{what}: invalid sampling {key} {value!r}")


def candidates(source: dict) -> list[dict]:
    """The repos to try for [source], in order."""
    what = source.get("id")
    listed = source.get("candidates")
    single = {key: source[key] for key in ("repo", "revision", "file") if key in source}
    if listed is not None and single:
        raise CatalogError(f"{what}: give candidates or repo/revision/file, not both")
    if listed is None:
        listed = [single]
    if not isinstance(listed, list) or not listed:
        raise CatalogError(f"{what}: candidates must be a non-empty list")
    for candidate in listed:
        if not isinstance(candidate, dict):
            raise CatalogError(f"{what}: invalid candidate {candidate!r}")
        unknown = set(candidate) - {"repo", "revision", "file"}
        if unknown:
            raise CatalogError(f"{what}: unknown candidate keys {sorted(unknown)}")
        repo = candidate.get("repo")
        if not isinstance(repo, str) or not _REPO.match(repo) or ".." in repo:
            raise CatalogError(f"{what}: invalid repo {repo!r}")
        revision = candidate.get("revision")
        if (
            not isinstance(revision, str)
            or not _REVISION.match(revision)
            or ".." in revision
        ):
            raise CatalogError(f"{what}: invalid revision {revision!r}")
        safe_file_name(candidate.get("file"), f"{what} ({repo})")
    return listed


def validate_sources(sources: dict, languages: set[str]) -> list[dict]:
    """The models of the sources document, validated."""
    if not isinstance(sources, dict) or sources.get("schemaVersion") != SCHEMA:
        raise CatalogError("the sources must be a schemaVersion 1 object")
    models = sources.get("models")
    if not isinstance(models, list):
        raise CatalogError("the sources have no model list")
    ids = set()
    for source in models:
        if not isinstance(source, dict):
            raise CatalogError(f"invalid source {source!r}")
        validate_metadata(source, languages)
        candidates(source)
        if source["id"] in ids:
            raise CatalogError(f"duplicate model id {source['id']!r}")
        ids.add(source["id"])
        if "size" in source or "sha256" in source or "url" in source:
            raise CatalogError(
                f"{source['id']}: size, sha256 and url are resolved, never "
                "written in the sources"
            )
    return models


def validate_catalog(
    catalog: dict, languages: set[str], insecure_ok: bool = False
) -> list[dict]:
    """The models of a models.json document, validated like the app's
    parser (LlamaModelCatalog.parse); [insecure_ok] accepts `http` model
    URLs (a local test server)."""
    if not isinstance(catalog, dict) or catalog.get("schemaVersion") != SCHEMA:
        raise CatalogError("models.json must be a schemaVersion 1 object")
    models = catalog.get("models")
    if not isinstance(models, list):
        raise CatalogError("models.json has no model list")
    ids, names = set(), set()
    for model in models:
        if not isinstance(model, dict):
            raise CatalogError(f"invalid model {model!r}")
        validate_metadata(model, languages)
        what = model["id"]
        name = safe_file_name(model.get("name"), what)
        url = urllib.parse.urlsplit(
            _https(model.get("url"), f"{what}: url", insecure_ok)
        )
        if url.query or url.fragment or url.path.rsplit("/", 1)[-1] != name:
            raise CatalogError(f"{what}: the URL must end in {name}")
        size = _int(model, "size", what)
        if size <= 0:
            raise CatalogError(f"{what}: invalid size {size}")
        if not _SHA256.match(str(model.get("sha256", ""))):
            raise CatalogError(f"{what}: invalid SHA-256")
        if what in ids or name.lower() in names:
            raise CatalogError(f"duplicate model {what!r}")
        ids.add(what)
        names.add(name.lower())
    return models


# --- Hugging Face's API ------------------------------------------------------


def _request(url: str, method: str = "GET") -> tuple[bytes, dict[str, str]]:
    """The body and headers of [url]; retries server errors and failed
    connections. Raises NotFound for 401, 403 and 404."""
    last: Exception | None = None
    for attempt in range(ATTEMPTS):
        request = urllib.request.Request(
            url, method=method, headers={"User-Agent": USER_AGENT}
        )
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
                headers = {k.lower(): v for k, v in response.headers.items()}
                return response.read(), headers
        except urllib.error.HTTPError as error:
            if error.code in (401, 403, 404):
                raise NotFound(f"HTTP {error.code}") from error
            if error.code < 500:
                raise ResolveError(f"HTTP {error.code} for {url}") from error
            last = error
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            last = error
        if attempt + 1 < ATTEMPTS:
            time.sleep(RETRY_DELAY * (attempt + 1))
    raise ResolveError(f"{url}: {last}")


def _get_json(url: str) -> tuple[object, dict[str, str]]:
    body, headers = _request(url)
    try:
        return json.loads(body), headers
    except ValueError as error:
        raise ResolveError(f"{url}: not JSON") from error


def _next_link(headers: dict[str, str]) -> str | None:
    """The `rel="next"` URL of a Link header (the tree API pages)."""
    for part in headers.get("link", "").split(","):
        match = re.match(r'\s*<([^>]+)>\s*;\s*rel="?next"?', part)
        if match:
            return match.group(1)
    return None


def commit_of(endpoint: str, repo: str, revision: str) -> str:
    """The commit [revision] of [repo] points at. Raises NotFound for a
    missing, gated or private repo."""
    info, _ = _get_json(
        f"{endpoint}/api/models/{repo}/revision/"
        f"{urllib.parse.quote(revision, safe='')}"
    )
    if not isinstance(info, dict):
        raise ResolveError(f"{repo}@{revision}: unexpected answer")
    for flag in ("gated", "private", "disabled"):
        if info.get(flag):
            raise NotFound(f"{flag} ({info.get(flag)})")
    commit = info.get("sha")
    if not isinstance(commit, str) or not _COMMIT.match(commit):
        raise ResolveError(f"{repo}@{revision}: no commit in the answer")
    return commit


def files_at(endpoint: str, repo: str, commit: str) -> dict[str, dict]:
    """Every file of [repo] at [commit] by path (all pages)."""
    url: str | None = f"{endpoint}/api/models/{repo}/tree/{commit}?recursive=true"
    files: dict[str, dict] = {}
    pages = 0
    while url:
        pages += 1
        if pages > 100:
            raise ResolveError(f"{repo}: too many pages of files")
        listing, headers = _get_json(url)
        if not isinstance(listing, list):
            raise ResolveError(f"{repo}@{commit}: unexpected file list")
        for entry in listing:
            if isinstance(entry, dict) and entry.get("type") == "file":
                files[str(entry.get("path"))] = entry
        url = _next_link(headers)
        if url and url.startswith("/"):
            url = endpoint + url
    return files


def _quantized(name: str, quantization: str) -> bool:
    tag = re.escape(quantization.lower())
    return bool(re.search(rf"(?<![a-z0-9]){tag}(?![a-z0-9])", name.lower()))


def pick_file(files: dict[str, dict], wanted: str, quantization: str) -> str:
    """The path of the model's file among [files]: [wanted] (also in a
    folder or in another case), else the one .gguf of [quantization] (not
    a vision projector, not split into shards). Raises ResolveError for
    none or several."""
    if wanted in files:
        return wanted
    by_name = [path for path in files if path.rsplit("/", 1)[-1].lower() == wanted.lower()]
    if len(by_name) == 1:
        return by_name[0]
    matching = [
        path
        for path in sorted(files)
        if path.lower().endswith(".gguf")
        and not path.rsplit("/", 1)[-1].lower().startswith("mmproj")
        and _quantized(path.rsplit("/", 1)[-1], quantization)
    ]
    whole = [path for path in matching if not _SHARD.search(path)]
    if len(whole) == 1:
        return whole[0]
    if not whole and matching:
        raise ResolveError(f"the {quantization} file is split into shards: {matching}")
    if not whole:
        raise ResolveError(f"no {quantization} .gguf file (looked for {wanted})")
    raise ResolveError(f"several {quantization} .gguf files: {whole}")


def resolve_model(source: dict, endpoint: str) -> tuple[dict, str]:
    """The models.json entry of [source] and its provenance line."""
    problems = []
    for candidate in candidates(source):
        repo, revision = candidate["repo"], candidate["revision"]
        try:
            commit = commit_of(endpoint, repo, revision)
            files = files_at(endpoint, repo, commit)
            path = pick_file(files, candidate["file"], source["quantization"])
        except NotFound as error:
            problems.append(f"{repo}@{revision}: {error}")
            continue
        except ResolveError as error:
            problems.append(f"{repo}@{revision}: {error}")
            continue
        entry = files[path]
        lfs = entry.get("lfs") if isinstance(entry.get("lfs"), dict) else {}
        sha256 = str(lfs.get("oid", "")).removeprefix("sha256:")
        size = lfs.get("size", entry.get("size"))
        if not _SHA256.match(sha256):
            problems.append(f"{repo}@{commit}: {path} has no LFS SHA-256")
            continue
        if not isinstance(size, int) or size <= 0 or size != entry.get("size", size):
            problems.append(f"{repo}@{commit}: {path} has no valid size")
            continue
        name = path.rsplit("/", 1)[-1]
        try:
            safe_file_name(name, source["id"])
        except CatalogError as error:
            problems.append(f"{repo}@{commit}: {error}")
            continue
        model = {
            "id": source["id"],
            "name": name,
            "url": f"{endpoint}/{repo}/resolve/{commit}/{urllib.parse.quote(path)}",
            "size": size,
            "sha256": sha256,
        }
        for key in MODEL_KEYS:
            if key not in model and key in source and key not in SOURCE_ONLY:
                if key == "languages" and not source[key]:
                    continue
                model[key] = source[key]
        provenance = f"{source['id']}: {repo} at {commit} ({revision}), {path}"
        return model, provenance
    raise ResolveError(f"{source['id']}: " + "; ".join(problems))


def resolve(sources: list[dict], endpoint: str) -> tuple[dict, list[str]]:
    """The models.json document of [sources] and the models that failed."""
    models, provenance, failures = [], [], []
    for source in sources:
        try:
            model, line = resolve_model(source, endpoint)
        except ResolveError as error:
            failures.append(str(error))
            continue
        models.append(model)
        provenance.append(line)
    document = {
        "schemaVersion": SCHEMA,
        "_provenance": [
            "Written by tool/llm_catalog.py resolve from tool/llm_catalog.json: "
            "sizes and SHA-256 from Hugging Face's API (the LFS object ids of "
            "the files), URLs pinned to the commit. Never edit by hand.",
            *provenance,
        ],
        "models": models,
    }
    return document, failures


FILE_KEYS = ("name", "url", "size", "sha256")


def keep_committed(
    document: dict, committed: dict | None, update: set[str] | None
) -> tuple[dict, list[str]]:
    """[document] with the file of every model already in [committed] kept
    (its FILE_KEYS and provenance line), except the ids in [update] (None:
    all of them are updated); and one note per kept model that now resolves
    to another file."""
    if not committed or update is None:
        return document, []
    kept = {
        model["id"]: model
        for model in committed.get("models", [])
        if isinstance(model, dict) and isinstance(model.get("id"), str)
    }
    lines = {
        line.split(": ", 1)[0]: line
        for line in committed.get("_provenance", [])[1:]
        if isinstance(line, str) and ": " in line
    }
    models, notes = [], []
    for model in document["models"]:
        old = kept.get(model["id"])
        if old is None or model["id"] in update:
            models.append(model)
            continue
        if any(old.get(key) != model[key] for key in FILE_KEYS):
            notes.append(
                f"{model['id']}: kept {old.get('name')} (SHA-256 "
                f"{str(old.get('sha256'))[:12]}..., {old.get('url')}); Hugging "
                f"Face now resolves {model['name']} (SHA-256 "
                f"{model['sha256'][:12]}..., {model['url']}). --update "
                f"{model['id']} takes it."
            )
        models.append({**model, **{key: old[key] for key in FILE_KEYS if key in old}})
    provenance = [document["_provenance"][0]]
    for model, line in zip(document["models"], document["_provenance"][1:]):
        if model["id"] in kept and model["id"] not in update and model["id"] in lines:
            line = lines[model["id"]]
        provenance.append(line)
    return {**document, "_provenance": provenance, "models": models}, notes


def dumps(document: dict) -> str:
    return json.dumps(document, indent=2, ensure_ascii=False) + "\n"


# --- check -----------------------------------------------------------------


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):  # noqa: D102
        return None


class _KeepHead(urllib.request.HTTPRedirectHandler):
    """Follows redirects with HEAD: Python before 3.13 turns a redirected
    HEAD into a GET, which would start downloading the model."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D102
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is not None and req.get_method() == "HEAD":
            new.method = "HEAD"
        return new


def head(url: str) -> tuple[int | None, dict[str, str]]:
    """The final size (Content-Length after redirects) of [url] and the
    headers of the first answer (Hugging Face puts X-Linked-* there)."""
    request = urllib.request.Request(
        url, method="HEAD", headers={"User-Agent": USER_AGENT}
    )
    first: dict[str, str] = {}
    try:
        with urllib.request.build_opener(_NoRedirect).open(request, timeout=TIMEOUT) as r:
            first = {k.lower(): v for k, v in r.headers.items()}
    except urllib.error.HTTPError as error:
        if error.code not in (301, 302, 303, 307, 308):
            raise
        first = {k.lower(): v for k, v in error.headers.items()}
    opener = urllib.request.build_opener(_KeepHead)
    with opener.open(request, timeout=TIMEOUT) as response:
        length = response.headers.get("Content-Length")
    return (int(length) if length is not None else None), first


def check_file(model: dict) -> tuple[str, str]:
    """("ok" | "mismatch" | "unreachable", message) for one model."""
    name, url, size, sha256 = model["id"], model["url"], model["size"], model["sha256"]
    last_error = ""
    for attempt in range(ATTEMPTS):
        try:
            served, first = head(url)
        except urllib.error.HTTPError as error:
            if error.code in (401, 403, 404):
                return "mismatch", f"{name}: HTTP {error.code} at {url}"
            last_error = f"HTTP {error.code}"
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            last_error = str(error)
        else:
            served_sha256 = first.get("x-linked-etag", "").strip('"') or None
            if served_sha256 and served_sha256 != sha256:
                return "mismatch", (
                    f"{name}: the catalogue says sha256 {sha256}, the server "
                    f"{served_sha256} ({url})"
                )
            if served is None:
                linked = first.get("x-linked-size")
                served = int(linked) if linked else None
            if served != size:
                return "mismatch", (
                    f"{name}: the catalogue says {size} bytes, the server "
                    f"{served} ({url})"
                )
            checked = " and sha256" if served_sha256 else ""
            return "ok", f"{name}: {size} bytes{checked} match"
        if attempt + 1 < ATTEMPTS:
            time.sleep(RETRY_DELAY * (attempt + 1))
    return "unreachable", f"{name}: {last_error} ({url})"


# --- Command line ------------------------------------------------------------


def _load(path: Path) -> object:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise CatalogError(f"cannot read {path}: {error}") from error


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Resolve and check the on-device AI model catalogue (see "
        "the module docstring).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    commands = parser.add_subparsers(dest="command", required=True)
    resolve_parser = commands.add_parser("resolve", help="write models.json")
    resolve_parser.add_argument("--sources", type=Path, default=SOURCES)
    resolve_parser.add_argument("--out", type=Path, default=MODELS)
    resolve_parser.add_argument(
        "--print", action="store_true", help="print models.json, write nothing"
    )
    resolve_parser.add_argument(
        "--hf-endpoint",
        default=os.environ.get("HF_ENDPOINT", HUGGING_FACE),
        help="Hugging Face's address (tests use a local server)",
    )
    resolve_parser.add_argument("--languages", type=Path, default=LANGUAGES)
    resolve_parser.add_argument(
        "--update",
        action="append",
        default=[],
        metavar="ID",
        help="take the newly resolved file of this model (repeatable)",
    )
    resolve_parser.add_argument(
        "--update-all",
        action="store_true",
        help="take the newly resolved file of every model",
    )
    check_parser = commands.add_parser("check", help="HEAD every model URL")
    check_parser.add_argument("--catalog", type=Path, default=MODELS)
    validate_parser = commands.add_parser("validate", help="offline checks")
    validate_parser.add_argument("--sources", type=Path, default=SOURCES)
    validate_parser.add_argument("--catalog", type=Path, default=MODELS)
    validate_parser.add_argument("--languages", type=Path, default=LANGUAGES)
    args = parser.parse_args(argv)

    if args.command == "check":
        try:
            catalog = _load(args.catalog)
            if not isinstance(catalog, dict) or not isinstance(
                catalog.get("models"), list
            ):
                raise CatalogError(f"{args.catalog} has no model list")
            for model in catalog["models"]:
                if not isinstance(model, dict) or not all(
                    key in model for key in ("id", "url", "size", "sha256")
                ):
                    raise CatalogError(f"invalid model {model!r}")
        except CatalogError as error:
            print(f"error: {error}", file=sys.stderr)
            return 2
        models = catalog["models"]
        if not models:
            print("The catalogue lists no model yet: nothing to check.")
            return 0
        counts = {"ok": 0, "mismatch": 0, "unreachable": 0}
        for model in models:
            status, message = check_file(model)
            counts[status] += 1
            print(f"{status.upper():12} {message}")
        print(
            f"{counts['ok']} of {len(models)} match, {counts['mismatch']} "
            f"differ, {counts['unreachable']} unreachable"
        )
        if counts["mismatch"]:
            return 1
        return 2 if counts["unreachable"] else 0

    try:
        languages = app_languages(args.languages)
        sources = validate_sources(_load(args.sources), languages)
        if args.command == "validate":
            models = validate_catalog(_load(args.catalog), languages)
            listed = {source["id"] for source in sources}
            for model in models:
                if model["id"] not in listed:
                    raise CatalogError(f"{model['id']} is not in the sources")
            print(
                f"{len(sources)} source(s) and {len(models)} catalogue model(s) "
                "are valid"
            )
            return 0
    except CatalogError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    committed = None
    if args.out.exists():
        try:
            committed = _load(args.out)
        except CatalogError as error:
            print(f"error: {error}", file=sys.stderr)
            return 2
        if not isinstance(committed, dict):
            print(f"error: {args.out} is not a catalogue", file=sys.stderr)
            return 2

    endpoint = args.hf_endpoint.rstrip("/")
    document, failures = resolve(sources, endpoint)
    document, notes = keep_committed(
        document, committed, None if args.update_all else set(args.update)
    )
    try:
        validate_catalog(document, languages, insecure_ok=endpoint != HUGGING_FACE)
    except CatalogError as error:
        # A file name or answer the app would refuse.
        print(f"error: {error}", file=sys.stderr)
        return 2
    for note in notes:
        print(f"CHANGED {note}", file=sys.stderr)
    for failure in failures:
        print(f"FAILED {failure}", file=sys.stderr)
    if args.print:
        sys.stdout.write(dumps(document))
    elif not failures:
        args.out.write_text(dumps(document), encoding="utf-8")
        print(f"wrote {len(document['models'])} model(s) to {args.out}")
    if os.environ.get("GITHUB_ACTIONS") == "true":
        # Workflow commands are read from stdout, after the catalogue.
        for note in notes:
            print(f"::warning::On-device AI catalogue: {note}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
