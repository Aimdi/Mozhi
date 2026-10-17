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

  Future<String> text(String package) async {
    final entries = await LicenseRegistry.licenses.toList();
    return entries
        .singleWhere((e) => e.packages.contains(package))
        .paragraphs
        .map((p) => p.text)
        .join('\n');
  }

  test('lists whisper.cpp, ggml and the Whisper models', () async {
    registerThirdPartyLicenses();
    expect(
      await text(whisperEngineLicensePackage),
      allOf(
        contains('https://github.com/ggml-org/whisper.cpp (tag v1.9.5)'),
        contains('The ggml authors'),
        contains('Jeffrey Quesnelle and Bowen Peng'),
        contains('MIT License'),
      ),
    );
    expect(
      await text(whisperModelsLicensePackage),
      allOf(
        contains('Copyright (c) 2022'),
        contains('OpenAI'),
        contains('huggingface.co'),
        contains('SHA-1'),
      ),
    );
  });

  test('matches the notices of the native library', () {
    final notices = File(
      'packages/whisper_speech/native/THIRD_PARTY_NOTICES.md',
    ).readAsStringSync();
    for (final line in [
      'MIT (© 2023-2026 The ggml authors)',
      'MIT (© 2023 Jeffrey Quesnelle and Bowen Peng)',
      'Apache-2.0 WITH LLVM-exception',
      '© 2022 OpenAI',
      'tag `v1.9.5`',
    ]) {
      expect(notices, contains(line));
    }
  });
}
