# Third-party notices: libmozhi_bergamot

`libmozhi_bergamot.so` (shipped in the APK) is built from the sources below,
all vendored as pinned git submodules under `third_party/` and compiled
statically: the translation engine and the CLD2 language identifier. Nothing here is GPL or proprietary. The app (MIT) must show
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
| zlib 1.2.11 (gzip model and config reading) | `marian-fork/src/3rd_party/zlib` | zlib (© 1995-2017 Jean-loup Gailly and Mark Adler) |
| faiss (LSH index; compiled with Marian, unreferenced, so the linker drops it: checked on Linux x86_64) | `marian-fork/src/3rd_party/faiss` | MIT (© Facebook, Inc. and its affiliates) |
| PCRE2 10.47 | `third_party/pcre2` ([PCRE2Project/pcre2](https://github.com/PCRE2Project/pcre2)) | BSD-3-Clause (with the PCRE2 binary-redistribution exemption) |
| CLD2 (Compact Language Detector 2, language identification; unmodified, "chrome" tables) | `third_party/cld2` ([CLD2Owners/cld2](https://github.com/CLD2Owners/cld2)) | Apache-2.0 (© 2013 Google Inc.) |
| LLVM libc++ (NDK, linked statically) | Android NDK r28 | Apache-2.0 WITH LLVM-exception |

Local changes: `patches/0001-marian-unaligned-quant-mult.patch` and
`patches/0002-marian-unaligned-binary-header.patch` (MIT, like the Marian
files they modify).

The translation **models** are downloaded at run time (never bundled) from
Mozilla's Firefox Translations bucket and are licensed MPL-2.0
(<https://github.com/mozilla/firefox-translations-models>).

The `mozhi_bergamot` shim itself (`src/`, `tool/`, `cmake/`) is MIT, like the
app.

License texts: Apache-2.0 <https://www.apache.org/licenses/LICENSE-2.0>,
MPL-2.0 <https://mozilla.org/MPL/2.0/>, and in each component's checkout
(`LICENSE`, `LICENSE.md`, `COPYING`; zlib's notice is at the top of
`zlib/zlib.h`). The zlib and faiss notices, reproduced because they are
short:

```
zlib 1.2.11, Copyright (C) 1995-2017 Jean-loup Gailly and Mark Adler

This software is provided 'as-is', without any express or implied
warranty.  In no event will the authors be held liable for any damages
arising from the use of this software.

Permission is granted to anyone to use this software for any purpose,
including commercial applications, and to alter it and redistribute it
freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not
   claim that you wrote the original software. If you use this software
   in a product, an acknowledgment in the product documentation would be
   appreciated but is not required.
2. Altered source versions must be plainly marked as such, and must not be
   misrepresented as being the original software.
3. This notice may not be removed or altered from any source distribution.
```

```
faiss: MIT License, Copyright (c) Facebook, Inc. and its affiliates.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
