import 'package:flutter/foundation.dart';

/// Package name under which the app's own license is listed.
const appLicensePackage = 'Mozhi app';

/// Package name of the Google ML Kit notice.
const mlKitLicensePackage = 'Google ML Kit';

/// Package name of the native Android/iOS libraries notice.
const nativeLibrariesLicensePackage = 'Native platform libraries';

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
On-device text recognition, translation and language identification use
Google ML Kit (com.google.mlkit:text-recognition, translate, language-id on
Android; the GoogleMLKit pods on iOS).

ML Kit is provided by Google LLC and its use is subject to the ML Kit Terms
of Service: https://developers.google.com/ml-kit/terms

Text recognition and translation run on this device; the text and images
are not sent to Google. ML Kit downloads language packs and models from
Google and, according to the terms above, sends metrics about the
performance and use of its APIs to Google.

ML Kit includes open-source components (for example TensorFlow Lite,
Apache License 2.0). Their notices are published at
https://developers.google.com/ml-kit/terms and in the SDK distributions.''';

/// Native libraries pulled in by Flutter plugins (Gradle / CocoaPods), which
/// Flutter's generated NOTICES do not list either.
const nativeLibrariesLicenseText = '''
The Android build includes the Kotlin standard library (JetBrains),
AndroidX libraries and Google Play services components used by the plugins
(Android Open Source Project / Google LLC). The iOS build includes Google
utility pods used by ML Kit (GoogleUtilities, GoogleToolboxForMac,
GTMSessionFetcher, PromisesObjC; Google LLC) and nanopb (Petteri Aimonen).

These components are licensed under the Apache License, Version 2.0
(https://www.apache.org/licenses/LICENSE-2.0), except nanopb, which is
licensed under the zlib license (https://opensource.org/license/zlib), and
Google Play services, which is subject to the Android Software Development
Kit License (https://developer.android.com/studio/terms).

Unless required by applicable law or agreed to in writing, software
distributed under these licenses is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.''';

bool _registered = false;

/// Adds the notices Flutter does not collect from pub packages (the app's
/// own license, ML Kit and native platform libraries) to the
/// [LicenseRegistry] shown by `showLicensePage`. Safe to call repeatedly.
void registerThirdPartyLicenses() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(
    () => Stream.fromIterable(const [
      LicenseEntryWithLineBreaks([appLicensePackage], appLicenseText),
      LicenseEntryWithLineBreaks([mlKitLicensePackage], mlKitLicenseText),
      LicenseEntryWithLineBreaks([
        nativeLibrariesLicensePackage,
      ], nativeLibrariesLicenseText),
    ]),
  );
}

/// Lets tests register the notices again after `LicenseRegistry.reset`.
@visibleForTesting
void resetThirdPartyLicensesForTesting() => _registered = false;
