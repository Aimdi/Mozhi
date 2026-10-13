import 'package:mt_api/src/language_tag.dart';
import 'package:test/test.dart';

void main() {
  group(LanguageTag, () {
    test('parses language, script and region', () {
      expect(LanguageTag.parse('en'), const LanguageTag('en'));
      expect(
        LanguageTag.parse(' EN_us '),
        const LanguageTag('en', region: 'us'),
      );
      expect(
        LanguageTag.parse('zh-Hant-TW'),
        const LanguageTag('zh', script: 'hant', region: 'tw'),
      );
      expect(
        LanguageTag.parse('es-419'),
        const LanguageTag('es', region: '419'),
      );
      expect(
        LanguageTag.parse('sr-Latn'),
        const LanguageTag('sr', script: 'latn'),
      );
    });

    test('ignores variants, extensions and repeated subtags', () {
      expect(
        LanguageTag.parse('de-DE-1996'),
        const LanguageTag('de', region: 'de'),
      );
      expect(
        LanguageTag.parse('en-US-GB'),
        const LanguageTag('en', region: 'us'),
      );
      expect(
        LanguageTag.parse('en-US-Latn'),
        const LanguageTag('en', region: 'us'),
      );
      expect(LanguageTag.parse('en-x-pirate'), const LanguageTag('en'));
      expect(LanguageTag.parse('en-12ab'), const LanguageTag('en'));
      expect(
        LanguageTag.parse('en--us'),
        const LanguageTag('en', region: 'us'),
      );
    });

    test('returns null without a language', () {
      expect(LanguageTag.parse(''), isNull);
      expect(LanguageTag.parse(' - _ '), isNull);
    });

    test('isAuto and isTraditionalChinese', () {
      expect(LanguageTag.parse('Auto')!.isAuto, isTrue);
      expect(LanguageTag.parse('en')!.isAuto, isFalse);
      for (final code in ['zh-Hant', 'zh-TW', 'zh-HK', 'zh-MO']) {
        expect(LanguageTag.parse(code)!.isTraditionalChinese, isTrue);
      }
      for (final code in ['zh', 'zh-CN', 'zh-Hans', 'zh-SG']) {
        expect(LanguageTag.parse(code)!.isTraditionalChinese, isFalse);
      }
    });

    test('toString uses canonical casing', () {
      expect(LanguageTag.parse('SR-latn-rs').toString(), 'sr-Latn-RS');
      expect(LanguageTag.parse('ES-419').toString(), 'es-419');
      expect(LanguageTag.parse('JA').toString(), 'ja');
    });

    test('equality and hashCode', () {
      expect(LanguageTag.parse('en-US'), LanguageTag.parse('en_us'));
      expect(
        LanguageTag.parse('en-US').hashCode,
        LanguageTag.parse('EN-us').hashCode,
      );
      expect(LanguageTag.parse('en-US'), isNot(LanguageTag.parse('en-GB')));
    });
  });
}
