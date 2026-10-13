import 'dart:convert';

import 'package:mozhi_api/mozhi_api.dart';
import 'package:test/test.dart';

import '../fixtures.dart';

void main() {
  group(MozhiImageTranslation, () {
    group('fromJson', () {
      test('reads the Go ImgOut field names', () {
        final result = MozhiImageTranslation.fromJson(
          jsonDecode(imageTranslationJson) as Map<String, dynamic>,
        );

        expect(result.sourceImageBase64, startsWith('iVBORw0KGgo'));
        expect(result.translatedImageBase64, startsWith('iVBORw0KGgo'));
        expect(result.translatedImageBase64, isNot(result.sourceImageBase64));
        expect(result.sourceLanguage, 'fr');
        expect(result.targetLanguage, 'en');
        expect(result.sourceText, 'Sortie de secours');
        expect(result.translatedText, 'Emergency exit');
        expect(base64Decode(result.translatedImageBase64).take(4), [
          0x89,
          0x50,
          0x4E,
          0x47,
        ]);
      });

      test('maps missing, null and mistyped fields to empty strings', () {
        final result = MozhiImageTranslation.fromJson(const {
          'TranslatedImgB64': null,
          'SourceLang': 1,
        });

        expect(result.translatedImageBase64, isEmpty);
        expect(result.sourceImageBase64, isEmpty);
        expect(result.sourceLanguage, isEmpty);
        expect(result.targetLanguage, isEmpty);
        expect(result.sourceText, isEmpty);
        expect(result.translatedText, isEmpty);
      });
    });
  });
}
