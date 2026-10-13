import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

Language lang(String code, [String? name]) =>
    Language(code: code, name: name ?? LanguageCatalog.nameOf(code));

List<Language> langs(List<String> codes) => [for (final c in codes) lang(c)];

void main() {
  group('LanguageMatcher.match', () {
    // (wanted, available, expected code or null)
    final cases = <(String, List<String>, String?)>[
      // Exact code, case-insensitive, `_` == `-`.
      ('en', ['de', 'en', 'fr'], 'en'),
      ('ZH_tw', ['zh-CN', 'zh-TW'], 'zh-TW'),
      ('pt-br', ['pt-PT', 'pt-BR'], 'pt-BR'),
      ('auto', ['auto', 'en'], 'auto'),
      // Aliases.
      ('nb', ['en', 'no'], 'no'),
      ('no', ['nb', 'nn'], 'nb'),
      ('he', ['iw', 'en'], 'iw'),
      ('iw', ['he'], 'he'),
      ('jv', ['jw'], 'jw'),
      ('jw', ['jv'], 'jv'),
      ('fil', ['tl'], 'tl'),
      ('tl', ['fil'], 'fil'),
      ('zh', ['zh-TW', 'zh-CN'], 'zh-CN'),
      ('zh-CN', ['zh-TW', 'zh'], 'zh'),
      ('zh-Hans', ['zh-TW', 'zh-CN'], 'zh-CN'),
      ('zh-SG', ['zh-TW', 'zh-CN'], 'zh-CN'),
      ('zh-CN', ['zh-TW', 'zh-Hans'], 'zh-Hans'),
      ('zh-Hant', ['zh-CN', 'zh-TW'], 'zh-TW'),
      ('zh-HK', ['zh-CN', 'zh-TW'], 'zh-TW'),
      ('zh-TW', ['zh-CN', 'zh-Hant'], 'zh-Hant'),
      ('pt', ['pt-PT', 'pt-BR'], 'pt-BR'),
      ('pt-BR', ['pt-PT', 'pt'], 'pt'),
      ('pt-PT', ['pt-BR', 'pt'], 'pt'),
      ('pt-PT', ['pt-BR'], 'pt-BR'),
      ('sr', ['sr-Latn', 'sr-Cyrl'], 'sr-Cyrl'),
      ('sr-Cyrl', ['sr-Latn', 'sr'], 'sr'),
      ('ku', ['kmr'], 'kmr'),
      ('kmr', ['ckb', 'ku'], 'ku'),
      ('mni-Mtei', ['mni'], 'mni'),
      ('mni', ['mni-Mtei'], 'mni-Mtei'),
      ('ckb', ['ku', 'ku-IQ'], 'ku-IQ'),
      ('ku-IQ', ['ku', 'ckb'], 'ckb'),
      // Codes that normalise to the same catalogue code.
      ('he-IL', ['iw'], 'iw'),
      ('zh-Hans-CN', ['zh-TW', 'zh-CN'], 'zh-CN'),
      ('sr-Latn-RS', ['sr', 'sr-Latn'], 'sr-Latn'),
      // Same primary subtag.
      ('en-GB', ['de', 'en', 'en-US'], 'en'),
      ('en', ['de', 'en-US', 'en-GB'], 'en-US'),
      ('en-AU', ['en-US', 'en-GB'], 'en-US'),
      ('fr-CA', ['fr'], 'fr'),
      ('es-419', ['es'], 'es'),
      ('ar-EG', ['ar'], 'ar'),
      ('de-CH', ['de-AT', 'de'], 'de'),
      // Nothing close.
      ('ja', ['en', 'de'], null),
      ('ckb', ['ku'], null),
      ('auto', ['en'], null),
    ];

    for (final (wanted, available, expected) in cases) {
      test('$wanted in $available -> $expected', () {
        final match = LanguageMatcher.match(lang(wanted), langs(available));
        expect(match?.code, expected);
      });
    }

    test('returns the instance from the available list', () {
      final available = [
        const Language(code: 'iw', name: 'Hebrew (engine)', nativeName: 'x'),
      ];
      expect(
        LanguageMatcher.match(lang('he'), available),
        same(available.single),
      );
    });

    test('falls back to the English name', () {
      final available = [
        const Language(code: 'x-klingon', name: 'Klingon'),
        const Language(code: 'x-sim', name: 'Chinese Simplified'),
      ];
      expect(
        LanguageMatcher.match(
          const Language(code: 'tlh', name: 'klingon'),
          available,
        )?.code,
        'x-klingon',
      );
      expect(
        LanguageMatcher.match(
          const Language(code: 'zz', name: 'Chinese (Simplified)'),
          available,
        )?.code,
        'x-sim',
      );
      expect(
        LanguageMatcher.match(const Language(code: 'yy', name: ''), available),
        isNull,
      );
      expect(
        LanguageMatcher.match(
          const Language(code: 'yy', name: '()'),
          available,
        ),
        isNull,
      );
    });

    test('returns null for an empty list', () {
      expect(LanguageMatcher.match(lang('en'), const []), isNull);
    });

    group('custom languages', () {
      const pirate = Language.custom('Pirate speak');

      test('match only custom entries', () {
        final available = [
          lang('en'),
          const Language(code: 'Pirate speak', name: 'Pirate speak'),
          const Language.custom('pirate speak '),
        ];
        expect(LanguageMatcher.match(pirate, available), same(available.last));
      });

      test('are returned as-is when allowCustom', () {
        expect(LanguageMatcher.match(pirate, langs(['en'])), isNull);
        expect(
          LanguageMatcher.match(pirate, langs(['en']), allowCustom: true),
          same(pirate),
        );
      });

      test('are never matched by real languages', () {
        final available = [const Language.custom('English')];
        expect(LanguageMatcher.match(lang('en'), available), isNull);
      });
    });
  });

  group('LanguageMatcher.normalize', () {
    final cases = <String, String>{
      // Casing and separators.
      'en': 'en',
      'EN': 'en',
      ' fr ': 'fr',
      'zh-CN': 'zh-CN',
      'ZH_tw': 'zh-TW',
      'zh_cn': 'zh-CN',
      'sr-latn': 'sr-Latn',
      'SR_LATN': 'sr-Latn',
      'mni-mtei': 'mni-Mtei',
      'es-419': 'es-419',
      'ndc-zw': 'ndc-ZW',
      'pt_br': 'pt-BR',
      // Legacy and engine-specific codes.
      'iw': 'he',
      'jw': 'jv',
      'in': 'id',
      'ji': 'yi',
      'nb': 'no',
      'fil': 'tl',
      'mni': 'mni-Mtei',
      'kmr': 'ku',
      'ku-IQ': 'ckb',
      'sr-Cyrl': 'sr',
      'prs': 'fa-AF',
      'tw': 'ak',
      'zh': 'zh-CN',
      'zh-Hans': 'zh-CN',
      'zh-SG': 'zh-CN',
      'zh-Hant': 'zh-TW',
      'zh-HK': 'zh-TW',
      'zh-Hant-HK': 'zh-TW',
      'zh-yue': 'yue',
      'arz': 'ar-EG',
      'deu': 'de',
      'fra': 'fr',
      'cmn': 'zh-CN',
      // Unknown regional variants fall back to a catalogued parent.
      'fr-FR': 'fr',
      'de-AT': 'de',
      'en-IN': 'en',
      'iw-IL': 'he',
      'nb-NO': 'no',
      'sr-Latn-RS': 'sr-Latn',
      'sr-RS': 'sr',
      'pt-AO': 'pt',
      // Catalogued variants stay.
      'en-GB': 'en-GB',
      'pt-PT': 'pt-PT',
      'fr-CA': 'fr-CA',
      'ar-EG': 'ar-EG',
      // Unknown codes keep canonical casing.
      'xx': 'xx',
      'xx-yy': 'xx-YY',
      'auto': 'auto',
      'AUTO': 'auto',
      'x-klingon': 'x-klingon',
      '': '',
      '  ': '',
      '-': '',
    };
    for (final MapEntry(key: input, value: expected) in cases.entries) {
      test('"$input" -> "$expected"', () {
        expect(LanguageMatcher.normalize(input), expected);
      });
    }
  });
}
