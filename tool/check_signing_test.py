#!/usr/bin/env python3
"""Tests tool/check_signing.py on APKs and bundles signed with throwaway keys
(needs keytool and jarsigner from a JDK).

  python3 tool/check_signing_test.py
"""

from __future__ import annotations

import hashlib
import io
import re
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

TOOL = Path(__file__).resolve().parent / "check_signing.py"
sys.path.insert(0, str(TOOL.parent))

import check_signing  # noqa: E402

PASSWORD = "throwaway-password"


def keystore(path: Path, alias: str) -> tuple[bytes, str]:
    """A new keystore at [path]: (its certificate in DER, keytool's SHA-256)."""
    subprocess.run(
        [
            "keytool", "-genkeypair", "-noprompt", "-keystore", str(path),
            "-storetype", "PKCS12", "-alias", alias, "-keyalg", "RSA",
            "-keysize", "2048", "-validity", "1", "-dname", f"CN={alias}",
            "-storepass", PASSWORD, "-keypass", PASSWORD,
        ],
        check=True,
        capture_output=True,
    )
    der = subprocess.run(
        ["keytool", "-exportcert", "-keystore", str(path), "-alias", alias, "-storepass", PASSWORD],
        check=True,
        capture_output=True,
    ).stdout
    listing = subprocess.run(
        ["keytool", "-list", "-v", "-keystore", str(path), "-storepass", PASSWORD],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    fingerprint = re.search(r"SHA256:\s*(\S+)", listing).group(1).replace(":", "").lower()
    return der, fingerprint


def prefixed(*parts: bytes) -> bytes:
    body = b"".join(parts)
    return struct.pack("<I", len(body)) + body


def v2_block(der: bytes) -> bytes:
    """An APK Signature Scheme v2 value with one signer holding [der]."""
    signed_data = prefixed(b"") + prefixed(prefixed(der)) + prefixed(b"")
    signer = prefixed(signed_data) + prefixed(b"") + prefixed(b"")
    return prefixed(prefixed(signer))


def apk_with_signing_block(path: Path, pairs: dict[int, bytes]) -> None:
    """A zip with an APK Signing Block (the [pairs]) before its central directory."""
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as apk:
        apk.writestr("AndroidManifest.xml", b"manifest")
        apk.writestr("classes.dex", b"dex\n035\0")
    data = buffer.getvalue()
    eocd = data.rfind(b"PK\x05\x06")
    (cd_offset,) = struct.unpack_from("<I", data, eocd + 16)
    body = b"".join(
        struct.pack("<QI", len(value) + 4, pair_id) + value for pair_id, value in pairs.items()
    )
    size = len(body) + 8 + 16
    block = struct.pack("<Q", size) + body + struct.pack("<Q", size) + check_signing.MAGIC
    data = data[:cd_offset] + block + data[cd_offset:]
    eocd += len(block)
    data = data[: eocd + 16] + struct.pack("<I", cd_offset + len(block)) + data[eocd + 20 :]
    path.write_bytes(data)


class CheckSigningTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.dir = tempfile.TemporaryDirectory()
        cls.root = Path(cls.dir.name)
        cls.release_store = cls.root / "release.p12"
        cls.release_der, cls.release_sha = keystore(cls.release_store, "release")
        cls.other_der, cls.other_sha = keystore(cls.root / "other.p12", "other")
        cls.expected = cls.root / "release-certificate.sha256"
        cls.expected.write_text(cls.release_sha + "\n", encoding="utf-8")

    @classmethod
    def tearDownClass(cls) -> None:
        cls.dir.cleanup()

    def run_tool(self, *files: Path, expect: bool = True) -> subprocess.CompletedProcess:
        args = [sys.executable, "-I", str(TOOL), "--certificate", str(self.expected)]
        if expect:
            args.append("--expect")
        return subprocess.run(
            [*args, *map(str, files)], capture_output=True, text=True, check=False
        )

    def jar_signed(self, name: str) -> Path:
        path = self.root / name
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("AndroidManifest.xml", b"manifest")
        subprocess.run(
            ["jarsigner", "-keystore", str(self.release_store), "-storepass", PASSWORD, str(path), "release"],
            check=True,
            capture_output=True,
        )
        return path

    def test_reads_the_v2_certificate_like_keytool(self) -> None:
        apk = self.root / "v2.apk"
        apk_with_signing_block(apk, {0x7109871A: v2_block(self.release_der)})
        self.assertEqual(check_signing.certificates(apk), {"v2": self.release_sha})
        self.assertEqual(hashlib.sha256(self.release_der).hexdigest(), self.release_sha)
        result = self.run_tool(apk)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"v2 {self.release_sha}", result.stdout)

    def test_v2_and_v3_with_unrelated_pairs(self) -> None:
        apk = self.root / "v2v3.apk"
        apk_with_signing_block(
            apk,
            {
                0x42726577: b"\0" * 64,  # verity padding
                0x7109871A: v2_block(self.release_der),
                0xF05368C0: v2_block(self.release_der),
            },
        )
        self.assertEqual(
            check_signing.certificates(apk), {"v2": self.release_sha, "v3": self.release_sha}
        )
        self.assertEqual(self.run_tool(apk).returncode, 0)

    def test_other_key_fails(self) -> None:
        apk = self.root / "other.apk"
        apk_with_signing_block(apk, {0x7109871A: v2_block(self.other_der)})
        result = self.run_tool(apk)
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"signed with v2 {self.other_sha}, not the release certificate", result.stdout)

    def test_mixed_keys_fail(self) -> None:
        apk = self.root / "mixed.apk"
        apk_with_signing_block(
            apk,
            {0x7109871A: v2_block(self.release_der), 0xF05368C0: v2_block(self.other_der)},
        )
        self.assertEqual(self.run_tool(apk).returncode, 1)

    def test_jar_signed_apk_and_bundle(self) -> None:
        apk = self.jar_signed("v1.apk")
        bundle = self.jar_signed("app.aab")
        self.assertEqual(check_signing.certificates(apk), {"jar": self.release_sha})
        result = self.run_tool(apk, bundle)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_unsigned_fails_only_with_expect(self) -> None:
        apk = self.root / "unsigned.apk"
        with zipfile.ZipFile(apk, "w") as archive:
            archive.writestr("AndroidManifest.xml", b"manifest")
        self.assertEqual(self.run_tool(apk).returncode, 1)
        result = self.run_tool(apk, expect=False)
        self.assertEqual(result.returncode, 0)
        self.assertIn("not signed", result.stdout)

    def test_not_a_zip_is_an_error(self) -> None:
        bad = self.root / "bad.apk"
        bad.write_bytes(b"not a zip at all")
        self.assertEqual(self.run_tool(bad).returncode, 2)


if __name__ == "__main__":
    unittest.main(verbosity=1)
