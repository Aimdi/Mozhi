#!/usr/bin/env python3
"""Tests tool/check_keystore.py with throwaway keystores (needs keytool).

  python3 tool/check_keystore_test.py
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TOOL = Path(__file__).resolve().parent / "check_keystore.py"
PASSWORD = "correct-horse-battery"


def make_keystore(path: Path, store_type: str) -> None:
    subprocess.run(
        [
            "keytool", "-genkeypair", "-noprompt", "-keystore", str(path),
            "-storetype", store_type, "-alias", "mozhi", "-keyalg", "RSA",
            "-keysize", "2048", "-validity", "1", "-dname", "CN=Test",
            "-storepass", PASSWORD, "-keypass", PASSWORD,
        ],
        check=True,
        capture_output=True,
    )


class CheckKeystoreTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.dir = tempfile.TemporaryDirectory()
        cls.pkcs12 = Path(cls.dir.name) / "release.p12"
        make_keystore(cls.pkcs12, "PKCS12")

    @classmethod
    def tearDownClass(cls) -> None:
        cls.dir.cleanup()

    def run_tool(self, keystore: Path, **secrets: str) -> subprocess.CompletedProcess:
        env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith("ANDROID_KEY")
        }
        env.update(secrets)
        return subprocess.run(
            [sys.executable, "-I", str(TOOL), str(keystore)],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_matching_secrets_pass(self) -> None:
        result = self.run_tool(
            self.pkcs12,
            ANDROID_KEYSTORE_PASSWORD=PASSWORD,
            ANDROID_KEY_ALIAS="mozhi",
            ANDROID_KEY_PASSWORD=PASSWORD,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("OK", result.stdout)

    def test_surrounding_whitespace_is_ignored(self) -> None:
        result = self.run_tool(
            self.pkcs12,
            ANDROID_KEYSTORE_PASSWORD=f"  {PASSWORD}\n",
            ANDROID_KEY_ALIAS="mozhi\n",
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_wrong_password_names_the_secret(self) -> None:
        result = self.run_tool(
            self.pkcs12, ANDROID_KEYSTORE_PASSWORD="wrong", ANDROID_KEY_ALIAS="mozhi"
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("ANDROID_KEYSTORE_PASSWORD doesn't open the keystore", result.stdout)
        self.assertNotIn("wrong", result.stdout.replace("doesn't", ""))

    def test_wrong_alias(self) -> None:
        result = self.run_tool(
            self.pkcs12, ANDROID_KEYSTORE_PASSWORD=PASSWORD, ANDROID_KEY_ALIAS="other"
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("no key named by ANDROID_KEY_ALIAS", result.stdout)

    def test_different_key_password_in_pkcs12(self) -> None:
        result = self.run_tool(
            self.pkcs12,
            ANDROID_KEYSTORE_PASSWORD=PASSWORD,
            ANDROID_KEY_ALIAS="mozhi",
            ANDROID_KEY_PASSWORD="something else",
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("ANDROID_KEY_PASSWORD differs", result.stdout)

    def test_missing_secrets(self) -> None:
        result = self.run_tool(self.pkcs12)
        self.assertEqual(result.returncode, 1)
        self.assertIn("ANDROID_KEYSTORE_PASSWORD is empty", result.stdout)
        self.assertIn("ANDROID_KEY_ALIAS is empty", result.stdout)

    def test_unreadable_keystore(self) -> None:
        bad = Path(self.dir.name) / "bad.jks"
        bad.write_bytes(b"not a keystore")
        result = self.run_tool(
            bad, ANDROID_KEYSTORE_PASSWORD=PASSWORD, ANDROID_KEY_ALIAS="mozhi"
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("ANDROID_KEYSTORE_BASE64 isn't a keystore: it decodes to 14 bytes", result.stdout)

    def test_usage(self) -> None:
        result = subprocess.run(
            [sys.executable, "-I", str(TOOL)], capture_output=True, text=True, check=False
        )
        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main(verbosity=1)
