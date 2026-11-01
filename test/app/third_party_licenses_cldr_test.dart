import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/app/third_party_licenses.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LicenseRegistry.reset();
    resetThirdPartyLicensesForTesting();
  });
  tearDown(LicenseRegistry.reset);

  test('lists the language names under the Unicode License v3', () async {
    registerThirdPartyLicenses();
    final entries = await LicenseRegistry.licenses.toList();
    final entry = entries.singleWhere(
      (e) => e.packages.contains(cldrLicensePackage),
    );
    expect(
      entry.paragraphs.map((p) => p.text).join('\n'),
      allOf(
        contains('Unicode Common Locale Data Repository (CLDR), version'),
        contains(languageNamesCldrVersion),
        contains('tool/language_names.py'),
        contains('UNICODE LICENSE V3'),
        contains('Copyright © 2001–2026 Unicode, Inc.'),
        contains('this copyright and permission notice appear with all'),
        contains('THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS"'),
      ),
    );
  });

  test('names the CLDR release of the generated names', () {
    expect(languageNamesCldrVersion, '49');
    expect(cldrLicenseText, contains('version\n49 '));
  });
}
