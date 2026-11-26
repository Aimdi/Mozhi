"""Unit tests for tool/passphrase_nfc.py."""

from __future__ import annotations

import io
import json
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import passphrase_nfc


class PassphraseNfcTest(unittest.TestCase):
    def test_committed_table_matches_generator(self) -> None:
        self.assertEqual(passphrase_nfc.main(["--check"]), 0)

    def test_combining_classes_and_decompositions_cover_latin_and_kana(self) -> None:
        classes = passphrase_nfc.combining_classes()
        self.assertEqual(classes[0x0301], 230)  # combining acute accent
        self.assertEqual(classes[0x3099], 8)  # kana voiced sound mark

        decomps = passphrase_nfc.decompositions()
        self.assertEqual(decomps[0x00E9], [0x0065, 0x0301])  # é -> e + combining acute

        comps = passphrase_nfc.compositions(decomps)
        self.assertEqual(comps[0x0065][0x0301], 0x00E9)

    def test_normalize_stdin_mode(self) -> None:
        raw = json.dumps(["cafe\u0301", "na\u00efve", "e\u0301"])
        out = io.StringIO()
        with (
            mock.patch.object(sys, "stdin", io.StringIO(raw)),
            mock.patch.object(sys, "stdout", out),
        ):
            rc = passphrase_nfc.main(["--normalize"])
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(out.getvalue()), ["caf\u00e9", "na\u00efve", "\u00e9"])

    def test_invalid_arg_returns_2(self) -> None:
        with mock.patch.object(sys, "stdout", io.StringIO()):
            self.assertEqual(passphrase_nfc.main(["--unknown"]), 2)


if __name__ == "__main__":
    unittest.main()
