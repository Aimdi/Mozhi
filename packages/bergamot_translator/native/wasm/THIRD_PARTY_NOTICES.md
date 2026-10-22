# Third-party notices: bergamot-translator.{js,wasm} (web app)

The web app's on-device engine (built by `../../tool/build_wasm.sh`, shipped
as `bergamot/bergamot-translator.{js,wasm}` in the web build) contains the
components of [`../THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md) that
the WebAssembly build compiles, plus the ones below. The Mozhi C API
(`../src`, `src/`) is MIT.

| Component | Where | License |
| --- | --- | --- |
| bergamot-translator, Marian, SentencePiece, protobuf-lite, intgemm (its SSSE3 code as the int8 GEMM fallback), yaml-cpp, spdlog/fmt, pathie-cpp, CLI11, sse_mathfun, cnpy, phf, mio, half_float, CLD2 | as in `../THIRD_PARTY_NOTICES.md` | as listed there |
| `import-gemm-module.js` and the Emscripten glue patch (`inference/wasm/`) | `third_party/translations/inference/wasm` | MPL-2.0 |
| ONNX.js wasm-ops (float GEMM of Marian's WebAssembly build) | `marian-fork/src/3rd_party/onnxjs` ([browsermt/onnxjs](https://github.com/browsermt/onnxjs)) | MIT (© Microsoft Corporation) |
| Eigen (used by ONNX.js; built with `EIGEN_MPL2_ONLY`, so no LGPL code) | `onnxjs/deps/eigen` | MPL-2.0 |
| Emscripten runtime (the JavaScript glue and the C/C++ standard libraries: musl, LLVM libc++/libc++abi, compiler-rt) | Emscripten 3.1.8 | MIT / University of Illinois NCSA (Emscripten); MIT (musl); Apache-2.0 WITH LLVM-exception (libc++, libc++abi, compiler-rt) |

Not in the WebAssembly build: ssplit-cpp and PCRE2 (sentences are split by
the browser's `Intl.Segmenter`), ruy, cpuinfo and simd_utils (ARM only),
zlib and faiss (not part of Marian's WebAssembly sources), the Android NDK's
libc++.

The MPL-2.0 sources are those of the pinned submodules in
`../third_party/` (and `native/wasm/patches/`).
