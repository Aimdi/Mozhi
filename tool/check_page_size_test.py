#!/usr/bin/env python3
"""Tests tool/check_page_size.py on synthetic ELF libraries, APKs and app
bundles (no Android SDK needed).

  python3 tool/check_page_size_test.py
"""

from __future__ import annotations

import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

TOOL = Path(__file__).resolve().parent / "check_page_size.py"
sys.path.insert(0, str(TOOL.parent))

import check_page_size  # noqa: E402

AARCH64, X86_64, ARM, X86 = 183, 62, 40, 3
PT_LOAD, PT_DYNAMIC = 1, 2


def elf(alignments: list[int], *, bits: int = 64, machine: int = AARCH64, phoff: int | None = None) -> bytes:
    """A minimal little-endian ELF shared object: one LOAD segment per entry
    of [alignments] (their p_align) plus a DYNAMIC one, the program header
    table at [phoff] (right after the ELF header by default)."""
    segments = [(PT_LOAD, align) for align in alignments] + [(PT_DYNAMIC, 8)]
    if bits == 64:
        ehsize, phentsize = 64, 56
        phdrs = b"".join(struct.pack("<IIQQQQQQ", kind, 5, 0, 0, 0, 0x100, 0x100, align) for kind, align in segments)
    else:
        ehsize, phentsize = 52, 32
        phdrs = b"".join(struct.pack("<IIIIIIII", kind, 0, 0, 0, 0x100, 0x100, 5, align) for kind, align in segments)
    phoff = ehsize if phoff is None else phoff
    ident = b"\x7fELF" + bytes([2 if bits == 64 else 1, 1, 1]) + bytes(9)
    if bits == 64:
        header = ident + struct.pack(
            "<HHIQQQIHHHHHH", 3, machine, 1, 0, phoff, 0, 0, ehsize, phentsize, len(segments), 0, 0, 0
        )
    else:
        header = ident + struct.pack(
            "<HHIIIIIHHHHHH", 3, machine, 1, 0, phoff, 0, 0, ehsize, phentsize, len(segments), 0, 0, 0
        )
    assert len(header) == ehsize
    body = header + bytes(phoff - ehsize) + phdrs
    return body + bytes(512)


def write_archive(path: Path, entries: list[tuple[str, bytes, str]]) -> None:
    """A zip of (name, data, mode) entries; mode "aligned" stores the entry
    with its data on a 16 KB boundary (padded like zipalign, extra field
    0xd935), "stored" stores it wherever it lands, "deflated" compresses it."""
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("AndroidManifest.xml", b"manifest")
        for name, data, mode in entries:
            info = zipfile.ZipInfo(name)
            if mode == "deflated":
                info.compress_type = zipfile.ZIP_DEFLATED
            else:
                info.compress_type = zipfile.ZIP_STORED
            if mode == "aligned":
                base = archive.fp.tell() + 30 + len(name.encode())
                length = 6 + (-(base + 6)) % check_page_size.PAGE_SIZE
                info.extra = struct.pack("<HHH", 0xD935, length - 4, check_page_size.PAGE_SIZE) + bytes(length - 6)
            archive.writestr(info, data)


class CheckPageSizeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.root = Path(self.dir.name)

    def tearDown(self) -> None:
        self.dir.cleanup()

    def run_tool(self, *files: Path) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, "-I", str(TOOL), *map(str, files)], capture_output=True, text=True, check=False
        )

    def test_aligned_apk_passes(self) -> None:
        apk = self.root / "good.apk"
        write_archive(
            apk,
            [
                ("lib/arm64-v8a/libmozhi_bergamot.so", elf([0x4000, 0x4000]), "aligned"),
                # libflutter.so is aligned to 64 KB: more than 16 KB is fine.
                ("lib/arm64-v8a/libflutter.so", elf([0x10000, 0x10000]), "aligned"),
                ("lib/x86_64/libmozhi_whisper.so", elf([0x4000], machine=X86_64), "deflated"),
                # 32-bit: listed, never a failure.
                ("lib/armeabi-v7a/libold.so", elf([0x1000], bits=32, machine=ARM), "stored"),
            ],
        )
        result = self.run_tool(apk)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("3 64-bit and 1 32-bit libraries", result.stdout)
        self.assertIn("lib/arm64-v8a/libflutter.so: LOAD align 0x10000, ok", result.stdout)
        self.assertIn("lib/armeabi-v7a/libold.so: LOAD align 0x1000, not checked (32-bit)", result.stdout)
        self.assertNotIn("::error", result.stdout)

    def test_4k_load_segment_fails(self) -> None:
        apk = self.root / "4k.apk"
        write_archive(
            apk,
            [
                ("lib/arm64-v8a/libok.so", elf([0x4000]), "aligned"),
                ("lib/x86_64/libplugin.so", elf([0x4000, 0x1000], machine=X86_64), "deflated"),
            ],
        )
        result = self.run_tool(apk)
        self.assertEqual(result.returncode, 1)
        self.assertIn("lib/x86_64/libplugin.so: LOAD align 0x1000, FAIL", result.stdout)
        self.assertIn(
            "::error title=16 KB pages::" + str(apk) + ": lib/x86_64/libplugin.so has LOAD segments aligned to 0x1000",
            result.stdout,
        )
        self.assertNotIn("libok.so has", result.stdout)

    def test_uncompressed_library_off_a_16k_boundary_fails(self) -> None:
        apk = self.root / "zip.apk"
        write_archive(apk, [("lib/arm64-v8a/libunaligned.so", elf([0x4000]), "stored")])
        with zipfile.ZipFile(apk) as archive:
            info = archive.getinfo("lib/arm64-v8a/libunaligned.so")
            self.assertNotEqual(check_page_size.data_offset(archive, info) % check_page_size.PAGE_SIZE, 0)
        result = self.run_tool(apk)
        self.assertEqual(result.returncode, 1)
        self.assertIn("libunaligned.so is stored uncompressed at offset", result.stdout)

    def test_aligned_helper_really_aligns(self) -> None:
        apk = self.root / "aligned.apk"
        write_archive(apk, [("lib/arm64-v8a/liba.so", elf([0x4000]), "aligned")])
        with zipfile.ZipFile(apk) as archive:
            offset = check_page_size.data_offset(archive, archive.getinfo("lib/arm64-v8a/liba.so"))
            self.assertEqual(offset % check_page_size.PAGE_SIZE, 0)
            self.assertGreater(offset, 0)

    def test_bundle_checks_the_elf_alignment_only(self) -> None:
        good = self.root / "good.aab"
        write_archive(good, [("base/lib/arm64-v8a/libok.so", elf([0x4000]), "stored")])
        result = self.run_tool(good)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("base/lib/arm64-v8a/libok.so: LOAD align 0x4000, ok", result.stdout)

        bad = self.root / "bad.aab"
        write_archive(bad, [("base/lib/arm64-v8a/lib4k.so", elf([0x1000]), "stored")])
        self.assertEqual(self.run_tool(bad).returncode, 1)

    def test_single_libraries(self) -> None:
        good = self.root / "libgood.so"
        good.write_bytes(elf([0x4000, 0x4000]))
        bad = self.root / "libbad.so"
        bad.write_bytes(elf([0x1000], machine=X86_64))
        old = self.root / "libold.so"
        old.write_bytes(elf([0x1000], bits=32, machine=ARM))
        self.assertEqual(self.run_tool(good, old).returncode, 0)
        result = self.run_tool(bad)
        self.assertEqual(result.returncode, 1)
        self.assertIn("libbad.so: LOAD align 0x1000, FAIL", result.stdout)

    def test_program_headers_after_the_first_read(self) -> None:
        late = self.root / "liblate.so"
        late.write_bytes(elf([0x4000, 0x1000], phoff=check_page_size.HEAD + 1024))
        self.assertEqual(
            check_page_size.check(late)[0].load_alignments, [0x4000, 0x1000]
        )
        self.assertEqual(self.run_tool(late).returncode, 1)

    def test_32_bit_program_headers(self) -> None:
        library = self.root / "lib32.so"
        library.write_bytes(elf([0x4000, 0x10000], bits=32, machine=ARM))
        [result] = check_page_size.check(library)
        self.assertEqual(result.abi, "armeabi-v7a")
        self.assertEqual(result.load_alignments, [0x4000, 0x10000])
        self.assertFalse(result.checked)

    def test_no_load_segments_fails(self) -> None:
        apk = self.root / "empty.apk"
        write_archive(apk, [("lib/arm64-v8a/libnothing.so", elf([]), "deflated")])
        result = self.run_tool(apk)
        self.assertEqual(result.returncode, 1)
        self.assertIn("libnothing.so has no LOAD segments", result.stdout)

    def test_unreadable_32_bit_libraries_never_fail(self) -> None:
        apk = self.root / "old.apk"
        write_archive(
            apk,
            [
                ("lib/arm64-v8a/libok.so", elf([0x4000]), "aligned"),
                ("lib/armeabi-v7a/libtext.so", b"INPUT(-lc)\n", "deflated"),
                # The program header table ends past the end of the file.
                ("lib/x86/libcut.so", elf([0x1000], bits=32, machine=X86)[:100], "stored"),
            ],
        )
        result = self.run_tool(apk)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("1 64-bit and 2 32-bit libraries", result.stdout)
        self.assertIn("lib/arm64-v8a/libok.so: LOAD align 0x4000, ok", result.stdout)
        self.assertIn(
            "lib/armeabi-v7a/libtext.so: unreadable (not an ELF file), not checked (32-bit)", result.stdout
        )
        self.assertIn(
            "lib/x86/libcut.so: unreadable (truncated program header table), not checked (32-bit)", result.stdout
        )
        self.assertNotIn("::error", result.stdout)
        self.assertEqual(result.stderr, "")

        single = self.root / "libcut32.so"
        single.write_bytes(elf([0x4000], bits=32, machine=ARM)[:100])
        [library] = check_page_size.check(single)
        self.assertEqual(library.abi, "armeabi-v7a")
        self.assertEqual(library.unreadable, "truncated program header table")
        self.assertEqual(self.run_tool(single).returncode, 0)

    def test_apk_without_native_code_passes(self) -> None:
        apk = self.root / "java.apk"
        write_archive(apk, [("classes.dex", b"dex\n035\0", "deflated")])
        result = self.run_tool(apk)
        self.assertEqual(result.returncode, 0)
        self.assertIn("0 64-bit and 0 32-bit libraries", result.stdout)

    def test_bad_input_is_an_error(self) -> None:
        text = self.root / "bad.apk"
        text.write_bytes(b"not a zip at all")
        self.assertEqual(self.run_tool(text).returncode, 2)

        truncated = self.root / "truncated.apk"
        write_archive(truncated, [("lib/arm64-v8a/libcut.so", elf([0x4000])[:40], "deflated")])
        result = self.run_tool(truncated)
        self.assertEqual(result.returncode, 2)
        self.assertIn("lib/arm64-v8a/libcut.so: not an ELF file", result.stderr)

        headers = self.root / "headers.apk"
        write_archive(headers, [("lib/x86_64/libcut.so", elf([0x4000], machine=X86_64)[:100], "deflated")])
        result = self.run_tool(headers)
        self.assertEqual(result.returncode, 2)
        self.assertIn("lib/x86_64/libcut.so: truncated program header table", result.stderr)

        self.assertEqual(self.run_tool(self.root / "missing.apk").returncode, 2)


if __name__ == "__main__":
    unittest.main(verbosity=1)
