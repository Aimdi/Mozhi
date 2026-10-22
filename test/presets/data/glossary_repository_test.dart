import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/presets/data/glossary_repository.dart';
import 'package:mozhi/presets/models/glossary.dart';

class _FailingOnceStore extends MemoryStore {
  bool _failed = false;

  @override
  Future<void> write(String key, String value) async {
    if (!_failed) {
      _failed = true;
      throw StateError('disk full');
    }
    await super.write(key, value);
  }
}

void main() {
  const tech = Glossary(
    id: 'tech',
    name: 'Tech',
    sourceCode: 'en',
    targetCode: 'de',
    terms: [
      GlossaryTerm(source: 'cloud', target: 'Cloud'),
      GlossaryTerm(source: 'API', target: 'API', caseSensitive: true),
    ],
  );
  const names = Glossary(
    id: 'names',
    name: 'Names',
    terms: [GlossaryTerm(source: 'Mozhi', target: 'Mozhi', note: 'app')],
  );

  group('GlossaryRepository', () {
    late MemoryStore store;
    late GlossaryRepository repository;
    late int counter;

    setUp(() {
      store = MemoryStore();
      counter = 0;
      repository = GlossaryRepository(
        store: store,
        generateId: () => 'id${counter++}',
      );
    });

    test('defaults to the preferences store and random ids', () {
      final defaults = GlossaryRepository();
      expect(defaults.store, isA<PreferencesStore>());
      expect(defaults.newId(), isNot(defaults.newId()));
    });

    test('load is empty without data or with unreadable data', () async {
      expect(await repository.load(), isEmpty);
      store.values[GlossaryRepository.storageKey] = '{broken';
      expect(await repository.load(), isEmpty);
      store.values[GlossaryRepository.storageKey] = '42';
      expect(await repository.load(), isEmpty);
    });

    test('save and load round-trip and update the cache', () async {
      await repository.save(const [tech, names]);
      expect(repository.glossaries, const [tech, names]);
      final raw = jsonDecode(store.values[GlossaryRepository.storageKey]!);
      expect(raw, containsPair('version', GlossaryRepository.version));
      final fresh = GlossaryRepository(store: store);
      expect(fresh.glossaries, isEmpty);
      expect(await fresh.load(), const [tech, names]);
      expect(fresh.glossaries, const [tech, names]);
    });

    test('a failed write does not block later writes', () async {
      final repo = GlossaryRepository(store: _FailingOnceStore());
      await expectLater(repo.save(const [tech]), throwsStateError);
      await repo.save(const [names]);
      expect(await repo.load(), const [names]);
    });

    test('activeGlossary uses the cache', () async {
      await repository.save(const [tech, names]);
      expect(repository.activeGlossary(sourceCode: 'en', targetCode: 'de'), {
        'cloud': 'Cloud',
        'API': 'API',
        'Mozhi': 'Mozhi',
      });
      expect(repository.activeGlossary(sourceCode: 'fr', targetCode: 'de'), {
        'Mozhi': 'Mozhi',
      });
    });

    group('parseGlossaries', () {
      test('accepts documents of any version and bare lists', () {
        expect(
          GlossaryRepository.parseGlossaries(
            GlossaryRepository.encode(const [tech]),
          ),
          const [tech],
        );
        expect(
          GlossaryRepository.parseGlossaries({
            'version': 7,
            'glossaries': [names.toJson()],
          }),
          const [names],
        );
        expect(GlossaryRepository.parseGlossaries([tech.toJson()]), const [
          tech,
        ]);
      });

      test('skips invalid entries and duplicate ids', () {
        expect(
          GlossaryRepository.parseGlossaries([
            tech.toJson(),
            {'name': 'no id'},
            'garbage',
            {...tech.toJson(), 'name': 'dupe'},
          ]),
          const [tech],
        );
      });

      test('returns null for other shapes', () {
        expect(GlossaryRepository.parseGlossaries('x'), isNull);
        expect(GlossaryRepository.parseGlossaries({'glossaries': 1}), isNull);
      });
    });

    group('parseImport', () {
      test('accepts export documents, lists and single glossaries', () {
        final imported = repository.parseImport(
          GlossaryRepository.exportJson(const [tech, names]),
        );
        expect(imported.map((g) => g.id), ['id0', 'id1']);
        expect(imported.first.terms, tech.terms);
        expect(
          repository.parseImport(jsonEncode([names.toJson()])).single.name,
          'Names',
        );
        expect(
          repository.parseImport(jsonEncode(tech.toJson())).single.name,
          'Tech',
        );
        expect(repository.parseImport('[]'), isEmpty);
      });

      test('throws for invalid input', () {
        expect(() => repository.parseImport('x'), throwsFormatException);
        expect(() => repository.parseImport('3'), throwsFormatException);
        expect(() => repository.parseImport('[1]'), throwsFormatException);
        expect(
          () => repository.parseImport('{"glossaries": [{}]}'),
          throwsFormatException,
        );
      });
    });

    group('parseTerms', () {
      test('reads CSV and TSV', () {
        final csv = GlossaryRepository.parseTerms('a,b\n,\nc,d');
        expect(csv.terms, const [
          GlossaryTerm(source: 'a', target: 'b'),
          GlossaryTerm(source: 'c', target: 'd'),
        ]);
        final tsv = GlossaryRepository.parseTerms('x\ty\nonly');
        expect(tsv.terms, const [GlossaryTerm(source: 'x', target: 'y')]);
        expect(tsv.skipped, 1);
      });

      test('reads JSON exports, glossaries and term lists', () {
        final export = GlossaryRepository.parseTerms(
          GlossaryRepository.exportJson(const [tech, names]),
        );
        expect(export.terms, [...tech.terms, ...names.terms]);

        final single = GlossaryRepository.parseTerms(
          jsonEncode({
            'terms': [
              {'source': 'a', 'target': 'b'},
            ],
          }),
        );
        expect(single.terms, const [GlossaryTerm(source: 'a', target: 'b')]);

        final list = GlossaryRepository.parseTerms(
          '  ${jsonEncode([
            {'source': ' a ', 'target': 'b'},
            {'source': 'missing'},
            3,
            {
              'terms': [
                {'source': 'c', 'target': 'd'},
              ],
            },
          ])}',
        );
        expect(list.terms, const [
          GlossaryTerm(source: 'a', target: 'b'),
          GlossaryTerm(source: 'c', target: 'd'),
        ]);
        expect(list.skipped, 2);

        final term = GlossaryRepository.parseTerms(
          '{"source": "x", "target": "y"}',
        );
        expect(term.terms, const [GlossaryTerm(source: 'x', target: 'y')]);
      });

      test('throws when nothing usable is found', () {
        expect(() => GlossaryRepository.parseTerms(''), throwsFormatException);
        expect(
          () => GlossaryRepository.parseTerms('only one column'),
          throwsFormatException,
        );
        expect(
          () => GlossaryRepository.parseTerms('[1, 2]'),
          throwsFormatException,
        );
        expect(
          () => GlossaryRepository.parseTerms('{broken'),
          throwsFormatException,
        );
      });
    });

    test('exportTerms in every format', () {
      final csv = GlossaryRepository.exportTerms(
        tech,
        GlossaryExportFormat.csv,
      );
      expect(csv, startsWith('source,target,note,case_sensitive\n'));
      expect(csv, contains('API,API,,true'));
      final tsv = GlossaryRepository.exportTerms(
        tech,
        GlossaryExportFormat.tsv,
      );
      expect(tsv, contains('cloud\tCloud\t\tfalse'));
      final json = GlossaryRepository.exportTerms(
        tech,
        GlossaryExportFormat.json,
      );
      expect(GlossaryRepository.parseGlossaries(jsonDecode(json)), const [
        tech,
      ]);
      expect(GlossaryExportFormat.json.mimeType, 'application/json');
      expect(GlossaryExportFormat.tsv.extension, 'tsv');
    });
  });

  group('GlossaryRepository for backups and sync', () {
    var now = DateTime.utc(2026, 10, 20, 9);
    late MemoryStore store;
    late GlossaryRepository repository;

    GlossaryRepository build([KeyValueStore? on]) =>
        GlossaryRepository(store: on ?? store, clock: () => now);

    Map<String, Object?> storedDocument() => Map.from(
      jsonDecode(store.values[GlossaryRepository.storageKey]!) as Map,
    );

    Map<String, Object?> storedTombstones() =>
        switch (store.values[GlossaryRepository.tombstonesStorageKey]) {
          final String raw => Map.from(jsonDecode(raw) as Map),
          null => const {},
        };

    Glossary at(Glossary glossary, int minutes) => glossary.copyWith(
      updatedAt: DateTime.utc(2026, 10, 20).add(Duration(minutes: minutes)),
    );

    setUp(() {
      now = DateTime.utc(2026, 10, 20, 9);
      store = MemoryStore();
      repository = build();
    });

    test('save records tombstones and drops them for saved ones', () async {
      await repository.save(const [tech, names]);
      await repository.save(const [names], deleted: ['tech']);

      expect(storedTombstones(), {'tech': now.millisecondsSinceEpoch});
      expect((await repository.backupData()).tombstones, [
        Tombstone(id: 'tech', deletedAt: now),
      ]);

      await repository.save(const [names, tech]);
      expect(storedTombstones(), isEmpty);
    });

    test('save stamps a new order only', () async {
      await repository.save(const [tech, names]);
      expect(storedDocument(), isNot(contains('orderUpdatedAt')));

      // Added and removed glossaries are no reorder.
      await repository.save(const [tech, Glossary(id: 'x')]);
      expect(storedDocument(), isNot(contains('orderUpdatedAt')));

      final reordered = now = now.add(const Duration(minutes: 1));
      await repository.save(const [Glossary(id: 'x'), tech]);
      expect(storedDocument()['orderUpdatedAt'], reordered.toIso8601String());

      now = now.add(const Duration(minutes: 1));
      await repository.save(const [Glossary(id: 'x'), tech, names]);
      expect((await repository.backupData()).orderUpdatedAt, reordered);
    });

    test('save writes the glossaries when the stored ones cannot be '
        'read', () async {
      final failing = _FailingReadsStore();

      await build(failing).save(const [tech], deleted: ['names']);

      expect(
        GlossaryRepository.parseGlossaries(
          jsonDecode(failing.values[GlossaryRepository.storageKey]!),
        ),
        const [tech],
      );
    });

    test('backupData holds the glossaries with their change times', () async {
      await repository.replaceAll([at(tech, 1)], orderUpdatedAt: now);

      final data = await repository.backupData();

      expect(data.glossaries.single.updatedAt, at(tech, 1).updatedAt);
      expect(data.orderUpdatedAt, now);
      expect(data.tombstones, isEmpty);
    });

    test('replaceAll makes the backup the glossaries and tombstones', () async {
      await repository.save(const [], deleted: ['old']);

      await repository.replaceAll(
        const [names],
        tombstones: [
          Tombstone(id: 'gone', deletedAt: now),
          Tombstone(id: 'names', deletedAt: now),
        ],
      );

      expect(repository.glossaries, const [names]);
      expect(await repository.load(), const [names]);
      expect(storedTombstones().keys, ['gone']);
      expect(storedDocument(), isNot(contains('orderUpdatedAt')));
    });

    group('mergeBackup', () {
      test('keeps the newer copy, this one on a tie', () async {
        await repository.replaceAll([
          at(tech.copyWith(name: 'mine'), 1),
          at(names.copyWith(name: 'mine'), 5),
        ]);

        final merged = await repository.mergeBackup([
          at(tech.copyWith(name: 'theirs'), 2),
          at(names.copyWith(name: 'theirs'), 5),
        ]);

        expect(merged.map((g) => g.name), ['theirs', 'mine']);
        expect(repository.glossaries, merged);
        expect(await build().load(), merged);
      });

      test('tombstones of either copy delete older glossaries', () async {
        await repository.save(const [tech, names]);
        await repository.save(const [names], deleted: ['tech']);

        final merged = await repository.mergeBackup(
          const [tech, names, Glossary(id: 'theirs')],
          tombstones: [Tombstone(id: 'names', deletedAt: now)],
        );

        expect(merged.map((g) => g.id), ['theirs']);
        expect(storedTombstones().keys, unorderedEquals(['tech', 'names']));
      });

      test('a glossary changed after its tombstone stays', () async {
        await repository.save(const [], deleted: ['tech']);

        final merged = await repository.mergeBackup([at(tech, 24 * 60)]);

        expect(merged.map((g) => g.id), ['tech']);
        expect(storedTombstones(), isEmpty);
      });

      test('keeps the order of the copy reordered last', () async {
        final earlier = now.subtract(const Duration(hours: 1));
        await repository.replaceAll(const [
          tech,
          names,
        ], orderUpdatedAt: earlier);

        var merged = await repository.mergeBackup(const [
          names,
          tech,
        ], orderUpdatedAt: now);
        expect(merged.map((g) => g.id), ['names', 'tech']);
        expect((await repository.backupData()).orderUpdatedAt, now);

        merged = await repository.mergeBackup(const [
          tech,
          names,
        ], orderUpdatedAt: earlier);
        expect(merged.map((g) => g.id), ['names', 'tech']);
      });

      test('merging the same backup twice changes nothing', () async {
        await repository.save(const [tech]);
        final backup = [at(names, 1), at(tech, 2)];

        final first = await repository.mergeBackup(backup);
        final firstJson = store.values[GlossaryRepository.storageKey];
        final second = await repository.mergeBackup(backup);

        expect(second, first);
        expect(store.values[GlossaryRepository.storageKey], firstJson);
      });
    });

    test('encode writes when the glossaries were reordered', () {
      final document = GlossaryRepository.encode(const [
        tech,
      ], orderUpdatedAt: now);

      expect(document['orderUpdatedAt'], '2026-10-20T09:00:00.000Z');
      expect(GlossaryRepository.parseOrderUpdatedAt(document), now);
      expect(
        GlossaryRepository.parseOrderUpdatedAt(
          GlossaryRepository.encode(const [tech]),
        ),
        isNull,
      );
      expect(GlossaryRepository.parseOrderUpdatedAt(const <Object?>[]), isNull);
    });

    test('exportJson leaves out the change times', () {
      final json = GlossaryRepository.exportJson([at(tech, 1)]);

      expect(json, isNot(contains('updatedAt')));
      expect(GlossaryRepository.parseGlossaries(jsonDecode(json)), const [
        tech,
      ]);
    });
  });
}

/// A store whose reads fail.
class _FailingReadsStore extends MemoryStore {
  @override
  Future<String?> read(String key) async => throw StateError('io');
}
