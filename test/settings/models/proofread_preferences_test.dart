import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  const chosen = ProofreadPreferences(
    writingStyle: WritingStyle.academic,
    correctionLevel: CorrectionLevel.comprehensive,
    formality: Formality.preferLess,
    tone: WritingTone.enthusiastic,
    readingLevel: ReadingLevel.c1,
    variety: ProofreadVariety.ptBr,
  );

  group('ProofreadPreferences', () {
    test('round-trips through JSON', () {
      expect(ProofreadPreferences.fromJson(chosen.toJson()), chosen);
      const defaults = ProofreadPreferences();
      expect(defaults.toJson().containsKey('variety'), isFalse);
      expect(ProofreadPreferences.fromJson(defaults.toJson()), defaults);
    });

    test('falls back to the defaults for missing or unknown values', () {
      expect(
        ProofreadPreferences.fromJson(const {
          'writingStyle': 'poetic',
          'tone': 42,
          'variety': 'xx',
        }),
        const ProofreadPreferences(),
      );
    });
  });

  group('AppSettings.proofread', () {
    test('is kept in the stored settings', () {
      const settings = AppSettings(proofread: chosen);
      final json =
          jsonDecode(jsonEncode(settings.toJson())) as Map<String, dynamic>;
      expect(AppSettings.fromJson(json).proofread, chosen);
      expect(settings.copyWith().proofread, chosen);
      expect(
        settings.copyWith(proofread: const ProofreadPreferences()),
        isNot(settings),
      );
    });

    test('defaults when missing or broken', () {
      expect(
        AppSettings.fromJson(const {}).proofread,
        const ProofreadPreferences(),
      );
      expect(
        AppSettings.fromJson(const {'proofread': 'nope'}).proofread,
        const ProofreadPreferences(),
      );
    });
  });
}
