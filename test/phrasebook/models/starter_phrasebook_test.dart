import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/phrasebook/models/starter_phrasebook.dart';

import '../starter_fixtures.dart';

const _sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

Map<String, Object?> _info({
  Object? id = 'pt',
  Object? url = 'https://example.org/r/pt.json.gz',
  Object? size = 100,
  Object? sha256 = _sha,
}) => {
  'id': id,
  'language': 'pt',
  'name': 'Portuguese',
  'url': url,
  'size': size,
  'sha256': sha256,
};

void main() {
  group('StarterPhrasebookInfo', () {
    test('round-trips through JSON', () {
      final info = StarterPhrasebookInfo.fromJson(_info());
      expect(info.baseLanguage, 'en');
      expect(info.fileName, 'pt.json.gz');
      expect(info.license, 'CC BY-SA 4.0');
      final again = StarterPhrasebookInfo.fromJson(info.toJson());
      expect(again, info);
      expect(again.toJson(), info.toJson());
    });

    test('rejects invalid entries', () {
      for (final json in [
        _info(id: 'Portuguese'),
        _info(id: 3),
        _info(url: 'http://example.org/r/pt.json.gz'),
        _info(url: 'https://example.org/r/es.json.gz'),
        _info(size: 0),
        _info(size: StarterPhrasebookInfo.maxSize + 1),
        _info(sha256: 'ABC'),
        {..._info(), 'phrases': -1},
        {..._info(), 'name': 4},
      ]) {
        expect(
          () => StarterPhrasebookInfo.fromJson(json),
          throwsFormatException,
          reason: '$json',
        );
      }
    });
  });

  group('StarterPhrasebookCatalog', () {
    test('parses and sorts packs by name', () {
      final catalog = StarterPhrasebookCatalog.parse(
        jsonEncode({
          'schemaVersion': 1,
          'release': 'phrasebooks-2026-10-22',
          'source': 'https://example.org/r',
          'packs': [
            {..._info(), 'name': 'Portuguese'},
            {
              ..._info(id: 'es', url: 'https://example.org/r/es.json.gz'),
              'name': 'Spanish',
              'language': 'es',
            },
            {
              ..._info(id: 'de', url: 'https://example.org/r/de.json.gz'),
              'name': 'German',
              'language': 'de',
            },
          ],
        }),
      );
      expect(catalog.packs.map((p) => p.id), ['de', 'pt', 'es']);
      expect(catalog.byId('es')?.name, 'Spanish');
      expect(catalog.byId('fr'), isNull);
      expect(catalog.isEmpty, isFalse);
      expect(catalog.source, 'https://example.org/r');
    });

    test('rejects invalid catalogues', () {
      for (final text in [
        '[]',
        '{"schemaVersion": 2, "packs": []}',
        '{"schemaVersion": 1}',
        '{"schemaVersion": 1, "packs": [3]}',
        jsonEncode({
          'schemaVersion': 1,
          'packs': [_info(), _info()],
        }),
      ]) {
        expect(
          () => StarterPhrasebookCatalog.parse(text),
          throwsFormatException,
          reason: text,
        );
      }
    });
  });

  group('InstalledStarterPhrasebook', () {
    test('round-trips through JSON and rejects invalid data', () {
      final installed = InstalledStarterPhrasebook(
        id: 'pt',
        language: 'pt',
        baseLanguage: 'en',
        name: 'Portuguese',
        sha256: _sha,
        size: 10,
        phrases: 3,
        installedAt: DateTime(2026, 10, 22),
      );
      expect(
        InstalledStarterPhrasebook.fromJson(installed.toJson()),
        installed,
      );
      expect(
        () => InstalledStarterPhrasebook.fromJson(const {'id': 'pt'}),
        throwsFormatException,
      );
      final noTime = {...installed.toJson()}..remove('installedAt');
      expect(
        InstalledStarterPhrasebook.fromJson(noTime).installedAt,
        DateTime.fromMillisecondsSinceEpoch(0),
      );
    });
  });

  group('StarterPhrasebook', () {
    final installedAt = DateTime(2026, 10, 22);

    test('reads the phrases of every section with their ids', () {
      final pack = StarterPhrasebook.fromJson(
        starterPackJson(),
        installedAt: installedAt,
      );
      expect(pack.id, 'pt');
      expect(pack.title, 'Portuguese phrasebook');
      expect(pack.revision, 1234);
      expect(pack.authorsUrl, contains('action=history'));
      expect(pack.licenseUrl, contains('by-sa/4.0'));
      expect(pack.retrieved, '2026-10-22');
      expect(pack.phrases.map((p) => p.id), ['s:pt:a1', 's:pt:a2', 's:pt:b1']);
      final first = pack.phrases.first;
      expect(first.sourceCode, 'en');
      expect(first.targetCode, 'pt');
      expect(first.createdAt, installedAt);
      expect(first.pronunciation, 'oh-LAH');
      expect(first.topic, 'Basics');
      expect(pack.phrases[1].pronunciation, '');
    });

    test('skips invalid and duplicate phrases', () {
      final json = starterPackJson();
      json['sections'] = [
        'nonsense',
        {'title': 'Odd', 'phrases': 'none'},
        {
          'title': 'Mixed',
          'phrases': [
            {'id': 'a', 'text': 'Yes', 'translation': 'Sim'},
            {'id': 'a', 'text': 'Yes again', 'translation': 'Sim'},
            {'id': 'b', 'text': ' ', 'translation': 'x'},
            {'id': '', 'text': 'x', 'translation': 'y'},
            3,
          ],
        },
      ];
      json.remove('revision');
      final pack = StarterPhrasebook.fromJson(json, installedAt: installedAt);
      expect(pack.phrases.single.text, 'Yes');
      expect(pack.revision, 0);
    });

    test('rejects what is not a pack', () {
      for (final change in <void Function(Map<String, Object?>)>[
        (json) => json['format'] = 'other',
        (json) => json['formatVersion'] = 2,
        (json) => json['formatVersion'] = '1',
        (json) => json['id'] = 'Not an id',
        (json) => json['sections'] = 'x',
        (json) => json['sections'] = <Object?>[],
        (json) => json.remove('language'),
      ]) {
        final json = starterPackJson();
        change(json);
        expect(
          () => StarterPhrasebook.fromJson(json, installedAt: installedAt),
          throwsFormatException,
        );
      }
    });
  });
}
