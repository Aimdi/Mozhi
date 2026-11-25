#!/usr/bin/env bash
# Builds llama.cpp to WebAssembly (web/llama/llama-engine.{js,wasm}) using
# Emscripten, matching packages/bergamot_translator/tool/build_wasm.sh and the
# artifacts expected by web/llama/worker.js.
#
# Usage:
#   bash packages/llama_engine/tool/build_wasm.sh [output-dir]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PKG_DIR/../.." && pwd)"
OUT_DIR="${1:-$REPO_ROOT/web/llama}"
BUILD_DIR="${LLAMA_WASM_BUILD_DIR:-$PKG_DIR/build/wasm}"
JOBS="${LLAMA_JOBS:-$(nproc 2>/dev/null || echo 4)}"

bash "$SCRIPT_DIR/fetch_native_deps.sh"

if ! command -v emcmake >/dev/null 2>&1; then
  echo "error: emcmake (Emscripten SDK) is not on PATH." >&2
  echo "Install emsdk and source emsdk_env.sh before building the WASM engine." >&2
  exit 2
fi

generator=()
if command -v ninja >/dev/null 2>&1; then
  generator=(-G Ninja)
fi

mkdir -p "$BUILD_DIR" "$OUT_DIR"

emcmake cmake -S "$PKG_DIR/native" -B "$BUILD_DIR" "${generator[@]}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_CPU=ON \
  -DGGML_NATIVE=OFF \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_SERVER=OFF \
  -DLLAMA_BUILD_TOOLS=OFF

cmake --build "$BUILD_DIR" --target mozhi_llama_wasm --parallel "$JOBS"

JS_ARTIFACT="$BUILD_DIR/llama-engine.js"
WASM_ARTIFACT="$BUILD_DIR/llama-engine.wasm"
if [ ! -f "$JS_ARTIFACT" ] || [ ! -f "$WASM_ARTIFACT" ]; then
  echo "error: expected $JS_ARTIFACT and $WASM_ARTIFACT after building mozhi_llama_wasm" >&2
  exit 1
fi

cp "$JS_ARTIFACT" "$WASM_ARTIFACT" "$OUT_DIR/"
echo "Built and copied llama-engine.{js,wasm} into $OUT_DIR"
