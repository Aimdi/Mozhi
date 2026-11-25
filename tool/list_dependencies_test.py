"""Unit tests for tool/list_dependencies.py."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import list_dependencies as ld


class ListDependenciesTest(unittest.TestCase):
    def test_parse_yaml_mapping_nested_and_comments(self) -> None:
        sample = """
# comment
name: "mozhi"
dependencies:
  http: ^1.2.0 # inline comment
  flutter:
    sdk: flutter
  ignored_list:
    - one
    - two
"""
        parsed = ld.parse_yaml_mapping(sample)
        self.assertEqual(parsed["name"], "mozhi")
        self.assertEqual(parsed["dependencies"]["http"], "^1.2.0")
        self.assertEqual(parsed["dependencies"]["flutter"]["sdk"], "flutter")

    def test_detect_licence_variants(self) -> None:
        self.assertEqual(
            ld.detect_licence("Mozilla Public License Version 2.0"),
            "MPL-2.0",
        )
        self.assertEqual(
            ld.detect_licence("Apache License, Version 2.0"),
            "Apache-2.0",
        )
        self.assertEqual(
            ld.detect_licence("Apache License Version 2.0 with LLVM Exceptions"),
            "Apache-2.0 WITH LLVM-exception",
        )
        self.assertEqual(
            ld.detect_licence("Permission is hereby granted, free of charge, to any person"),
            "MIT",
        )
        self.assertEqual(
            ld.detect_licence(
                "Redistribution and use in source and binary forms... Neither the name of"
            ),
            "BSD-3-Clause",
        )
        self.assertEqual(
            ld.detect_licence("Redistribution and use in source and binary forms only"),
            "BSD-2-Clause",
        )
        self.assertEqual(
            ld.detect_licence("provided 'as-is' ... altered source versions"),
            "Zlib",
        )
        self.assertEqual(ld.detect_licence("GNU General Public License v3"), "GPL")
        self.assertEqual(ld.detect_licence("Custom proprietary text"), "unknown")

    def test_licence_in_directory(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            self.assertIsNone(ld.licence_in(path))
            (path / "LICENSE").write_text(
                "Permission is hereby granted, free of charge", encoding="utf-8"
            )
            self.assertEqual(ld.licence_in(path), "MIT")

    def test_splice_replaces_markers_preserving_surrounding_text(self) -> None:
        doc = f"before\n{ld.BEGIN}\nold\n{ld.END}\nafter\n"
        block = f"{ld.BEGIN}\nnew\n{ld.END}\n"
        self.assertEqual(ld.splice(doc, block), f"before\n{ld.BEGIN}\nnew\n{ld.END}\nafter\n")

    def test_splice_raises_when_markers_missing(self) -> None:
        with self.assertRaises(SystemExit):
            ld.splice("no markers here", "block")

    def test_table_escapes_pipes(self) -> None:
        rows = ld.table(["A", "B"], [["x|y", "z"]])
        self.assertEqual(rows[2], "| x\\|y | z |")

    def test_manifests_includes_root_and_packages(self) -> None:
        found = ld.manifests()
        self.assertEqual(found[0], Path("."))
        names = {p.name for p in found[1:]}
        self.assertIn("mozhi_api", names)
        self.assertIn("llama_engine", names)


if __name__ == "__main__":
    unittest.main()
