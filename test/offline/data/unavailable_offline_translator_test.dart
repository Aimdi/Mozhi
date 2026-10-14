import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/offline/offline.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  group('UnavailableOfflineTranslator', () {
    const translator = UnavailableOfflineTranslator();

    test('is not available and knows no languages', () async {
      expect(translator.isAvailable, isFalse);
      expect(translator.supportedLanguages, isEmpty);
      expect(await translator.downloadedLanguages(), isEmpty);
      expect(await translator.identifyLanguage('Hallo Welt'), isNull);
      await translator.dispose();
    });

    test('refuses model operations and translation', () async {
      await expectLater(
        translator.downloadLanguage('de'),
        throwsUnsupportedError,
      );
      await expectLater(
        translator.deleteLanguage('de'),
        throwsUnsupportedError,
      );
      await expectLater(
        translator.translate('Hallo', source: 'de', target: 'en'),
        throwsUnsupportedError,
      );
    });

    test('gives the repository no offline engine', () {
      final repository = TranslationRepository(offline: translator);
      expect(repository.hasOfflineEngine, isFalse);
    });
  });
}
