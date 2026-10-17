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

/// Package name of the notice of the offline translation models.
const bergamotModelsLicensePackage = 'Firefox Translations models';

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

/// The license of the Firefox Translations models (downloaded at run time,
/// never bundled).
const bergamotModelsLicenseText = '''
The offline translation models are Mozilla's Firefox Translations models
(https://github.com/mozilla/firefox-translations-models), licensed under
the Mozilla Public License 2.0 (https://mozilla.org/MPL/2.0/).

They are not part of the app: each language is downloaded only when you
choose it, from Mozilla's Firefox Translations storage
(storage.googleapis.com), checked against the SHA-256 checksums bundled
with the app and kept on this device.''';

bool _registered = false;

/// Adds the notices Flutter does not collect from pub packages (the app's
/// own license, the offline translation engine and models, ML Kit and
/// native platform libraries) to the [LicenseRegistry] shown by
/// `showLicensePage`. Safe to call repeatedly.
///
/// The ML Kit notice is only added with [includeMlKit] (the Play variant;
/// `bootstrap` passes `mlKitIncluded`).
void registerThirdPartyLicenses({bool includeMlKit = false}) {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(
    () => Stream.fromIterable([
      const LicenseEntryWithLineBreaks([appLicensePackage], appLicenseText),
      const LicenseEntryWithLineBreaks([
        bergamotEngineLicensePackage,
      ], bergamotEngineLicenseText),
      const LicenseEntryWithLineBreaks([
        bergamotModelsLicensePackage,
      ], bergamotModelsLicenseText),
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
