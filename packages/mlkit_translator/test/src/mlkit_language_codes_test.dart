import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:mlkit_translator/mlkit_translator.dart';

void main() {
  group('MlKitLanguageCodes', () {
    test('supported lists the 59 ML Kit models', () {
      expect(MlKitLanguageCodes.supported, hasLength(59));
      expect(MlKitLanguageCodes.supported, {
        for (final language in TranslateLanguage.values) language.bcpCode,
      });
      expect(
        MlKitLanguageCodes.supported,
        containsAll(<String>['af', 'zh', 'he', 'no', 'tl', 'cy', 'en']),
      );
      expect(() => MlKitLanguageCodes.supported.add('xx'), throwsA(anything));
    });

    group('toMlKit', () {
      const table = <String, String?>{
        // Supported codes map to themselves (case/whitespace-insensitive).
        'de': 'de',
        'DE': 'de',
        ' fr ': 'fr',
        'zh': 'zh',
        // Chinese variants.
        'zh-CN': 'zh',
        'zh-TW': 'zh',
        'zh-Hans': 'zh',
        'zh-Hant': 'zh',
        'zh_hant_tw': 'zh',
        'zh-HK': 'zh',
        'cmn': 'zh',
        // Norwegian.
        'nb': 'no',
        'nn': 'no',
        'nb-NO': 'no',
        'no': 'no',
        // Legacy and alias codes.
        'iw': 'he',
        'he-IL': 'he',
        'in': 'id',
        'fil': 'tl',
        'tl': 'tl',
        'mo': 'ro',
        'prs': 'fa',
        'fa-AF': 'fa',
        'deu': 'de',
        // Regional variants.
        'pt-BR': 'pt',
        'pt_PT': 'pt',
        'en-GB': 'en',
        'en-us': 'en',
        'es-419': 'es',
        'fr-CA': 'fr',
        'ar-EG': 'ar',
        'ms-MY': 'ms',
        // Unsupported.
        'auto': null,
        'AUTO': null,
        '': null,
        '  ': null,
        'und': null,
        'yue': null,
        'zh-yue': null,
        'zh-yue-HK': null,
        'sr': null,
        'sr-Latn': null,
        'ckb': null,
        'grc': null,
        'la': null,
        'Pirate speak': null,
      };
      for (final MapEntry(key: code, value: expected) in table.entries) {
        test("'$code' -> $expected", () {
          expect(MlKitLanguageCodes.toMlKit(code), expected);
          expect(MlKitLanguageCodes.isSupported(code), expected != null);
        });
      }

      test('every mapped code is supported', () {
        for (final code in table.keys) {
          final mapped = MlKitLanguageCodes.toMlKit(code);
          if (mapped != null) {
            expect(MlKitLanguageCodes.supported, contains(mapped));
          }
        }
      });
    });

    group('normalizeIdentified', () {
      const table = <String, String?>{
        'und': null,
        'UND': null,
        '': null,
        'en': 'en',
        'iw': 'he',
        'fil': 'tl',
        'nb': 'no',
        'zh': 'zh',
        'ja-Latn': 'ja-Latn',
        'HI_latn': 'hi-Latn',
        'zh-hant-tw': 'zh-Hant-TW',
        'haw': 'haw',
        'yo': 'yo',
        'es-419': 'es-419',
      };
      for (final MapEntry(key: code, value: expected) in table.entries) {
        test("'$code' -> $expected", () {
          expect(MlKitLanguageCodes.normalizeIdentified(code), expected);
        });
      }
    });
  });
}
