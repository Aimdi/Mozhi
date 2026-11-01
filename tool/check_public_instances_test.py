#!/usr/bin/env python3
"""Tests for check_public_instances.py, against local fake Mozhi servers.

  python3 tool/check_public_instances_test.py
"""

from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import threading
import unittest
import urllib.parse
from contextlib import redirect_stdout
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import check_public_instances as check  # noqa: E402


def _server(handler: type[BaseHTTPRequestHandler]) -> ThreadingHTTPServer:
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


class _FakeMozhi(BaseHTTPRequestHandler):
    """Engines google and deepl; google translates, deepl echoes the text
    back (as a broken engine does), yandex is not listed. Every answer
    allows any origin (CORS: `cors`, and `translate_cors` for translations;
    None leaves the header out)."""

    engines = {"all": "All Engines", "google": "Google", "deepl": "DeepL"}
    posts: list[dict[str, list[str]]] = []
    origins: list[str | None] = []
    cors: str | None = "*"
    translate_cors: str | None = "*"

    def log_message(self, *args) -> None:  # noqa: D102
        pass

    def _json(self, status: int, body: object, cors: str | None) -> None:
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        if cors is not None:
            self.send_header("Access-Control-Allow-Origin", cors)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:  # noqa: N802, D102
        type(self).origins.append(self.headers.get("Origin"))
        if self.path.startswith("/api/engines"):
            self._json(200, self.engines, self.cors)
        else:
            self._json(404, {}, self.cors)

    def do_POST(self) -> None:  # noqa: N802, D102
        type(self).origins.append(self.headers.get("Origin"))
        length = int(self.headers.get("Content-Length", 0))
        form = urllib.parse.parse_qs(self.rfile.read(length).decode())
        type(self).posts.append(form)
        engine = form["engine"][0]
        text = form["text"][0]
        if engine == "google":
            self._json(
                200,
                {"engine": "google", "translated-text": "Bonjour !"},
                self.translate_cors,
            )
        elif engine == "deepl":
            self._json(
                200,
                {"engine": "deepl", "translated-text": text},
                self.translate_cors,
            )
        else:
            self.send_response(500)
            self.end_headers()


class _NoCors(_FakeMozhi):
    """Translates like _FakeMozhi, but no answer allows another origin."""

    cors = None
    translate_cors = None


class _CorsOnEnginesOnly(_FakeMozhi):
    """Allows the web app's origin for the engine list only."""

    cors = "https://example.org"
    translate_cors = None


class _Broken(BaseHTTPRequestHandler):
    def log_message(self, *args) -> None:  # noqa: D102
        pass

    def do_GET(self) -> None:  # noqa: N802, D102
        self.send_response(502)
        self.end_headers()


class PublicInstancesTest(unittest.TestCase):
    def test_reads_the_list_from_the_dart_source(self):
        urls = check.public_instances()
        self.assertGreaterEqual(len(urls), 3)
        self.assertTrue(all(u.startswith("https://") for u in urls))
        self.assertEqual(len(urls), len(set(urls)))

    def test_reads_only_the_public_instances_block(self):
        source = """
          class MozhiInstance {
            static const other = MozhiInstance(url: 'https://not.this');
            static const publicInstances = <MozhiInstance>[
              MozhiInstance(url: 'https://a.example', label: 'a'),
              MozhiInstance(
                url: 'https://b.example',
              ),
            ];
            static const later = MozhiInstance(url: 'https://nor.this');
          }
        """
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "mozhi_instance.dart"
            path.write_text(source, encoding="utf-8")
            self.assertEqual(
                check.public_instances(path),
                ["https://a.example", "https://b.example"],
            )

    def test_refuses_a_source_without_the_list(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "mozhi_instance.dart"
            path.write_text("class MozhiInstance {}", encoding="utf-8")
            with self.assertRaises(ValueError):
                check.public_instances(path)


class TranslationOfTest(unittest.TestCase):
    def test_takes_the_translated_text(self):
        body = json.dumps({"translated-text": " Bonjour "}).encode()
        self.assertEqual(check.translation_of(body, "Hello"), "Bonjour")

    def test_takes_the_first_of_a_list(self):
        body = json.dumps([{"translated-text": "Salut"}]).encode()
        self.assertEqual(check.translation_of(body, "Hello"), "Salut")

    def test_refuses_echoes_empty_and_odd_answers(self):
        for body in [
            json.dumps({"translated-text": "hello"}).encode(),
            json.dumps({"translated-text": ""}).encode(),
            json.dumps({"translated-text": 3}).encode(),
            json.dumps([]).encode(),
            json.dumps("Bonjour").encode(),
            b"<html>error</html>",
            b"\xff\xfe",
        ]:
            self.assertIsNone(check.translation_of(body, "Hello"), body)


class AllowsOriginTest(unittest.TestCase):
    def test_allows_any_origin_or_the_web_apps(self):
        self.assertTrue(check.allows_origin({"Access-Control-Allow-Origin": "*"}))
        self.assertTrue(
            check.allows_origin(
                {"Access-Control-Allow-Origin": "https://example.org/"}
            )
        )
        self.assertTrue(
            check.allows_origin(
                {"Access-Control-Allow-Origin": " https://example.org "}
            )
        )

    def test_refuses_other_origins_and_none(self):
        for headers in [
            {"Access-Control-Allow-Origin": "https://mozhi.example"},
            {"Access-Control-Allow-Origin": ""},
            {},
            None,
        ]:
            self.assertFalse(check.allows_origin(headers), headers)


class CheckInstanceTest(unittest.TestCase):
    def setUp(self):
        _FakeMozhi.posts = []
        _FakeMozhi.origins = []
        self.server = _server(_FakeMozhi)
        self.url = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def test_translates_with_each_listed_engine(self):
        result = check.check_instance(self.url, "Hello")

        self.assertTrue(result.reachable)
        self.assertEqual(result.engines, ["google", "deepl"])
        self.assertEqual(result.translated, {"google": "Bonjour !"})
        self.assertEqual(result.failed, {"deepl": "no translation"})
        self.assertTrue(result.default_works)
        self.assertIsNotNone(result.default_seconds)

    def test_sends_only_the_test_sentence_as_a_form(self):
        check.check_instance(self.url, "Hello")

        self.assertEqual(len(_FakeMozhi.posts), 2)
        for form in _FakeMozhi.posts:
            self.assertEqual(form["text"], ["Hello"])
            self.assertEqual(form["from"], ["en"])
            self.assertEqual(form["to"], ["fr"])

    def test_sends_the_web_apps_origin(self):
        check.check_instance(self.url, "Hello")

        self.assertEqual(_FakeMozhi.origins, [check.CORS_ORIGIN] * 3)

    def test_checks_cors_on_every_answer(self):
        result = check.check_instance(self.url, "Hello")

        self.assertTrue(result.cors_ok)
        self.assertEqual(result.cors_missing, [])

    def test_reports_a_server_without_cors(self):
        for handler, missing in [
            (_NoCors, ["engines", "google", "deepl"]),
            (_CorsOnEnginesOnly, ["google", "deepl"]),
        ]:
            server = _server(handler)
            try:
                result = check.check_instance(
                    f"http://127.0.0.1:{server.server_port}", "Hello"
                )
            finally:
                server.shutdown()
                server.server_close()

            self.assertFalse(result.cors_ok, handler)
            self.assertEqual(result.cors_missing, missing)
            # It still translates (the Android app needs no CORS).
            self.assertTrue(result.default_works)

    def test_reports_a_server_that_fails(self):
        broken = _server(_Broken)
        try:
            result = check.check_instance(
                f"http://127.0.0.1:{broken.server_port}"
            )
        finally:
            broken.shutdown()
            broken.server_close()

        self.assertFalse(result.reachable)
        self.assertEqual(result.error, "engines: HTTP 502")
        self.assertFalse(result.default_works)
        self.assertEqual(check._web(result), "")

    def test_reports_a_server_that_is_not_there(self):
        result = check.check_instance("http://127.0.0.1:9")

        self.assertFalse(result.reachable)
        self.assertTrue(result.error)
        self.assertIsNone(result.cors_ok)


class TableTest(unittest.TestCase):
    def result(self, **fields) -> check.Result:
        values = {
            "reachable": True,
            "engines": ["google", "deepl"],
            "translated": {"google": "Bonjour"},
            "default_seconds": 0.4,
            **fields,
        }
        return check.Result("https://a.example", **values)

    def test_has_a_web_column(self):
        rows = check.table(
            [
                self.result(cors_missing=[]),
                self.result(cors_missing=["engines", "google", "deepl"]),
                self.result(cors_missing=["deepl"]),
                self.result(),
                check.Result("https://down.example", error="timed out"),
            ]
        ).splitlines()

        self.assertIn("| Web (CORS) |", rows[0])
        self.assertIn("| 0.4 s | ✓ |", rows[2])
        self.assertIn("| 0.4 s | ✗ |", rows[3])
        self.assertIn("| 0.4 s | ✗ (deepl) |", rows[4])
        self.assertIn("| 0.4 s |  |", rows[5])
        self.assertEqual(
            rows[6], "| down.example | ✗ | | | | unreachable: timed out |"
        )
        self.assertTrue(all(row.count("|") == 7 for row in rows), rows)

    def test_summary_counts_servers_the_web_app_can_use(self):
        everyone = check.summary([self.result(cors_missing=[])])
        self.assertIn("1 of 1 reachable instances allow the web app", everyone)
        self.assertNotIn("warning", everyone)

        some = check.summary(
            [
                self.result(cors_missing=[]),
                self.result(cors_missing=["engines"]),
                check.Result("https://down.example", cors_missing=["engines"]),
            ]
        )
        self.assertIn("1 of 2 reachable instances allow the web app", some)
        self.assertIn("a warning only", some)


class _GetOnly(BaseHTTPRequestHandler):
    """Fails the app's POST with a reason, answers a GET."""

    def log_message(self, *args) -> None:  # noqa: D102
        pass

    def do_POST(self) -> None:  # noqa: N802, D102
        body = b'{"error": "google: unexpected response"}'
        self.send_response(500)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802, D102
        data = json.dumps({"translated-text": "Bonjour"}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class DiagnoseTest(unittest.TestCase):
    def test_shows_the_reason_and_which_variant_works(self):
        server = _server(_GetOnly)
        try:
            report = check.diagnose(
                f"http://127.0.0.1:{server.server_port}", "Hello"
            )
        finally:
            server.shutdown()
            server.server_close()

        self.assertIn("POST form (the app): HTTP 500", report)
        self.assertIn("google: unexpected response", report)
        self.assertIn("GET query: HTTP 200: translated: 'Bonjour'", report)


class MainTest(unittest.TestCase):
    def setUp(self):
        _FakeMozhi.posts = []
        self.good = _server(_FakeMozhi)
        self.bad = _server(_Broken)
        self.no_cors = _server(_NoCors)
        self.urls = [
            f"http://127.0.0.1:{self.good.server_port}",
            f"http://127.0.0.1:{self.bad.server_port}",
        ]
        patcher = mock.patch.object(
            check, "public_instances", return_value=self.urls
        )
        patcher.start()
        self.addCleanup(patcher.stop)
        environment = mock.patch.dict(os.environ)
        environment.start()
        self.addCleanup(environment.stop)
        os.environ.pop("GITHUB_ACTIONS", None)
        os.environ.pop("GITHUB_STEP_SUMMARY", None)

    def tearDown(self):
        for server in (self.good, self.bad, self.no_cors):
            server.shutdown()
            server.server_close()

    def run_main(self, *args: str) -> tuple[int, str]:
        out = io.StringIO()
        with redirect_stdout(out):
            status = check.main(list(args))
        return status, out.getvalue()

    def test_passes_while_one_server_translates(self):
        status, out = self.run_main()

        self.assertEqual(status, 0)
        self.assertIn("1 of 2 public instances translate with google", out)
        self.assertIn("unreachable: engines: HTTP 502", out)
        self.assertNotIn("::warning::", out)

    def test_fails_below_the_minimum(self):
        status, _ = self.run_main("--min-working", "2")

        self.assertEqual(status, 1)

    def test_warns_and_writes_the_summary_on_github_actions(self):
        with tempfile.TemporaryDirectory() as directory:
            summary = Path(directory) / "summary.md"
            os.environ["GITHUB_ACTIONS"] = "true"
            os.environ["GITHUB_STEP_SUMMARY"] = str(summary)

            status, out = self.run_main()

            self.assertEqual(status, 0)
            self.assertIn(
                f"::warning::{self.urls[1]} does not translate with google",
                out,
            )
            self.assertNotIn(f"::warning::{self.urls[0]}", out)
            text = summary.read_text(encoding="utf-8")
            self.assertIn("### Public Mozhi instances", text)
            self.assertIn("| Server | google |", text)
            self.assertNotIn("does not allow the web app", out)

    def test_missing_cors_is_a_warning_not_a_failure(self):
        self.urls[1] = f"http://127.0.0.1:{self.no_cors.server_port}"
        os.environ["GITHUB_ACTIONS"] = "true"

        status, out = self.run_main("--min-working", "2")

        self.assertEqual(status, 0)
        self.assertIn("1 of 2 reachable instances allow the web app", out)
        self.assertIn(
            f"::warning::{self.urls[1]} does not allow the web app", out
        )
        self.assertNotIn(f"::warning::{self.urls[0]}", out)


if __name__ == "__main__":
    unittest.main()
