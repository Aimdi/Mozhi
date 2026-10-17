# Third-party notices: libmozhi_bergamot

`libmozhi_bergamot.so` (shipped in the APK) is built from the sources below,
all vendored as pinned git submodules under `third_party/` and compiled
statically. Nothing here is GPL or proprietary. The app (MIT) must show
these notices (e.g. on its licenses page) and, for the MPL-2.0 parts, say
where their source is available (the submodule URLs and commits below).

| Component | Where | License |
| --- | --- | --- |
| bergamot-translator (Mozilla's Firefox Translations inference engine) | `third_party/translations/inference` ([mozilla/translations](https://github.com/mozilla/translations)) | MPL-2.0 |
| Marian (browsermt/Mozilla fork) | `third_party/translations/inference/marian-fork` | MIT (© 2016 Marcin Junczys-Dowmunt, University of Edinburgh, Adam Mickiewicz University) |
| ssplit-cpp (sentence splitter) | `inference/3rd_party/ssplit-cpp` | Apache-2.0 (its LGPL `nonbreaking_prefixes/` data files are not compiled in or shipped) |
| SentencePiece (browsermt fork) | `marian-fork/src/3rd_party/sentencepiece` | Apache-2.0 |
| protobuf-lite (inside SentencePiece) | `sentencepiece/third_party/protobuf-lite` | BSD-3-Clause (© 2008 Google Inc.) |
| intgemm (x86_64 int8 GEMM) | `marian-fork/src/3rd_party/intgemm` | MIT |
| ruy (ARM int8 GEMM; float GEMM everywhere) | `marian-fork/src/3rd_party/ruy` | Apache-2.0 |
| cpuinfo (used by ruy) | `ruy/third_party/cpuinfo` | BSD-2-Clause |
| simd_utils (SSE-on-NEON, ARM) | `marian-fork/src/3rd_party/simd_utils` | BSD-2-Clause (© 2019 JishinMaster; includes sse2neon, MIT) |
| yaml-cpp | `marian-fork/src/3rd_party/yaml-cpp` | MIT (© 2008-2015 Jesse Beder) |
| spdlog / fmt | `marian-fork/src/3rd_party/spdlog` | MIT (© 2016 Gabi Melman) |
| pathie-cpp | `marian-fork/src/3rd_party/pathie-cpp` | BSD-2-Clause (© 2015, 2017 Marvin Gülker) |
| zstr | `marian-fork/src/3rd_party/zstr` | MIT (© 2015 Matei David, OICR) |
| CLI11 | `marian-fork/src/3rd_party/CLI` | BSD-3-Clause |
| sse_mathfun / avx_mathfun / threadpool | `marian-fork/src/3rd_party/*.h` | zlib |
| cnpy, phf, mio, half_float | `marian-fork/src/3rd_party/` | MIT |
| PCRE2 10.47 | `third_party/pcre2` ([PCRE2Project/pcre2](https://github.com/PCRE2Project/pcre2)) | BSD-3-Clause (with the PCRE2 binary-redistribution exemption) |
| LLVM libc++ (NDK, linked statically) | Android NDK r28 | Apache-2.0 WITH LLVM-exception |

Local changes: `patches/0001-marian-unaligned-quant-mult.patch` and
`patches/0002-marian-unaligned-binary-header.patch` (MIT, like the Marian
files they modify).

The translation **models** are downloaded at run time (never bundled) from
Mozilla's Firefox Translations bucket and are licensed MPL-2.0
(<https://github.com/mozilla/firefox-translations-models>).

The `mozhi_bergamot` shim itself (`src/`, `tool/`, `cmake/`) is MIT, like the
app.
