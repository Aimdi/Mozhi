import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/app/third_party_licenses.dart';

Future<List<LicenseEntry>> _entries() => LicenseRegistry.licenses.toList();

String _text(List<LicenseEntry> entries, String package) => entries
    .singleWhere((e) => e.packages.contains(package))
    .paragraphs
    .map((p) => p.text)
    .join('\n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LicenseRegistry.reset();
    resetThirdPartyLicensesForTesting();
  });
  tearDown(LicenseRegistry.reset);

  group('registerThirdPartyLicenses', () {
    test('adds the app, offline engine and native library notices', () async {
      registerThirdPartyLicenses();

      final entries = await _entries();
      final packages = {for (final e in entries) ...e.packages};
      expect(
        packages,
        containsAll([
          appLicensePackage,
          bergamotEngineLicensePackage,
          bergamotModelsLicensePackage,
          nativeLibrariesLicensePackage,
        ]),
      );
      expect(
        _text(entries, appLicensePackage).split('\n').first,
        'MIT License',
      );
      expect(
        _text(entries, bergamotEngineLicensePackage),
        allOf(
          contains('https://github.com/mozilla/translations'),
          contains('Mozilla Public License 2.0'),
        ),
      );
      expect(
        _text(entries, bergamotModelsLicensePackage),
        allOf(
          contains('Mozilla Public License 2.0'),
          contains('storage.googleapis.com'),
        ),
      );
    });

    test('leaves out ML Kit and Play services by default', () async {
      registerThirdPartyLicenses();

      final entries = await _entries();
      final packages = {for (final e in entries) ...e.packages};
      expect(packages, isNot(contains(mlKitLicensePackage)));
      expect(
        _text(entries, nativeLibrariesLicensePackage),
        isNot(contains('Google Play services')),
      );
    });

    test('adds the ML Kit notice in the Play variant', () async {
      registerThirdPartyLicenses(includeMlKit: true);

      final entries = await _entries();
      final text = _text(entries, mlKitLicensePackage);
      expect(text, contains('https://developers.google.com/ml-kit/terms'));
      expect(text, contains('Google Play services'));
    });

    test('lists the web engine only in the web app', () async {
      registerThirdPartyLicenses();
      var packages = {for (final e in await _entries()) ...e.packages};
      expect(packages, isNot(contains(bergamotWebEngineLicensePackage)));

      LicenseRegistry.reset();
      resetThirdPartyLicensesForTesting();
      registerThirdPartyLicenses(includeWebEngine: true);

      final entries = await _entries();
      packages = {for (final e in entries) ...e.packages};
      expect(packages, contains(bergamotWebEngineLicensePackage));
      final text = _text(entries, bergamotWebEngineLicensePackage);
      expect(text, contains('WebAssembly'));
      expect(text, contains('ONNX.js'));
      expect(text, contains('EIGEN_MPL2_ONLY'));
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

  group('bergamotEngineLicenseText', () {
    test('names every component of THIRD_PARTY_NOTICES.md', () {
      final notices = File(
        'packages/bergamot_translator/native/THIRD_PARTY_NOTICES.md',
      ).readAsLinesSync();
      final components = [
        for (final line in notices)
          if (line.startsWith('| ') &&
              !line.startsWith('| Component') &&
              !line.startsWith('| ---'))
            line.substring(2).split(' | ').first.split(' (').first.trim(),
      ];

      expect(components, hasLength(greaterThan(10)));
      for (final component in components) {
        expect(bergamotEngineLicenseText, contains(component));
      }
    });

    test('names the language identifier and quotes the short licenses', () {
      expect(
        bergamotEngineLicenseText,
        allOf(
          contains('CLD2'),
          contains('https://github.com/CLD2Owners/cld2'),
          // zlib's and faiss's own notices, not just their names.
          contains('This notice may not be removed or altered'),
          contains('Copyright (c) Facebook, Inc. and its affiliates'),
          contains('The above copyright notice and this permission'),
        ),
      );
    });
  });

  group('tesseractEngineLicenseText', () {
    test('names every component of THIRD_PARTY_NOTICES.md', () {
      final notices = File(
        'packages/tesseract_ocr/native/THIRD_PARTY_NOTICES.md',
      ).readAsLinesSync();
      final components = [
        for (final line in notices)
          if (line.startsWith('| ') &&
              !line.startsWith('| Component') &&
              !line.startsWith('| ---'))
            line.substring(2).split(' | ').first.split(' (').first.trim(),
      ];

      expect(components, hasLength(3));
      for (final component in components) {
        expect(tesseractEngineLicenseText, contains(component));
      }
    });

    test('is registered with the language data notice', () async {
      registerThirdPartyLicenses();

      final entries = await _entries();
      expect(
        _text(entries, tesseractEngineLicensePackage),
        allOf(
          contains('https://github.com/tesseract-ocr/tesseract'),
          contains('Apache License 2.0'),
          contains('Redistributions in binary form must reproduce'),
        ),
      );
      expect(
        _text(entries, tesseractDataLicensePackage),
        allOf(
          contains('https://github.com/tesseract-ocr/tessdata_fast'),
          contains('raw.githubusercontent.com'),
        ),
      );
    });
  });

  test('lists the practice scheduler with the py-fsrs notice', () async {
    registerThirdPartyLicenses();

    expect(
      _text(await _entries(), fsrsLicensePackage),
      allOf(
        contains('https://github.com/open-spaced-repetition/py-fsrs'),
        contains('Copyright (c) 2022 Open Spaced Repetition'),
        contains('The above copyright notice and this permission'),
      ),
    );
  });
}
