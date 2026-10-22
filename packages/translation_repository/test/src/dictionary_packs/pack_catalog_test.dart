import 'dart:convert';

import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

const _sha = 'abababababababababababababababababababababababababababababababab';

Map<String, Object?> _pack({
  String id = 'es',
  String language = 'es',
  String name = 'Spanish',
}) => {
  'id': id,
  'language': language,
  'glossLanguage': 'en',
  'name': name,
  'file': '$id.mzd',
  'url': 'https://github.com/Aimdi/Mozhi/releases/download/r/$id.mzd',
  'size': 1234,
  'sha256': _sha,
  'entries': 9,
  'snapshot': '2026-10-01',
  'license': 'CC BY-SA 4.0',
  'source': 'Wiktionary',
};

void main() {
  group('DictionaryPackCatalog', () {
    test('parses the catalogue', () {
      final catalog = DictionaryPackCatalog.parse(
        jsonEncode({
          'schemaVersion': 1,
          'release': 'dictionary-packs-2026-10-22',
          'source': 'https://github.com/Aimdi/Mozhi/releases/tag/r',
          'packs': [
            _pack(),
            _pack(id: 'pt', language: 'pt-BR', name: 'Portuguese'),
            _pack(id: 'en', language: 'en', name: 'English'),
          ],
        }),
      );
      expect(catalog.release, 'dictionary-packs-2026-10-22');
      expect(catalog.isEmpty, isFalse);
      expect([for (final pack in catalog.packs) pack.id], ['en', 'pt', 'es']);
      final spanish = catalog.byId('es')!;
      expect(spanish.fileName, 'es.mzd');
      expect(spanish.size, 1234);
      expect(spanish.sha256, _sha);
      expect(spanish.entries, 9);
      expect(spanish.license, 'CC BY-SA 4.0');
      expect(catalog.byId('de'), isNull);
      expect(catalog.forLanguage('pt'), [catalog.byId('pt')]);
      expect(catalog.forLanguage('PT_pt'), [catalog.byId('pt')]);
      expect(catalog.forLanguage('es-MX'), [spanish]);
      expect(catalog.forLanguage('de'), isEmpty);
      expect(
        DictionaryPackCatalog.fromJson(catalog.toJson()).packs,
        catalog.packs,
      );
      expect(spanish.toJson(), _pack());
      expect('$spanish', 'DictionaryPackInfo(es)');
      expect(spanish.hashCode, DictionaryPackInfo.fromJson(_pack()).hashCode);
    });

    test('an empty catalogue has no packs', () {
      final catalog = DictionaryPackCatalog.parse(
        '{"schemaVersion": 1, "packs": []}',
      );
      expect(catalog.isEmpty, isTrue);
      expect(catalog.release, isNull);
      expect(catalog.toJson(), {'schemaVersion': 1, 'packs': <Object?>[]});
    });

    test('defaults optional pack fields', () {
      final pack = DictionaryPackInfo.fromJson(
        _pack()
          ..remove('glossLanguage')
          ..remove('entries')
          ..remove('snapshot')
          ..remove('license')
          ..remove('source'),
      );
      expect(pack.glossLanguage, 'en');
      expect(pack.entries, 0);
      expect(pack.snapshot, '');
      expect(pack.license, 'CC BY-SA 4.0');
      expect(pack.source, 'Wiktionary');
    });

    test('rejects invalid catalogues', () {
      void rejects(Object? json) => expect(
        () => DictionaryPackCatalog.parse(jsonEncode(json)),
        throwsFormatException,
        reason: '$json',
      );

      rejects([]);
      rejects({'schemaVersion': 2, 'packs': <Object?>[]});
      rejects({'schemaVersion': 1});
      rejects({
        'schemaVersion': 1,
        'packs': ['es'],
      });
      rejects({
        'schemaVersion': 1,
        'packs': [_pack(), _pack()],
      });
      for (final edit in <void Function(Map<String, Object?>)>[
        (pack) => pack['id'] = 'ES',
        (pack) => pack['id'] = '../x',
        (pack) => pack['url'] = 'http://example.org/es.mzd',
        (pack) => pack['url'] = 'https:///es.mzd',
        (pack) => pack['url'] = 'https://example.org/other.mzd',
        (pack) => pack['file'] = 'es.zip',
        (pack) => pack['sha256'] = 'xyz',
        (pack) => pack['size'] = 0,
        (pack) => pack['entries'] = -1,
        (pack) => pack.remove('language'),
        (pack) => pack['name'] = '',
      ]) {
        final pack = _pack();
        edit(pack);
        rejects({
          'schemaVersion': 1,
          'packs': [pack],
        });
      }
    });
  });

  test('dictionaryPackDownloadUrls tries a mirror first', () {
    final pack = DictionaryPackInfo.fromJson(_pack());
    expect(dictionaryPackDownloadUrls(pack), [pack.url]);
    expect(
      dictionaryPackDownloadUrls(
        pack,
        mirror: Uri.parse('https://example.org/models/'),
      ),
      [Uri.parse('https://example.org/models/dictionary/es.mzd')],
    );
    expect(
      dictionaryPackDownloadUrls(
        pack,
        mirror: Uri.parse('http://192.168.1.2:8080/m'),
        fallbackToDefault: true,
      ),
      [Uri.parse('http://192.168.1.2:8080/m/dictionary/es.mzd'), pack.url],
    );
    for (final mirror in [
      'ftp://example.org/',
      'https:///models/',
      'https://example.org/?q',
      'https://example.org/#f',
    ]) {
      expect(
        () => dictionaryPackDownloadUrls(pack, mirror: Uri.parse(mirror)),
        throwsArgumentError,
        reason: mirror,
      );
    }
  });

  test('dictionaryLanguageMatches compares primary languages', () {
    expect(dictionaryLanguageMatches('es', 'es'), isTrue);
    expect(dictionaryLanguageMatches('es', 'es-MX'), isTrue);
    expect(dictionaryLanguageMatches('zh', 'zh_TW'), isTrue);
    expect(dictionaryLanguageMatches('pt-BR', 'PT'), isTrue);
    expect(dictionaryLanguageMatches('es', 'en'), isFalse);
    expect(dictionaryLanguageMatches('', 'en'), isFalse);
    expect(dictionaryLanguageMatches('en', ' '), isFalse);
  });

  test('OfflineDictionaryAnswer has value equality', () {
    const attribution = DictionaryAttribution(source: 'W', license: 'L');
    const a = OfflineDictionaryAnswer(
      entry: DictionaryEntry(word: 'go'),
      language: 'en',
      attribution: attribution,
      inflectedForm: 'went',
      otherLemmas: ['wend'],
    );
    const b = OfflineDictionaryAnswer(
      entry: DictionaryEntry(word: 'go'),
      language: 'en',
      attribution: attribution,
      inflectedForm: 'went',
      otherLemmas: ['wend'],
    );
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(
      a,
      isNot(
        const OfflineDictionaryAnswer(
          entry: DictionaryEntry(word: 'go'),
          language: 'en',
          attribution: attribution,
        ),
      ),
    );
    expect('$a', 'OfflineDictionaryAnswer(go, en)');
  });
}
