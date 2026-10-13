import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/quick_translate/quick_translate.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

void main() {
  group('QuickLanguages.build', () {
    test('puts pinned before recent languages, deduplicated', () {
      final languages = QuickLanguages.build(
        available: mozhiTargets,
        recent: const [german, french, Language.auto],
        pinned: const [french],
      );
      expect(languages.recent, const [french, german]);
    });

    test('maps recent languages onto the engine targets', () {
      const frenchFr = Language(code: 'fr-FR', name: 'French');
      final languages = QuickLanguages.build(
        available: const [english, frenchFr],
        recent: const [french, japanese],
      );
      expect(languages.recent, const [frenchFr]);
    });

    test('limits the recent languages', () {
      final languages = QuickLanguages.build(
        available: mozhiTargets,
        recent: mozhiTargets,
        maxRecent: 2,
      );
      expect(languages.recent, const [english, french]);
    });

    test('keeps custom targets only when allowed', () {
      const pirate = Language.custom('Pirate speak');
      expect(
        QuickLanguages.build(
          available: mozhiTargets,
          recent: const [pirate],
        ).recent,
        isEmpty,
      );
      expect(
        QuickLanguages.build(
          available: mozhiTargets,
          recent: const [pirate, pirate],
          allowCustom: true,
        ).recent,
        const [pirate],
      );
    });

    test('lists preferred then common languages not in recent', () {
      final languages = QuickLanguages.build(
        available: mozhiTargets,
        recent: const [english],
        preferredCodes: const ['ja', '', 'xx'],
      );
      expect(languages.common, const [japanese, french, german]);
    });

    test('limits the common languages', () {
      final languages = QuickLanguages.build(available: const [], maxCommon: 3);
      expect(languages.common.map((l) => l.code), ['en', 'es', 'fr']);
    });

    test('uses the catalogue when the engine reports no targets', () {
      final languages = QuickLanguages.build(available: const []);
      expect(languages.all, LanguageCatalog.all);
      expect(languages.common, isNotEmpty);
    });

    test('never offers auto', () {
      final languages = QuickLanguages.build(
        available: const [Language.auto, english],
      );
      expect(languages.all, const [english]);
    });
  });

  group('QuickLanguages.search', () {
    const languages = QuickLanguages(
      all: [english, french, german, japanese, arabic],
    );

    test('returns nothing for a blank query', () {
      expect(languages.search('  '), isEmpty);
    });

    test('ranks prefix matches before substring matches', () {
      expect(languages.search('an'), isEmpty);
      expect(languages.search('ch'), const [french]);
      expect(languages.search('e'), const [english, french, german, japanese]);
    });

    test('matches native names and codes', () {
      expect(languages.search('deu'), const [german]);
      expect(languages.search('日本'), const [japanese]);
      expect(languages.search('ja'), const [japanese]);
      expect(languages.search('rançais'), const [french]);
    });

    test('limits the results', () {
      expect(languages.search('e', limit: 2), const [english, french]);
    });
  });

  test('isRtlLanguage detects right-to-left scripts', () {
    expect(isRtlLanguage('ar'), isTrue);
    expect(isRtlLanguage('he-IL'), isTrue);
    expect(isRtlLanguage('fa_IR'), isTrue);
    expect(isRtlLanguage('en'), isFalse);
    expect(isRtlLanguage(''), isFalse);
    expect(isRtlLanguage(null), isFalse);
  });
}
