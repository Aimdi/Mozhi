import 'package:mt_api/mt_api.dart';
import 'package:test/test.dart';

void main() {
  group('option constants', () {
    test('match the DeepL API values', () {
      expect(DeeplFormality.values, [
        'default',
        'more',
        'less',
        'prefer_more',
        'prefer_less',
      ]);
      expect(DeeplTagHandling.values, ['html', 'xml']);
      expect(DeeplModelType.values, [
        'quality_optimized',
        'prefer_quality_optimized',
        'latency_optimized',
      ]);
    });
  });

  group(DeeplTranslation, () {
    const full = DeeplTranslation(
      text: 'Hallo',
      detectedSourceLanguage: 'EN',
      billedCharacters: 5,
      modelTypeUsed: 'quality_optimized',
    );

    test('round-trips through JSON', () {
      expect(DeeplTranslation.fromJson(full.toJson()), full);
      expect(full.toJson(), {
        'text': 'Hallo',
        'detected_source_language': 'EN',
        'billed_characters': 5,
        'model_type_used': 'quality_optimized',
      });
    });

    test('omits absent optional fields from JSON', () {
      const minimal = DeeplTranslation(text: 'a', detectedSourceLanguage: '');
      expect(minimal.toJson(), {'text': 'a', 'detected_source_language': ''});
    });

    test('is lenient', () {
      expect(
        DeeplTranslation.fromJson(const {
          'text': 1,
          'billed_characters': '5',
          'model_type_used': '',
        }),
        const DeeplTranslation(text: '', detectedSourceLanguage: ''),
      );
      expect(
        DeeplTranslation.fromJson(const {'billed_characters': 3.0}),
        const DeeplTranslation(
          text: '',
          detectedSourceLanguage: '',
          billedCharacters: 3,
        ),
      );
    });

    test('equality, hashCode and toString', () {
      const same = DeeplTranslation(
        text: 'Hallo',
        detectedSourceLanguage: 'EN',
        billedCharacters: 5,
        modelTypeUsed: 'quality_optimized',
      );
      expect(full, same);
      expect(full.hashCode, same.hashCode);
      expect(
        full,
        isNot(
          const DeeplTranslation(text: 'Hallo', detectedSourceLanguage: 'EN'),
        ),
      );
      expect(full.toString(), 'DeeplTranslation(EN: Hallo)');
    });
  });

  group(DeeplLanguage, () {
    const german = DeeplLanguage(
      code: 'DE',
      name: 'German',
      supportsFormality: true,
    );

    test('round-trips through JSON', () {
      expect(DeeplLanguage.fromJson(german.toJson()), german);
      expect(german.toJson(), {
        'language': 'DE',
        'name': 'German',
        'supports_formality': true,
      });
    });

    test('is lenient', () {
      expect(
        DeeplLanguage.fromJson(const {
          'language': 'EN',
          'supports_formality': 1,
        }),
        const DeeplLanguage(code: 'EN', name: ''),
      );
    });

    test('equality, hashCode and toString', () {
      expect(
        german,
        const DeeplLanguage(
          code: 'DE',
          name: 'German',
          supportsFormality: true,
        ),
      );
      expect(
        german.hashCode,
        const DeeplLanguage(
          code: 'DE',
          name: 'German',
          supportsFormality: true,
        ).hashCode,
      );
      expect(german, isNot(const DeeplLanguage(code: 'DE', name: 'German')));
      expect(german.toString(), 'DeeplLanguage(DE, German)');
    });
  });

  group(DeeplUsage, () {
    test('round-trips through JSON', () {
      const usage = DeeplUsage(characterCount: 10, characterLimit: 100);
      expect(DeeplUsage.fromJson(usage.toJson()), usage);
      expect(usage.toJson(), {'character_count': 10, 'character_limit': 100});
    });

    test('derived values with a limit', () {
      const usage = DeeplUsage(characterCount: 25, characterLimit: 100);
      expect(usage.hasLimit, isTrue);
      expect(usage.remaining, 75);
      expect(usage.usedFraction, 0.25);
      expect(usage.isQuotaExceeded, isFalse);
    });

    test('derived values over the limit', () {
      const usage = DeeplUsage(characterCount: 120, characterLimit: 100);
      expect(usage.remaining, 0);
      expect(usage.usedFraction, 1);
      expect(usage.isQuotaExceeded, isTrue);
    });

    test('derived values without a limit', () {
      final usage = DeeplUsage.fromJson(const {'character_count': 5});
      expect(usage.characterLimit, 0);
      expect(usage.hasLimit, isFalse);
      expect(usage.remaining, isNull);
      expect(usage.usedFraction, isNull);
      expect(usage.isQuotaExceeded, isFalse);
    });

    test('equality, hashCode and toString', () {
      const a = DeeplUsage(characterCount: 1, characterLimit: 2);
      const b = DeeplUsage(characterCount: 1, characterLimit: 2);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const DeeplUsage(characterCount: 2, characterLimit: 2)));
      expect(a.toString(), 'DeeplUsage(1 / 2)');
    });
  });

  group(DeeplGlossary, () {
    final glossary = DeeplGlossary(
      id: 'g1',
      name: 'Terms',
      sourceLang: 'en',
      targetLang: 'de',
      creationTime: DateTime.utc(2021, 8, 3, 14, 16, 18, 329),
      entryCount: 3,
    );

    test('round-trips through JSON', () {
      expect(DeeplGlossary.fromJson(glossary.toJson()), glossary);
      expect(glossary.toJson(), {
        'glossary_id': 'g1',
        'name': 'Terms',
        'ready': true,
        'source_lang': 'en',
        'target_lang': 'de',
        'creation_time': '2021-08-03T14:16:18.329Z',
        'entry_count': 3,
      });
    });

    test('is lenient', () {
      final parsed = DeeplGlossary.fromJson(const {
        'glossary_id': 'g',
        'ready': false,
        'creation_time': 'yesterday',
      });
      expect(parsed.ready, isFalse);
      expect(parsed.creationTime, isNull);
      expect(parsed.entryCount, 0);
      expect(parsed.toJson().containsKey('creation_time'), isFalse);
      expect(DeeplGlossary.fromJson(const {}).ready, isTrue);
    });

    test('equality, hashCode and toString', () {
      final same = DeeplGlossary.fromJson(glossary.toJson());
      expect(glossary, same);
      expect(glossary.hashCode, same.hashCode);
      expect(
        glossary,
        isNot(
          const DeeplGlossary(
            id: 'g1',
            name: 'Terms',
            sourceLang: 'en',
            targetLang: 'de',
          ),
        ),
      );
      expect(glossary.toString(), 'DeeplGlossary(g1, Terms, en->de, 3)');
    });
  });

  group(DeeplGlossaryLanguagePair, () {
    const pair = DeeplGlossaryLanguagePair(sourceLang: 'en', targetLang: 'de');

    test('round-trips through JSON', () {
      expect(DeeplGlossaryLanguagePair.fromJson(pair.toJson()), pair);
      expect(pair.toJson(), {'source_lang': 'en', 'target_lang': 'de'});
    });

    test('equality, hashCode and toString', () {
      const same = DeeplGlossaryLanguagePair(
        sourceLang: 'en',
        targetLang: 'de',
      );
      expect(pair, same);
      expect(pair.hashCode, same.hashCode);
      expect(
        pair,
        isNot(
          const DeeplGlossaryLanguagePair(sourceLang: 'de', targetLang: 'en'),
        ),
      );
      expect(pair.toString(), 'DeeplGlossaryLanguagePair(en->de)');
    });
  });
}
