# Third-party notices: libmozhi_tesseract

`libmozhi_tesseract.so` (shipped in the APK) is built from the sources
below, vendored as pinned git submodules under `third_party/` and compiled
statically. Nothing here is GPL or proprietary, and nothing comes from
Google Play services or ML Kit. The app (MIT) must show these notices (e.g.
on its licenses page).

| Component | Where | License |
| --- | --- | --- |
| Tesseract OCR 5.5.3 (LSTM recognizer, layout analysis; the legacy engine, training tools and ScrollView are not built) | `third_party/tesseract` ([tesseract-ocr/tesseract](https://github.com/tesseract-ocr/tesseract), tag `5.5.3`, commit `db0ec62f81b0737fbbe184d8fea40af5738f8eef`) | Apache-2.0 (© Hewlett-Packard Company, Google Inc. and the Tesseract contributors) |
| Leptonica 1.87.0 (image processing: thresholding, scaling, connected components; no image codecs) | `third_party/leptonica` ([DanBloomberg/leptonica](https://github.com/DanBloomberg/leptonica), tag `1.87.0`, commit `13275a278eb55b5746e33f95fbf5a2c8f604b3ab`) | BSD-2-Clause (© 2001-2020 Leptonica); its red-black tree (`rbtree.c`) is derived from public-domain (CC0 1.0) code |
| LLVM libc++ (NDK, linked statically) | Android NDK r28 | Apache-2.0 WITH LLVM-exception |

No local changes: both checkouts are unmodified. Tesseract's Android build
asks for Google's `cpu_features` (to detect NEON on 32-bit ARM); it is not
used or linked: `cmake/CpuFeaturesNdkCompatConfig.cmake` stands in for it
and `getauxval()` detects NEON instead.

The **language data** is downloaded at run time (never bundled), one
`<code>.traineddata` file per language, from Tesseract's
[tessdata_fast](https://github.com/tesseract-ocr/tessdata_fast) repository
at commit `87416418657359cb625c412a48b6e1d6d41c29bd`, licensed Apache-2.0
(© Google Inc. and the Tesseract contributors). `../assets/catalog.json`
lists the files with their sizes and SHA-256 checksums
(`../tool/tessdata_catalog.py`).

The `mozhi_tesseract` shim itself (`src/`, `tool/`, `cmake/`) is MIT, like
the app.

License texts: Apache-2.0 <https://www.apache.org/licenses/LICENSE-2.0>
(and `third_party/tesseract/LICENSE`); Leptonica's, reproduced because it
is short (also `third_party/leptonica/leptonica-license.txt`):

```
Copyright (C) 2001-2020 Leptonica.  All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above
   copyright notice, this list of conditions and the following
   disclaimer in the documentation and/or other materials
   provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL ANY
CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```
