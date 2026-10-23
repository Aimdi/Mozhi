#!/usr/bin/env python3
"""Tests tool/whisper_catalog.py against a local fixture server that
answers like Hugging Face (no network).

  python3 tool/whisper_catalog_test.py
"""

from __future__ import annotations

import hashlib
import io
import json
import sys
import tempfile
import threading
import unittest
from contextlib import redirect_stderr, redirect_stdout
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

TOOL = Path(__file__).resolve().parent / "whisper_catalog.py"
sys.path.insert(0, str(TOOL.parent))

import whisper_catalog as catalog  # noqa: E402

catalog.RETRY_DELAY = 0.01

REPOSITORY = catalog.REPOSITORY
COMMIT = "0123456789abcdef0123456789abcdef01234567"
FILES = {
    "ggml-base-q5_1.bin": b"base q5_1 " * 300,
    "ggml-small-q5_1.bin": b"small q5_1 " * 500,
    "ggml-large-v3-turbo-q5_0.bin": b"turbo q5_0 " * 700,
}


def _sha1(data: bytes) -> str:
    return hashlib.sha1(data).hexdigest()


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class _HuggingFace:
    """Serves the revision, tree and resolve endpoints for [files]; a
    resolve answers with a redirect to the file (like the CDN). [tree]
    overrides listed entries; [fail] answers paths with a status once."""

    def __init__(self, files: dict[str, bytes]) -> None:
        self.files = dict(files)
        self.tree: dict[str, dict] = {}
        self.served: dict[str, bytes] = {}
        self.fail: dict[str, int] = {}
        self.requests: list[str] = []
        server = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):  # noqa: D102
                pass

            def _send(self, status: int, body: bytes = b"", headers=None):
                self.send_response(status)
                for key, value in (headers or {}).items():
                    self.send_header(key, value)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):  # noqa: N802, D102
                path = self.path
                server.requests.append(path)
                if path in server.fail:
                    self._send(server.fail.pop(path))
                    return
                if path == f"/api/models/{REPOSITORY}/revision/main":
                    self._send(200, json.dumps({"sha": COMMIT}).encode())
                    return
                if path == f"/api/models/{REPOSITORY}/tree/{COMMIT}":
                    entries = [
                        {"type": "file", "path": ".gitattributes", "size": 1477},
                    ]
                    for name, data in server.files.items():
                        entries.append(
                            server.tree.get(
                                name,
                                {
                                    "type": "file",
                                    "oid": _sha1(b"pointer " + name.encode()),
                                    "size": len(data),
                                    "path": name,
                                    "lfs": {
                                        "oid": _sha256(data),
                                        "size": len(data),
                                        "pointerSize": 134,
                                    },
                                },
                            )
                        )
                    self._send(200, json.dumps(entries).encode())
                    return
                prefix = f"/{REPOSITORY}/resolve/{COMMIT}/"
                if path.startswith(prefix) and path[len(prefix) :] in server.files:
                    name = path[len(prefix) :]
                    self._send(302, headers={"Location": f"/cdn/{name}"})
                    return
                if path.startswith("/cdn/"):
                    name = path[len("/cdn/") :]
                    body = server.served.get(name, server.files.get(name))
                    if body is not None:
                        self._send(200, body)
                        return
                self._send(404)

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.base = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()


def _run(*args: str) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        status = catalog.main(list(args))
    return status, out.getvalue(), err.getvalue()


class WhisperCatalogTest(unittest.TestCase):
    def setUp(self) -> None:
        self.sources = catalog.SOURCES
        # The fixture files, with the README SHA-1 of the fixture.
        catalog.SOURCES = [dict(source) for source in self.sources]
        catalog.SOURCES[2]["readmeSha1"] = _sha1(FILES["ggml-large-v3-turbo-q5_0.bin"])
        self.addCleanup(setattr, catalog, "SOURCES", self.sources)
        self.server = _HuggingFace(FILES)
        self.addCleanup(self.server.close)

    def test_prints_the_entries_pinned_to_the_commit(self) -> None:
        status, out, err = _run("resolve", "--print", "--base-url", self.server.base)
        self.assertEqual(status, 0, err)
        printed = json.loads(out)
        self.assertIn(COMMIT, printed["_provenance"])
        entries = printed["models"]
        self.assertEqual(
            [entry["id"] for entry in entries],
            ["base-q5_1", "small-q5_1", "large-v3-turbo-q5_0"],
        )
        small = entries[1]
        data = FILES["ggml-small-q5_1.bin"]
        self.assertEqual(
            small,
            {
                "id": "small-q5_1",
                "name": "ggml-small-q5_1.bin",
                # The public URL, never the server asked.
                "url": f"https://huggingface.co/{REPOSITORY}/resolve/{COMMIT}/"
                "ggml-small-q5_1.bin",
                "size": len(data),
                "sha1": _sha1(data),
                "sha256": _sha256(data),
                "multilingual": True,
                "parameters": 244000000,
                "minRamMb": 3000,
            },
        )
        self.assertNotIn("minRamMb", entries[0])
        self.assertEqual(entries[2]["minRamMb"], 7000)
        self.assertIn("OK           ggml-base-q5_1.bin", err)

    def test_the_real_sources_are_the_documented_ones(self) -> None:
        self.assertEqual(
            [source["file"] for source in self.sources],
            [
                "ggml-base-q5_1.bin",
                "ggml-small-q5_1.bin",
                "ggml-large-v3-turbo-q5_0.bin",
            ],
        )
        # whisper.cpp v1.9.5 models/README.md.
        self.assertEqual(
            self.sources[2]["readmeSha1"],
            "e050f7970618a659205450ad97eb95a18d69c9ee",
        )
        for source in self.sources:
            self.assertIn(source["id"], catalog.ORDER)

    def test_only(self) -> None:
        status, out, _ = _run(
            "resolve", "--only", "small-q5_1", "--base-url", self.server.base
        )
        self.assertEqual(status, 0)
        self.assertEqual([e["id"] for e in json.loads(out)["models"]], ["small-q5_1"])
        self.assertFalse(any("base-q5_1" in path for path in self.server.requests))
        status, _, err = _run(
            "resolve", "--only", "medium", "--base-url", self.server.base
        )
        self.assertEqual(status, 1)
        self.assertIn("unknown model ids: medium", err)

    def test_a_download_that_differs_from_the_tree_fails(self) -> None:
        self.server.served["ggml-base-q5_1.bin"] = b"something else"
        status, out, err = _run("resolve", "--base-url", self.server.base)
        self.assertEqual(status, 1)
        self.assertEqual(out, "")
        self.assertIn("ggml-base-q5_1.bin: Hugging Face lists", err)
        self.assertIn("bytes", err)

        data = FILES["ggml-base-q5_1.bin"]
        self.server.served["ggml-base-q5_1.bin"] = bytes(len(data))
        status, _, err = _run("resolve", "--base-url", self.server.base)
        self.assertEqual(status, 1)
        self.assertIn(f"lists sha256 {_sha256(data)}", err)

    def test_a_readme_sha1_that_differs_fails(self) -> None:
        catalog.SOURCES[2]["readmeSha1"] = "0" * 40
        status, _, err = _run("resolve", "--base-url", self.server.base)
        self.assertEqual(status, 1)
        self.assertIn("models/README.md lists sha1 " + "0" * 40, err)

    def test_missing_files_and_tree_entries(self) -> None:
        self.server.tree["ggml-small-q5_1.bin"] = {
            "type": "file",
            "path": "ggml-small-q5_1.bin",
            "size": 10,
        }
        status, _, err = _run("resolve", "--base-url", self.server.base)
        self.assertEqual(status, 1)
        self.assertIn("ggml-small-q5_1.bin: no SHA-256 in the tree", err)

        del self.server.tree["ggml-small-q5_1.bin"]
        del self.server.files["ggml-small-q5_1.bin"]
        status, _, err = _run("resolve", "--base-url", self.server.base)
        self.assertEqual(status, 1)
        self.assertIn(f"ggml-small-q5_1.bin: not in {REPOSITORY}@{COMMIT}", err)

    def test_retries_server_errors(self) -> None:
        self.server.fail[f"/api/models/{REPOSITORY}/revision/main"] = 503
        self.server.fail["/cdn/ggml-base-q5_1.bin"] = 500
        status, out, err = _run("resolve", "--base-url", self.server.base)
        self.assertEqual(status, 0, err)
        self.assertEqual(len(json.loads(out)["models"]), 3)

    def test_unreachable(self) -> None:
        self.server.close()
        status, _, err = _run("resolve", "--base-url", self.server.base)
        self.assertEqual(status, 2)
        self.assertIn("UNREACHABLE", err)

    def test_write_merges_in_catalogue_order(self) -> None:
        bundled = json.loads(catalog.CATALOG.read_text(encoding="utf-8"))
        path = Path(tempfile.mkdtemp(prefix="whisper_catalog_")) / "models.json"
        path.write_text(json.dumps(bundled, indent=2) + "\n", encoding="utf-8")

        args = (
            "resolve",
            "--write",
            "--catalog",
            str(path),
            "--base-url",
            self.server.base,
        )
        status, out, err = _run(*args)
        self.assertEqual(status, 0, err)
        self.assertEqual(out, "")
        written = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(
            [model["id"] for model in written["models"]],
            [
                "tiny",
                "base-q5_1",
                "base",
                "small-q5_1",
                "large-v3-turbo-q5_0",
                "silero-vad",
            ],
        )
        # The other entries are untouched; the resolved ones are replaced.
        resolved = {source["id"] for source in catalog.SOURCES}
        for model in bundled["models"]:
            if model["id"] not in resolved:
                self.assertIn(model, written["models"])
        self.assertEqual(written["schemaVersion"], 1)
        quantized = [
            line
            for line in written["_provenance"]
            if line.startswith("Quantized models (")
        ]
        self.assertEqual(len(quantized), 1)
        self.assertIn(COMMIT, quantized[0])
        kept = [
            line
            for line in bundled["_provenance"]
            if not line.startswith("Quantized models (")
        ]
        self.assertEqual(written["_provenance"][: len(kept)], kept)

        # Again: the same file (entries replaced, one provenance line).
        before = path.read_text(encoding="utf-8")
        status, _, _ = _run(*args)
        self.assertEqual(status, 0)
        self.assertEqual(path.read_text(encoding="utf-8"), before)

    def test_merge_keeps_unknown_entries_after_the_ordered_ones(self) -> None:
        merged = catalog.merge(
            {
                "models": [
                    {"id": "vad", "kind": "vad"},
                    {"id": "medium"},
                    {"id": "base"},
                    {"id": "tiny"},
                ],
            },
            [{"id": "small-q5_1"}],
            COMMIT,
        )
        self.assertEqual(
            [model["id"] for model in merged["models"]],
            ["tiny", "base", "small-q5_1", "medium", "vad"],
        )
        self.assertEqual(len(merged["_provenance"]), 1)
        self.assertEqual(catalog.merge({"models": []}, [], COMMIT)["_provenance"], [])

    def test_a_commit_or_tree_that_is_not_one_fails(self) -> None:
        original = catalog._json
        self.addCleanup(setattr, catalog, "_json", original)
        catalog._json = lambda url: {"sha": "short"}
        with self.assertRaisesRegex(catalog.ResolveError, "no commit"):
            catalog.pin_commit(self.server.base, REPOSITORY, "main")
        catalog._json = lambda url: {"not": "a list"}
        with self.assertRaisesRegex(catalog.ResolveError, "unexpected tree"):
            catalog.tree(self.server.base, REPOSITORY, COMMIT)


if __name__ == "__main__":
    unittest.main()
