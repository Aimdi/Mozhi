"""Unit tests for tool/check_model_downloads.py."""

from __future__ import annotations

import json
import sys
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_model_downloads as cmd


class CheckModelDownloadsTest(unittest.TestCase):
    def test_entries_upstream_includes_llm_and_all_kinds(self) -> None:
        files, errors = cmd.entries(None)
        self.assertEqual(errors, [])
        prefixes = {name.split("/", 1)[0] for name, _, _, _ in files}
        self.assertEqual(prefixes, {"whisper", "tessdata", "bergamot", "llm"})

    def test_entries_only_llm_checks_pinned_models(self) -> None:
        files, errors = cmd.entries("llm")
        self.assertEqual(errors, [])
        self.assertGreaterEqual(len(files), 3)
        for name, url, size, sha256 in files:
            self.assertTrue(name.startswith("llm/"))
            self.assertTrue(url.startswith("https://"))
            self.assertGreater(size, 0)
            self.assertIsNotNone(sha256)

    def test_check_ok_and_sha256_mismatch(self) -> None:
        with mock.patch.object(
            cmd, "head", return_value=(1234, {"x-linked-etag": '"abcd"'})
        ):
            status, msg = cmd.check("llm/test.gguf", "https://example.org/a", 1234, "abcd")
            self.assertEqual(status, "ok")
            self.assertIn("1234 bytes", msg)

            status, msg = cmd.check("llm/test.gguf", "https://example.org/a", 1234, "ffff")
            self.assertEqual(status, "mismatch")
            self.assertIn("sha256", msg)

    def test_check_404_is_immediate_mismatch(self) -> None:
        err = urllib.error.HTTPError("https://example.org/x", 404, "Not Found", {}, None)
        with mock.patch.object(cmd, "head", side_effect=err) as m:
            status, msg = cmd.check("whisper/tiny", "https://example.org/x", 100)
            self.assertEqual(status, "mismatch")
            self.assertIn("404", msg)
            self.assertEqual(m.call_count, 1)

    def test_check_falls_back_to_x_linked_size(self) -> None:
        with mock.patch.object(
            cmd, "head", return_value=(None, {"x-linked-size": "555"})
        ):
            status, _ = cmd.check("llm/m", "https://example.org/m", 555)
            self.assertEqual(status, "ok")

    def test_mirror_reads_index_and_maps_urls(self) -> None:
        whisper_catalog = json.loads(cmd.WHISPER.read_text(encoding="utf-8"))
        first_model = whisper_catalog["models"][0]
        index_payload = {
            "schemaVersion": 1,
            "kind": "whisper",
            "items": [first_model["id"]],
        }
        with mock.patch.object(
            cmd, "fetch_json", return_value=("ok", index_payload)
        ):
            files, errors = cmd.entries("whisper", mirror="https://mirror.test/models")
        self.assertEqual(errors, [])
        self.assertEqual(len(files), 1)
        label, url, size, sha = files[0]
        self.assertEqual(label, f"whisper/{first_model['name']}")
        self.assertEqual(url, f"https://mirror.test/models/whisper/{first_model['name']}")
        self.assertEqual(size, int(first_model["size"]))
        self.assertIsNone(sha)

    def test_mirror_reports_unknown_index_item_and_bad_schema(self) -> None:
        with mock.patch.object(
            cmd,
            "fetch_json",
            return_value=("ok", {"schemaVersion": 1, "kind": "llm", "items": ["nope"]}),
        ):
            files, errors = cmd.entries("llm", mirror="https://mirror.test/models/")
        self.assertEqual(files, [])
        self.assertEqual(len(errors), 1)
        self.assertEqual(errors[0][0], "mismatch")
        self.assertIn("nope", errors[0][1])

        with mock.patch.object(
            cmd,
            "fetch_json",
            return_value=("ok", {"schemaVersion": 99, "kind": "llm", "items": []}),
        ):
            _, errors = cmd.entries("llm", mirror="https://mirror.test/models/")
        self.assertEqual(errors[0][0], "mismatch")

    def test_mirror_missing_index_skipped_unless_explicit_only(self) -> None:
        with mock.patch.object(
            cmd, "fetch_json", return_value=("missing", "missing (404)")
        ):
            _, all_errors = cmd.entries(None, mirror="https://mirror.test/models")
            self.assertEqual(all_errors, [])
            _, only_errors = cmd.entries("llm", mirror="https://mirror.test/models")
            self.assertEqual(len(only_errors), 1)
            self.assertEqual(only_errors[0][0], "mismatch")

    def test_mirror_all_catalog_maps_without_fetching_index(self) -> None:
        with mock.patch.object(cmd, "fetch_json") as fetch:
            files, errors = cmd.entries(
                "llm", mirror="https://mirror.test/models", all_catalog=True
            )
        fetch.assert_not_called()
        self.assertEqual(errors, [])
        self.assertTrue(all(url.startswith("https://mirror.test/models/llm/") for _, url, _, _ in files))

    def test_main_exit_codes(self) -> None:
        with (
            mock.patch.object(cmd, "entries", return_value=([("llm/a", "u", 10, None)], [])),
            mock.patch.object(cmd, "check", return_value=("ok", "llm/a: 10 bytes")),
        ):
            self.assertEqual(cmd.main(["--only", "llm"]), 0)

        with (
            mock.patch.object(cmd, "entries", return_value=([("llm/a", "u", 10, None)], [])),
            mock.patch.object(cmd, "check", return_value=("mismatch", "diff")),
        ):
            self.assertEqual(cmd.main(["--only", "llm"]), 1)

        with (
            mock.patch.object(cmd, "entries", return_value=([("llm/a", "u", 10, None)], [])),
            mock.patch.object(cmd, "check", return_value=("unreachable", "timeout")),
        ):
            self.assertEqual(cmd.main(["--only", "llm"]), 2)


if __name__ == "__main__":
    unittest.main()
