import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/presets/data/presets_repository.dart';
import 'package:mozhi/presets/models/preset.dart';
import 'package:translation_repository/translation_repository.dart';

class _SlowStore extends MemoryStore {
  final List<String> writes = [];
  final List<Completer<void>> pending = [];

  @override
  Future<void> write(String key, String value) async {
    final completer = Completer<void>();
    pending.add(completer);
    await completer.future;
    writes.add(value);
    await super.write(key, value);
  }
}

void main() {
  const a = Preset(id: 'a', name: 'A');
  const b = Preset(
    id: 'b',
    name: 'B',
    options: TranslationOptions(readingLevel: ReadingLevel.b1),
  );

  group('PresetsRepository', () {
    late MemoryStore store;
    late PresetsRepository repository;
    late int counter;

    setUp(() {
      store = MemoryStore();
      counter = 0;
      repository = PresetsRepository(
        store: store,
        generateId: () => 'id${counter++}',
      );
    });

    test('defaults to the preferences store and random ids', () {
      final defaults = PresetsRepository();
      expect(defaults.store, isA<PreferencesStore>());
      expect(defaults.newId(), isNot(defaults.newId()));
    });

    test('load seeds the examples when nothing is stored', () async {
      expect(await repository.load(), PresetCollection.examples());
      expect(store.values, isEmpty);
    });

    test('load falls back to the examples for unreadable data', () async {
      store.values[PresetsRepository.storageKey] = '{not json';
      expect(await repository.load(), PresetCollection.examples());
      store.values[PresetsRepository.storageKey] = '"string"';
      expect(await repository.load(), PresetCollection.examples());
    });

    test('save and load round-trip', () async {
      const collection = PresetCollection(presets: [a, b], defaultId: 'b');
      await repository.save(collection);
      final raw = store.values[PresetsRepository.storageKey]!;
      expect(jsonDecode(raw), containsPair('version', 1));
      expect(await repository.load(), collection);
    });

    test('an empty stored list stays empty', () async {
      await repository.save(const PresetCollection());
      expect(await repository.load(), const PresetCollection());
    });

    test('save serialises writes', () async {
      final slow = _SlowStore();
      final repo = PresetsRepository(store: slow);
      final first = repo.save(const PresetCollection(presets: [a]));
      final second = repo.save(const PresetCollection(presets: [b]));
      await pumpEventQueue();
      expect(slow.pending, hasLength(1));
      slow.pending.first.complete();
      await first;
      await pumpEventQueue();
      expect(slow.pending, hasLength(2));
      slow.pending.last.complete();
      await second;
      expect(slow.writes, hasLength(2));
      expect(await repo.load(), const PresetCollection(presets: [b]));
    });

    test('a failed write does not block later writes', () async {
      final failing = _FailingOnceStore();
      final repo = PresetsRepository(store: failing);
      await expectLater(
        repo.save(const PresetCollection(presets: [a])),
        throwsA(isA<StateError>()),
      );
      await repo.save(const PresetCollection(presets: [b]));
      expect(await repo.load(), const PresetCollection(presets: [b]));
    });

    test('exportJson writes everything or a subset', () {
      const collection = PresetCollection(presets: [a, b], defaultId: 'b');
      final all = jsonDecode(repository.exportJson(collection)) as Map;
      expect(all['presets'], hasLength(2));
      expect(all['defaultId'], 'b');
      final onlyA =
          jsonDecode(repository.exportJson(collection, ids: {'a'})) as Map;
      expect(onlyA['presets'], hasLength(1));
      expect(onlyA.containsKey('defaultId'), isFalse);
    });

    group('parseImport', () {
      test('accepts an export document with fresh ids', () {
        const collection = PresetCollection(presets: [a, b], defaultId: 'b');
        final imported = repository.parseImport(
          repository.exportJson(collection),
        );
        expect(imported.map((p) => p.id), ['id0', 'id1']);
        expect(imported.map((p) => p.name), ['A', 'B']);
        expect(imported.last.options, b.options);
      });

      test('accepts a list and a single preset', () {
        expect(
          repository.parseImport(jsonEncode([a.toJson()])).single.name,
          'A',
        );
        expect(repository.parseImport(jsonEncode(b.toJson())).single.name, 'B');
        expect(repository.parseImport('[]'), isEmpty);
      });

      test('throws for invalid input', () {
        expect(() => repository.parseImport('nope'), throwsFormatException);
        expect(() => repository.parseImport('"text"'), throwsFormatException);
        expect(() => repository.parseImport('[1, 2]'), throwsFormatException);
        expect(
          () => repository.parseImport('{"presets": [{"name": "x"}]}'),
          throwsFormatException,
        );
        expect(
          () => repository.parseImport('{"name": "no id"}'),
          throwsFormatException,
        );
      });
    });
  });

  group('PresetsRepository for backups and sync', () {
    var now = DateTime.utc(2026, 10, 20, 9);
    late MemoryStore store;
    late PresetsRepository repository;

    PresetsRepository build([KeyValueStore? on]) =>
        PresetsRepository(store: on ?? store, clock: () => now);

    Map<String, Object?> storedTombstones() =>
        switch (store.values[PresetsRepository.tombstonesStorageKey]) {
          final String raw => Map.from(jsonDecode(raw) as Map),
          null => const {},
        };

    Preset at(Preset preset, int minutes) => preset.copyWith(
      updatedAt: DateTime.utc(2026, 10, 20).add(Duration(minutes: minutes)),
    );

    setUp(() {
      now = DateTime.utc(2026, 10, 20, 9);
      store = MemoryStore();
      repository = build();
    });

    test('save records tombstones for deleted presets', () async {
      await repository.save(const PresetCollection(presets: [a, b]));

      await repository.save(
        const PresetCollection(presets: [b]),
        deleted: ['a'],
      );

      expect(storedTombstones(), {'a': now.millisecondsSinceEpoch});
      expect((await repository.backupData()).tombstones, [
        Tombstone(id: 'a', deletedAt: now),
      ]);
    });

    test('a preset saved again drops its tombstone', () async {
      await repository.save(const PresetCollection(), deleted: ['a']);

      await repository.save(const PresetCollection(presets: [a]));

      expect(
        store.values,
        isNot(contains(PresetsRepository.tombstonesStorageKey)),
      );
    });

    test('save stamps a new order and a new default, nothing else', () async {
      await repository.save(const PresetCollection(presets: [a, b]));
      var saved = await repository.load();
      expect(saved.orderUpdatedAt, isNull);
      expect(saved.defaultUpdatedAt, isNull);

      final reordered = now = now.add(const Duration(minutes: 1));
      await repository.save(const PresetCollection(presets: [b, a]));
      saved = await repository.load();
      expect(saved.orderUpdatedAt, reordered);
      expect(saved.defaultUpdatedAt, isNull);

      final defaulted = now = now.add(const Duration(minutes: 1));
      await repository.save(
        const PresetCollection(presets: [b, a], defaultId: 'a'),
      );
      saved = await repository.load();
      expect(saved.orderUpdatedAt, reordered);
      expect(saved.defaultUpdatedAt, defaulted);

      // Adding and removing presets is no reorder.
      now = now.add(const Duration(minutes: 1));
      await repository.save(
        const PresetCollection(
          presets: [
            Preset(id: 'new'),
            b,
          ],
          defaultId: 'a',
        ),
        deleted: ['a'],
      );
      saved = await repository.load();
      expect(saved.orderUpdatedAt, reordered);
      // The default went with its preset.
      expect(saved.defaultUpdatedAt, now);
    });

    test('save notices a reorder of the examples nothing stored yet', () async {
      final examples = PresetCollection.examples().presets;

      await repository.save(
        PresetCollection(presets: examples.reversed.toList()),
      );

      expect((await repository.load()).orderUpdatedAt, now);
    });

    test('save keeps later change times it is given', () async {
      final later = now.add(const Duration(days: 1));
      await repository.save(const PresetCollection(presets: [a]));

      await repository.save(
        PresetCollection(
          presets: const [a],
          orderUpdatedAt: later,
          defaultUpdatedAt: later,
        ),
      );

      final saved = await repository.load();
      expect(saved.orderUpdatedAt, later);
      expect(saved.defaultUpdatedAt, later);
    });

    test(
      'save writes the presets when the stored ones cannot be read',
      () async {
        final failing = _FailingReadsStore();
        await build(failing)
            .save(const PresetCollection(presets: [a]), deleted: ['b']);

        expect(
          PresetCollection.tryParse(
            jsonDecode(failing.values[PresetsRepository.storageKey]!),
          ),
          const PresetCollection(presets: [a]),
        );
      },
    );

    test('save ignores failing tombstones', () async {
      final failing = _FailingKeyStore(PresetsRepository.tombstonesStorageKey);
      final repository = build(failing);

      await repository.save(
        const PresetCollection(presets: [b]),
        deleted: ['a'],
      );

      expect((await repository.load()).presets, const [b]);
    });

    test('backupData holds the presets with their change times', () async {
      await repository.replaceAll(
        PresetCollection(
          presets: [at(a, 1)],
          orderUpdatedAt: now,
          defaultUpdatedAt: now,
        ),
      );

      final data = await repository.backupData();

      expect(data.collection.presets.single.updatedAt, at(a, 1).updatedAt);
      expect(data.collection.orderUpdatedAt, now);
      expect(data.collection.defaultUpdatedAt, now);
      expect(data.tombstones, isEmpty);
    });

    test('replaceAll makes the backup the presets and tombstones', () async {
      await repository.save(const PresetCollection(presets: [a]));
      await repository.save(const PresetCollection(), deleted: ['a']);

      await repository.replaceAll(
        const PresetCollection(presets: [b], defaultId: 'b'),
        tombstones: [
          Tombstone(id: 'gone', deletedAt: now),
          Tombstone(id: 'b', deletedAt: now),
        ],
      );

      expect(
        await repository.load(),
        const PresetCollection(presets: [b], defaultId: 'b'),
      );
      expect(storedTombstones().keys, ['gone']);
    });

    group('mergeBackup', () {
      test('keeps the newer copy of a preset, this one on a tie', () async {
        await repository.replaceAll(
          PresetCollection(
            presets: [
              at(a.copyWith(name: 'mine'), 1),
              at(b.copyWith(name: 'mine'), 5),
              const Preset(id: 'c', name: 'mine'),
            ],
          ),
        );

        final merged = await repository.mergeBackup(
          PresetCollection(
            presets: [
              at(a.copyWith(name: 'theirs'), 2),
              at(b.copyWith(name: 'theirs'), 4),
              const Preset(id: 'c', name: 'theirs'),
            ],
          ),
        );

        expect(merged.presets.map((p) => p.name), ['theirs', 'mine', 'mine']);
        expect(await repository.load(), merged);
      });

      test("a backup's tombstone deletes presets not changed since", () async {
        await repository.replaceAll(
          PresetCollection(
            presets: [
              const Preset(id: 'old'),
              at(a, 10),
            ],
          ),
        );

        final merged = await repository.mergeBackup(
          const PresetCollection(),
          tombstones: [
            Tombstone(id: 'old', deletedAt: DateTime.utc(2026, 10, 19)),
            // Edited here after it was deleted there: it stays.
            Tombstone(id: 'a', deletedAt: DateTime.utc(2026, 10, 20, 0, 5)),
          ],
        );

        expect(merged.presets.map((p) => p.id), ['a']);
        expect(storedTombstones().keys, ['old']);
      });

      test(
        'a tombstone here keeps a deleted preset from coming back',
        () async {
          await repository.save(const PresetCollection(presets: [a, b]));
          await repository.save(
            const PresetCollection(presets: [b]),
            deleted: ['a'],
          );

          final merged = await repository.mergeBackup(
            const PresetCollection(presets: [a, b]),
          );

          expect(merged.presets, const [b]);
          expect(storedTombstones().keys, ['a']);
        },
      );

      test('a preset re-created after its tombstone comes back', () async {
        await repository.save(const PresetCollection(), deleted: ['a']);

        final merged = await repository.mergeBackup(
          PresetCollection(presets: [at(a, 24 * 60 + 1)]),
        );

        expect(merged.presets.map((p) => p.id), ['a']);
        expect(storedTombstones(), isEmpty);
      });

      test('keeps the order of the copy reordered last', () async {
        final earlier = now.subtract(const Duration(hours: 1));
        await repository.replaceAll(
          PresetCollection(
            presets: const [
              a,
              b,
              Preset(id: 'mine'),
            ],
            orderUpdatedAt: earlier,
          ),
        );

        final theirs = await repository.mergeBackup(
          PresetCollection(
            presets: const [
              b,
              Preset(id: 'theirs'),
              a,
            ],
            orderUpdatedAt: now,
          ),
        );

        // Mine came after b here.
        expect(theirs.presets.map((p) => p.id), ['b', 'mine', 'theirs', 'a']);
        expect(theirs.orderUpdatedAt, now);

        final mine = await repository.mergeBackup(
          PresetCollection(
            presets: const [
              a,
              b,
              Preset(id: 'theirs'),
            ],
            orderUpdatedAt: earlier,
          ),
        );

        expect(mine.presets.map((p) => p.id), ['b', 'mine', 'theirs', 'a']);
        expect(mine.orderUpdatedAt, now);
      });

      test('keeps the default of the copy where it changed last', () async {
        final earlier = now.subtract(const Duration(hours: 1));
        await repository.replaceAll(
          PresetCollection(
            presets: const [a, b],
            defaultId: 'a',
            defaultUpdatedAt: earlier,
          ),
        );

        var merged = await repository.mergeBackup(
          PresetCollection(
            presets: const [a, b],
            defaultId: 'b',
            defaultUpdatedAt: now,
          ),
        );
        expect(merged.defaultId, 'b');
        expect(merged.defaultUpdatedAt, now);

        // Cleared here later than it was set there.
        await repository.replaceAll(
          PresetCollection(presets: const [a, b], defaultUpdatedAt: now),
        );
        merged = await repository.mergeBackup(
          PresetCollection(
            presets: const [a, b],
            defaultId: 'b',
            defaultUpdatedAt: earlier,
          ),
        );
        expect(merged.defaultId, isNull);
        expect(merged.defaultUpdatedAt, now);
      });

      test('without change times keeps the default here, else the '
          "backup's", () async {
        await repository.replaceAll(
          const PresetCollection(presets: [a, b], defaultId: 'a'),
        );
        expect(
          (await repository.mergeBackup(
            const PresetCollection(presets: [a, b], defaultId: 'b'),
          )).defaultId,
          'a',
        );

        await repository.replaceAll(const PresetCollection(presets: [a, b]));
        expect(
          (await repository.mergeBackup(
            const PresetCollection(presets: [a, b], defaultId: 'b'),
          )).defaultId,
          'b',
        );
      });

      test('clears a default that was deleted', () async {
        await repository.replaceAll(
          PresetCollection(
            presets: const [a, b],
            defaultId: 'a',
            defaultUpdatedAt: now,
          ),
        );

        final merged = await repository.mergeBackup(
          const PresetCollection(presets: [b]),
          tombstones: [Tombstone(id: 'a', deletedAt: now)],
        );

        expect(merged.presets, const [b]);
        expect(merged.defaultId, isNull);
      });

      test('merges into the examples when nothing is stored', () async {
        final merged = await repository.mergeBackup(
          const PresetCollection(presets: [a]),
          tombstones: [Tombstone(id: 'builtin-chatCasual', deletedAt: now)],
        );

        expect(merged.presets.map((p) => p.id), [
          'builtin-emailFormal',
          'builtin-simpleA2',
          'a',
        ]);
      });

      test('merging the same backup twice changes nothing', () async {
        await repository.replaceAll(
          PresetCollection(
            presets: [
              at(a, 1),
              const Preset(id: 'mine'),
            ],
          ),
        );
        final backup = PresetCollection(
          presets: [at(b, 2), at(a, 0)],
          orderUpdatedAt: now,
        );
        final tombstones = [Tombstone(id: 'mine', deletedAt: now)];

        final first = await repository.mergeBackup(
          backup,
          tombstones: tombstones,
        );
        final firstJson = store.values[PresetsRepository.storageKey];
        final second = await repository.mergeBackup(
          backup,
          tombstones: tombstones,
        );

        expect(second, first);
        expect(store.values[PresetsRepository.storageKey], firstJson);
      });
    });

    test('exportJson leaves out the change times', () {
      final collection = PresetCollection(
        presets: [at(a, 1)],
        orderUpdatedAt: now,
        defaultUpdatedAt: now,
      );

      final json = repository.exportJson(collection);

      expect(json, isNot(contains('updatedAt')));
      expect(json, isNot(contains('UpdatedAt')));
    });
  });
}

/// A store whose reads fail.
class _FailingReadsStore extends MemoryStore {
  @override
  Future<String?> read(String key) async => throw StateError('io');
}

/// A store that fails every write of [failing].
class _FailingKeyStore extends MemoryStore {
  new(this.failing);

  final String failing;

  @override
  Future<void> write(String key, String value) async {
    if (key == failing) throw StateError('disk full');
    await super.write(key, value);
  }
}

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
