#!/usr/bin/env python3
"""Writes tiny llama-architecture GGUF models for the engine's tests.

Usage:
  tool/make_test_model.py OUT.gguf [--chat-template NAME]
  tool/make_test_model.py OUT.gguf --vocab-model NAME
  tool/make_test_model.py --all DIR

--chat-template NAME is one of chatml (default), qwen3, gemma4,
hunyuan-dense, llama3 or none (no template); --vocab-model NAME one of
qwen2-vocab or gemma4-vocab (see below). --all writes every one of them to
DIR as llama-test-<NAME>.gguf.

The models (about 3 MB each) borrow the vocabulary of LLaMA's
SentencePiece tokenizer from the llama.cpp checkout
(models/ggml-vocab-llama-spm.gguf: 32,000 tokens) and are written with
llama.cpp's own gguf-py, so they load like real ones. The weights are
random (a fixed seed: the same file every time) except for a "bigram
script" that makes the output predictable, so the tests can check what the
engine returns:

  * token embeddings of the script's tokens are orthogonal (one-hot,
    scaled), the layers only add a little noise, and the output layer maps
    each script token to its successor, so every one of them is followed by
    its successor with near-certainty (also when sampling at a temperature
    of 0.7);
  * after "\\n" (the end of a ChatML or Qwen3 prompt) the model writes
    "abcdefghijklmnopqrstuvwxyz" and then "中" as three byte tokens
    (<0xE4> <0xB8> <0xAD>: one character split between tokens), then the
    end-of-text token;
  * after ">" (the end of a Gemma 4 prompt) it writes the digits
    "0123456789" over and over, never ending (for cancellation and
    length limits);
  * "{" is the second choice after "\\n", "}" follows "{" and the end of
    text follows "}": with the JSON grammar the answer is "{}".

The --vocab-model models instead borrow the vocabulary of a real chat model
(Qwen2's byte-level BPE, models/ggml-vocab-qwen2.gguf, with Qwen3's chat
template; Gemma 4's, models/ggml-vocab-gemma-4.gguf, with Gemma 4's), whose
chat markers (<|im_start|>, <|im_end|>, <|turn>, <turn|>, ...) are special
tokens, for the tests of how prompts are tokenized. Their weights are
random and small (tied embeddings: about 9 and 21 MB, mostly the
vocabulary), with no script: they are only tokenized and run for a token
or two.

Needs Python 3.9+ and numpy (gguf-py's only dependency; PyYAML is replaced
by a stub when missing, gguf-py only needs it for model cards).
"""

from __future__ import annotations

import argparse
import sys
import types
from pathlib import Path

PACKAGE_DIR = Path(__file__).resolve().parent.parent
LLAMA_CPP = PACKAGE_DIR / "native" / "third_party" / "llama.cpp"
VOCAB = LLAMA_CPP / "models" / "ggml-vocab-llama-spm.gguf"

SEED = 20261022
N_EMBD = 64
N_LAYER = 2
N_HEAD = 2
N_HEAD_KV = 1
N_FF = 128
CONTEXT_LENGTH = 4096

# Embedding scale of the script's tokens (one-hot) and the weight of their
# successors in the output layer: logits of about 22 against 0 for the
# rest of the vocabulary.
EMBEDDING_SCALE = 8.0
NEXT_WEIGHT = 4.0
SECOND_CHOICE_WEIGHT = 2.0

LETTERS = [chr(c) for c in range(ord("a"), ord("z") + 1)]
DIGITS = [str(d) for d in range(10)]
CHINESE_BYTES = ["<0xE4>", "<0xB8>", "<0xAD>"]  # 中, UTF-8 E4 B8 AD
END = "</s>"

# (token, successor, weight): the bigram script.
SCRIPT = (
    [("<0x0A>", "a", NEXT_WEIGHT), ("<0x0A>", "{", SECOND_CHOICE_WEIGHT)]
    + [(LETTERS[i], LETTERS[i + 1], NEXT_WEIGHT) for i in range(25)]
    + [("z", CHINESE_BYTES[0], NEXT_WEIGHT)]
    + [(CHINESE_BYTES[0], CHINESE_BYTES[1], NEXT_WEIGHT),
       (CHINESE_BYTES[1], CHINESE_BYTES[2], NEXT_WEIGHT),
       (CHINESE_BYTES[2], END, NEXT_WEIGHT)]
    + [(">", "0", NEXT_WEIGHT)]
    + [(DIGITS[i], DIGITS[(i + 1) % 10], NEXT_WEIGHT) for i in range(10)]
    + [("{", "}", NEXT_WEIGHT), ("}", END, NEXT_WEIGHT)]
)

CHATML = (
    "{% for message in messages %}"
    "{{'<|im_start|>' + message['role'] + '\\n' + message['content'] + "
    "'<|im_end|>' + '\\n'}}"
    "{% endfor %}"
    "{% if add_generation_prompt %}{{ '<|im_start|>assistant\\n' }}{% endif %}"
)

CHAT_TEMPLATES = {
    "chatml": CHATML,
    # Qwen3: ChatML whose generation prompt can turn thinking off.
    "qwen3": CHATML.replace(
        "{% endif %}",
        "{%- if enable_thinking is defined and enable_thinking is false %}"
        "{{- '<think>\\n\\n</think>\\n\\n' }}{%- endif %}{% endif %}",
    ),
    # Gemma 4: an excerpt with its turn markers.
    "gemma4": (
        "{{ bos_token }}{%- for message in messages -%}"
        "{%- set role = 'model' if message['role'] == 'assistant' "
        "else message['role'] -%}"
        "{{- '<|turn>' + role + '\\n' + message['content'] | trim + "
        "'<turn|>\\n' -}}{%- endfor -%}"
        "{%- if add_generation_prompt -%}{{- '<|turn>model\\n' -}}"
        "{{- '<|channel>thought\\n<channel|>' -}}{%- endif -%}"
    ),
    # Hunyuan dense (Hy-MT2): its system and assistant markers.
    "hunyuan-dense": (
        "{{ bos_token }}{% for message in messages %}"
        "{% if message['role'] == 'system' %}"
        "{{ message['content'] + '<｜hy_place▁holder▁no▁3｜>' }}"
        "{% elif message['role'] == 'user' %}"
        "{{ '<｜hy_User｜>' + message['content'] }}"
        "{% else %}{{ '<｜hy_Assistant｜>' + message['content'] + "
        "'<｜hy_place▁holder▁no▁2｜>' }}{% endif %}{% endfor %}"
        "{% if add_generation_prompt %}{{ '<｜hy_Assistant｜>' }}{% endif %}"
    ),
    # Llama 3: llama.cpp's built-in trims the contents.
    "llama3": (
        "{% for message in messages %}"
        "{{ '<|start_header_id|>' + message['role'] + '<|end_header_id|>\\n\\n'"
        " + message['content'] | trim + '<|eot_id|>' }}{% endfor %}"
        "{% if add_generation_prompt %}"
        "{{ '<|start_header_id|>assistant<|end_header_id|>\\n\\n' }}"
        "{% endif %}"
    ),
    "none": None,
}

# name: (vocabulary in llama.cpp's models/, chat template).
VOCAB_MODELS = {
    # <|im_start|>, <|im_end|> and <|endoftext|> are control tokens.
    "qwen2-vocab": ("ggml-vocab-qwen2.gguf", "qwen3"),
    # <|turn>, <turn|>, <bos> and <eos> are control tokens, <|channel> and
    # <channel|> user-defined ones.
    "gemma4-vocab": ("ggml-vocab-gemma-4.gguf", "gemma4"),
}

# The --vocab-model models: one small layer, tied embeddings.
VOCAB_N_EMBD = 32
VOCAB_N_FF = 32


def import_gguf():
    """llama.cpp's gguf-py from the checkout (never an installed copy)."""
    if not (LLAMA_CPP / "gguf-py" / "gguf" / "__init__.py").is_file():
        sys.exit(
            "error: llama.cpp is missing; run tool/fetch_native_deps.sh first"
        )
    try:
        import yaml  # noqa: F401  # gguf.metadata imports it at load time.
    except ImportError:
        sys.modules["yaml"] = types.ModuleType("yaml")
    sys.path.insert(0, str(LLAMA_CPP / "gguf-py"))
    import gguf  # noqa: PLC0415

    return gguf


def read_vocab(gguf, vocab=VOCAB):
    """The tokenizer.* key/values of the borrowed vocabulary, in order."""
    reader = gguf.GGUFReader(str(vocab))
    fields = []
    for key, field in reader.fields.items():
        if not key.startswith("tokenizer."):
            continue
        value_type = field.types[0]
        sub_type = field.types[-1] if value_type == gguf.GGUFValueType.ARRAY else None
        fields.append((key, field.contents(), value_type, sub_type))
    tokens = reader.fields["tokenizer.ggml.tokens"].contents()
    return fields, {token: index for index, token in enumerate(tokens)}


def build_weights(np, ids, n_vocab):
    """Deterministic float32 weights: noise plus the bigram script."""
    random = np.random.RandomState(SEED)
    inputs = []
    for token, _, _ in SCRIPT:
        if token not in inputs:
            inputs.append(token)
    for token in {t for s in SCRIPT for t in s[:2]}:
        if token not in ids:
            sys.exit(f"error: {token!r} is not in the vocabulary")
    if len(inputs) > N_EMBD:
        sys.exit("error: the script needs more embedding dimensions")
    dimension = {token: index for index, token in enumerate(inputs)}

    embeddings = random.normal(0.0, 1.0, (n_vocab, N_EMBD)).astype(np.float32)
    for token, index in dimension.items():
        row = np.zeros(N_EMBD, dtype=np.float32)
        row[index] = EMBEDDING_SCALE
        embeddings[ids[token]] = row

    output = np.zeros((n_vocab, N_EMBD), dtype=np.float32)
    for token, successor, weight in SCRIPT:
        output[ids[successor], dimension[token]] += weight

    def noise(*shape, scale=0.02):
        return random.normal(0.0, scale, shape).astype(np.float32)

    head_dim = N_EMBD // N_HEAD
    kv = N_HEAD_KV * head_dim
    layers = []
    for _ in range(N_LAYER):
        layers.append({
            "attn_norm": np.ones(N_EMBD, dtype=np.float32),
            "attn_q": noise(N_EMBD, N_EMBD),
            "attn_k": noise(kv, N_EMBD),
            "attn_v": noise(kv, N_EMBD),
            "attn_output": noise(N_EMBD, N_EMBD),
            "ffn_norm": np.ones(N_EMBD, dtype=np.float32),
            "ffn_gate": noise(N_FF, N_EMBD),
            "ffn_up": noise(N_FF, N_EMBD),
            "ffn_down": noise(N_EMBD, N_FF),
        })
    return embeddings, output, layers


def write_model(path: Path, template: str) -> None:
    gguf = import_gguf()
    import numpy as np  # noqa: PLC0415

    fields, ids = read_vocab(gguf)
    n_vocab = len(ids)
    embeddings, output, layers = build_weights(np, ids, n_vocab)

    path.parent.mkdir(parents=True, exist_ok=True)
    writer = gguf.GGUFWriter(str(path), "llama")
    writer.add_name("Mozhi test model")
    writer.add_description(
        "Tiny random llama model for the tests of packages/llama_engine"
    )
    writer.add_file_type(gguf.LlamaFileType.MOSTLY_Q4_0)
    writer.add_quantization_version(gguf.GGML_QUANT_VERSION)
    writer.add_vocab_size(n_vocab)
    writer.add_context_length(CONTEXT_LENGTH)
    writer.add_embedding_length(N_EMBD)
    writer.add_block_count(N_LAYER)
    writer.add_feed_forward_length(N_FF)
    writer.add_head_count(N_HEAD)
    writer.add_head_count_kv(N_HEAD_KV)
    writer.add_rope_dimension_count(N_EMBD // N_HEAD)
    writer.add_layer_norm_rms_eps(1e-5)
    for key, value, value_type, sub_type in fields:
        if key == "tokenizer.chat_template":
            continue
        writer.add_key_value(key, value, value_type, sub_type=sub_type)
    chat_template = CHAT_TEMPLATES[template]
    if chat_template is not None:
        writer.add_chat_template(chat_template)

    # Q4_0 for the large matrices (it represents the script's 8s, 4s, 2s
    # and 0s exactly, and on arm64 its matrix products use the repacked
    # dotprod/i8mm kernels), Q8_0 for the layers, F32 for the norms.
    def add(name, array, qtype):
        if qtype is None:
            writer.add_tensor(name, array)
        else:
            writer.add_tensor(name, gguf.quants.quantize(array, qtype),
                              raw_dtype=qtype)

    q4 = gguf.GGMLQuantizationType.Q4_0
    q8 = gguf.GGMLQuantizationType.Q8_0
    add("token_embd.weight", embeddings, q4)
    add("output_norm.weight", np.ones(N_EMBD, dtype=np.float32), None)
    add("output.weight", output, q4)
    for index, layer in enumerate(layers):
        for name, array in layer.items():
            add(f"blk.{index}.{name}.weight", array,
                None if array.ndim == 1 else q8)

    writer.write_header_to_file()
    writer.write_kv_data_to_file()
    writer.write_tensors_to_file()
    writer.close()


def write_vocab_model(path: Path, name: str) -> None:
    """A random model with the vocabulary and template of VOCAB_MODELS[name]."""
    gguf = import_gguf()
    import numpy as np  # noqa: PLC0415

    vocab, template = VOCAB_MODELS[name]
    fields, ids = read_vocab(gguf, LLAMA_CPP / "models" / vocab)
    n_vocab = len(ids)
    random = np.random.RandomState(SEED)

    path.parent.mkdir(parents=True, exist_ok=True)
    writer = gguf.GGUFWriter(str(path), "llama")
    writer.add_name(f"Mozhi test model ({name})")
    writer.add_file_type(gguf.LlamaFileType.MOSTLY_Q4_0)
    writer.add_quantization_version(gguf.GGML_QUANT_VERSION)
    writer.add_vocab_size(n_vocab)
    writer.add_context_length(CONTEXT_LENGTH)
    writer.add_embedding_length(VOCAB_N_EMBD)
    writer.add_block_count(1)
    writer.add_feed_forward_length(VOCAB_N_FF)
    writer.add_head_count(1)
    writer.add_head_count_kv(1)
    writer.add_rope_dimension_count(VOCAB_N_EMBD)
    writer.add_layer_norm_rms_eps(1e-5)
    for key, value, value_type, sub_type in fields:
        if key == "tokenizer.chat_template":
            continue
        writer.add_key_value(key, value, value_type, sub_type=sub_type)
    writer.add_chat_template(CHAT_TEMPLATES[template])

    def noise(*shape, scale=0.02):
        return random.normal(0.0, scale, shape).astype(np.float32)

    def add(name, array, qtype):
        if qtype is None:
            writer.add_tensor(name, array)
        else:
            writer.add_tensor(name, gguf.quants.quantize(array, qtype),
                              raw_dtype=qtype)

    q4 = gguf.GGMLQuantizationType.Q4_0
    q8 = gguf.GGMLQuantizationType.Q8_0
    ones = np.ones(VOCAB_N_EMBD, dtype=np.float32)
    # No output.weight: llama.cpp uses the token embeddings (tied).
    add("token_embd.weight", noise(n_vocab, VOCAB_N_EMBD, scale=1.0), q4)
    add("output_norm.weight", ones, None)
    for tensor, shape in [
        ("attn_q", (VOCAB_N_EMBD, VOCAB_N_EMBD)),
        ("attn_k", (VOCAB_N_EMBD, VOCAB_N_EMBD)),
        ("attn_v", (VOCAB_N_EMBD, VOCAB_N_EMBD)),
        ("attn_output", (VOCAB_N_EMBD, VOCAB_N_EMBD)),
        ("ffn_gate", (VOCAB_N_FF, VOCAB_N_EMBD)),
        ("ffn_up", (VOCAB_N_FF, VOCAB_N_EMBD)),
        ("ffn_down", (VOCAB_N_EMBD, VOCAB_N_FF)),
    ]:
        add(f"blk.0.{tensor}.weight", noise(*shape), q8)
    add("blk.0.attn_norm.weight", ones, None)
    add("blk.0.ffn_norm.weight", ones, None)

    writer.write_header_to_file()
    writer.write_kv_data_to_file()
    writer.write_tensors_to_file()
    writer.close()


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("out", nargs="?", help="the GGUF file to write")
    parser.add_argument("--chat-template", default="chatml",
                        choices=sorted(CHAT_TEMPLATES))
    parser.add_argument("--vocab-model", choices=sorted(VOCAB_MODELS),
                        help="a model with a real chat vocabulary instead")
    parser.add_argument("--all", metavar="DIR",
                        help="write every model variant to DIR")
    args = parser.parse_args(argv)
    if args.all:
        for template in sorted(CHAT_TEMPLATES):
            out = Path(args.all) / f"llama-test-{template}.gguf"
            write_model(out, template)
            print(f"{out} ({out.stat().st_size} bytes)")
        for name in sorted(VOCAB_MODELS):
            out = Path(args.all) / f"llama-test-{name}.gguf"
            write_vocab_model(out, name)
            print(f"{out} ({out.stat().st_size} bytes)")
        return 0
    if not args.out:
        parser.error("OUT.gguf or --all DIR is required")
    out = Path(args.out)
    if args.vocab_model:
        write_vocab_model(out, args.vocab_model)
    else:
        write_model(out, args.chat_template)
    print(f"{out} ({out.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
