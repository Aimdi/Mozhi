import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  group('isRtlLanguageCode', () {
    test('recognises right-to-left languages and scripts', () {
      for (final code in [
        'ar',
        'AR',
        'ar-EG',
        'he',
        'iw',
        'fa',
        'fa_IR',
        'ur',
        'ps',
        'sd',
        'ug',
        'yi',
        'dv',
        'ckb',
        'arz',
        'pnb',
        'pa-Arab',
        'az-Arab',
        'ms-arab',
      ]) {
        expect(isRtlLanguageCode(code), isTrue, reason: code);
      }
    });

    test('treats everything else as left to right', () {
      for (final code in [
        null,
        '',
        'en',
        'fr',
        'ja',
        'zh-Hant',
        'ku',
        'ku-Latn',
        'sd-Deva',
        'uz-Latn',
        'pa',
        'auto',
      ]) {
        expect(isRtlLanguageCode(code), isFalse, reason: '$code');
      }
    });
  });

  group('textDirectionFor*', () {
    test('codes and languages', () {
      expect(textDirectionForCode('ar'), TextDirection.rtl);
      expect(textDirectionForCode('de'), TextDirection.ltr);
      expect(textDirectionForCode(null), isNull);
      expect(textDirectionForCode(' '), isNull);
      expect(textDirectionForCode('auto'), isNull);
      expect(
        textDirectionForLanguage(const Language(code: 'he', name: 'Hebrew')),
        TextDirection.rtl,
      );
      expect(textDirectionForLanguage(Language.auto), isNull);
      expect(
        textDirectionForLanguage(const Language.custom('Pirate speak')),
        isNull,
      );
    });

    test('text', () {
      expect(textDirectionForText('مرحبا بالعالم'), TextDirection.rtl);
      expect(textDirectionForText('שלום עולם'), TextDirection.rtl);
      expect(textDirectionForText('Hello world'), TextDirection.ltr);
      expect(textDirectionForText('  '), isNull);
    });
  });

  group('localeFor*', () {
    test('parses BCP-47 codes', () {
      expect(localeForCode('ja'), const Locale('ja'));
      expect(localeForCode('pt-BR'), const Locale('pt', 'BR'));
      expect(localeForCode('pt_br'), const Locale('pt', 'BR'));
      expect(
        localeForCode('zh-hant'),
        const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      );
      expect(
        localeForCode('sr-Latn-RS'),
        const Locale.fromSubtags(
          languageCode: 'sr',
          scriptCode: 'Latn',
          countryCode: 'RS',
        ),
      );
      expect(localeForCode('es-419'), const Locale('es', '419'));
      expect(localeForCode('ckb'), const Locale('ckb'));
      expect(localeForCode('de-CH-1996'), const Locale('de', 'CH'));
    });

    test('rejects auto, empty and malformed codes', () {
      expect(localeForCode(null), isNull);
      expect(localeForCode(''), isNull);
      expect(localeForCode('auto'), isNull);
      expect(localeForCode('LinkedIn Speak'), isNull);
      expect(localeForCode('x1'), isNull);
      expect(localeForCode('en-L4tn'), isNull);
      expect(localeForLanguage(Language.auto), isNull);
      expect(localeForLanguage(const Language.custom('Pirate')), isNull);
      expect(
        localeForLanguage(const Language(code: 'ko', name: 'Korean')),
        const Locale('ko'),
      );
    });
  });
}
