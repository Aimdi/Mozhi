import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/voice/voice.dart';

void main() {
  group(SpeechLocaleMatcher, () {
    const android = [
      'en_AU',
      'en_GB',
      'en_IN',
      'en_US',
      'es_ES',
      'es_MX',
      'es_US',
      'fr_CA',
      'fr_FR',
      'pt_BR',
      'pt_PT',
      'cmn_Hans_CN',
      'cmn_Hant_TW',
      'iw_IL',
      'in_ID',
      'fil_PH',
      'nb_NO',
      'sr_RS',
      'sr_Latn_RS',
      'de_DE',
      'de_CH',
      'ja_JP',
    ];

    final table = <(String?, List<String>, String?, String?)>[
      // (language code, recogniser locales, system locale, expected)
      ('en-US', android, null, 'en_US'),
      ('en-GB', android, null, 'en_GB'),
      ('EN_gb', android, null, 'en_GB'),
      ('en', android, null, 'en_US'),
      ('en', android, 'en_IN', 'en_IN'),
      ('en', ['en_AU', 'en_IN'], null, 'en_AU'),
      ('fr', android, null, 'fr_FR'),
      ('fr-CA', android, null, 'fr_CA'),
      ('pt', android, null, 'pt_BR'),
      ('pt-PT', android, null, 'pt_PT'),
      ('pt-PT', ['pt_BR'], null, 'pt_BR'),
      ('es-419', android, null, 'es_MX'),
      ('es-419', ['es_ES', 'es_US'], null, 'es_US'),
      ('es-MX', android, null, 'es_MX'),
      ('de-CH', android, null, 'de_CH'),
      ('de', android, null, 'de_DE'),
      ('ja', android, null, 'ja_JP'),
      ('zh-CN', android, null, 'cmn_Hans_CN'),
      ('zh-TW', android, null, 'cmn_Hant_TW'),
      ('zh-CN', ['zh-TW', 'zh-CN'], null, 'zh-CN'),
      ('he', android, null, 'iw_IL'),
      ('iw', ['he-IL'], null, 'he-IL'),
      ('id', android, null, 'in_ID'),
      ('tl', android, null, 'fil_PH'),
      ('no', android, null, 'nb_NO'),
      ('sr', android, null, 'sr_RS'),
      ('sr-Latn', android, null, 'sr_Latn_RS'),
      ('en-US', ['en-us', 'en-GB'], null, 'en-us'),
      ('ko', android, null, null),
      ('auto', android, 'en_US', null),
      (null, android, null, null),
      ('', android, null, null),
      ('Pirate speak', android, null, null),
      ('en', const <String>[], null, null),
      ('en', ['not a locale', '', 'en-US'], null, 'en-US'),
    ];

    for (final (code, locales, system, expected) in table) {
      test('maps $code (system $system) to $expected', () {
        expect(
          SpeechLocaleMatcher.match(code, locales, systemLocaleId: system),
          expected,
        );
      });
    }

    test('normalize canonicalises casing, separators and aliases', () {
      expect(SpeechLocaleMatcher.normalize('EN_us'), 'en-US');
      expect(SpeechLocaleMatcher.normalize('iw_IL'), 'he-IL');
      expect(SpeechLocaleMatcher.normalize('cmn-hans-cn'), 'zh-Hans-CN');
      expect(SpeechLocaleMatcher.normalize('es-419'), 'es-419');
      expect(SpeechLocaleMatcher.normalize('de-DE-1996'), 'de-DE');
      expect(SpeechLocaleMatcher.normalize('Pirate speak'), isNull);
      expect(SpeechLocaleMatcher.normalize(' '), isNull);
    });
  });
}
