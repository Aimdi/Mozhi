import 'package:mt_api/mt_api.dart';
import 'package:test/test.dart';

void main() {
  test('LibreFormat values', () {
    expect(LibreFormat.values, ['text', 'html']);
  });

  group(LibreDetectedLanguage, () {
    const fr = LibreDetectedLanguage(code: 'fr', confidence: 90.5);

    test('round-trips through JSON', () {
      expect(LibreDetectedLanguage.fromJson(fr.toJson()), fr);
      expect(fr.toJson(), {'language': 'fr', 'confidence': 90.5});
    });

    test('is lenient', () {
      expect(
        LibreDetectedLanguage.fromJson(const {'confidence': '90'}),
        const LibreDetectedLanguage(code: '', confidence: 0),
      );
      expect(
        LibreDetectedLanguage.fromJson(const {'confidence': 42}).confidence,
        42.0,
      );
    });

    test('equality, hashCode and toString', () {
      const same = LibreDetectedLanguage(code: 'fr', confidence: 90.5);
      expect(fr, same);
      expect(fr.hashCode, same.hashCode);
      expect(fr, isNot(const LibreDetectedLanguage(code: 'fr', confidence: 1)));
      expect(fr.toString(), 'LibreDetectedLanguage(fr, 90.5)');
    });
  });

  group(LibreTranslation, () {
    const full = LibreTranslation(
      text: 'Hello',
      detectedLanguage: LibreDetectedLanguage(code: 'fr', confidence: 90),
      alternatives: ['Hi'],
    );

    test('round-trips through JSON', () {
      expect(LibreTranslation.fromJson(full.toJson()), full);
      expect(full.toJson(), {
        'translatedText': 'Hello',
        'detectedLanguage': {'language': 'fr', 'confidence': 90.0},
        'alternatives': ['Hi'],
      });
    });

    test('omits absent optional fields from JSON', () {
      expect(const LibreTranslation(text: 'a').toJson(), {
        'translatedText': 'a',
      });
    });

    test('is lenient', () {
      expect(
        LibreTranslation.fromJson(const {
          'translatedText': 3,
          'detectedLanguage': 'fr',
          'alternatives': ['a', 1, null],
        }),
        const LibreTranslation(text: '', alternatives: ['a']),
      );
    });

    test('equality, hashCode and toString', () {
      final same = LibreTranslation.fromJson(full.toJson());
      expect(full, same);
      expect(full.hashCode, same.hashCode);
      expect(
        full,
        isNot(
          const LibreTranslation(
            text: 'Hello',
            detectedLanguage: LibreDetectedLanguage(code: 'fr', confidence: 90),
            alternatives: ['Hey'],
          ),
        ),
      );
      expect(
        full,
        isNot(
          const LibreTranslation(
            text: 'Hello',
            detectedLanguage: LibreDetectedLanguage(code: 'fr', confidence: 90),
          ),
        ),
      );
      expect(full.toString(), 'LibreTranslation(Hello)');
    });
  });

  group(LibreLanguage, () {
    const en = LibreLanguage(code: 'en', name: 'English', targets: ['de']);

    test('round-trips through JSON', () {
      expect(LibreLanguage.fromJson(en.toJson()), en);
      expect(en.toJson(), {
        'code': 'en',
        'name': 'English',
        'targets': ['de'],
      });
    });

    test('is lenient', () {
      expect(
        LibreLanguage.fromJson(const {'code': 'en', 'targets': 'de'}),
        const LibreLanguage(code: 'en', name: ''),
      );
    });

    test('equality, hashCode and toString', () {
      const same = LibreLanguage(code: 'en', name: 'English', targets: ['de']);
      expect(en, same);
      expect(en.hashCode, same.hashCode);
      expect(en, isNot(const LibreLanguage(code: 'en', name: 'English')));
      expect(
        en,
        isNot(
          const LibreLanguage(code: 'en', name: 'English', targets: ['fr']),
        ),
      );
      expect(en.toString(), 'LibreLanguage(en, English)');
    });
  });

  group(LibreSettings, () {
    const settings = LibreSettings(
      apiKeys: true,
      keyRequired: true,
      charLimit: 5000,
      suggestions: true,
      filesTranslation: true,
      supportedFilesFormat: ['.txt'],
    );

    test('round-trips through JSON', () {
      expect(LibreSettings.fromJson(settings.toJson()), settings);
      expect(settings.toJson(), {
        'apiKeys': true,
        'keyRequired': true,
        'charLimit': 5000,
        'suggestions': true,
        'filesTranslation': true,
        'supportedFilesFormat': ['.txt'],
      });
    });

    test('treats -1 and missing char limits as unlimited', () {
      expect(LibreSettings.fromJson(const {'charLimit': -1}).charLimit, isNull);
      expect(LibreSettings.fromJson(const {}).charLimit, isNull);
      expect(const LibreSettings().toJson()['charLimit'], -1);
      expect(LibreSettings.fromJson(const {'charLimit': 250.0}).charLimit, 250);
    });

    test('defaults', () {
      expect(LibreSettings.fromJson(const {}), const LibreSettings());
    });

    test('equality, hashCode and toString', () {
      final same = LibreSettings.fromJson(settings.toJson());
      expect(settings, same);
      expect(settings.hashCode, same.hashCode);
      expect(
        settings,
        isNot(
          const LibreSettings(
            apiKeys: true,
            keyRequired: true,
            charLimit: 5000,
            suggestions: true,
            filesTranslation: true,
          ),
        ),
      );
      expect(
        settings.toString(),
        'LibreSettings(keyRequired: true, charLimit: 5000)',
      );
    });
  });
}
