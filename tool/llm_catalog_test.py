#!/usr/bin/env python3
"""Tests tool/llm_catalog.py against a local stand-in for Hugging Face's API
(no network).

  python3 tool/llm_catalog_test.py
"""

from __future__ import annotations

import copy
import hashlib
import io
import json
import os
import sys
import tempfile
import threading
import unittest
import urllib.parse
from contextlib import redirect_stderr, redirect_stdout
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock

TOOL = Path(__file__).resolve().parent / "llm_catalog.py"
sys.path.insert(0, str(TOOL.parent))

import llm_catalog as catalog  # noqa: E402

catalog.RETRY_DELAY = 0.01

COMMIT_A = "a" * 40
COMMIT_B = "b" * 40


class _Hub:
    """Serves repos like Hugging Face: /api/models/<repo>/revision/<rev>,
    /api/models/<repo>/tree/<commit> (in pages of [page_size]) and
    /<repo>/resolve/<commit>/<path> (HEAD redirects to /cdn/<sha256>)."""

    def __init__(self) -> None:
        # repo -> {"commit": sha, "files": {path: bytes}, "flags": {...}}
        self.repos: dict[str, dict] = {}
        self.requests: list[tuple[str, str]] = []
        self.page_size = 2
        self.status: dict[str, int] = {}
        self.etag: dict[str, str] = {}
        self.length: dict[str, int] = {}
        hub = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):  # noqa: D102
                pass

            def _json(self, value, headers=None):
                body = json.dumps(value).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                for key, header in (headers or {}).items():
                    self.send_header(key, header)
                self.end_headers()
                self.wfile.write(body)

            def _empty(self, code, headers=None):
                self.send_response(code)
                for key, header in (headers or {}).items():
                    self.send_header(key, header)
                self.send_header("Content-Length", "0")
                self.end_headers()

            def do_GET(self):  # noqa: N802, D102
                hub.requests.append(("GET", self.path))
                url = urllib.parse.urlsplit(self.path)
                path = urllib.parse.unquote(url.path)
                if path in hub.status:
                    return self._empty(hub.status[path])
                parts = path.strip("/").split("/")
                if parts[:2] != ["api", "models"] or len(parts) < 6:
                    return self._empty(404)
                repo = "/".join(parts[2:4])
                found = hub.repos.get(repo)
                if found is None:
                    return self._empty(401)
                if parts[4] == "revision":
                    if "/".join(parts[5:]) not in ("main", found["commit"]):
                        return self._empty(404)
                    return self._json({"id": repo, "sha": found["commit"], **found["flags"]})
                if parts[4] == "tree" and parts[5] == found["commit"]:
                    query = urllib.parse.parse_qs(url.query)
                    if query.get("recursive") != ["true"]:
                        return self._empty(400)
                    entries = [
                        {"type": "directory", "oid": "0" * 40, "path": "docs", "size": 0}
                    ]
                    for name, data in sorted(found["files"].items()):
                        entry = {"type": "file", "oid": "1" * 40, "path": name, "size": len(data)}
                        if name.endswith(".gguf"):
                            entry["lfs"] = {
                                "oid": hashlib.sha256(data).hexdigest(),
                                "size": len(data),
                                "pointerSize": 134,
                            }
                        entries.append(entry)
                    start = int(query.get("cursor", ["0"])[0])
                    page = entries[start : start + hub.page_size]
                    headers = {}
                    if start + hub.page_size < len(entries):
                        headers["Link"] = (
                            f"</api/models/{repo}/tree/{found['commit']}?recursive=true"
                            f"&cursor={start + hub.page_size}>; rel=\"next\""
                        )
                    return self._json(page, headers)
                return self._empty(404)

            def do_HEAD(self):  # noqa: N802, D102
                hub.requests.append(("HEAD", self.path))
                path = urllib.parse.unquote(urllib.parse.urlsplit(self.path).path)
                if path in hub.status:
                    return self._empty(hub.status[path])
                parts = path.strip("/").split("/")
                if parts[0] == "cdn":
                    data = hub.blob(parts[1])
                    if data is None:
                        return self._empty(404)
                    self.send_response(200)
                    self.send_header(
                        "Content-Length", str(hub.length.get(parts[1], len(data)))
                    )
                    self.end_headers()
                    return None
                if len(parts) < 5 or parts[2] != "resolve":
                    return self._empty(404)
                found = hub.repos.get("/".join(parts[:2]))
                file = "/".join(parts[4:])
                if found is None or parts[3] != found["commit"] or file not in found["files"]:
                    return self._empty(404)
                digest = hashlib.sha256(found["files"][file]).hexdigest()
                return self._empty(
                    302,
                    {
                        "Location": f"/cdn/{digest}",
                        "X-Linked-Etag": f'"{hub.etag.get(file, digest)}"',
                        "X-Linked-Size": str(len(found["files"][file])),
                    },
                )

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.base = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def blob(self, digest: str) -> bytes | None:
        for repo in self.repos.values():
            for data in repo["files"].values():
                if hashlib.sha256(data).hexdigest() == digest:
                    return data
        return None

    def add(self, repo: str, files: dict[str, bytes], commit: str = COMMIT_A, **flags):
        self.repos[repo] = {"commit": commit, "files": files, "flags": flags}

    def close(self) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()


def _sources() -> dict:
    """The real sources, so their metadata is what the tests resolve."""
    return json.loads(catalog.SOURCES.read_text(encoding="utf-8"))


class LlmCatalogTest(unittest.TestCase):
    def setUp(self) -> None:
        self.hub = _Hub()
        self.addCleanup(self.hub.close)
        self.tmp = Path(tempfile.mkdtemp(prefix="llm_catalog_"))
        self.sources = _sources()
        self.hy = b"hy-mt2 weights " * 50
        self.gemma = b"gemma weights " * 70
        self.qwen = b"qwen weights " * 60
        self.hub.add(
            "tencent/Hy-MT2-1.8B-GGUF",
            {
                "Hy-MT2-1.8B-Q4_K_M.gguf": self.hy,
                "Hy-MT2-1.8B-Q8_0.gguf": b"q8",
                "README.md": b"# Hy-MT2",
            },
        )
        # No official Gemma GGUF repo: ggml-org's is the first that exists.
        self.hub.add(
            "ggml-org/gemma-4-E2B-it-GGUF",
            {
                "gemma-4-E2B-it-Q4_K_M.gguf": self.gemma,
                "mmproj-gemma-4-E2B-it-Q4_K_M.gguf": b"vision",
            },
            commit=COMMIT_B,
        )
        # Qwen's own repo has no Q4_K_M file: the next candidate has it.
        self.hub.add("Qwen/Qwen3-1.7B-GGUF", {"Qwen3-1.7B-Q8_0.gguf": b"q8"})
        self.hub.add(
            "ggml-org/Qwen3-1.7B-GGUF", {"Qwen3-1.7B-Q4_K_M.gguf": self.qwen}
        )
        self.write_sources()

    def write_sources(self) -> None:
        (self.tmp / "sources.json").write_text(json.dumps(self.sources))

    def run_tool(self, *args: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = catalog.main(list(args))
        return code, out.getvalue(), err.getvalue()

    def resolve(self, *extra: str) -> tuple[int, str, str]:
        return self.run_tool(
            "resolve",
            "--sources",
            str(self.tmp / "sources.json"),
            "--out",
            str(self.tmp / "models.json"),
            "--hf-endpoint",
            self.hub.base,
            *extra,
        )

    def resolved(self) -> dict:
        return json.loads((self.tmp / "models.json").read_text())

    def test_resolves_every_model_pinned_to_its_commit(self) -> None:
        code, out, err = self.resolve()
        self.assertEqual(code, 0, err)
        self.assertIn("wrote 3 model(s)", out)
        document = self.resolved()
        self.assertEqual(document["schemaVersion"], 1)
        models = {model["id"]: model for model in document["models"]}
        self.assertEqual(list(models), ["hy-mt2-1.8b-q4", "gemma-4-e2b-q4", "qwen3-1.7b-q4"])

        hy = models["hy-mt2-1.8b-q4"]
        self.assertEqual(hy["name"], "Hy-MT2-1.8B-Q4_K_M.gguf")
        self.assertEqual(
            hy["url"],
            f"{self.hub.base}/tencent/Hy-MT2-1.8B-GGUF/resolve/{COMMIT_A}/"
            "Hy-MT2-1.8B-Q4_K_M.gguf",
        )
        self.assertEqual(hy["size"], len(self.hy))
        self.assertEqual(hy["sha256"], hashlib.sha256(self.hy).hexdigest())
        self.assertEqual(hy["role"], "translation")
        self.assertEqual(len(hy["languages"]), 38)
        self.assertEqual(hy["sampling"]["topK"], 20)
        self.assertEqual(list(hy)[: len(catalog.MODEL_KEYS)], list(catalog.MODEL_KEYS))
        for key in ("repo", "revision", "file", "candidates", "note"):
            self.assertNotIn(key, hy)

        gemma = models["gemma-4-e2b-q4"]
        self.assertIn(f"/ggml-org/gemma-4-E2B-it-GGUF/resolve/{COMMIT_B}/", gemma["url"])
        self.assertEqual(gemma["sha256"], hashlib.sha256(self.gemma).hexdigest())
        self.assertNotIn("languages", gemma)
        self.assertIn("/ggml-org/Qwen3-1.7B-GGUF/", models["qwen3-1.7b-q4"]["url"])

        provenance = document["_provenance"]
        self.assertIn("never edit by hand", provenance[0].lower())
        self.assertIn(
            f"hy-mt2-1.8b-q4: tencent/Hy-MT2-1.8B-GGUF at {COMMIT_A} (main), "
            "Hy-MT2-1.8B-Q4_K_M.gguf",
            provenance,
        )
        # The tree API was read page by page.
        trees = [path for method, path in self.hub.requests if "/tree/" in path]
        self.assertTrue(any("cursor=2" in path for path in trees), trees)

    def test_print_writes_nothing(self) -> None:
        code, out, _ = self.resolve("--print")
        self.assertEqual(code, 0)
        self.assertEqual(len(json.loads(out)["models"]), 3)
        self.assertFalse((self.tmp / "models.json").exists())

    def test_keeps_the_committed_files_until_updated(self) -> None:
        code, _, err = self.resolve()
        self.assertEqual(code, 0, err)
        first = self.resolved()
        # Upstream moves on: new weights at a new commit.
        self.hub.add(
            "tencent/Hy-MT2-1.8B-GGUF",
            {"Hy-MT2-1.8B-Q4_K_M.gguf": b"retrained " * 40},
            commit=COMMIT_B,
        )
        self.sources["models"][0]["displayName"] = "Hy-MT2 1.8B (new name)"
        self.write_sources()

        code, out, err = self.resolve()
        self.assertEqual(code, 0, err)
        second = self.resolved()
        hy_before, hy_after = first["models"][0], second["models"][0]
        for key in catalog.FILE_KEYS:
            self.assertEqual(hy_after[key], hy_before[key], key)
        # The other fields follow the sources.
        self.assertEqual(hy_after["displayName"], "Hy-MT2 1.8B (new name)")
        self.assertEqual(second["_provenance"], first["_provenance"])
        self.assertEqual(second["models"][1:], first["models"][1:])
        self.assertIn("CHANGED hy-mt2-1.8b-q4: kept Hy-MT2-1.8B-Q4_K_M.gguf", err)
        self.assertIn("--update hy-mt2-1.8b-q4 takes it", err)
        self.assertEqual(err.count("CHANGED"), 1, err)
        self.assertNotIn("::warning::", out)

        # --print says the same and keeps the files too.
        code, out, err = self.resolve("--print")
        self.assertEqual(code, 0, err)
        self.assertEqual(json.loads(out)["models"][0]["sha256"], hy_before["sha256"])
        self.assertIn("CHANGED hy-mt2-1.8b-q4", err)

        # --update takes the new file of that model only.
        code, _, err = self.resolve("--update", "hy-mt2-1.8b-q4")
        self.assertEqual(code, 0, err)
        third = self.resolved()
        hy = third["models"][0]
        self.assertEqual(hy["sha256"], hashlib.sha256(b"retrained " * 40).hexdigest())
        self.assertIn(f"/resolve/{COMMIT_B}/", hy["url"])
        self.assertIn(
            f"hy-mt2-1.8b-q4: tencent/Hy-MT2-1.8B-GGUF at {COMMIT_B}",
            third["_provenance"][1],
        )
        self.assertNotIn("CHANGED", err)

    def test_update_all_and_github_warnings(self) -> None:
        code, _, err = self.resolve()
        self.assertEqual(code, 0, err)
        self.hub.add(
            "ggml-org/Qwen3-1.7B-GGUF",
            {"Qwen3-1.7B-Q4_K_M.gguf": b"qwen again " * 30},
            commit=COMMIT_B,
        )
        with mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "true"}):
            code, out, err = self.resolve("--print")
        self.assertEqual(code, 0, err)
        document, _, warnings = out.partition("\n}\n")
        self.assertEqual(
            json.loads(document + "\n}")["models"][2]["sha256"],
            self.resolved()["models"][2]["sha256"],
        )
        self.assertIn("::warning::On-device AI catalogue: qwen3-1.7b-q4: kept", warnings)

        code, _, err = self.resolve("--update-all")
        self.assertEqual(code, 0, err)
        self.assertEqual(
            self.resolved()["models"][2]["sha256"],
            hashlib.sha256(b"qwen again " * 30).hexdigest(),
        )
        self.assertNotIn("CHANGED", err)

    def test_refuses_an_unreadable_committed_catalogue(self) -> None:
        (self.tmp / "models.json").write_text("{not json")
        code, _, err = self.resolve()
        self.assertEqual(code, 2)
        self.assertIn("cannot read", err)
        (self.tmp / "models.json").write_text("[]")
        code, _, err = self.resolve()
        self.assertEqual(code, 2)
        self.assertIn("is not a catalogue", err)

    def test_picks_the_quantization_when_the_name_differs(self) -> None:
        self.hub.add(
            "tencent/Hy-MT2-1.8B-GGUF",
            {"quants/hy-mt2-1.8b-q4_k_m.gguf": self.hy, "hy-mt2-1.8b-q2_k.gguf": b"x"},
        )
        code, _, err = self.resolve()
        self.assertEqual(code, 0, err)
        hy = self.resolved()["models"][0]
        self.assertEqual(hy["name"], "hy-mt2-1.8b-q4_k_m.gguf")
        self.assertTrue(hy["url"].endswith(f"/resolve/{COMMIT_A}/quants/hy-mt2-1.8b-q4_k_m.gguf"))

    def test_fails_loudly_without_the_quantization(self) -> None:
        self.hub.add("tencent/Hy-MT2-1.8B-GGUF", {"Hy-MT2-1.8B-Q8_0.gguf": b"x"})
        code, out, err = self.resolve("--print")
        self.assertEqual(code, 1)
        self.assertIn("FAILED hy-mt2-1.8b-q4", err)
        self.assertIn("no Q4_K_M .gguf file", err)
        # The other models are still printed (for the log).
        self.assertEqual(len(json.loads(out)["models"]), 2)
        code, _, _ = self.resolve()
        self.assertEqual(code, 1)
        self.assertFalse((self.tmp / "models.json").exists(), "nothing written")

    def test_refuses_ambiguous_or_split_files(self) -> None:
        self.hub.add(
            "tencent/Hy-MT2-1.8B-GGUF",
            {"a-Q4_K_M.gguf": b"1", "b-Q4_K_M.gguf": b"2"},
        )
        code, _, err = self.resolve()
        self.assertEqual(code, 1)
        self.assertIn("several Q4_K_M .gguf files", err)

        self.hub.add(
            "tencent/Hy-MT2-1.8B-GGUF",
            {
                "x-Q4_K_M-00001-of-00002.gguf": b"1",
                "x-Q4_K_M-00002-of-00002.gguf": b"2",
            },
        )
        code, _, err = self.resolve()
        self.assertEqual(code, 1)
        self.assertIn("split into shards", err)

    def test_skips_gated_and_missing_candidates(self) -> None:
        self.hub.add(
            "google/gemma-4-E2B-it-GGUF",
            {"gemma-4-E2B-it-Q4_K_M.gguf": b"gated weights"},
            gated="manual",
        )
        code, _, err = self.resolve()
        self.assertEqual(code, 0, err)
        gemma = self.resolved()["models"][1]
        self.assertIn("/ggml-org/", gemma["url"])

        del self.hub.repos["ggml-org/gemma-4-E2B-it-GGUF"]
        code, _, err = self.resolve()
        self.assertEqual(code, 1)
        self.assertIn("google/gemma-4-E2B-it-GGUF@main: gated (manual)", err)
        self.assertIn("ggml-org/gemma-4-E2B-it-GGUF@main: HTTP 401", err)
        self.assertIn("unsloth/gemma-4-E2B-it-GGUF@main: HTTP 401", err)

    def test_resolves_a_pinned_revision(self) -> None:
        self.sources["models"][0]["revision"] = COMMIT_A
        self.write_sources()
        code, _, err = self.resolve()
        self.assertEqual(code, 0, err)
        revisions = [path for _, path in self.hub.requests if "/revision/" in path]
        self.assertIn(f"/api/models/tencent/Hy-MT2-1.8B-GGUF/revision/{COMMIT_A}", revisions)

        self.sources["models"][0]["revision"] = "v2"
        self.write_sources()
        code, _, err = self.resolve()
        self.assertEqual(code, 1)
        self.assertIn("tencent/Hy-MT2-1.8B-GGUF@v2: HTTP 404", err)

    def test_reports_server_errors_after_retries(self) -> None:
        path = "/api/models/tencent/Hy-MT2-1.8B-GGUF/revision/main"
        self.hub.status[path] = 503
        code, _, err = self.resolve()
        self.assertEqual(code, 1)
        self.assertIn("HTTP Error 503", err)
        self.assertEqual(
            [p for _, p in self.hub.requests].count(path), catalog.ATTEMPTS
        )
        self.hub.status[path] = 400
        code, _, err = self.resolve()
        self.assertEqual(code, 1)
        self.assertIn("HTTP 400", err)

    def test_rejects_files_without_a_checksum(self) -> None:
        self.hub.add("tencent/Hy-MT2-1.8B-GGUF", {"Hy-MT2-1.8B-Q4_K_M.gguf": self.hy})
        original = catalog.files_at

        def without_lfs(endpoint, repo, commit):
            files = original(endpoint, repo, commit)
            for entry in files.values():
                entry.pop("lfs", None)
            return files

        catalog.files_at = without_lfs
        self.addCleanup(setattr, catalog, "files_at", original)
        code, _, err = self.resolve()
        self.assertEqual(code, 1)
        self.assertIn("has no LFS SHA-256", err)

    def test_check_compares_sizes_and_checksums(self) -> None:
        self.assertEqual(self.resolve()[0], 0)
        models = str(self.tmp / "models.json")
        code, out, _ = self.run_tool("check", "--catalog", models)
        self.assertEqual(code, 0, out)
        self.assertIn("3 of 3 match", out)
        self.assertIn("OK           hy-mt2-1.8b-q4", out)
        self.assertIn("and sha256 match", out)

        self.hub.etag["Hy-MT2-1.8B-Q4_K_M.gguf"] = "0" * 64
        code, out, _ = self.run_tool("check", "--catalog", models)
        self.assertEqual(code, 1)
        self.assertIn("MISMATCH     hy-mt2-1.8b-q4: the catalogue says sha256", out)

        self.hub.etag.clear()
        self.hub.length[hashlib.sha256(self.qwen).hexdigest()] = 1
        code, out, _ = self.run_tool("check", "--catalog", models)
        self.assertEqual(code, 1)
        self.assertIn("qwen3-1.7b-q4: the catalogue says", out)

        self.hub.length.clear()
        del self.hub.repos["tencent/Hy-MT2-1.8B-GGUF"]
        code, out, _ = self.run_tool("check", "--catalog", models)
        self.assertEqual(code, 1)
        self.assertIn("hy-mt2-1.8b-q4: HTTP 404", out)

    def test_check_reports_an_unreachable_server(self) -> None:
        self.assertEqual(self.resolve()[0], 0)
        document = self.resolved()
        for model in document["models"]:
            path = urllib.parse.urlsplit(model["url"]).path
            self.hub.status[path] = 502
        (self.tmp / "models.json").write_text(json.dumps(document))
        code, out, _ = self.run_tool("check", "--catalog", str(self.tmp / "models.json"))
        self.assertEqual(code, 2)
        self.assertIn("3 unreachable", out)

    def test_check_an_empty_catalogue(self) -> None:
        empty = self.tmp / "empty.json"
        empty.write_text(json.dumps({"schemaVersion": 1, "models": []}))
        code, out, _ = self.run_tool("check", "--catalog", str(empty))
        self.assertEqual(code, 0)
        self.assertIn("nothing to check", out)
        empty.write_text("{")
        self.assertEqual(self.run_tool("check", "--catalog", str(empty))[0], 2)
        empty.write_text(json.dumps({"models": [{"id": "x"}]}))
        self.assertEqual(self.run_tool("check", "--catalog", str(empty))[0], 2)

    def test_the_repository_files_are_valid(self) -> None:
        code, out, err = self.run_tool("validate")
        self.assertEqual(code, 0, err)
        self.assertIn("3 source(s)", out)
        bundled = json.loads(catalog.MODELS.read_text(encoding="utf-8"))
        self.assertIsInstance(bundled["models"], list)
        hy = self.sources["models"][0]
        # The 33 languages of the Hy-MT2 README and its 5 variants, as app codes.
        self.assertEqual(len(hy["languages"]), 38)
        for code_ in ("zh-CN", "zh-TW", "yue", "tl", "he", "bo", "ug"):
            self.assertIn(code_, hy["languages"])

    def test_validate_checks_a_resolved_catalogue(self) -> None:
        self.assertEqual(self.resolve()[0], 0)
        document = self.resolved()
        for model in document["models"]:
            model["url"] = model["url"].replace(self.hub.base, catalog.HUGGING_FACE)
        good = self.tmp / "good.json"
        good.write_text(json.dumps(document))
        args = ("validate", "--sources", str(self.tmp / "sources.json"), "--catalog", str(good))
        self.assertEqual(self.run_tool(*args)[0], 0)

        cases = {
            "http url": lambda m: m.update(url=m["url"].replace("https", "http")),
            "url naming another file": lambda m: m.update(url=m["url"] + "x"),
            "bad size": lambda m: m.update(size=0),
            "bad sha256": lambda m: m.update(sha256="A" * 64),
            "unsafe name": lambda m: m.update(name="../x.gguf"),
            "not in the sources": lambda m: m.update(id="other"),
        }
        for name, change in cases.items():
            with self.subTest(name):
                broken = copy.deepcopy(document)
                change(broken["models"][0])
                path = self.tmp / "broken.json"
                path.write_text(json.dumps(broken))
                code, _, err = self.run_tool(
                    "validate", "--sources", str(self.tmp / "sources.json"), "--catalog", str(path)
                )
                self.assertEqual(code, 2, name)
                self.assertIn("error:", err)
        duplicate = copy.deepcopy(document)
        duplicate["models"].append(copy.deepcopy(duplicate["models"][0]))
        good.write_text(json.dumps(duplicate))
        self.assertEqual(self.run_tool(*args)[0], 2)

    def test_refuses_invalid_sources(self) -> None:
        def model(index: int = 0):
            return self.sources["models"][index]

        cases = {
            "unsafe id": lambda: model().update(id="../x"),
            "unknown role": lambda: model().update(role="chat"),
            "unknown family": lambda: model().update(family="llama"),
            "unknown profile": lambda: model().update(promptProfile="chatml"),
            "missing display name": lambda: model().pop("displayName"),
            "bad quantization": lambda: model().update(quantization=None),
            "bad context": lambda: model().update(contextSize=10),
            "context not an int": lambda: model().update(contextSize="4096"),
            "memory out of order": lambda: model().update(recommendedRamMb=1),
            "unknown language": lambda: model().update(languages=["xx-YY"]),
            "bad language": lambda: model().update(languages=["EN"]),
            "languages not a list": lambda: model().update(languages="en"),
            "duplicate language": lambda: model().update(languages=["en", "en"]),
            "no languages": lambda: model().update(languages=[]),
            "bad license": lambda: model().update(license="Apache 2.0"),
            "http source": lambda: model().update(sourceUrl="http://example.org"),
            "sampling not an object": lambda: model().update(sampling=1),
            "unknown sampling": lambda: model().update(sampling={"top_p": 1}),
            "sampling out of range": lambda: model().update(sampling={"topP": 2}),
            "topK not an int": lambda: model().update(sampling={"topK": 1.5}),
            "both repo and candidates": lambda: model(1).update(repo="a/b"),
            "empty candidates": lambda: model(1).update(candidates=[]),
            "candidate not an object": lambda: model(1).update(candidates=["x"]),
            "unknown candidate key": lambda: model(1)["candidates"][0].update(x=1),
            "bad repo": lambda: model().update(repo="no-owner"),
            "bad revision": lambda: model().update(revision="../main"),
            "unsafe file": lambda: model().update(file="x.bin"),
            "resolved fields": lambda: model().update(size=1),
            "duplicate id": lambda: model(2).update(id=model()["id"]),
            "source not an object": lambda: self.sources["models"].append("x"),
            "no model list": lambda: self.sources.update(models={}),
            "unknown schema": lambda: self.sources.update(schemaVersion=2),
        }
        original = copy.deepcopy(self.sources)
        for name, change in cases.items():
            with self.subTest(name):
                self.sources = copy.deepcopy(original)
                change()
                self.write_sources()
                code, _, err = self.resolve()
                self.assertEqual(code, 2, name)
                self.assertIn("error:", err)
        (self.tmp / "sources.json").write_text("{not json")
        self.assertEqual(self.resolve()[0], 2)
        missing = self.tmp / "missing.dart"
        code, _, err = self.run_tool("validate", "--languages", str(missing))
        self.assertEqual(code, 2)
        empty = self.tmp / "empty.dart"
        empty.write_text("// no languages")
        self.assertEqual(self.run_tool("validate", "--languages", str(empty))[0], 2)

    def test_next_link(self) -> None:
        self.assertIsNone(catalog._next_link({}))
        self.assertEqual(
            catalog._next_link({"link": '<https://x/a?cursor=1>; rel="next"'}),
            "https://x/a?cursor=1",
        )
        self.assertIsNone(catalog._next_link({"link": '<https://x/a>; rel="prev"'}))


if __name__ == "__main__":
    unittest.main()
