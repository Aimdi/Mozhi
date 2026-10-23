import 'package:flutter/foundation.dart';

/// Package name under which the app's own license is listed.
const appLicensePackage = 'Mozhi app';

/// Package name of the Google ML Kit notice.
const mlKitLicensePackage = 'Google ML Kit';

/// Package name of the native Android/iOS libraries notice.
const nativeLibrariesLicensePackage = 'Native platform libraries';

/// Package name of the offline translation engine's notice
/// (`libmozhi_bergamot.so`, packages/bergamot_translator).
const bergamotEngineLicensePackage = 'Firefox Translations engine (Bergamot)';

/// Package name of the web app's offline translation engine's notice
/// (`bergamot-translator.wasm`, built by
/// packages/bergamot_translator/tool/build_wasm.sh).
const bergamotWebEngineLicensePackage =
    'Firefox Translations engine for the web (WebAssembly)';

/// Package name of the notice of the offline translation models.
const bergamotModelsLicensePackage = 'Firefox Translations models';

/// Package name of the text recognition engine's notice
/// (`libmozhi_tesseract.so`, packages/tesseract_ocr).
const tesseractEngineLicensePackage = 'Tesseract OCR engine';

/// Package name of the notice of the text recognition language data.
const tesseractDataLicensePackage = 'Tesseract language data (tessdata_fast)';

/// Package name of the offline speech recognition engine's notice
/// (`libmozhi_whisper.so`, packages/whisper_speech).
const whisperEngineLicensePackage = 'Whisper speech recognition (whisper.cpp)';

/// Package name of the notice of the offline speech recognition models.
const whisperModelsLicensePackage = 'Whisper speech models (OpenAI)';

/// Package name of the on-device AI engine's notice
/// (`libmozhi_llama*.so`, packages/llama_engine).
const llamaEngineLicensePackage = 'On-device AI engine (llama.cpp)';

/// Package name of the notice of the on-device AI models
/// (packages/llama_engine/assets/models.json).
const onDeviceAiModelsLicensePackage =
    'On-device AI models (Hy-MT2, Gemma 4, Qwen3)';

/// Package name of the notice of the practice scheduler
/// (`lib/practice/data/fsrs.dart`, a port of py-fsrs).
const fsrsLicensePackage = 'FSRS spaced repetition scheduler (py-fsrs)';

/// The app's own license (repository `LICENSE`).
const appLicenseText = '''
MIT License

Copyright (c) 2026 io.github.aimdi

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
SOFTWARE.''';

/// ML Kit is a closed-source Google SDK (not a pub package), so Flutter's
/// generated NOTICES do not cover it.
const mlKitLicenseText = '''
On-device text recognition (camera and image translation) uses Google ML
Kit (com.google.mlkit:text-recognition and its Chinese, Devanagari,
Japanese and Korean script models). Only this build variant includes it.

ML Kit is provided by Google LLC and its use is subject to the ML Kit Terms
of Service: https://developers.google.com/ml-kit/terms

Text recognition runs on this device; the images are not sent to Google.
According to the terms above, ML Kit sends metrics about the performance
and use of its APIs to Google.

ML Kit includes open-source components (for example TensorFlow Lite,
Apache License 2.0). Their notices are published at
https://developers.google.com/ml-kit/terms and in the SDK distributions.

ML Kit brings Google Play services components (Google LLC), which are
subject to the Android Software Development Kit License
(https://developer.android.com/studio/terms).''';

/// Native libraries pulled in by Flutter plugins (Gradle / CocoaPods), which
/// Flutter's generated NOTICES do not list either.
const nativeLibrariesLicenseText = '''
The Android build includes the Kotlin standard library (JetBrains) and
AndroidX libraries used by the plugins (Android Open Source Project).

These components are licensed under the Apache License, Version 2.0
(https://www.apache.org/licenses/LICENSE-2.0).

Unless required by applicable law or agreed to in writing, software
distributed under these licenses is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.''';

/// The notices of `libmozhi_bergamot.so`, from
/// `packages/bergamot_translator/native/THIRD_PARTY_NOTICES.md` (a test
/// checks that every component listed there is named here).
const bergamotEngineLicenseText = '''
Offline translation runs Mozilla's Firefox Translations inference engine
(bergamot-translator) and the Marian neural machine translation framework,
compiled into one native library (libmozhi_bergamot.so) together with the
CLD2 language identifier.

Source code: https://github.com/mozilla/translations (directory
inference/) and https://github.com/CLD2Owners/cld2, pinned as git
submodules in
packages/bergamot_translator/native/third_party/ of the Mozhi repository
(https://github.com/Aimdi/Mozhi), together with the build files and the
local changes. The Mozilla Public License 2.0 files are unmodified.

Components and their licenses:
- bergamot-translator (Mozilla): Mozilla Public License 2.0
- Marian (browsermt/Mozilla fork): MIT, Copyright (c) 2016 Marcin Junczys-Dowmunt, the University of Edinburgh, Adam Mickiewicz University
- ssplit-cpp (sentence splitter): Apache License 2.0
- SentencePiece (browsermt fork): Apache License 2.0
- protobuf-lite (inside SentencePiece): BSD-3-Clause, Copyright 2008 Google Inc.
- intgemm: MIT
- ruy: Apache License 2.0
- cpuinfo (used by ruy): BSD-2-Clause
- simd_utils: BSD-2-Clause, Copyright (c) 2019 JishinMaster (includes sse2neon, MIT)
- yaml-cpp: MIT, Copyright (c) 2008-2015 Jesse Beder
- spdlog / fmt: MIT, Copyright (c) 2016 Gabi Melman
- pathie-cpp: BSD-2-Clause, Copyright (c) 2015, 2017 Marvin Gülker
- zstr: MIT, Copyright (c) 2015 Matei David, Ontario Institute for Cancer Research
- CLI11: BSD-3-Clause
- sse_mathfun / avx_mathfun / threadpool: zlib
- cnpy, phf, mio, half_float: MIT
- zlib 1.2.11: zlib, Copyright (C) 1995-2017 Jean-loup Gailly and Mark Adler
- faiss (compiled with Marian; its code is not used): MIT, Copyright (c) Facebook, Inc. and its affiliates
- PCRE2 10.47: BSD-3-Clause, with the PCRE2 binary-redistribution exemption
- CLD2 (Compact Language Detector 2, language identification): Apache License 2.0, Copyright 2013 Google Inc.
- LLVM libc++ (Android NDK, linked statically): Apache License 2.0 with LLVM exception
- The mozhi_bergamot interface and Mozhi's two Marian alignment fixes: MIT, like the app

License texts:
- Mozilla Public License 2.0: https://mozilla.org/MPL/2.0/
- Apache License 2.0: https://www.apache.org/licenses/LICENSE-2.0
- MIT: https://opensource.org/license/mit
- BSD-2-Clause: https://opensource.org/license/bsd-2-clause
- BSD-3-Clause: https://opensource.org/license/bsd-3-clause
- zlib: https://opensource.org/license/zlib

Unless required by applicable law or agreed to in writing, these
components are distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
CONDITIONS OF ANY KIND, either express or implied.

zlib 1.2.11, Copyright (C) 1995-2017 Jean-loup Gailly and Mark Adler:
This software is provided 'as-is', without any express or implied
warranty. In no event will the authors be held liable for any damages
arising from the use of this software. Permission is granted to anyone to
use this software for any purpose, including commercial applications, and
to alter it and redistribute it freely, subject to the following
restrictions: 1. The origin of this software must not be misrepresented;
you must not claim that you wrote the original software. If you use this
software in a product, an acknowledgment in the product documentation
would be appreciated but is not required. 2. Altered source versions must
be plainly marked as such, and must not be misrepresented as being the
original software. 3. This notice may not be removed or altered from any
source distribution.

faiss, MIT License, Copyright (c) Facebook, Inc. and its affiliates:
Permission is hereby granted, free of charge, to any person obtaining a
copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to permit
persons to whom the Software is furnished to do so, subject to the
following conditions: The above copyright notice and this permission
notice shall be included in all copies or substantial portions of the
Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN
NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
USE OR OTHER DEALINGS IN THE SOFTWARE.''';

/// The notices of `libmozhi_tesseract.so`, from
/// `packages/tesseract_ocr/native/THIRD_PARTY_NOTICES.md` (a test checks
/// that every component listed there is named here).
const tesseractEngineLicenseText = '''
On-device text recognition (photo and camera translation) runs the
Tesseract OCR engine with the Leptonica image processing library, compiled
into one native library (libmozhi_tesseract.so).

Source code: https://github.com/tesseract-ocr/tesseract (tag 5.5.3) and
https://github.com/DanBloomberg/leptonica (tag 1.87.0), pinned as git
submodules in packages/tesseract_ocr/native/third_party/ of the Mozhi
repository (https://github.com/Aimdi/Mozhi), together with the build files.
Both are unmodified.

Components and their licenses:
- Tesseract OCR 5.5.3: Apache License 2.0, Copyright Hewlett-Packard Company, Google Inc. and the Tesseract contributors
- Leptonica 1.87.0: BSD-2-Clause, Copyright (C) 2001-2020 Leptonica (its red-black tree is derived from public-domain CC0 code)
- LLVM libc++ (Android NDK, linked statically): Apache License 2.0 with LLVM exception
- The mozhi_tesseract interface: MIT, like the app

License texts:
- Apache License 2.0: https://www.apache.org/licenses/LICENSE-2.0

Leptonica, Copyright (C) 2001-2020 Leptonica. All rights reserved.
Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met: 1. Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.
THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL ANY CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
SUCH DAMAGE.''';

/// The license of the text recognition language data (downloaded at run
/// time, never bundled).
const tesseractDataLicenseText = '''
The text recognition language data is Tesseract's tessdata_fast
(https://github.com/tesseract-ocr/tessdata_fast), licensed under the
Apache License 2.0 (https://www.apache.org/licenses/LICENSE-2.0).

It is not part of the app: each language is downloaded only when you
choose it, from GitHub (raw.githubusercontent.com) or the mirror chosen
in Settings > Translation engines > Model source, checked against the
SHA-256 checksums bundled with the app and kept on this device.''';

/// The notices of the web app's engine (`bergamot-translator.{js,wasm}`),
/// from `packages/bergamot_translator/native/wasm/THIRD_PARTY_NOTICES.md`:
/// the native engine's components it compiles, plus these.
const bergamotWebEngineLicenseText = '''
In the web app, offline translation runs the same Firefox Translations
engine (bergamot-translator, Marian, SentencePiece, intgemm, CLD2 and the
other components listed under "Firefox Translations engine (Bergamot)",
except ssplit-cpp, PCRE2, ruy, cpuinfo, simd_utils, zlib, faiss and the
Android NDK's libc++) compiled to WebAssembly with Emscripten 3.1.8, in a
Web Worker on this device. Sentences are split by the browser.

Source code and build: packages/bergamot_translator/tool/build_wasm.sh and
packages/bergamot_translator/native/wasm/ of the Mozhi repository
(https://github.com/Aimdi/Mozhi).

Additional components and their licenses:
- import-gemm-module.js and the Emscripten glue patch (Mozilla, inference/wasm): Mozilla Public License 2.0
- ONNX.js wasm-ops (browsermt/onnxjs; the float matrix multiplication): MIT, Copyright (c) Microsoft Corporation
- Eigen (used by ONNX.js, built with EIGEN_MPL2_ONLY): Mozilla Public License 2.0
- Emscripten runtime (JavaScript glue): MIT / University of Illinois NCSA Open Source License
- musl libc: MIT
- LLVM libc++, libc++abi and compiler-rt: Apache License 2.0 with LLVM exception

License texts:
- Mozilla Public License 2.0: https://mozilla.org/MPL/2.0/
- Apache License 2.0: https://www.apache.org/licenses/LICENSE-2.0
- MIT: https://opensource.org/license/mit
- University of Illinois/NCSA: https://opensource.org/license/uoi-ncsa''';

/// The license of the Firefox Translations models (downloaded at run time,
/// never bundled).
const bergamotModelsLicenseText = '''
The offline translation models are Mozilla's Firefox Translations models
(https://github.com/mozilla/firefox-translations-models), licensed under
the Mozilla Public License 2.0 (https://mozilla.org/MPL/2.0/).

They are not part of the app: each language is downloaded only when you
choose it, from Mozilla's Firefox Translations storage
(storage.googleapis.com) or the mirror chosen in Settings > Translation
engines > Model source, checked against the SHA-256 checksums bundled
with the app and kept on this device.''';

/// The notices of `libmozhi_whisper.so`, from
/// `packages/whisper_speech/native/THIRD_PARTY_NOTICES.md`.
const whisperEngineLicenseText = '''
Offline voice input runs OpenAI's Whisper speech recognition with
whisper.cpp and its ggml tensor library (CPU only), compiled into one
native library (libmozhi_whisper.so; on 64-bit ARM also
libmozhi_whisper_dotprod.so and libmozhi_whisper_i8mm.so, the same code
built for newer processors, of which the app loads the fastest one the
phone supports).

Source code: https://github.com/ggml-org/whisper.cpp (tag v1.9.5), pinned
as a git submodule in packages/whisper_speech/native/third_party/ of the
Mozhi repository (https://github.com/Aimdi/Mozhi), together with the build
files.

Components and their licenses:
- whisper.cpp and ggml: MIT, Copyright (c) 2023-2026 The ggml authors
- YaRN RoPE scaling in ggml: MIT, Copyright (c) 2023 Jeffrey Quesnelle and Bowen Peng
- LLVM libc++ (Android NDK, linked statically): Apache-2.0 WITH LLVM-exception
- The mozhi_whisper interface: MIT, like the app

MIT License

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
SOFTWARE.''';

/// The notice of the Whisper models (`ggml-tiny.bin`, `ggml-base.bin`).
const whisperModelsLicenseText = '''
The offline speech models are OpenAI's Whisper tiny, base, small and
large-v3-turbo models (https://github.com/openai/whisper), converted to the
ggml format (base, small and large-v3-turbo also quantized, q5_1 and q5_0)
by the whisper.cpp project, licensed under the MIT License, Copyright (c)
2022 OpenAI.

The speech detector, which tells speech from noise so that text appears
phrase by phrase, is Silero VAD v6.2.0
(https://github.com/snakers4/silero-vad), converted to the ggml format by
the whisper.cpp project, licensed under the MIT License, Copyright (c)
2020-present Silero Team.

They are not part of the app: a model is downloaded only when you choose
it, from Hugging Face (huggingface.co/ggerganov/whisper.cpp) or the mirror
chosen in Settings > Translation engines > Model source, or imported from a
file, checked against the SHA-256 and SHA-1 checksums bundled with the app
and kept on this device.''';

/// The notice of the on-device AI models (the catalogue of
/// packages/llama_engine: GGUF files on Hugging Face).
const onDeviceAiModelsLicenseText = '''
On-device AI runs these models on this device, as GGUF files in the
Q4_K_M quantization:
- Hy-MT2 1.8B, the translation model: Copyright (C) 2026 Tencent, licensed
  under the Apache License 2.0
  (https://github.com/Tencent-Hunyuan/Hy-MT2).
- Gemma 4 E2B, an assistant model: by Google, licensed under the Apache
  License 2.0 (https://huggingface.co/google/gemma-4-E2B-it).
- Qwen3 1.7B, a smaller assistant model: by the Qwen team (Alibaba Cloud),
  licensed under the Apache License 2.0
  (https://huggingface.co/Qwen/Qwen3-1.7B).

Apache License 2.0: https://www.apache.org/licenses/LICENSE-2.0

They are not part of the app: a model is downloaded only when you choose
it, from Hugging Face (huggingface.co, pinned to one commit of its
repository) or the mirror chosen in Settings > Translation engines > Model
source, or imported from a file, checked against the size and SHA-256
checksum bundled with the app and kept on this device.''';

/// The notice of py-fsrs, which the practice scheduler is ported from.
const fsrsLicenseText = '''
Practice schedules its flashcards with FSRS-5 (Free Spaced Repetition
Scheduler), ported to Dart from py-fsrs v5.1.3
(https://github.com/open-spaced-repetition/py-fsrs), with its default
parameters. It runs on this device.

MIT License

Copyright (c) 2022 Open Spaced Repetition

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
SOFTWARE.''';

/// The notices of `libmozhi_llama*.so`, from
/// `packages/llama_engine/native/THIRD_PARTY_NOTICES.md`.
const llamaEngineLicenseText = '''
On-device AI runs language models with llama.cpp and its ggml tensor
library (CPU only), compiled into native libraries (libmozhi_llama.so; on
64-bit ARM phones also libmozhi_llama_dotprod.so and libmozhi_llama_i8mm.so,
the same code built for newer processors, of which the app loads the
fastest one the phone supports).

Source code: https://github.com/ggml-org/llama.cpp (tag v0.6.0), pinned as
a git submodule in packages/llama_engine/native/third_party/ of the Mozhi
repository (https://github.com/Aimdi/Mozhi), together with the build
files.

Components and their licenses:
- llama.cpp and ggml: MIT, Copyright (c) 2023-2026 The ggml authors
- YaRN RoPE scaling in ggml: MIT, Copyright (c) 2023 Jeffrey Quesnelle and Bowen Peng
- Unicode character tables in llama.cpp: Unicode License v3, Copyright © 1991-2026 Unicode, Inc.
- LLVM libc++ (Android NDK, linked statically): Apache-2.0 WITH LLVM-exception
- The mozhi_llama interface: MIT, like the app

MIT License

Copyright (c) 2023-2026 The ggml authors

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

UNICODE LICENSE V3

COPYRIGHT AND PERMISSION NOTICE

Copyright © 1991-2026 Unicode, Inc.

NOTICE TO USER: Carefully read the following legal agreement. BY
DOWNLOADING, INSTALLING, COPYING OR OTHERWISE USING DATA FILES, AND/OR
SOFTWARE, YOU UNEQUIVOCALLY ACCEPT, AND AGREE TO BE BOUND BY, ALL OF THE
TERMS AND CONDITIONS OF THIS AGREEMENT. IF YOU DO NOT AGREE, DO NOT
DOWNLOAD, INSTALL, COPY, DISTRIBUTE OR USE THE DATA FILES OR SOFTWARE.

Permission is hereby granted, free of charge, to any person obtaining a
copy of data files and any associated documentation (the "Data Files") or
software and any associated documentation (the "Software") to deal in the
Data Files or Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, and/or sell
copies of the Data Files or Software, and to permit persons to whom the
Data Files or Software are furnished to do so, provided that either (a)
this copyright and permission notice appear with all copies of the Data
Files or Software, or (b) this copyright and permission notice appear in
associated Documentation.

THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
THIRD PARTY RIGHTS.

IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS INCLUDED IN THIS NOTICE
BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR CONSEQUENTIAL DAMAGES,
OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS,
WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THE DATA
FILES OR SOFTWARE.

Except as contained in this notice, the name of a copyright holder shall
not be used in advertising or otherwise to promote the sale, use or other
dealings in these Data Files or Software without prior written
authorization of the copyright holder.''';

bool _registered = false;

/// Adds the notices Flutter does not collect from pub packages (the app's
/// own license, the offline translation engine and models, the text
/// recognition engine and data, the offline speech recognition engine and
/// models, the on-device AI models, the practice scheduler, ML Kit and
/// native platform libraries) to
/// the [LicenseRegistry] shown by `showLicensePage`. Safe to call
/// repeatedly.
///
/// The ML Kit notice is only added with [includeMlKit] (the Play variant;
/// `bootstrap` passes `mlKitIncluded`), and the web engine's with
/// [includeWebEngine] (default: in the web app).
void registerThirdPartyLicenses({
  bool includeMlKit = false,
  bool includeWebEngine = kIsWeb,
}) {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(
    () => Stream.fromIterable([
      const LicenseEntryWithLineBreaks([appLicensePackage], appLicenseText),
      const LicenseEntryWithLineBreaks([
        bergamotEngineLicensePackage,
      ], bergamotEngineLicenseText),
      if (includeWebEngine)
        const LicenseEntryWithLineBreaks([
          bergamotWebEngineLicensePackage,
        ], bergamotWebEngineLicenseText),
      const LicenseEntryWithLineBreaks([
        bergamotModelsLicensePackage,
      ], bergamotModelsLicenseText),
      const LicenseEntryWithLineBreaks([
        tesseractEngineLicensePackage,
      ], tesseractEngineLicenseText),
      const LicenseEntryWithLineBreaks([
        tesseractDataLicensePackage,
      ], tesseractDataLicenseText),
      const LicenseEntryWithLineBreaks([
        whisperEngineLicensePackage,
      ], whisperEngineLicenseText),
      const LicenseEntryWithLineBreaks([
        whisperModelsLicensePackage,
      ], whisperModelsLicenseText),
      const LicenseEntryWithLineBreaks([
        llamaEngineLicensePackage,
      ], llamaEngineLicenseText),
      const LicenseEntryWithLineBreaks([
        onDeviceAiModelsLicensePackage,
      ], onDeviceAiModelsLicenseText),
      const LicenseEntryWithLineBreaks([fsrsLicensePackage], fsrsLicenseText),
      if (includeMlKit)
        const LicenseEntryWithLineBreaks([
          mlKitLicensePackage,
        ], mlKitLicenseText),
      const LicenseEntryWithLineBreaks([
        nativeLibrariesLicensePackage,
      ], nativeLibrariesLicenseText),
    ]),
  );
}

/// Lets tests register the notices again after `LicenseRegistry.reset`.
@visibleForTesting
void resetThirdPartyLicensesForTesting() => _registered = false;
