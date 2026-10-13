import 'dart:convert';

import 'package:mozhi_api/mozhi_api.dart';
import 'package:test/test.dart';
import 'package:translation_repository/src/repository/mappers.dart';
import 'package:translation_repository/translation_repository.dart';

import 'test_helpers.dart';

void main() {
  group('mozhiEngineId', () {
    test('uses mozhiEngine', () {
      expect(mozhiEngineId(googleEngine), 'google');
    });

    test('falls back to the id without prefix', () {
      const engine = TranslationEngine(
        id: 'mozhi:libre',
        kind: EngineKind.mozhi,
        name: 'Libre',
      );
      expect(mozhiEngineId(engine), 'libre');
      const bare = TranslationEngine(
        id: 'duckduckgo',
        kind: EngineKind.mozhi,
        name: 'DDG',
      );
      expect(mozhiEngineId(bare), 'duckduckgo');
    });
  });

  group('normalizeDetected', () {
    test('returns null for missing, auto and undetermined codes', () {
      expect(normalizeDetected(null), isNull);
      expect(normalizeDetected(''), isNull);
      expect(normalizeDetected('  '), isNull);
      expect(normalizeDetected('auto'), isNull);
      expect(normalizeDetected('AUTO'), isNull);
      expect(normalizeDetected('und'), isNull);
    });

    test('normalises through LanguageMatcher', () {
      expect(normalizeDetected('de'), LanguageMatcher.normalize('de'));
      expect(normalizeDetected(' iw '), LanguageMatcher.normalize('iw'));
      expect(normalizeDetected('iw'), 'he');
      expect(normalizeDetected('ZH_tw'), 'zh-TW');
    });
  });

  group('mapMozhiLanguages', () {
    test('puts auto first as Language.auto and keeps engine ids', () {
      final languages = mapMozhiLanguages(const [
        MozhiLanguage(id: 'en', name: 'English'),
        MozhiLanguage(id: 'auto', name: 'Detect Language'),
        MozhiLanguage(id: 'iw', name: 'Hebrew'),
      ]);
      expect(languages.map((l) => l.code), ['auto', 'en', 'iw']);
      expect(languages.first, same(Language.auto));
      expect(languages[1].name, 'English');
      expect(languages[2].name, 'Hebrew');
    });

    test('enriches native names from the catalogue', () {
      final languages = mapMozhiLanguages(const [
        MozhiLanguage(id: 'de', name: 'German'),
        MozhiLanguage(id: 'iw', name: 'Hebrew'),
        MozhiLanguage(id: 'xx-unknown', name: 'Unknown'),
      ]);
      expect(languages[0].nativeName, LanguageCatalog.byCode('de')?.nativeName);
      expect(languages[0].nativeName, isNotNull);
      expect(languages[1].nativeName, LanguageCatalog.byCode('he')?.nativeName);
      expect(languages[2].nativeName, isNull);
    });

    test('has no auto entry for target lists', () {
      final languages = mapMozhiLanguages(const [
        MozhiLanguage(id: 'fr', name: 'French'),
      ]);
      expect(languages, [french]);
    });

    test('skips empty and duplicate ids and falls back to id names', () {
      final languages = mapMozhiLanguages(const [
        MozhiLanguage(id: '', name: 'Nothing'),
        MozhiLanguage(id: 'fr', name: 'French'),
        MozhiLanguage(id: 'fr', name: 'French again'),
        MozhiLanguage(id: 'xq', name: ' '),
      ]);
      expect(languages.map((l) => l.code), ['fr', 'xq']);
      expect(languages.first.name, 'French');
      expect(languages.last.name, 'xq');
    });
  });

  group('mapMozhiTranslation', () {
    const translation = MozhiTranslation(
      engine: 'google',
      translatedText: 'Hallo',
      detectedLanguage: 'en',
      sourceTransliteration: 'src-tr',
      targetTransliteration: 'tgt-tr',
      sourceSynonyms: ['hi'],
      targetSynonyms: ['servus'],
      wordChoices: [
        MozhiWordChoice(
          word: 'hello',
          definition: 'a greeting',
          example: 'hello there',
        ),
        MozhiWordChoice(
          word: 'hi',
          examplesSource: ['hi you'],
          examplesTarget: ['hallo du'],
          example: 'ignored',
        ),
        MozhiWordChoice(word: ' '),
      ],
    );

    test('maps every field', () {
      final result = mapMozhiTranslation(
        googleEngine,
        const TranslationRequest(
          text: 'Hello',
          source: Language.auto,
          target: german,
        ),
        translation,
        elapsed: const Duration(milliseconds: 12),
      );
      expect(result.engineId, 'mozhi:google');
      expect(result.engineName, 'Google');
      expect(result.text, 'Hallo');
      expect(result.isComplete, isTrue);
      expect(result.detectedSource, 'en');
      expect(result.sourceTransliteration, 'src-tr');
      expect(result.targetTransliteration, 'tgt-tr');
      expect(result.sourceSynonyms, ['hi']);
      expect(result.targetSynonyms, ['servus']);
      expect(result.elapsed, const Duration(milliseconds: 12));
      expect(result.wordChoices, hasLength(2));
      expect(result.wordChoices.first.word, 'hello');
      expect(result.wordChoices.first.definition, 'a greeting');
      expect(result.wordChoices.first.examplesSource, ['hello there']);
      expect(result.wordChoices.last.examplesSource, ['hi you']);
      expect(result.wordChoices.last.examplesTarget, ['hallo du']);
    });

    test('only reports the detected language for auto sources', () {
      final result = mapMozhiTranslation(
        googleEngine,
        const TranslationRequest(
          text: 'Hello',
          source: english,
          target: german,
        ),
        translation,
      );
      expect(result.detectedSource, isNull);
    });

    test('maps an empty detected language to null', () {
      final result = mapMozhiTranslation(
        googleEngine,
        const TranslationRequest(
          text: 'Hello',
          source: Language.auto,
          target: german,
        ),
        const MozhiTranslation(engine: 'google', translatedText: 'Hallo'),
      );
      expect(result.detectedSource, isNull);
    });
  });

  group('decodeBase64Image', () {
    final bytes = [137, 80, 78, 71, 1, 2, 3];
    final encoded = base64.encode(bytes);

    test('decodes plain base64', () {
      expect(decodeBase64Image(encoded), bytes);
    });

    test('decodes data URIs and ignores whitespace', () {
      expect(decodeBase64Image('data:image/png;base64,$encoded'), bytes);
      final wrapped = '${encoded.substring(0, 4)}\n${encoded.substring(4)} ';
      expect(decodeBase64Image(wrapped), bytes);
    });

    test('tolerates missing padding', () {
      expect(decodeBase64Image(encoded.replaceAll('=', '')), bytes);
    });

    test('returns null for empty or invalid data', () {
      expect(decodeBase64Image(''), isNull);
      expect(decodeBase64Image('data:image/png;base64,'), isNull);
      expect(decodeBase64Image('data:nothing'), isNull);
      expect(decodeBase64Image('not base64 at all!'), isNull);
    });
  });
}
