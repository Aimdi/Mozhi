#!/usr/bin/env python3
"""Checks the `coverage:ignore-*` markers in Dart sources the way
package:coverage reads them, before `--coverage` test runs.

package:coverage only recognises a marker that follows `//` directly
(`// coverage:ignore-start`, nothing else in the comment) and throws on an
`ignore-end` without a matching start. That error surfaces after a test
file finishes, and the test run then hangs until the CI job times out.

  python3 tool/check_coverage_markers.py [ROOT ...]

ROOTs default to lib and packages/*/lib. Exit status 1 when a marker is
misplaced, 0 otherwise.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# The patterns of package:coverage (lib/src/util.dart, getIgnoredLines).
_START = re.compile(r"//\s*coverage:ignore-start[\w\d\s]*$")
_END = re.compile(r"//\s*coverage:ignore-end[\w\d\s]*$")
_LINE = re.compile(r"//\s*coverage:ignore-line[\w\d\s]*$")
_FILE = re.compile(r"//\s*coverage:ignore-file[\w\d\s]*$")


def problems(text: str) -> list[tuple[int, str]]:
    """The misplaced markers of one file: (line, what)."""
    found = []
    open_at = None
    for number, line in enumerate(text.splitlines(), start=1):
        for name, pattern in (
            ("ignore-start", _START),
            ("ignore-end", _END),
            ("ignore-line", _LINE),
            ("ignore-file", _FILE),
        ):
            if f"coverage:{name}" in line and not pattern.search(line):
                found.append(
                    (number, f"coverage:{name} must follow // on its own")
                )
        if _START.search(line):
            if open_at is not None:
                found.append((number, f"ignore-start inside the block of line {open_at}"))
            open_at = number
        elif _END.search(line):
            if open_at is None:
                found.append((number, "ignore-end without an ignore-start"))
            open_at = None
    if open_at is not None:
        found.append((open_at, "ignore-start without an ignore-end"))
    return found


def dart_files(roots: list[Path]):
    for root in roots:
        for path in sorted(root.rglob("*.dart")):
            if "/gen/" in path.as_posix() or path.name.endswith(".g.dart"):
                continue
            yield path


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    roots = [Path(a) for a in args] or [Path("lib"), *sorted(Path("packages").glob("*/lib"))]
    bad = 0
    for path in dart_files(roots):
        for line, what in problems(path.read_text(encoding="utf-8")):
            print(f"{path}:{line}: {what}")
            bad += 1
    if bad:
        print(f"{bad} misplaced coverage marker(s)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
