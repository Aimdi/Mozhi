#!/usr/bin/env python3
"""Fails unless every native library of the 64-bit ABIs in APKs and app
bundles can be loaded on Android devices with 16 KB memory pages (Android
15+; https://developer.android.com/guide/practices/page-sizes).

  python3 tool/check_page_size.py FILE...

FILE is an APK, an app bundle (.aab) or a single .so. Every
`lib/<abi>/*.so` is checked, not only the on-device engines: Flutter's
libflutter.so and libapp.so and the plugins' libraries too.

- **ELF alignment**: every LOAD segment of a 64-bit library (arm64-v8a,
  x86_64) must be aligned to at least 16 KB (p_align >= 0x4000). The
  engines link with -Wl,-z,max-page-size=16384 (their CMakeLists.txt) and
  NDK r28 does the same by default; a library linked for 4 KB pages fails
  to load on a 16 KB device.
- **Zip alignment** (APKs only): a library stored uncompressed, which
  Android maps straight from the APK, must start at a multiple of 16 KB in
  the file, as `zipalign -c -P 16` checks. Compressed libraries are
  extracted at install and need no alignment; app bundles are aligned
  again by bundletool or Google Play.

32-bit libraries (armeabi-v7a, x86) are listed but never fail: 16 KB page
devices are 64-bit. Nothing but the Python standard library is needed (no
Android SDK).

Exit status: 0 when every 64-bit library passes, 1 when one doesn't, 2 on
a usage or file error.
"""

from __future__ import annotations

import argparse
import re
import struct
import sys
import zipfile
from dataclasses import dataclass
from pathlib import Path

PAGE_SIZE = 16 * 1024
ABIS_64 = {"arm64-v8a", "x86_64"}
LIBRARY = re.compile(r"(?:^|/)lib/(?P<abi>[^/]+)/[^/]+\.so$")
ELF_MAGIC = b"\x7fELF"
PT_LOAD = 1
# e_machine -> ABI, for a bare .so given on the command line.
MACHINES = {183: "arm64-v8a", 62: "x86_64", 40: "armeabi-v7a", 3: "x86"}
# Enough for the ELF header and the program headers of any real library;
# more is read when the program header table ends later.
HEAD = 64 * 1024


@dataclass
class Result:
    """What was found for one library."""

    name: str
    abi: str
    load_alignments: list[int]
    zip_offset: int | None  # data offset of an uncompressed APK entry

    @property
    def checked(self) -> bool:
        return self.abi in ABIS_64

    def problems(self) -> list[str]:
        found = []
        if not self.load_alignments:
            found.append("has no LOAD segments")
        low = [align for align in self.load_alignments if align < PAGE_SIZE]
        if low:
            found.append(
                "has LOAD segments aligned to "
                + ", ".join(sorted({hex(align) for align in low}))
                + " (needs 0x4000 or more: link with -Wl,-z,max-page-size=16384)"
            )
        if self.zip_offset is not None and self.zip_offset % PAGE_SIZE:
            found.append(
                f"is stored uncompressed at offset {self.zip_offset}, not on a "
                "16 KB boundary (zipalign -P 16; Android Gradle Plugin 8.5.1+)"
            )
        return found


def elf_header(head: bytes) -> tuple[int, int, int, int, str]:
    """(class, e_phoff, e_phentsize, e_phnum, endianness) of an ELF file."""
    if len(head) < 0x40 or not head.startswith(ELF_MAGIC):
        raise ValueError("not an ELF file")
    elf_class, data = head[4], head[5]
    if data not in (1, 2):
        raise ValueError("unknown ELF byte order")
    order = "<" if data == 1 else ">"
    if elf_class == 2:
        (phoff,) = struct.unpack_from(order + "Q", head, 0x20)
        phentsize, phnum = struct.unpack_from(order + "HH", head, 0x36)
    elif elf_class == 1:
        (phoff,) = struct.unpack_from(order + "I", head, 0x1C)
        phentsize, phnum = struct.unpack_from(order + "HH", head, 0x2A)
    else:
        raise ValueError("unknown ELF class")
    return elf_class, phoff, phentsize, phnum, order


def machine_abi(head: bytes) -> str:
    """The Android ABI of an ELF file, from e_machine."""
    _, _, _, _, order = elf_header(head)
    (machine,) = struct.unpack_from(order + "H", head, 0x12)
    return MACHINES.get(machine, f"machine {machine}")


def load_alignments(read) -> list[int]:
    """p_align of every LOAD segment; [read(n)] returns the first n bytes."""
    head = read(HEAD)
    elf_class, phoff, phentsize, phnum, order = elf_header(head)
    end = phoff + phentsize * phnum
    if end > len(head):
        head = read(end)
        if end > len(head):
            raise ValueError("truncated program header table")
    alignments = []
    for index in range(phnum):
        base = phoff + index * phentsize
        (p_type,) = struct.unpack_from(order + "I", head, base)
        if p_type != PT_LOAD:
            continue
        if elf_class == 2:
            (align,) = struct.unpack_from(order + "Q", head, base + 48)
        else:
            (align,) = struct.unpack_from(order + "I", head, base + 28)
        alignments.append(align)
    return alignments


def data_offset(archive: zipfile.ZipFile, info: zipfile.ZipInfo) -> int:
    """Where the data of [info] starts in the zip file (after its local header)."""
    archive.fp.seek(info.header_offset)
    header = archive.fp.read(30)
    if header[:4] != b"PK\x03\x04":
        raise ValueError(f"{info.filename}: bad local file header")
    name_length, extra_length = struct.unpack_from("<HH", header, 26)
    return info.header_offset + 30 + name_length + extra_length


def check_archive(path: Path) -> list[Result]:
    """Every lib/<abi>/*.so of an APK or app bundle."""
    results = []
    bundle = path.suffix == ".aab"
    with zipfile.ZipFile(path) as archive:
        for info in archive.infolist():
            match = LIBRARY.search(info.filename)
            if not match or info.is_dir():
                continue

            def read(size: int, info: zipfile.ZipInfo = info) -> bytes:
                with archive.open(info) as entry:
                    return entry.read(size)

            stored = info.compress_type == zipfile.ZIP_STORED
            results.append(
                Result(
                    name=info.filename,
                    abi=match.group("abi"),
                    load_alignments=load_alignments(read),
                    zip_offset=data_offset(archive, info) if stored and not bundle else None,
                )
            )
    return results


def check_library(path: Path) -> list[Result]:
    """A single .so file (no zip alignment)."""
    with path.open("rb") as file:

        def read(size: int) -> bytes:
            file.seek(0)
            return file.read(size)

        abi = machine_abi(read(HEAD))
        return [Result(name=path.name, abi=abi, load_alignments=load_alignments(read), zip_offset=None)]


def check(path: Path) -> list[Result]:
    with path.open("rb") as file:
        magic = file.read(4)
    if magic == ELF_MAGIC:
        return check_library(path)
    if not zipfile.is_zipfile(path):
        raise ValueError("not an APK, app bundle or ELF library")
    return check_archive(path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("files", nargs="+", type=Path)
    args = parser.parse_args()

    status = 0
    for path in args.files:
        try:
            results = check(path)
        except (OSError, ValueError, struct.error, zipfile.BadZipFile) as error:
            print(f"check_page_size: {path}: {error}", file=sys.stderr)
            return 2
        checked = [result for result in results if result.checked]
        print(f"{path}: {len(checked)} 64-bit and {len(results) - len(checked)} 32-bit libraries")
        for result in results:
            smallest = min(result.load_alignments, default=0)
            problems = result.problems() if result.checked else []
            verdict = "FAIL" if problems else ("ok" if result.checked else "not checked (32-bit)")
            print(f"  {result.name}: LOAD align {hex(smallest)}, {verdict}")
            for problem in problems:
                print(f"::error title=16 KB pages::{path}: {result.name} {problem}")
                status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())
