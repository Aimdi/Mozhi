import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/speech/speech_language.dart';

void main() {
  group('isSpeakableLanguageCode', () {
    test('accepts engine language codes', () {
      for (final code in [
        'en',
        'fil',
        'zh-CN',
        'pt_BR',
        'mni-Mtei',
        'es-419',
      ]) {
        expect(isSpeakableLanguageCode(code), isTrue, reason: code);
      }
    });

    test('rejects auto, custom languages and garbage', () {
      for (final code in ['auto', 'AUTO', 'Pirate speak', '', 'e', 'en-']) {
        expect(isSpeakableLanguageCode(code), isFalse, reason: code);
      }
    });
  });

  group('speechLanguageTag', () {
    test('canonicalises case and separators', () {
      expect(speechLanguageTag('FR'), 'fr');
      expect(speechLanguageTag('pt_br'), 'pt-BR');
      expect(speechLanguageTag(' es-419 '), 'es-419');
      expect(speechLanguageTag('sr-latn-rs'), 'sr-Latn-RS');
      expect(speechLanguageTag('de-1996ab'), 'de-1996ab');
    });

    test('maps legacy and Google-specific codes', () {
      expect(speechLanguageTag('iw'), 'he');
      expect(speechLanguageTag('jw'), 'jv');
      expect(speechLanguageTag('in'), 'id');
      expect(speechLanguageTag('ji'), 'yi');
      expect(speechLanguageTag('tl'), 'fil');
      expect(speechLanguageTag('no'), 'nb');
      expect(speechLanguageTag('zh'), 'zh-CN');
      expect(speechLanguageTag('zh-Hans'), 'zh-CN');
      expect(speechLanguageTag('zh-Hant'), 'zh-TW');
      expect(speechLanguageTag('mni-Mtei'), 'mni');
    });

    test('is null for codes that cannot be spoken', () {
      expect(speechLanguageTag('auto'), isNull);
      expect(speechLanguageTag('LinkedIn Speak'), isNull);
    });
  });

  group('matchLanguageTag', () {
    const engine = ['en-US', 'en-GB', 'fr_FR', 'pt-BR'];

    test('prefers an exact, case-insensitive match', () {
      expect(matchLanguageTag('en-gb', engine), 'en-GB');
      expect(matchLanguageTag('fr-FR', engine), 'fr_FR');
    });

    test('falls back to the first voice of the same language', () {
      expect(matchLanguageTag('en', engine), 'en-US');
      expect(matchLanguageTag('pt-PT', engine), 'pt-BR');
    });

    test('is null without a voice for the language', () {
      expect(matchLanguageTag('de', engine), isNull);
      expect(matchLanguageTag('de', const []), isNull);
    });
  });
}
