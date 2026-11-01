import 'package:test/test.dart';
import 'package:translation_repository/src/language_names_data.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  Language catalogued(String code) => LanguageCatalog.byCode(code)!;

  group('languageDisplayName', () {
    test('names languages in German', () {
      expect(languageDisplayName(catalogued('en'), 'de'), 'Englisch');
      expect(languageDisplayName(catalogued('fr'), 'de'), 'Französisch');
      expect(languageDisplayName(catalogued('de'), 'de'), 'Deutsch');
      expect(
        languageDisplayName(catalogued('zh-CN'), 'de'),
        'Chinesisch (vereinfacht)',
      );
      expect(
        languageDisplayName(catalogued('pt-BR'), 'de'),
        'Portugiesisch (Brasilien)',
      );
    });

    test('names languages in Japanese', () {
      expect(languageDisplayName(catalogued('en'), 'ja'), '英語');
      expect(languageDisplayName(catalogued('ja'), 'ja'), '日本語');
    });

    test('upper-cases the first letter of lower-case CLDR names', () {
      expect(languageDisplayName(catalogued('en'), 'fr'), 'Anglais');
      expect(languageDisplayName(catalogued('en'), 'es'), 'Inglés');
      expect(languageDisplayName(catalogued('en'), 'ru'), 'Английский');
      expect(languageDisplayName(catalogued('en'), 'tr'), 'İngilizce');
    });

    test('uses only the language subtag of the UI locale', () {
      expect(languageDisplayName(catalogued('fr'), 'de_CH'), 'Französisch');
      expect(languageDisplayName(catalogued('fr'), 'DE-at'), 'Französisch');
      expect(languageDisplayName(catalogued('en'), 'zh-Hans-CN'), '英语');
      expect(languageDisplayName(catalogued('en'), 'pt_BR'), 'Inglês');
    });

    test('keeps the English name in English and unknown UI languages', () {
      final english = catalogued('en-GB');
      expect(languageDisplayName(english, 'en'), 'English (UK)');
      expect(languageDisplayName(english, 'en_US'), 'English (UK)');
      expect(languageDisplayName(english, 'sw'), 'English (UK)');
      expect(languageDisplayName(english, ''), 'English (UK)');
    });

    test('falls back to the name for codes outside the catalogue', () {
      const unknown = Language(code: 'xx-unknown', name: 'Unknownese');
      expect(languageDisplayName(unknown, 'de'), 'Unknownese');
    });

    test('falls back to the English name when CLDR has none', () {
      // Yucatec Maya is not in CLDR.
      expect(languageDisplayName(catalogued('yua'), 'de'), 'Yucatec Maya');
      // Afrikaans is Afrikaans in German too.
      expect(languageDisplayName(catalogued('af'), 'de'), 'Afrikaans');
    });

    test('looks engine codes up like the catalogue', () {
      // An engine's own names and legacy codes.
      const hebrew = Language(code: 'iw', name: 'Hebrew');
      expect(languageDisplayName(hebrew, 'de'), 'Hebräisch');
      const chinese = Language(code: 'zh', name: 'Chinese');
      expect(languageDisplayName(chinese, 'de'), 'Chinesisch (vereinfacht)');
      const french = Language(code: 'fr_FR', name: 'French');
      expect(languageDisplayName(french, 'de'), 'Französisch');
    });

    test('keeps custom languages and Detect language', () {
      expect(
        languageDisplayName(const Language.custom('Pirate speak'), 'de'),
        'Pirate speak',
      );
      // A custom language named like a code stays custom.
      expect(languageDisplayName(const Language.custom('fr'), 'de'), 'fr');
      expect(languageDisplayName(Language.auto, 'de'), 'Detect language');
    });
  });

  group('languageDisplayNameOf', () {
    test('names catalogue codes', () {
      expect(languageDisplayNameOf('fr', 'de'), 'Französisch');
      expect(languageDisplayNameOf('fr', 'en'), 'French');
      expect(languageDisplayNameOf('yua', 'de'), 'Yucatec Maya');
    });

    test('is the code itself outside the catalogue', () {
      expect(languageDisplayNameOf('qqq', 'de'), 'qqq');
    });
  });

  group('localizedLanguageName', () {
    test('is null without a name of its own', () {
      expect(localizedLanguageName('fr', 'de'), 'Französisch');
      expect(localizedLanguageName('fr', 'en'), isNull);
      expect(localizedLanguageName('af', 'de'), isNull);
      expect(localizedLanguageName('qqq', 'de'), isNull);
    });
  });

  group('language names data', () {
    const appLocales = [
      'ar', 'de', 'es', 'fr', 'hi', 'id', 'it', 'ja', 'ko', //
      'nl', 'pl', 'pt', 'ru', 'ta', 'tr', 'uk', 'vi', 'zh',
    ];

    test('covers every app language but English', () {
      expect(languageNameLocales.toSet(), appLocales.toSet());
      expect(languageNamesCldrVersion, isNotEmpty);
    });

    test('only has catalogue codes and names that differ from English', () {
      final english = {
        for (final language in LanguageCatalog.all)
          language.code: language.name,
      };
      for (final MapEntry(key: locale, value: names)
          in languageNamesData.entries) {
        for (final MapEntry(key: code, value: name) in names.entries) {
          expect(english, contains(code), reason: '$locale: $code');
          expect(name, isNot(english[code]), reason: '$locale: $code');
          expect(name.trim(), name, reason: '$locale: $code');
          expect(name, isNotEmpty, reason: '$locale: $code');
        }
      }
    });

    test('names the main languages in every app language', () {
      for (final locale in appLocales) {
        for (final code in ['en', 'fr', 'de', 'es', 'ja', 'zh-CN']) {
          expect(
            localizedLanguageName(code, locale),
            isNotNull,
            reason: '$code in $locale',
          );
        }
      }
    });
  });
}
