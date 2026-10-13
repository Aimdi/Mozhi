import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  group(PromptProfile, () {
    test('detect', () {
      const cases = {
        'translategemma:4b': PromptProfile.translateGemma,
        'google/TranslateGemma-12b-it': PromptProfile.translateGemma,
        'translate-gemma-27b': PromptProfile.translateGemma,
        'tencent/HY-MT1.5-1.8B': PromptProfile.hunyuanMt,
        'hymt-7b': PromptProfile.hunyuanMt,
        'Hunyuan-MT-7B': PromptProfile.hunyuanMt,
        'hunyuanmt-chimera': PromptProfile.hunyuanMt,
        'gemma3:4b': PromptProfile.general,
        'hunyuan-a13b': PromptProfile.general,
        '': PromptProfile.general,
      };
      cases.forEach((model, profile) {
        expect(PromptProfile.detect(model), profile, reason: model);
      });
    });

    test('resolve', () {
      expect(
        PromptProfile.auto.resolve('translategemma'),
        PromptProfile.translateGemma,
      );
      expect(PromptProfile.auto.resolve('gpt-4o'), PromptProfile.general);
      expect(
        PromptProfile.general.resolve('translategemma'),
        PromptProfile.general,
      );
      expect(
        PromptProfile.hunyuanMt.resolve('gpt-4o'),
        PromptProfile.hunyuanMt,
      );
    });

    test('tryParse', () {
      for (final profile in PromptProfile.values) {
        expect(PromptProfile.tryParse(profile.name), profile);
      }
      expect(PromptProfile.tryParse('nope'), isNull);
      expect(PromptProfile.tryParse(null), isNull);
      expect(PromptProfile.tryParse(1), isNull);
    });

    test('isTranslationOnly', () {
      expect(PromptProfile.translateGemma.isTranslationOnly, isTrue);
      expect(PromptProfile.hunyuanMt.isTranslationOnly, isTrue);
      expect(PromptProfile.general.isTranslationOnly, isFalse);
      expect(PromptProfile.auto.isTranslationOnly, isFalse);
    });
  });
}
