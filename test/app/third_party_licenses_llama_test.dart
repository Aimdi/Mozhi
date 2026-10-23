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

  test('lists llama.cpp, ggml and the Unicode tables', () async {
    registerThirdPartyLicenses();
    expect(
      await text(llamaEngineLicensePackage),
      allOf(
        contains('https://github.com/ggml-org/llama.cpp (tag v0.6.0)'),
        contains('The ggml authors'),
        contains('Jeffrey Quesnelle and Bowen Peng'),
        contains('Unicode License v3'),
        contains('UNICODE LICENSE V3'),
        contains('MIT License'),
      ),
    );
  });

  test('matches the notices of the native library', () {
    final notices = File('packages/llama_engine/native/THIRD_PARTY_NOTICES.md')
        .readAsStringSync();
    for (final line in [
      'tag `v0.6.0`',
      'MIT (© 2023-2026 The ggml authors)',
      'MIT (© 2023 Jeffrey Quesnelle and Bowen Peng)',
      'Unicode License v3 (© 1991-2026 Unicode, Inc.)',
      'Apache-2.0 WITH LLVM-exception',
    ]) {
      expect(notices, contains(line));
    }
    // The license texts in the app are the ones of the notices file.
    for (final block in RegExp(
      r'```\n(.*?)\n```',
      dotAll: true,
    ).allMatches(notices).map((m) => m.group(1)!)) {
      expect(llamaEngineLicenseText, contains(block));
    }
  });
}
