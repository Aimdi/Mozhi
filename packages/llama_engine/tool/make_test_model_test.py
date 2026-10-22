#!/usr/bin/env python3
"""Tests for make_test_model.py (needs numpy; llama.cpp loading the models
is tested by test/src/engine/native_engine_test.dart).

Usage: python3 packages/llama_engine/tool/make_test_model_test.py
"""

from __future__ import annotations

import hashlib
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import make_test_model  # noqa: E402


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class MakeTestModelTest(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)

    def tearDown(self) -> None:
        self.directory.cleanup()

    def read(self, path: Path):
        gguf = make_test_model.import_gguf()
        return gguf.GGUFReader(str(path))

    def test_is_deterministic_and_small(self) -> None:
        first = self.root / "a.gguf"
        second = self.root / "b.gguf"
        make_test_model.write_model(first, "chatml")
        make_test_model.write_model(second, "chatml")
        self.assertEqual(sha256(first), sha256(second))
        self.assertLess(first.stat().st_size, 5 * 1024 * 1024)

    def test_writes_a_llama_model_with_the_borrowed_vocabulary(self) -> None:
        path = self.root / "model.gguf"
        make_test_model.write_model(path, "gemma4")
        reader = self.read(path)
        fields = reader.fields
        self.assertEqual(fields["general.architecture"].contents(), "llama")
        self.assertEqual(fields["general.name"].contents(), "Mozhi test model")
        self.assertEqual(fields["llama.context_length"].contents(), 4096)
        self.assertEqual(fields["llama.embedding_length"].contents(), 64)
        self.assertEqual(fields["tokenizer.ggml.model"].contents(), "llama")
        self.assertEqual(len(fields["tokenizer.ggml.tokens"].contents()), 32000)
        self.assertIn("<|turn>", fields["tokenizer.chat_template"].contents())
        names = {tensor.name for tensor in reader.tensors}
        self.assertEqual(len(names), 3 + 9 * make_test_model.N_LAYER)
        self.assertIn("token_embd.weight", names)
        self.assertIn("output.weight", names)
        self.assertIn("blk.1.ffn_down.weight", names)

    def test_every_template_variant(self) -> None:
        self.assertEqual(make_test_model.main(["--all", str(self.root)]), 0)
        for template, text in make_test_model.CHAT_TEMPLATES.items():
            reader = self.read(self.root / f"llama-test-{template}.gguf")
            field = reader.fields.get("tokenizer.chat_template")
            if text is None:
                self.assertIsNone(field, template)
            else:
                self.assertEqual(field.contents(), text, template)
        self.assertIn("enable_thinking", make_test_model.CHAT_TEMPLATES["qwen3"])
        self.assertIn(
            "<｜hy_place▁holder▁no▁3｜>",
            make_test_model.CHAT_TEMPLATES["hunyuan-dense"],
        )

    def test_the_script_fits_the_embedding(self) -> None:
        inputs = {token for token, _, _ in make_test_model.SCRIPT}
        self.assertLessEqual(len(inputs), make_test_model.N_EMBD)
        successors = [s for t, s, _ in make_test_model.SCRIPT if t == "<0x0A>"]
        self.assertEqual(successors, ["a", "{"])

    def test_needs_an_output(self) -> None:
        with self.assertRaises(SystemExit):
            make_test_model.main([])


if __name__ == "__main__":
    unittest.main()
