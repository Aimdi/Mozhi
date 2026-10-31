import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/app/third_party_licenses.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LicenseRegistry.reset();
    resetThirdPartyLicensesForTesting();
  });
  tearDown(LicenseRegistry.reset);

  test('lists the terminal font under the SIL Open Font License', () async {
    registerThirdPartyLicenses();
    final entries = await LicenseRegistry.licenses.toList();
    final entry = entries.singleWhere(
      (e) => e.packages.contains(jetBrainsMonoLicensePackage),
    );
    expect(
      entry.paragraphs.map((p) => p.text).join('\n'),
      allOf(
        contains('Copyright 2020 The JetBrains Mono Project Authors'),
        contains('SIL OPEN FONT LICENSE Version 1.1'),
        contains('Reserved Font Name'),
        contains('THE FONT SOFTWARE IS PROVIDED "AS IS"'),
      ),
    );
  });

  test('is the bundled OFL.txt word for word', () {
    final bundled = File('assets/fonts/jetbrains_mono/OFL.txt')
        .readAsStringSync();
    expect(jetBrainsMonoLicenseText.trim(), bundled.trim());
  });
}
