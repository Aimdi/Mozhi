#!/usr/bin/env python3
"""Tests for tool/check_coverage_markers.py."""

import io
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_coverage_markers as markers  # noqa: E402


class ProblemsTest(unittest.TestCase):
    def test_balanced_blocks_and_lines_pass(self) -> None:
        text = (
            "a();\n"
            "  // coverage:ignore-start\n"
            "b();\n"
            "  // coverage:ignore-end\n"
            "c(); // coverage:ignore-line\n"
        )
        self.assertEqual(markers.problems(text), [])

    def test_marker_after_other_comment_text_is_not_seen(self) -> None:
        text = "  // Closed already. coverage:ignore-start\nb();\n  // coverage:ignore-end\n"
        self.assertEqual(
            markers.problems(text),
            [
                (1, "coverage:ignore-start must follow // on its own"),
                (3, "ignore-end without an ignore-start"),
            ],
        )

    def test_unclosed_and_nested_starts(self) -> None:
        text = "// coverage:ignore-start\n// coverage:ignore-start\n"
        self.assertEqual(
            markers.problems(text),
            [
                (2, "ignore-start inside the block of line 1"),
                (2, "ignore-start without an ignore-end"),
            ],
        )

    def test_main_reports_files_and_skips_generated_code(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "ok.dart").write_text("// coverage:ignore-start\n// coverage:ignore-end\n")
            (root / "gen").mkdir()
            (root / "gen" / "bad.dart").write_text("// coverage:ignore-end\n")
            (root / "bad.dart").write_text("x(); // why coverage:ignore-line\n")
            output = io.StringIO()
            with redirect_stdout(output):
                code = markers.main([str(root)])
            self.assertEqual(code, 1)
            self.assertIn("bad.dart:1: coverage:ignore-line must follow", output.getvalue())
            self.assertNotIn("gen/bad.dart", output.getvalue())
            (root / "bad.dart").unlink()
            with redirect_stdout(io.StringIO()):
                self.assertEqual(markers.main([str(root)]), 0)

    def test_the_repository_is_clean(self) -> None:
        repo = Path(__file__).resolve().parent.parent
        roots = [repo / "lib", *sorted((repo / "packages").glob("*/lib"))]
        found = [
            (path, problem)
            for path in markers.dart_files(roots)
            for problem in markers.problems(path.read_text(encoding="utf-8"))
        ]
        self.assertEqual(found, [])


if __name__ == "__main__":
    unittest.main()
