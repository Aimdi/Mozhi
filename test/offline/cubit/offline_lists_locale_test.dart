import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:mozhi/offline/offline.dart';
import 'package:translation_repository/translation_repository.dart';

/// Languages as the cubits list them: sorted by their English names.
const _english = [
  OfflineLanguage(code: 'en', name: 'English'),
  OfflineLanguage(code: 'fr', name: 'French', nativeName: 'Français'),
  OfflineLanguage(code: 'de', name: 'German', nativeName: 'Deutsch'),
  OfflineLanguage(code: 'ja', name: 'Japanese', nativeName: '日本語'),
];

List<String> _codes(Iterable<Object> items) => [
  for (final item in items)
    switch (item) {
      final OfflineLanguage language => language.code,
      final DictionaryPackItem pack => pack.id,
      final OcrLanguageItem language => language.display.code,
      _ => '$item',
    },
];

void main() {
  group('OfflineLanguage.matches', () {
    const french = OfflineLanguage(
      code: 'fr',
      name: 'French',
      nativeName: 'Français',
    );

    test('finds the name shown in the UI language', () {
      expect(french.displayNameIn('de'), 'Französisch');
      expect(french.matches('franz'), isFalse);
      expect(french.matches('franz', locale: 'de'), isTrue);
      expect(french.matches('Französisch', locale: 'de'), isTrue);
    });

    test('ignores case and accents', () {
      expect(french.matches('FRANCAIS'), isTrue);
      expect(french.matches('franzosisch', locale: 'de'), isTrue);
      expect(french.matches('  '), isTrue);
      expect(french.matches('FR'), isTrue);
      expect(french.matches('f'), isTrue);
      expect(french.matches('xx', locale: 'de'), isFalse);
    });
  });

  group('OfflineModelsState in a UI language', () {
    const state = OfflineModelsState(
      languages: _english,
      downloaded: {'en', 'de'},
    );

    test('sorts by the names shown', () {
      // Deutsch, Englisch, Französisch, Japanisch.
      expect(_codes(state.visibleIn('de')), ['de', 'en', 'fr', 'ja']);
      expect(_codes(state.visibleDownloadedIn('de')), ['de', 'en']);
      expect(_codes(state.visibleAvailableIn('de')), ['fr', 'ja']);
      expect(_codes(state.visibleIn('en')), ['en', 'fr', 'de', 'ja']);
    });

    test('searches the names shown', () {
      final searched = state.copyWith(query: 'Französ');
      expect(_codes(searched.visibleIn('de')), ['fr']);
      expect(_codes(searched.visible), isEmpty);
      expect(_codes(state.copyWith(query: 'ja').visibleIn('de')), ['ja']);
    });
  });

  group('DictionaryPacksState in a UI language', () {
    DictionaryPackItem item(OfflineLanguage language) => DictionaryPackItem(
      pack: DictionaryPackInfo(
        id: language.code,
        language: language.code,
        name: language.name,
        url: Uri.parse('https://packs.example/${language.code}.mzd'),
        size: 1,
        sha256: 'a' * 64,
      ),
      display: language,
    );
    final state = DictionaryPacksState(
      packs: [for (final language in _english) item(language)],
    );

    test('sorts and searches by the names shown', () {
      expect(_codes(state.visibleIn('de')), ['de', 'en', 'fr', 'ja']);
      expect(_codes(state.visibleAvailableIn('de')), ['de', 'en', 'fr', 'ja']);
      expect(state.visibleInstalledIn('de'), isEmpty);
      expect(_codes(state.copyWith(query: 'franzosisch').visibleIn('de')), [
        'fr',
      ]);
      expect(_codes(state.copyWith(query: 'DE').visibleIn('fr')), ['de']);
    });
  });

  group('OcrLanguagesState in a UI language', () {
    OcrLanguageItem item(OfflineLanguage language) => OcrLanguageItem(
      ocr: OcrLanguage(
        code: '${language.code}x',
        appCode: language.code,
        downloadSize: 1,
      ),
      display: language,
    );
    final state = OcrLanguagesState(
      languages: [for (final language in _english) item(language)],
      installed: const {'jax': 1},
    );

    test('sorts and searches by the names shown', () {
      expect(_codes(state.visibleIn('de')), ['de', 'en', 'fr', 'ja']);
      expect(_codes(state.visibleInstalledIn('de')), ['ja']);
      expect(_codes(state.visibleAvailableIn('de')), ['de', 'en', 'fr']);
      expect(_codes(state.copyWith(query: 'Englisch').visibleIn('de')), ['en']);
      expect(_codes(state.copyWith(query: 'frx').visibleIn('de')), ['fr']);
    });
  });
}
