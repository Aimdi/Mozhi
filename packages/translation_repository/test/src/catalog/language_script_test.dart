import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  group('LanguageCatalog.usesNonLatinScript', () {
    test('is true for languages written in other scripts', () {
      for (final code in [
        'ja',
        'zh',
        'zh-CN',
        'zh-TW',
        'yue',
        'ko',
        'ru',
        'uk',
        'sr',
        'bg',
        'el',
        'grc',
        'he',
        'iw',
        'yi',
        'ar',
        'ar-EG',
        'fa',
        'ur',
        'hi',
        'bn',
        'ta',
        'th',
        'km',
        'my',
        'ka',
        'hy',
        'am',
        'bo',
        'chr',
        'iu',
        'mni-Mtei',
        'pa',
        'pa-Arab',
        'ber',
        'ms-Arab',
        'kk',
        'mn',
      ]) {
        expect(LanguageCatalog.usesNonLatinScript(code), isTrue, reason: code);
      }
    });

    test('is false for Latin-script languages', () {
      for (final code in [
        'en',
        'en-GB',
        'fr',
        'de',
        'vi',
        'tr',
        'pl',
        'ms',
        'sw',
        'uz',
        'az',
        'ku',
        'sr-Latn',
        'ber-Latn',
        'tlh',
        'tok',
        'la',
        'haw',
        'ndc-ZW',
      ]) {
        expect(LanguageCatalog.usesNonLatinScript(code), isFalse, reason: code);
      }
    });

    test('an explicit script subtag decides', () {
      expect(LanguageCatalog.usesNonLatinScript('uz-Cyrl'), isTrue);
      expect(LanguageCatalog.usesNonLatinScript('az-Arab'), isTrue);
      expect(LanguageCatalog.usesNonLatinScript('zh-Hant-HK'), isTrue);
      expect(LanguageCatalog.usesNonLatinScript('ja-Latn'), isFalse);
      expect(LanguageCatalog.usesNonLatinScript('sr_latn_RS'), isFalse);
      expect(LanguageCatalog.usesNonLatinScript('xx-Cyrl'), isTrue);
    });

    test('regional variants follow their base language', () {
      expect(LanguageCatalog.usesNonLatinScript('ru-UA'), isTrue);
      expect(LanguageCatalog.usesNonLatinScript('JA-jp'), isTrue);
      expect(LanguageCatalog.usesNonLatinScript(' ko_KR '), isTrue);
      expect(LanguageCatalog.usesNonLatinScript('de-AT'), isFalse);
    });

    test('is false for auto, unknown codes and non-codes', () {
      for (final code in [
        '',
        '  ',
        'auto',
        'Language.auto',
        'qq',
        'xyz-Latn',
        'Pirate speak',
        'Runes-Futh',
        '日本語',
      ]) {
        expect(LanguageCatalog.usesNonLatinScript(code), isFalse, reason: code);
      }
    });

    test('agrees with the native name of every catalogue entry', () {
      // Native names are either entirely in a non-Latin script or Latin
      // (possibly with modifier letters such as the okina).
      final latin = RegExp(r'\p{Script=Latin}', unicode: true);
      for (final language in LanguageCatalog.all) {
        expect(
          LanguageCatalog.usesNonLatinScript(language.code),
          !latin.hasMatch(language.nativeName!),
          reason: '${language.code} ${language.nativeName}',
        );
      }
    });
  });

  group('LanguageCatalog.hasNonLatinLetters', () {
    test('finds letters of other scripts', () {
      for (final text in [
        '東京',
        'Hello Мир',
        'カタカナ',
        '한국어',
        'हिन्दी',
        'שלום',
        'ⵜⴰⵎⴰⵣⵉⵖⵜ',
        'αβγ',
      ]) {
        expect(LanguageCatalog.hasNonLatinLetters(text), isTrue, reason: text);
      }
    });

    test('ignores Latin letters, digits, punctuation and emoji', () {
      for (final text in [
        '',
        'Hello, world!',
        'Tiếng Việt',
        'Ærøskøbing ß',
        '123 456.78 %',
        '😀👍 → ✓',
        'Tōkyō',
      ]) {
        expect(LanguageCatalog.hasNonLatinLetters(text), isFalse, reason: text);
      }
    });
  });
}
