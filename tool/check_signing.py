#!/usr/bin/env python3
"""Prints the signing certificate (SHA-256) of APKs and app bundles and,
with --expect, fails unless every one is the release certificate in
tool/release-certificate.sha256 (the value published in the README).

  python3 tool/check_signing.py [--expect] [--certificate FILE] FILE...

An APK's certificate is read from its APK Signature Scheme v2/v3 block
(https://source.android.com/docs/security/features/apksigning/v2); an APK
with only a JAR signature, and an .aab, are read with keytool. Nothing is
verified cryptographically: this checks *which* key signed a build, not that
the signature is valid (Android, apksigner and the stores check that).
The SHA-256 is the same value `apksigner verify --print-certs` and
`keytool -printcert` print.

Exit status: 0 when every file matches (or without --expect), 1 when one
doesn't, 2 on a usage or file error.
"""

from __future__ import annotations

import argparse
import hashlib
import mmap
import re
import struct
import subprocess
import sys
from pathlib import Path

RELEASE_CERTIFICATE = Path(__file__).resolve().parent / "release-certificate.sha256"
MAGIC = b"APK Sig Block 42"
SCHEMES = {0x7109871A: "v2", 0xF05368C0: "v3", 0x1B93AD61: "v3.1"}


def prefixed(buf: bytes, pos: int) -> tuple[bytes, int]:
    """The uint32-length-prefixed field at [pos] and the position after it."""
    (length,) = struct.unpack_from("<I", buf, pos)
    end = pos + 4 + length
    if end > len(buf):
        raise ValueError("truncated APK signing block")
    return buf[pos + 4 : end], end


def signing_block_pairs(data: bytes) -> dict[int, bytes]:
    """The ID-value pairs of the APK Signing Block (empty when there is none)."""
    eocd = data.rfind(b"PK\x05\x06", max(0, len(data) - 0xFFFF - 22))
    if eocd < 0:
        raise ValueError("not a zip file")
    (cd_offset,) = struct.unpack_from("<I", data, eocd + 16)
    if cd_offset < 32 or data[cd_offset - 16 : cd_offset] != MAGIC:
        return {}
    (size,) = struct.unpack_from("<Q", data, cd_offset - 24)
    start = cd_offset - 8 - size
    if start < 0 or struct.unpack_from("<Q", data, start)[0] != size:
        raise ValueError("malformed APK signing block")
    pairs, pos, end = {}, start + 8, cd_offset - 24
    while pos < end:
        (length,) = struct.unpack_from("<Q", data, pos)
        (pair_id,) = struct.unpack_from("<I", data, pos + 8)
        pairs[pair_id] = bytes(data[pos + 12 : pos + 8 + length])
        pos += 8 + length
    return pairs


def first_certificate(scheme_block: bytes) -> bytes:
    """The DER certificate of the first signer of a v2/v3 block."""
    signers, _ = prefixed(scheme_block, 0)
    signer, _ = prefixed(signers, 0)
    signed_data, _ = prefixed(signer, 0)
    _digests, pos = prefixed(signed_data, 0)
    certificates, _ = prefixed(signed_data, pos)
    certificate, _ = prefixed(certificates, 0)
    return certificate


def keytool_certificate(path: Path) -> str | None:
    """The SHA-256 of a JAR-signed file's certificate, from keytool."""
    result = subprocess.run(
        ["keytool", "-printcert", "-jarfile", str(path)],
        capture_output=True,
        text=True,
        check=False,
    )
    match = re.search(r"SHA256:\s*([0-9A-Fa-f:]{95})", result.stdout)
    return match.group(1).replace(":", "").lower() if match else None


def certificates(path: Path) -> dict[str, str]:
    """{signature scheme: certificate SHA-256} of an APK or app bundle."""
    found = {}
    if path.suffix != ".aab":
        with path.open("rb") as file, mmap.mmap(file.fileno(), 0, access=mmap.ACCESS_READ) as data:
            for pair_id, block in signing_block_pairs(data).items():
                if pair_id in SCHEMES:
                    found[SCHEMES[pair_id]] = hashlib.sha256(first_certificate(block)).hexdigest()
    if not found:
        jar = keytool_certificate(path)
        if jar:
            found["jar"] = jar
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--expect", action="store_true", help="fail unless signed with the release key")
    parser.add_argument(
        "--certificate",
        type=Path,
        default=RELEASE_CERTIFICATE,
        help="the expected certificate SHA-256 (default: %(default)s)",
    )
    parser.add_argument("files", nargs="+", type=Path)
    args = parser.parse_args()

    want = re.sub(r"[\s:]", "", args.certificate.read_text(encoding="utf-8")).lower()
    status = 0
    for path in args.files:
        try:
            found = certificates(path)
        except (OSError, ValueError, struct.error) as error:
            print(f"check_signing: {path}: {error}", file=sys.stderr)
            return 2
        shown = ", ".join(f"{scheme} {digest}" for scheme, digest in found.items())
        print(f"{path}: {shown or 'not signed'}")
        if args.expect and (not found or set(found.values()) != {want}):
            print(
                f"::error title=Signing::{path} is signed with "
                f"{shown or 'nothing'}, not the release certificate {want}"
            )
            status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())
