#!/usr/bin/env python3
"""Tests tool/mirror_models.py against a local fixture server (no network).

  python3 tool/mirror_models_test.py
"""

from __future__ import annotations

import gzip
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

TOOL = Path(__file__).resolve().parent / "mirror_models.py"
sys.path.insert(0, str(TOOL.parent))

import mirror_models as mirror  # noqa: E402

mirror.RETRY_DELAY = 0.01


class _Server:
    """Serves [files] (path -> bytes) on 127.0.0.1 with Range support; can
    cut a response short once ([cut]) or answer with a status ([status])."""

    def __init__(self) -> None:
        self.files: dict[str, bytes] = {}
        self.requests: list[tuple[str, str | None]] = []
        self.cut: dict[str, int] = {}
        self.status: dict[str, int] = {}
        server = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):  # noqa: D102
                pass

            def do_GET(self):  # noqa: N802, D102
                path = self.path
                server.requests.append((path, self.headers.get("Range")))
                if path in server.status:
                    self.send_response(server.status[path])
                    self.end_headers()
                    return
                body = server.files.get(path)
                if body is None:
                    self.send_response(404)
                    self.end_headers()
                    return
                start = 0
                range_header = self.headers.get("Range")
                if range_header:
                    start = int(range_header.split("=")[1].rstrip("-"))
                    self.send_response(206)
                else:
                    self.send_response(200)
                rest = body[start:]
                self.send_header("Content-Length", str(len(rest)))
                self.end_headers()
                cut = server.cut.pop(path, None)
                if cut is not None:
                    self.wfile.write(rest[:cut])
                    self.wfile.flush()
                    self.close_connection = True
                    return
                self.wfile.write(rest)

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.base = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def close(self) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class MirrorModelsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.server = _Server()
        self.addCleanup(self.server.close)
        self.tmp = Path(tempfile.mkdtemp(prefix="mirror_models_"))
        self.out = self.tmp / "models"
        base = self.server.base
        self.blobs: dict[str, bytes] = {}

        def publish(path: str, data: bytes) -> str:
            self.server.files[path] = data
            return base + path

        bergamot_models = []
        for source, target, version in (
            ("de", "en", "run_de"),
            ("en", "de", "run_ende"),
            ("fr", "en", "run_fr"),
            ("en", "fr", "run_enfr"),
        ):
            pair = f"{source}{target}"
            files = {}
            for kind, name in (
                ("model", f"model.{pair}.intgemm.alphas.bin"),
                ("lexicalShortlist", f"lex.50.50.{pair}.s2t.bin"),
                ("vocab", f"vocab.{pair}.spm"),
            ):
                raw = f"{pair} {kind} ".encode() * 200
                gz = gzip.compress(raw)
                url = publish(
                    f"/bucket/models/{source}-{target}/{version}/exported/{name}.gz",
                    gz,
                )
                files[kind] = {
                    "name": name,
                    "url": url,
                    "size": len(gz),
                    "sha256": _sha256(gz),
                    "uncompressedSize": len(raw),
                    "uncompressedSha256": _sha256(raw),
                }
            bergamot_models.append(
                {"source": source, "target": target, "version": version, "files": files}
            )
        self.bergamot = {"schemaVersion": 1, "models": bergamot_models}

        whisper_models = []
        for model_id, name in (("tiny", "ggml-tiny.bin"), ("silero-vad", "ggml-vad.bin")):
            data = f"whisper {model_id}".encode() * 300
            whisper_models.append(
                {
                    "id": model_id,
                    "name": name,
                    "url": publish(f"/hf/resolve/main/{name}", data),
                    "size": len(data),
                    "sha1": hashlib.sha1(data).hexdigest(),
                    "sha256": _sha256(data),
                }
            )
        self.whisper = {"schemaVersion": 1, "models": whisper_models}

        languages = []
        for code, app in (("deu", ["de"]), ("fra", ["fr"]), ("chi_tra", ["zh-TW", "yue"])):
            data = f"tessdata {code}".encode() * 250
            languages.append(
                {
                    "code": code,
                    "name": code,
                    "languages": app,
                    "url": publish(f"/tessdata/abc123/{code}.traineddata", data),
                    "size": len(data),
                    "sha256": _sha256(data),
                }
            )
        self.tesseract = {"schemaVersion": 1, "languages": languages}

        packs = []
        for pack_id, language in (("es", "es"), ("pt", "pt-BR")):
            data = b"MOZHIDCT" + f"pack {pack_id}".encode() * 300
            packs.append(
                {
                    "id": pack_id,
                    "language": language,
                    "name": pack_id,
                    "file": f"{pack_id}.mzd",
                    "url": publish(f"/releases/download/r/{pack_id}.mzd", data),
                    "size": len(data),
                    "sha256": _sha256(data),
                }
            )
        self.dictionary = {"schemaVersion": 1, "release": "r", "packs": packs}
        self.write_catalogs()

    def write_catalogs(self) -> None:
        for name, catalog in (
            ("bergamot", self.bergamot),
            ("whisper", self.whisper),
            ("tesseract", self.tesseract),
            ("dictionary", self.dictionary),
        ):
            (self.tmp / f"{name}.json").write_text(json.dumps(catalog))

    def run_tool(self, *args: str) -> tuple[int, str]:
        output = io.StringIO()
        with redirect_stdout(output), redirect_stderr(output):
            code = mirror.main(
                [
                    str(self.out),
                    "--bergamot-catalog",
                    str(self.tmp / "bergamot.json"),
                    "--whisper-catalog",
                    str(self.tmp / "whisper.json"),
                    "--tesseract-catalog",
                    str(self.tmp / "tesseract.json"),
                    "--dictionary-catalog",
                    str(self.tmp / "dictionary.json"),
                    "--jobs",
                    "2",
                    *args,
                ]
            )
        return code, output.getvalue()

    def mirrored(self) -> set[str]:
        return {
            path.relative_to(self.out).as_posix()
            for path in self.out.rglob("*")
            if path.is_file()
        }

    def test_mirrors_every_file_in_the_app_layout(self) -> None:
        code, output = self.run_tool()
        self.assertEqual(code, 0, output)
        files = self.mirrored()
        self.assertEqual(len(files), 12 + 2 + 3 + 2)
        # The layout of bergamotMirrorUrl, whisperMirrorUrl, tessdataMirrorUrl.
        self.assertIn("bergamot/en-de/run_ende/model.ende.intgemm.alphas.bin.gz", files)
        self.assertIn("bergamot/de-en/run_de/vocab.deen.spm.gz", files)
        self.assertIn("whisper/ggml-tiny.bin", files)
        self.assertIn("tesseract/chi_tra.traineddata", files)
        self.assertIn("dictionary/es.mzd", files)
        self.assertEqual(
            (self.out / "tesseract/deu.traineddata").read_bytes(),
            self.server.files["/tessdata/abc123/deu.traineddata"],
        )
        self.assertFalse([name for name in files if name.endswith(".part")])
        self.assertIn("19 downloaded, 0 already in place, 0 failed", output)

    def test_filters_by_language_pair_id_and_kind(self) -> None:
        code, _ = self.run_tool("--languages", "de", "--whisper", "tiny")
        self.assertEqual(code, 0)
        self.assertEqual(
            {path.split("/")[0] + "/" + path.split("/")[1] for path in self.mirrored()},
            {"bergamot/de-en", "bergamot/en-de", "whisper/ggml-tiny.bin",
             "tesseract/deu.traineddata"},
        )

        self.out = self.tmp / "only"
        code, _ = self.run_tool("--only", "bergamot", "--pairs", "en-fr")
        self.assertEqual(code, 0)
        self.assertEqual(
            {path.split("/")[1] for path in self.mirrored()}, {"en-fr"}
        )

        self.out = self.tmp / "ocr"
        code, _ = self.run_tool(
            "--only", "tesseract,whisper", "--languages", "zh", "--whisper", ""
        )
        self.assertEqual(code, 0)
        self.assertEqual(self.mirrored(), {"tesseract/chi_tra.traineddata"})

        self.out = self.tmp / "codes"
        code, _ = self.run_tool("--only", "tesseract", "--tesseract", "fra")
        self.assertEqual(self.mirrored(), {"tesseract/fra.traineddata"})

        self.out = self.tmp / "english"
        code, _ = self.run_tool("--only", "bergamot", "--languages", "en")
        self.assertEqual(code, 0)
        self.assertEqual(self.mirrored(), set())

    def test_mirrors_dictionary_packs(self) -> None:
        code, output = self.run_tool("--only", "dictionary")
        self.assertEqual(code, 0, output)
        self.assertEqual(self.mirrored(), {"dictionary/es.mzd", "dictionary/pt.mzd"})
        self.assertEqual(
            (self.out / "dictionary/pt.mzd").read_bytes(),
            self.server.files["/releases/download/r/pt.mzd"],
        )

        self.out = self.tmp / "by-language"
        code, _ = self.run_tool("--only", "dictionary", "--languages", "pt-PT")
        self.assertEqual(code, 0)
        self.assertEqual(self.mirrored(), {"dictionary/pt.mzd"})

        self.out = self.tmp / "by-id"
        code, _ = self.run_tool("--only", "dictionary", "--dictionaries", "es")
        self.assertEqual(code, 0)
        self.assertEqual(self.mirrored(), {"dictionary/es.mzd"})

        # Resumes, and keeps files the catalogue does not list.
        self.out = self.tmp / "resume"
        old = self.out / "dictionary/fr.mzd"
        old.parent.mkdir(parents=True)
        old.write_bytes(b"an older release")
        self.server.cut["/releases/download/r/es.mzd"] = 100
        code, output = self.run_tool("--dictionaries", "es", "--only", "dictionary")
        self.assertEqual(code, 0, output)
        self.assertTrue(old.exists())
        self.assertEqual(
            (self.out / "dictionary/es.mzd").read_bytes(),
            self.server.files["/releases/download/r/es.mzd"],
        )

    def test_a_damaged_pack_is_not_mirrored(self) -> None:
        path = "/releases/download/r/es.mzd"
        self.server.files[path] = b"x" + self.server.files[path][1:]
        code, output = self.run_tool("--only", "dictionary")
        self.assertEqual(code, 1)
        self.assertIn("FAILED dictionary/es.mzd", output)
        self.assertEqual(self.mirrored(), {"dictionary/pt.mzd"})

    def test_reads_the_dart_dictionary_catalogue(self) -> None:
        catalog = {
            "schemaVersion": 1,
            "release": "a\\b$c",
            "packs": self.dictionary["packs"],
        }
        text = json.dumps(catalog, indent=2)
        dart = self.tmp / "dictionary_catalog_data.dart"
        dart.write_text(
            "// Generated.\nconst dictionaryCatalogJson = '''\n"
            + text.replace("\\", "\\\\").replace("$", "\\$")
            + "\n''';\n"
        )
        self.assertEqual(mirror.read_dictionary_catalog(dart), catalog)
        (self.tmp / "broken.dart").write_text("const x = 1;")
        with self.assertRaises(ValueError):
            mirror.read_dictionary_catalog(self.tmp / "broken.dart")
        # The app's own file (empty until the first release) parses too.
        bundled = mirror.read_dictionary_catalog(mirror.DICTIONARY)
        self.assertEqual(bundled["schemaVersion"], 1)
        self.assertIsInstance(bundled["packs"], list)

    def test_skips_verified_files_and_never_deletes_unknown_ones(self) -> None:
        self.assertEqual(self.run_tool("--only", "whisper")[0], 0)
        unknown = self.out / "whisper/ggml-old.bin"
        unknown.write_bytes(b"from an older app version")
        notes = self.out / "README.txt"
        notes.write_text("my notes")
        self.server.requests.clear()

        code, output = self.run_tool("--only", "whisper")
        self.assertEqual(code, 0)
        self.assertEqual(self.server.requests, [])
        self.assertIn("0 downloaded, 2 already in place", output)
        self.assertTrue(unknown.exists())
        self.assertEqual(notes.read_text(), "my notes")

    def test_replaces_a_known_file_that_does_not_match(self) -> None:
        target = self.out / "tesseract/deu.traineddata"
        target.parent.mkdir(parents=True)
        target.write_bytes(b"an older version of the data")
        code, _ = self.run_tool("--only", "tesseract", "--tesseract", "deu")
        self.assertEqual(code, 0)
        self.assertEqual(
            target.read_bytes(), self.server.files["/tessdata/abc123/deu.traineddata"]
        )

    def test_resumes_an_interrupted_download(self) -> None:
        path = "/hf/resolve/main/ggml-tiny.bin"
        self.server.cut[path] = 1000
        code, output = self.run_tool("--only", "whisper", "--whisper", "tiny")
        self.assertEqual(code, 0, output)
        ranges = [header for (url, header) in self.server.requests if url == path]
        self.assertEqual(ranges, [None, "bytes=1000-"])
        self.assertEqual(
            (self.out / "whisper/ggml-tiny.bin").read_bytes(), self.server.files[path]
        )

    def test_resumes_a_part_left_by_an_earlier_run(self) -> None:
        path = "/hf/resolve/main/ggml-tiny.bin"
        part = self.out / "whisper/ggml-tiny.bin.part"
        part.parent.mkdir(parents=True)
        part.write_bytes(self.server.files[path][:500])
        code, _ = self.run_tool("--only", "whisper", "--whisper", "tiny")
        self.assertEqual(code, 0)
        self.assertEqual(self.server.requests, [(path, "bytes=500-")])
        self.assertFalse(part.exists())

    def test_rejects_a_file_that_does_not_match(self) -> None:
        path = "/tessdata/abc123/fra.traineddata"
        self.server.files[path] = b"x" + self.server.files[path][1:]
        code, output = self.run_tool("--only", "tesseract", "--tesseract", "fra")
        self.assertEqual(code, 1)
        self.assertIn("FAILED tesseract/fra.traineddata", output)
        self.assertIn("SHA-256", output)
        self.assertEqual(self.mirrored(), set())

    def test_rejects_a_server_that_sends_too_much(self) -> None:
        path = "/tessdata/abc123/fra.traineddata"
        self.server.files[path] += b"extra"
        code, output = self.run_tool("--only", "tesseract", "--tesseract", "fra")
        self.assertEqual(code, 1)
        self.assertIn("more than", output)
        self.assertEqual(self.mirrored(), set())

    def test_reports_missing_files_and_server_errors(self) -> None:
        del self.server.files["/tessdata/abc123/fra.traineddata"]
        self.server.status["/tessdata/abc123/deu.traineddata"] = 503
        code, output = self.run_tool("--only", "tesseract")
        self.assertEqual(code, 1)
        self.assertIn("FAILED tesseract/fra.traineddata", output)
        self.assertIn("404", output)
        self.assertIn("FAILED tesseract/deu.traineddata", output)
        self.assertIn("1 downloaded, 0 already in place, 2 failed", output)
        # A server error is retried; a missing file is not.
        urls = [url for (url, _) in self.server.requests]
        self.assertEqual(urls.count("/tessdata/abc123/deu.traineddata"), mirror.ATTEMPTS)
        self.assertEqual(urls.count("/tessdata/abc123/fra.traineddata"), 1)

    def test_list_and_verify_send_nothing(self) -> None:
        code, output = self.run_tool("--list", "--only", "whisper")
        self.assertEqual(code, 0)
        self.assertIn("2 file(s)", output)
        self.assertIn("whisper/ggml-tiny.bin\t", output)
        self.assertFalse(self.out.exists())

        code, output = self.run_tool("--verify", "--only", "whisper")
        self.assertEqual(code, 1)
        self.assertIn("missing: whisper/ggml-tiny.bin", output)

        self.run_tool("--only", "whisper")
        (self.out / "whisper/ggml-vad.bin").write_bytes(b"damaged")
        self.server.requests.clear()
        code, output = self.run_tool("--verify", "--only", "whisper")
        self.assertEqual(code, 1)
        self.assertIn("damaged: whisper/ggml-vad.bin", output)
        self.assertEqual(self.server.requests, [])

        (self.out / "whisper/ggml-vad.bin").unlink()
        self.run_tool("--only", "whisper")
        code, output = self.run_tool("--verify", "--only", "whisper")
        self.assertEqual(code, 0)
        self.assertIn("all verified", output)

    def test_refuses_unsafe_or_unknown_input(self) -> None:
        cases = {
            "version": lambda: self.bergamot["models"][0].update(version="../x"),
            "code": lambda: self.bergamot["models"][0].update(source="DE"),
            "url": lambda: self.bergamot["models"][0]["files"]["model"].update(
                url=self.server.base + "/dir/"
            ),
            "sha": lambda: self.tesseract["languages"][0].update(sha256="ABC"),
            "tess url": lambda: self.tesseract["languages"][0].update(
                url=self.server.base + "/other.traineddata"
            ),
            "tess code": lambda: self.tesseract["languages"][0].update(code="../x"),
            "whisper name": lambda: self.whisper["models"][0].update(name=".hidden"),
            "whisper sha256": lambda: self.whisper["models"][0].pop("sha256"),
            "size": lambda: self.whisper["models"][0].update(size=0),
            "pack id": lambda: self.dictionary["packs"][0].update(id="../x"),
            "pack url": lambda: self.dictionary["packs"][0].update(
                url=self.server.base + "/other.mzd"
            ),
            "pack sha": lambda: self.dictionary["packs"][0].update(sha256="0"),
        }
        originals = (
            json.dumps(self.bergamot),
            json.dumps(self.whisper),
            json.dumps(self.tesseract),
            json.dumps(self.dictionary),
        )
        for name, change in cases.items():
            with self.subTest(name):
                self.bergamot, self.whisper, self.tesseract, self.dictionary = (
                    json.loads(text) for text in originals
                )
                change()
                self.write_catalogs()
                code, output = self.run_tool("--list")
                self.assertEqual(code, 2, output)
                self.assertIn("error:", output)

        self.bergamot, self.whisper, self.tesseract, self.dictionary = (
            json.loads(text) for text in originals
        )
        self.write_catalogs()
        self.assertEqual(self.run_tool("--only", "fonts")[0], 2)
        (self.tmp / "whisper.json").write_text("{not json")
        self.assertEqual(self.run_tool("--list")[0], 2)
        self.write_catalogs()
        (self.tmp / "dictionary.json").write_text("{not json")
        self.assertEqual(self.run_tool("--list")[0], 2)

    def test_reads_the_bundled_catalogues(self) -> None:
        catalogs = mirror.load_catalogs(mirror.parser().parse_args(["out"]))
        args = mirror.parser().parse_args(["out"])
        files = mirror.select(args, catalogs)
        kinds = {file.kind for file in files}
        self.assertEqual(kinds, {"bergamot", "whisper", "tesseract"})
        self.assertTrue(all(file.url.startswith("https://") for file in files))
        paths = {file.path for file in files}
        self.assertIn("whisper/ggml-base.bin", paths)
        self.assertIn("tesseract/deu.traineddata", paths)
        self.assertTrue(
            any(path.startswith("bergamot/en-de/") for path in paths), paths
        )

    def test_human_sizes(self) -> None:
        self.assertEqual(mirror.human(512), "512 B")
        self.assertEqual(mirror.human(1500), "1.5 KB")
        self.assertEqual(mirror.human(3.1e9), "3.1 GB")


if __name__ == "__main__":
    unittest.main()
