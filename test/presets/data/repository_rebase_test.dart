import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/presets/cubit/glossary_cubit.dart';
import 'package:mozhi/presets/cubit/presets_cubit.dart';
import 'package:mozhi/presets/data/glossary_repository.dart';
import 'package:mozhi/presets/data/presets_repository.dart';
import 'package:mozhi/presets/models/glossary.dart';
import 'package:mozhi/presets/models/preset.dart';
import 'package:translation_repository/translation_repository.dart';

/// A store whose reads can be held back (each read is answered with what
/// the store held when it was asked).
class _SlowStore extends MemoryStore {
  final List<Completer<void>> held = [];
  bool slow = false;

  @override
  Future<String?> read(String key) async {
    final value = await super.read(key);
    if (!slow) return value;
    final gate = Completer<void>();
    held.add(gate);
    await gate.future;
    return value;
  }
}

/// A store whose reads of the tombstones fail.
class _NoTombstonesStore extends MemoryStore {
  @override
  Future<String?> read(String key) => key.endsWith('.tombstones')
      ? Future.error(StateError('io'))
      : super.read(key);
}

void main() {
  final now = DateTime.utc(2026, 10, 31, 9);
  final earlier = DateTime.utc(2026, 10, 30);

  group('PresetsRepository: a save after a merge by another repository', () {
    late MemoryStore store;
    late PresetsRepository app;
    late PresetsRepository sync;

    setUp(() async {
      store = MemoryStore();
      app = PresetsRepository(store: store, clock: () => now);
      sync = PresetsRepository(store: store, clock: () => now);
      await app.replaceAll(
        PresetCollection(
          presets: [
            Preset(id: 'a', name: 'A', updatedAt: earlier),
            Preset(id: 'b', name: 'B', updatedAt: earlier),
          ],
          defaultId: 'a',
        ),
      );
      await app.load();
    });

    Future<void> merge() => sync.mergeBackup(
      PresetCollection(
        presets: [
          Preset(id: 'b', name: 'B', updatedAt: earlier),
          Preset(id: 'a', name: 'A, theirs', updatedAt: now),
          Preset(id: 'c', name: 'C', updatedAt: now),
        ],
        defaultId: 'c',
        orderUpdatedAt: now,
        defaultUpdatedAt: now,
      ),
    );

    test("applies the app's change to the merged presets", () async {
      final held = await app.load();
      await merge();

      // The app edits b from what it held before the merge.
      await app.save(
        PresetCollection(
          presets: [
            held.presets[0],
            held.presets[1].copyWith(name: 'B, edited', updatedAt: now),
          ],
          defaultId: held.defaultId,
        ),
      );

      final stored = await sync.load();
      expect(stored.presets.map((p) => p.name), [
        'B, edited',
        'A, theirs',
        'C',
      ]);
      // Neither the order nor the default changed in the app: the merged
      // ones stay.
      expect(stored.defaultId, 'c');
      expect(stored.orderUpdatedAt, now);
    });

    test('a later save from the same stale presets still keeps the merge, '
        'until the app reads them again', () async {
      final held = await app.load();
      await merge();
      final edited = PresetCollection(
        presets: [
          held.presets[0].copyWith(
            name: 'A, mine',
            updatedAt: now.add(const Duration(minutes: 1)),
          ),
          held.presets[1],
        ],
        defaultId: held.defaultId,
      );
      await app.save(edited);
      await app.save(PresetCollection(presets: edited.presets, defaultId: 'b'));

      var stored = await sync.load();
      expect(stored.presets.map((p) => p.id), ['b', 'a', 'c']);
      expect(stored.byId('a')!.name, 'A, mine');
      expect(stored.defaultId, 'b');

      // Read again: from now on a save is written as it is.
      final fresh = await app.load();
      await app.save(
        PresetCollection(presets: fresh.presets.sublist(0, 1)),
        deleted: ['a', 'c'],
      );
      stored = await sync.load();
      expect(stored.presets.map((p) => p.id), ['b']);
    });

    test('deletes, reorders and adds as the app did', () async {
      final held = await app.load();
      await merge();
      await app.save(
        PresetCollection(
          presets: [
            Preset(id: 'd', name: 'D', updatedAt: now),
            held.presets[1],
          ],
          defaultId: 'd',
        ),
        deleted: ['a'],
      );

      final stored = await sync.load();
      // a was deleted after its merged change; d goes where the app put it
      // (before b), in the merged order; the app chose a default.
      expect(stored.presets.map((p) => p.id), ['d', 'b', 'c']);
      expect(stored.defaultId, 'd');
      expect(stored.defaultUpdatedAt, now);
      final data = await sync.backupData();
      expect(data.tombstones.map((t) => t.id), ['a']);
    });

    test('a merged deletion stays when the app saves a stale copy', () async {
      final held = await app.load();
      await sync.mergeBackup(
        const PresetCollection(),
        tombstones: [Tombstone(id: 'b', deletedAt: now)],
      );
      await app.save(
        PresetCollection(
          presets: [
            held.presets[0].copyWith(name: 'A2', updatedAt: now),
            held.presets[1],
          ],
          defaultId: 'a',
        ),
      );

      expect((await sync.load()).presets.map((p) => p.name), ['A2']);
    });

    test('a load that a save overtook does not hide a merge', () async {
      final slow = _SlowStore();
      final repository = PresetsRepository(store: slow, clock: () => now);
      final other = PresetsRepository(store: slow, clock: () => now);
      await repository.replaceAll(
        const PresetCollection(presets: [Preset(id: 'a')]),
      );
      final view = await repository.load();
      await other.mergeBackup(
        PresetCollection(
          presets: [Preset(id: 'm', updatedAt: now)],
        ),
      );

      slow.slow = true;
      final loading = repository.load();
      final saving = repository.save(
        PresetCollection(
          presets: [view.presets.single.copyWith(name: 'x', updatedAt: now)],
        ),
      );
      while (slow.held.isEmpty) {
        await pumpEventQueue();
      }
      slow.slow = false;
      slow.held.first.complete();
      await loading;
      for (final gate in slow.held) {
        if (!gate.isCompleted) gate.complete();
      }
      await saving;

      expect((await other.load()).presets.map((p) => p.id), ['a', 'm']);
    });
  });

  group('GlossaryRepository: a save after a merge by another repository', () {
    late MemoryStore store;
    late GlossaryRepository app;
    late GlossaryRepository sync;

    setUp(() async {
      store = MemoryStore();
      app = GlossaryRepository(store: store, clock: () => now);
      sync = GlossaryRepository(store: store, clock: () => now);
      await app.replaceAll([
        Glossary(id: 'a', name: 'A', updatedAt: earlier),
        Glossary(id: 'b', name: 'B', updatedAt: earlier),
      ]);
    });

    test("applies the app's change to the merged glossaries", () async {
      final held = await app.load();
      await sync.mergeBackup([
        Glossary(id: 'c', name: 'C', updatedAt: now),
        Glossary(id: 'b', name: 'B', updatedAt: earlier),
        Glossary(id: 'a', name: 'A', updatedAt: earlier),
      ], orderUpdatedAt: now);

      await app.save([held[0].copyWith(name: 'A2', updatedAt: now), held[1]]);

      final stored = await sync.load();
      expect(stored.map((g) => g.name), ['C', 'B', 'A2']);
      expect(app.glossaries.map((g) => g.name), ['C', 'B', 'A2']);
    });

    test('a reorder in the app wins over the merged order', () async {
      final held = await app.load();
      await sync.mergeBackup([Glossary(id: 'c', name: 'C', updatedAt: now)]);
      await app.save([held[1], held[0]]);

      // The app's order, with c after the glossary before it there (b).
      final stored = await sync.load();
      expect(stored.map((g) => g.id), ['b', 'c', 'a']);
    });

    test('nothing changed meanwhile: written as it is', () async {
      final held = await app.load();
      await app.save([held[1]], deleted: ['a']);
      await app.save([held[1]]);
      expect((await sync.load()).map((g) => g.id), ['b']);
    });
  });

  group('cubits read again when a change overtook a load', () {
    test('PresetsCubit', () async {
      final slow = _SlowStore();
      final cubit = PresetsCubit(
        repository: PresetsRepository(store: slow),
        clock: () => now,
      );
      addTearDown(cubit.close);
      await cubit.load();
      slow.slow = true;
      final loading = cubit.load();
      while (slow.held.isEmpty) {
        await pumpEventQueue();
      }
      final adding = cubit.add(
        name: 'New',
        options: const TranslationOptions(),
      );
      slow.slow = false;
      for (final gate in [...slow.held]) {
        gate.complete();
      }
      await adding;
      await loading;

      expect(cubit.state.presets.map((p) => p.name), contains('New'));
    });

    test('GlossaryCubit', () async {
      final slow = _SlowStore();
      final cubit = GlossaryCubit(
        repository: GlossaryRepository(store: slow),
        clock: () => now,
      );
      addTearDown(cubit.close);
      await cubit.load();
      slow.slow = true;
      final loading = cubit.load();
      while (slow.held.isEmpty) {
        await pumpEventQueue();
      }
      final creating = cubit.create(name: 'New');
      slow.slow = false;
      for (final gate in [...slow.held]) {
        gate.complete();
      }
      await creating;
      await loading;

      expect(cubit.state.glossaries.map((g) => g.name), ['New']);
    });
  });

  test('a change applied to merged data without readable tombstones still '
      'lands', () async {
    final store = _NoTombstonesStore();
    final presets = PresetsRepository(store: store, clock: () => now);
    final glossaries = GlossaryRepository(store: store, clock: () => now);
    final presetsView = await presets.load();
    final glossariesView = await glossaries.load();
    await PresetsRepository(store: store).replaceAll(
      PresetCollection(
        presets: [Preset(id: 'm', updatedAt: now)],
      ),
    );
    await GlossaryRepository(store: store)
        .replaceAll([Glossary(id: 'm', name: 'M', updatedAt: now)]);

    await presets.save(
      PresetCollection(
        presets: [
          ...presetsView.presets,
          Preset(id: 'x', updatedAt: now),
        ],
      ),
    );
    await glossaries.save([
      ...glossariesView,
      Glossary(id: 'x', name: 'X', updatedAt: now),
    ]);

    expect(
      (await presets.load()).presets.map((p) => p.id),
      containsAll(['m', 'x']),
    );
    expect((await glossaries.load()).map((g) => g.id), ['m', 'x']);
  });
}
