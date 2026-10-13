import 'package:mt_api/mt_api.dart';
import 'package:test/test.dart';

/// DeepL `/v2/languages?type=target` codes (2026).
const _deeplTargets = [
  'AR', 'BG', 'CS', 'DA', 'DE', 'EL', 'EN-GB', 'EN-US', 'ES', 'ES-419', //
  'ET', 'FI', 'FR', 'HE', 'HU', 'ID', 'IT', 'JA', 'KO', 'LT', 'LV', 'NB',
  'NL', 'PL', 'PT-BR', 'PT-PT', 'RO', 'RU', 'SK', 'SL', 'SV', 'TH', 'TR',
  'UK', 'VI', 'ZH', 'ZH-HANS', 'ZH-HANT',
];

void main() {
  group('deeplTargetCode', () {
    const table = {
      'en': 'EN-US',
      'EN': 'EN-US',
      'en-US': 'EN-US',
      'en_us': 'EN-US',
      'en-CA': 'EN-US',
      'en-GB': 'EN-GB',
      'en-AU': 'EN-GB',
      'en-IN': 'EN-GB',
      'pt': 'PT-BR',
      'pt-BR': 'PT-BR',
      'pt-PT': 'PT-PT',
      'pt-AO': 'PT-PT',
      'zh': 'ZH-HANS',
      'zh-CN': 'ZH-HANS',
      'zh-SG': 'ZH-HANS',
      'zh-Hans': 'ZH-HANS',
      'zh-TW': 'ZH-HANT',
      'zh-HK': 'ZH-HANT',
      'zh-MO': 'ZH-HANT',
      'zh-Hant': 'ZH-HANT',
      'zh-Hant-TW': 'ZH-HANT',
      'ZH-HANS': 'ZH-HANS',
      'es': 'ES',
      'es-ES': 'ES',
      'es-419': 'ES-419',
      'es-MX': 'ES-419',
      'es-AR': 'ES-419',
      'es-US': 'ES-419',
      'no': 'NB',
      'nb': 'NB',
      'iw': 'HE',
      'he': 'HE',
      'in': 'ID',
      'de': 'DE',
      'de-CH': 'DE',
      'fr-CA': 'FR',
      'nl-BE': 'NL',
      'ar-EG': 'AR',
      'sr-Latn': 'SR',
      ' ja ': 'JA',
      'uk': 'UK',
    };
    for (final MapEntry(key: app, value: deepl) in table.entries) {
      test('$app -> $deepl', () => expect(deeplTargetCode(app), deepl));
    }

    test('all non-deprecated DeepL targets map to themselves', () {
      for (final code in _deeplTargets.where((c) => c != 'ZH')) {
        expect(deeplTargetCode(code), code);
        expect(
          deeplTargetCode(code, supported: _deeplTargets),
          code,
          reason: code,
        );
      }
    });

    test('picks a variant the server lists, in its spelling', () {
      expect(deeplTargetCode('fr-CA', supported: ['fr', 'fr-ca']), 'fr-ca');
      expect(deeplTargetCode('fr-CA', supported: ['FR', 'DE']), 'FR');
      expect(deeplTargetCode('sr-Latn', supported: ['SR-LATN']), 'SR-LATN');
      expect(deeplTargetCode('zh-TW', supported: ['ZH']), 'ZH');
      expect(deeplTargetCode('zh-CN', supported: ['zh']), 'zh');
      expect(deeplTargetCode('en-AU', supported: ['EN-US']), 'EN-US');
      expect(deeplTargetCode('en', supported: ['EN']), 'EN');
      expect(deeplTargetCode('pt-PT', supported: ['PT-BR']), 'PT-BR');
      expect(deeplTargetCode('es-MX', supported: ['ES']), 'ES');
      expect(deeplTargetCode('es', supported: ['ES-419']), 'ES-419');
    });

    test('falls back to the preferred code when nothing matches', () {
      expect(deeplTargetCode('tl', supported: _deeplTargets), 'TL');
      expect(deeplTargetCode('fr-CA', supported: const []), 'FR');
      expect(deeplTargetCode('en', supported: const ['DE']), 'EN-US');
    });

    test('rejects auto and empty codes', () {
      expect(() => deeplTargetCode('auto'), throwsArgumentError);
      expect(() => deeplTargetCode(''), throwsArgumentError);
      expect(() => deeplTargetCode(' - '), throwsArgumentError);
    });
  });

  group('deeplSourceCode', () {
    const table = {
      'en': 'EN',
      'en-US': 'EN',
      'en-GB': 'EN',
      'pt-BR': 'PT',
      'zh-CN': 'ZH',
      'zh-TW': 'ZH',
      'ZH-HANT': 'ZH',
      'no': 'NB',
      'iw': 'HE',
      'in': 'ID',
      'es-419': 'ES',
      'ja': 'JA',
    };
    for (final MapEntry(key: app, value: deepl) in table.entries) {
      test('$app -> $deepl', () => expect(deeplSourceCode(app), deepl));
    }

    test('auto and empty mean detect', () {
      expect(deeplSourceCode('auto'), isNull);
      expect(deeplSourceCode('AUTO'), isNull);
      expect(deeplSourceCode(''), isNull);
      expect(deeplSourceCode('  '), isNull);
    });
  });

  group('appCodeFromDeepl', () {
    const table = {
      'EN': 'en',
      'EN-US': 'en-US',
      'EN-GB': 'en-GB',
      'PT-BR': 'pt-BR',
      'PT-PT': 'pt-PT',
      'PT': 'pt',
      'ZH': 'zh-CN',
      'ZH-HANS': 'zh-CN',
      'zh-hant': 'zh-TW',
      'NB': 'no',
      'ES-419': 'es-419',
      'DE': 'de',
      'JA': 'ja',
    };
    for (final MapEntry(key: deepl, value: app) in table.entries) {
      test('$deepl -> $app', () => expect(appCodeFromDeepl(deepl), app));
    }

    test('returns blank input trimmed', () {
      expect(appCodeFromDeepl('  '), '');
    });

    test('round-trips app codes the catalogue uses', () {
      for (final code in [
        'en-US',
        'en-GB',
        'pt-BR',
        'pt-PT',
        'zh-CN',
        'zh-TW',
        'es-419',
        'no',
        'de',
        'ja',
      ]) {
        expect(appCodeFromDeepl(deeplTargetCode(code)), code);
      }
    });
  });
}
