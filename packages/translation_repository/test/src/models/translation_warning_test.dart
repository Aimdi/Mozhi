import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  group(TranslationWarningKind, () {
    test('suspect kinds', () {
      expect(
        {
          for (final kind in TranslationWarningKind.values)
            if (kind.isSuspect) kind,
        },
        {
          TranslationWarningKind.echo,
          TranslationWarningKind.wrongLanguage,
          TranslationWarningKind.length,
          TranslationWarningKind.notATranslation,
        },
      );
    });
  });

  group(TranslationWarning, () {
    test('has value equality', () {
      const a = TranslationWarning(
        TranslationWarningKind.links,
        items: ['https://x'],
      );
      expect(
        a,
        const TranslationWarning(
          TranslationWarningKind.links,
          items: ['https://x'],
        ),
      );
      expect(
        a.hashCode,
        const TranslationWarning(
          TranslationWarningKind.links,
          items: ['https://x'],
        ).hashCode,
      );
      expect(a, isNot(const TranslationWarning(TranslationWarningKind.links)));
      expect(a.isSuspect, isFalse);
      expect(
        const TranslationWarning(TranslationWarningKind.echo).isSuspect,
        isTrue,
      );
    });

    test('toString never shows the items', () {
      const warning = TranslationWarning(
        TranslationWarningKind.emails,
        items: ['secret@mail.example'],
      );
      expect(warning.toString(), 'TranslationWarning(emails, 1 items)');
      expect(
        const TranslationWarning(TranslationWarningKind.echo).toString(),
        'TranslationWarning(echo)',
      );
    });
  });

  group('TranslationResult checks', () {
    const result = TranslationResult(
      engineId: 'mozhi:google',
      engineName: 'Google',
      text: 'Hallo',
    );

    test('default to none', () {
      expect(result.warnings, isEmpty);
      expect(result.maskedPersonalData, 0);
      expect(result.isSuspect, isFalse);
    });

    test('copyWith, equality, isSuspect and toString', () {
      final checked = result.copyWith(
        warnings: const [TranslationWarning(TranslationWarningKind.echo)],
        maskedPersonalData: 2,
        sourceTransliteration: 'src',
        targetTransliteration: 'tgt',
      );
      expect(checked.isSuspect, isTrue);
      expect(checked.maskedPersonalData, 2);
      expect(checked.sourceTransliteration, 'src');
      expect(checked.targetTransliteration, 'tgt');
      expect(checked, isNot(result));
      expect(
        checked,
        result.copyWith(
          warnings: const [TranslationWarning(TranslationWarningKind.echo)],
          maskedPersonalData: 2,
          sourceTransliteration: 'src',
          targetTransliteration: 'tgt',
        ),
      );
      expect(checked.hashCode, isNot(result.hashCode));
      expect(checked.toString(), contains('warnings: echo'));
      expect(checked.toString(), contains('masked: 2'));
      expect(result.toString(), isNot(contains('warnings')));
      expect(checked.copyWith(text: 'x').warnings, checked.warnings);
    });
  });

  group('AiProviderConfig.preferQualityModel', () {
    const config = AiProviderConfig(
      id: 'deepl',
      name: 'DeepL',
      provider: LlmProvider.openAiCompatible,
      baseUrl: '',
      model: '',
      service: MtService.deepl,
    );

    test('is off by default and only written when on', () {
      expect(config.preferQualityModel, isFalse);
      expect(config.toJson().containsKey('preferQualityModel'), isFalse);
      final on = config.copyWith(preferQualityModel: true);
      expect(on.toJson()['preferQualityModel'], isTrue);
      expect(AiProviderConfig.fromJson(on.toJson()), on);
      expect(AiProviderConfig.fromJson(config.toJson()), config);
      expect(on, isNot(config));
      expect(on.hashCode, isNot(config.hashCode));
      expect(on.copyWith(name: 'x').preferQualityModel, isTrue);
    });
  });
}
