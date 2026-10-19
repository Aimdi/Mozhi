#!/usr/bin/env python3
"""Checks that the signing secrets fit together, before a long build finds
out (Gradle only opens the keystore when it signs, ~25 minutes in).

  python3 tool/check_keystore.py KEYSTORE

Reads ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS and ANDROID_KEY_PASSWORD
from the environment, trimmed like android/app/build.gradle.kts trims them,
and checks with keytool that the password opens KEYSTORE, that the alias
names a key in it and, for a PKCS12 keystore (one password for the store
and its key), that ANDROID_KEY_PASSWORD is empty or the same password.
Nothing secret is printed: each problem is reported as a GitHub error
annotation that names the secret to fix.

Exit status: 0 when everything fits, 1 when a secret doesn't, 2 on a usage
error.
"""

from __future__ import annotations

import os
import subprocess
import sys

SIGNING_DOCS = "docs/release.md#signing"


def secret(name: str) -> str:
    return os.environ.get(name, "").strip()


def keytool(keystore: str, password: str, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["keytool", "-list", "-keystore", keystore, "-storepass:env", "MOZHI_STOREPASS", *args],
        env={**os.environ, "MOZHI_STOREPASS": password},
        capture_output=True,
        text=True,
        check=False,
    )


def problems(keystore: str) -> list[str]:
    password = secret("ANDROID_KEYSTORE_PASSWORD")
    alias = secret("ANDROID_KEY_ALIAS") or secret("ANDROID_KEYSTORE_ALIAS")
    key_password = secret("ANDROID_KEY_PASSWORD")
    found = []
    if not password:
        found.append("ANDROID_KEYSTORE_PASSWORD is empty.")
    if not alias:
        found.append("ANDROID_KEY_ALIAS is empty.")
    if found:
        return found

    listed = keytool(keystore, password, "-v")
    if listed.returncode != 0:
        output = listed.stdout + listed.stderr
        if "password" in output.lower():
            return [
                "ANDROID_KEYSTORE_PASSWORD doesn't open the keystore in "
                "ANDROID_KEYSTORE_BASE64. Paste the keystore's password again "
                "(only the password, on one line)."
            ]
        return [
            "The keystore in ANDROID_KEYSTORE_BASE64 can't be read: "
            + (output.strip().splitlines() or ["keytool failed"])[-1]
        ]
    if keytool(keystore, password, "-alias", alias).returncode != 0:
        found.append(
            "The keystore has no key named by ANDROID_KEY_ALIAS. Paste the "
            "alias again (`keytool -list -keystore <file>` lists them)."
        )
    is_pkcs12 = "Keystore type: PKCS12" in listed.stdout
    if is_pkcs12 and key_password and key_password != password:
        found.append(
            "ANDROID_KEY_PASSWORD differs from ANDROID_KEYSTORE_PASSWORD, but "
            "a PKCS12 keystore has one password for the store and its key. "
            "Set both secrets to the keystore's password."
        )
    return found


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: python3 tool/check_keystore.py KEYSTORE", file=sys.stderr)
        return 2
    found = problems(sys.argv[1])
    for problem in found:
        print(f"::error title=Signing secrets::{problem} See {SIGNING_DOCS}.")
    if not found:
        print("check_keystore: OK: the signing secrets open the keystore and its key")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
