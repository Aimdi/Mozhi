import 'package:mt_api/mt_api.dart';
import 'package:test/test.dart';

/// `/languages` of an older (1.5) and a newer (1.7+) server.
const _oldServer = ['en', 'fr', 'zh', 'zt', 'pb', 'pt', 'nb', 'he', 'tl'];
const _newServer = ['en', 'fr', 'zh-Hans', 'zh-Hant', 'pt-BR', 'pt', 'nb'];

void main() {
  group('libreLanguageCode', () {
    const table = {
      'auto': 'auto',
      'AUTO': 'auto',
      'en': 'en',
      'en-US': 'en',
      'en_GB': 'en',
      'zh': 'zh',
      'zh-CN': 'zh',
      'zh-Hans': 'zh',
      'zh-TW': 'zt',
      'zh-HK': 'zt',
      'zh-Hant': 'zt',
      'zt': 'zt',
      'pt': 'pt',
      'pt-PT': 'pt',
      'pt-BR': 'pb',
      'pb': 'pb',
      'no': 'nb',
      'nb': 'nb',
      'iw': 'he',
      'he': 'he',
      'in': 'id',
      'fil': 'tl',
      'tl': 'tl',
      'fr-CA': 'fr',
      'sr-Latn': 'sr',
      ' DE ': 'de',
    };
    for (final MapEntry(key: app, value: libre) in table.entries) {
      test('$app -> $libre', () => expect(libreLanguageCode(app), libre));
    }

    test('uses the spelling an older server lists', () {
      expect(libreLanguageCode('zh-CN', supported: _oldServer), 'zh');
      expect(libreLanguageCode('zh-TW', supported: _oldServer), 'zt');
      expect(libreLanguageCode('pt-BR', supported: _oldServer), 'pb');
      expect(libreLanguageCode('no', supported: _oldServer), 'nb');
    });

    test('uses the spelling a newer server lists', () {
      expect(libreLanguageCode('zh-CN', supported: _newServer), 'zh-Hans');
      expect(libreLanguageCode('zh-TW', supported: _newServer), 'zh-Hant');
      expect(libreLanguageCode('pt-BR', supported: _newServer), 'pt-BR');
      expect(libreLanguageCode('pt-PT', supported: _newServer), 'pt');
    });

    test('prefers a listed variant, then the bare language', () {
      expect(libreLanguageCode('sr-Latn', supported: ['sr-latn']), 'sr-latn');
      expect(libreLanguageCode('fr-CA', supported: ['fr']), 'fr');
      expect(libreLanguageCode('pt-BR', supported: ['pt']), 'pt');
    });

    test('falls back when the server lists nothing suitable', () {
      expect(libreLanguageCode('ja', supported: _oldServer), 'ja');
      expect(libreLanguageCode('zh-TW', supported: const []), 'zt');
    });

    test('rejects an empty code', () {
      expect(() => libreLanguageCode(''), throwsArgumentError);
      expect(() => libreLanguageCode(' _ '), throwsArgumentError);
    });
  });

  group('appCodeFromLibre', () {
    const table = {
      'zh': 'zh-CN',
      'zh-Hans': 'zh-CN',
      'zt': 'zh-TW',
      'zh-Hant': 'zh-TW',
      'pb': 'pt-BR',
      'pt-BR': 'pt-BR',
      'pt': 'pt',
      'nb': 'no',
      'iw': 'he',
      'in': 'id',
      'en': 'en',
      'auto': 'auto',
      'sr-latn': 'sr-Latn',
    };
    for (final MapEntry(key: libre, value: app) in table.entries) {
      test('$libre -> $app', () => expect(appCodeFromLibre(libre), app));
    }

    test('returns blank input trimmed', () {
      expect(appCodeFromLibre(' '), '');
    });

    test('round-trips app codes the catalogue uses', () {
      for (final code in ['zh-CN', 'zh-TW', 'pt-BR', 'pt', 'no', 'he', 'en']) {
        expect(appCodeFromLibre(libreLanguageCode(code)), code);
        expect(
          appCodeFromLibre(libreLanguageCode(code, supported: _newServer)),
          code,
        );
      }
    });
  });
}
