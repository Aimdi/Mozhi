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

  test('credits the on-device AI models and how they are downloaded', () async {
    registerThirdPartyLicenses();
    final entries = await LicenseRegistry.licenses.toList();
    final text = entries
        .singleWhere((e) => e.packages.contains(onDeviceAiModelsLicensePackage))
        .paragraphs
        .map((p) => p.text)
        .join('\n');
    expect(
      text,
      allOf(
        contains('Hy-MT2 1.8B'),
        contains('Copyright (C) 2026 Tencent'),
        contains('Gemma 4 E2B'),
        contains('Qwen3 1.7B'),
        contains('Apache License 2.0'),
        contains('huggingface.co'),
        contains('SHA-256'),
      ),
    );
  });
}
