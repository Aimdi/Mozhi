import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/presets/models/apply_preset.dart';
import 'package:mozhi/presets/models/preset.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  group('applyPresetAndGlossary', () {
    const base = TranslationOptions(
      style: TranslationStyle.literal,
      formality: Formality.less,
      context: 'Chat',
      preserveFormatting: false,
      glossary: {'Cloud': 'Wolke'},
      instructions: 'Shorter',
    );

    test('without preset and glossary returns the base options', () {
      expect(applyPresetAndGlossary(base: base), base);
    });

    test('preset fields override every base setting', () {
      const preset = Preset(
        id: 'p',
        options: TranslationOptions(
          formality: Formality.more,
          readingLevel: ReadingLevel.a2,
          speakerGender: Gender.feminine,
          addresseeGender: Gender.neutral,
          glossary: {'ignored': 'x'},
          instructions: 'ignored',
        ),
      );
      final result = applyPresetAndGlossary(base: base, preset: preset);
      expect(
        result,
        const TranslationOptions(
          formality: Formality.more,
          readingLevel: ReadingLevel.a2,
          speakerGender: Gender.feminine,
          addresseeGender: Gender.neutral,
          glossary: {'Cloud': 'Wolke'},
          instructions: 'Shorter',
        ),
      );
    });

    test('merges the glossary, base wins on conflicts', () {
      final result = applyPresetAndGlossary(
        base: base,
        glossary: const {' cloud ': 'Cloud', 'server': 'Server', ' ': 'blank'},
      );
      expect(result.glossary, {'Cloud': 'Wolke', 'server': 'Server'});
      expect(result.style, TranslationStyle.literal);
      expect(result.instructions, 'Shorter');
    });

    test('combines preset and glossary', () {
      final result = applyPresetAndGlossary(
        base: const TranslationOptions(),
        preset: Preset.example(BuiltInPreset.simpleA2),
        glossary: const {'a': 'b'},
      );
      expect(result.readingLevel, ReadingLevel.a2);
      expect(result.glossary, {'a': 'b'});
    });
  });
}
