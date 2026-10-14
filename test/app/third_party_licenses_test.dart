import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/app/third_party_licenses.dart';

Future<List<LicenseEntry>> _entries() => LicenseRegistry.licenses.toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LicenseRegistry.reset();
    resetThirdPartyLicensesForTesting();
  });
  tearDown(LicenseRegistry.reset);

  group('registerThirdPartyLicenses', () {
    test('adds the app, ML Kit and native library notices', () async {
      registerThirdPartyLicenses();

      final entries = await _entries();
      final packages = {for (final e in entries) ...e.packages};
      expect(
        packages,
        containsAll([
          appLicensePackage,
          mlKitLicensePackage,
          nativeLibrariesLicensePackage,
        ]),
      );
      final mlKit = entries.singleWhere(
        (e) => e.packages.contains(mlKitLicensePackage),
      );
      final text = mlKit.paragraphs.map((p) => p.text).join('\n');
      expect(text, contains('https://developers.google.com/ml-kit/terms'));
      final app = entries.singleWhere(
        (e) => e.packages.contains(appLicensePackage),
      );
      expect(app.paragraphs.first.text, 'MIT License');
    });

    test('registers only once', () async {
      registerThirdPartyLicenses();
      registerThirdPartyLicenses();

      final entries = await _entries();
      expect(
        entries.where((e) => e.packages.contains(appLicensePackage)),
        hasLength(1),
      );
    });
  });
}
