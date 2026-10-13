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
