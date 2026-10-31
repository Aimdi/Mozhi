#!/usr/bin/env python3
"""Tests tool/fetch_test_model.py against a local server (no network).

  python3 packages/whisper_speech/tool/fetch_test_model_test.py
"""

from __future__ import annotations

import hashlib
import io
import json
import sys
import tempfile
import threading
import unittest
import wave
from contextlib import redirect_stderr, redirect_stdout
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

TOOL = Path(__file__).resolve().parent / "fetch_test_model.py"
sys.path.insert(0, str(TOOL.parent))

import fetch_test_model as fetch  # noqa: E402

fetch.RETRY_DELAY = 0.01

MODEL = b"not really a whisper model " * 1000


class _Server(BaseHTTPRequestHandler):
    body = MODEL
    requests = 0

    def do_GET(self):  # noqa: N802 (http.server's name)
        type(self).requests += 1
        self.send_response(200)
        self.send_header("Content-Length", str(len(self.body)))
        self.end_headers()
        self.wfile.write(self.body)

    def log_message(self, *args):
        pass


def _entry(data: bytes) -> dict:
    return {
        "id": "tiny",
        "name": "ggml-tiny.bin",
        "url": "http://unused.example/ggml-tiny.bin",
        "size": len(data),
        "sha1": hashlib.sha1(data).hexdigest(),
        "sha256": hashlib.sha256(data).hexdigest(),
    }


def _wav(path: Path, *, rate: int = 16000, channels: int = 1) -> None:
    with wave.open(str(path), "wb") as file:
        file.setnchannels(channels)
        file.setsampwidth(2)
        file.setframerate(rate)
        file.writeframes(b"\0\0" * rate * channels)


class FetchTestModelTest(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.out = self.dir / "out"
        self.catalog = self.dir / "models.json"
        self.catalog.write_text(
            json.dumps(
                {
                    "models": [
                        _entry(MODEL),
                        {"id": "silero-vad", "kind": "vad", "name": "v.bin"},
                    ]
                }
            )
        )
        self.sample = self.dir / "jfk.wav"
        _wav(self.sample)
        _Server.body = MODEL
        _Server.requests = 0
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), _Server)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_port}/ggml-tiny.bin"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def run_tool(self, *extra: str) -> int:
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            return fetch.main(
                [
                    "--out",
                    str(self.out),
                    "--catalog",
                    str(self.catalog),
                    "--url",
                    self.url,
                    "--sample",
                    str(self.sample),
                    *extra,
                ]
            )

    def test_downloads_checks_and_copies_the_sample(self):
        self.assertEqual(self.run_tool(), 0)
        self.assertEqual((self.out / "ggml-tiny.bin").read_bytes(), MODEL)
        self.assertTrue((self.out / fetch.SAMPLE_NAME).exists())
        self.assertEqual(_Server.requests, 1)

    def test_a_file_in_place_is_not_downloaded_again(self):
        self.assertEqual(self.run_tool(), 0)
        self.assertEqual(self.run_tool(), 0)
        self.assertEqual(_Server.requests, 1)

    def test_a_damaged_file_in_place_is_replaced(self):
        self.out.mkdir(parents=True)
        (self.out / "ggml-tiny.bin").write_bytes(b"damaged")
        self.assertEqual(self.run_tool(), 0)
        self.assertEqual((self.out / "ggml-tiny.bin").read_bytes(), MODEL)

    def test_a_download_that_does_not_match_is_refused(self):
        _Server.body = MODEL[:-1] + b"!"
        self.assertEqual(self.run_tool(), 1)
        self.assertFalse((self.out / "ggml-tiny.bin").exists())
        self.assertFalse((self.out / "ggml-tiny.bin.part").exists())

    def test_an_unreachable_server_fails_after_retries(self):
        self.url = "http://127.0.0.1:9/ggml-tiny.bin"
        self.assertEqual(self.run_tool(), 2)

    def test_the_sample_must_be_16_khz_mono(self):
        _wav(self.sample, rate=44100)
        self.assertEqual(self.run_tool(), 1)
        self.sample.unlink()
        self.assertEqual(self.run_tool(), 1)

    def test_an_unknown_model_is_an_error(self):
        with self.assertRaises(SystemExit):
            self.run_tool("--model", "silero-vad")

    def test_the_catalogue_lists_the_default_model(self):
        entry = fetch.catalog_entry("tiny")
        self.assertEqual(entry["name"], "ggml-tiny.bin")
        self.assertEqual(entry["size"], 77691713)
        self.assertEqual(len(entry["sha256"]), 64)


if __name__ == "__main__":
    unittest.main()
