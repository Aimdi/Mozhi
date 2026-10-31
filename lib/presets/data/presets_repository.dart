import 'dart:async';
import 'dart:convert';

import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/presets/data/id_generator.dart';
import 'package:mozhi/presets/data/merge_copies.dart';
import 'package:mozhi/presets/data/store_lock.dart';
import 'package:mozhi/presets/data/tombstone_store.dart';
import 'package:mozhi/presets/models/preset.dart';
import 'package:mozhi/presets/models/tombstone.dart';

export '../models/tombstone.dart';

/// Persists presets as JSON under [storageKey]:
/// `{"version": 1, "defaultId": "...", "orderUpdatedAt": "...",
/// "defaultUpdatedAt": "...", "presets": [...]}` (the change times only
/// once there are any).
///
/// When nothing is stored yet, [load] returns the built-in examples
/// ([PresetCollection.examples]). Unreadable or unknown data also loads as
/// the examples and is only overwritten by the next [save]. Writes are
/// serialised.
///
/// For backups and sync ([backupData], [replaceAll], [mergeBackup]):
/// presets carry their change time ([Preset.updatedAt], stamped by the
/// `PresetsCubit`), [save] stamps when the order and the default change
/// ([PresetCollection.orderUpdatedAt], [PresetCollection.defaultUpdatedAt])
/// and records a [Tombstone] for every preset it is told was deleted.
/// Tombstones are stored under [tombstonesStorageKey] (plain JSON, like the
/// presets), kept for [tombstoneMaxAge] and at most [maxTombstones] of
/// them; a preset that is saved again drops its tombstone. They are best
/// effort: when they can't be read or written, the presets still are.
///
/// Every repository over the same [store] reads and writes one at a time
/// ([StoreLock]): the app's and the backup section's (sync merges through
/// the latter). When the stored presets changed since this repository's
/// caller last read or saved them (a sync merged in between), [save]
/// applies the caller's change to the stored presets instead of writing
/// over them (see there), so that neither the change nor the merge is
/// lost.
class PresetsRepository {
  new({
    KeyValueStore? store,
    IdGenerator? generateId,
    DateTime Function()? clock,
    this.maxTombstones = 10000,
    this.tombstoneMaxAge = const Duration(days: 180),
  }) : store = store ?? PreferencesStore(),
       _generateId = generateId ?? generateLocalId,
       _clock = clock ?? DateTime.now;

  /// Key of the presets JSON in [store].
  static const storageKey = 'presets.v1';

  /// Key of the presets' tombstones in [store].
  static const tombstonesStorageKey = 'presets.v1.tombstones';

  final KeyValueStore store;
  final IdGenerator _generateId;
  final DateTime Function() _clock;

  /// At most this many tombstones are kept (the newest).
  final int maxTombstones;

  /// Tombstones older than this are dropped.
  final Duration tombstoneMaxAge;

  late final TombstoneStore _tombstones = TombstoneStore(
    store: store,
    key: tombstonesStorageKey,
    maxCount: maxTombstones,
    maxAge: tombstoneMaxAge,
    clock: _clock,
  );

  /// The presets this repository's caller holds: what it last loaded or
  /// saved (null before either).
  PresetCollection? _view;

  /// What [store] held when this repository last read or wrote it (before
  /// a write that failed): another repository wrote since when it holds
  /// something else. Only used in [_synchronized] actions, which run in
  /// the order they were started.
  String? _knownRaw;

  /// Whether the stored presets are the caller's (those it last loaded or
  /// saved, as far as this repository wrote them); not after a save that
  /// had to apply the caller's change to presets merged in meanwhile.
  bool _viewMatches = false;

  /// How many saves were started (a load that a save overtook leaves the
  /// caller's presets to the save).
  int _saves = 0;

  /// A new unique preset id.
  String newId() => _generateId();

  /// The stored presets (after the changes started before this call).
  Future<PresetCollection> load() {
    final saves = _saves;
    return _synchronized(() async {
      final raw = await store.read(storageKey);
      final collection = _decode(raw);
      if (_saves == saves) {
        _view = collection;
        _knownRaw = raw;
        _viewMatches = true;
      }
      return collection;
    });
  }

  Future<PresetCollection> _read() async =>
      _decode(await store.read(storageKey));

  static PresetCollection _decode(String? raw) {
    if (raw == null) return PresetCollection.examples();
    try {
      return PresetCollection.tryParse(jsonDecode(raw)) ??
          PresetCollection.examples();
    } on FormatException {
      return PresetCollection.examples();
    }
  }

  /// Writes [collection]: the presets after a change in the app.
  ///
  /// The presets named in [deleted] (deleted by the change) leave a
  /// tombstone; those in [collection] drop theirs. When the order of the
  /// presets kept, or the default, differs from the stored one, it is
  /// stamped as changed now ([PresetCollection.orderUpdatedAt],
  /// [PresetCollection.defaultUpdatedAt]); otherwise the stored change
  /// times are kept (or [collection]'s, when later). Storage errors of the
  /// presets are thrown, those of the tombstones and change times ignored.
  ///
  /// When the stored presets are no longer the ones [collection] was made
  /// from (what this repository last loaded or saved: a sync merged in
  /// between), the change is applied to the stored presets: per preset
  /// the newer copy wins (the change's are stamped now by the cubit),
  /// [deleted] ones are deleted, presets only stored are kept, and the
  /// order and the default are [collection]'s only when the change set
  /// them, the stored ones otherwise.
  Future<void> save(
    PresetCollection collection, {
    Iterable<String> deleted = const [],
  }) {
    final base = _view;
    _saves++;
    _view = collection;
    return _synchronized(() async {
      String? raw;
      PresetCollection? previous;
      try {
        raw = await store.read(storageKey);
        previous = _decode(raw);
      } on Object {
        previous = null;
      }
      if (base != null &&
          previous != null &&
          (raw != _knownRaw || !_viewMatches)) {
        _knownRaw = raw;
        _viewMatches = false;
        await _rebase(base, collection, previous, deleted: deleted);
        return;
      }
      _knownRaw = raw;
      _viewMatches = true;
      _knownRaw = await _write(_stamped(collection, previous));
      await _tombstones.update(
        deleted: deleted,
        present: [for (final preset in collection.presets) preset.id],
      );
    });
  }

  /// Writes the change from [base] to [mine] applied to the stored
  /// [theirs] (see [save]).
  Future<void> _rebase(
    PresetCollection base,
    PresetCollection mine,
    PresetCollection theirs, {
    required Iterable<String> deleted,
  }) async {
    final now = _clock().toUtc();
    final reordered = !sameRelativeOrder(
      [for (final preset in base.presets) preset.id],
      [for (final preset in mine.presets) preset.id],
    );
    final merged = mergeCopies(
      local: mine.presets,
      other: theirs.presets,
      idOf: (preset) => preset.id,
      modifiedAt: (preset) => preset.modifiedAt,
      localTombstones: {for (final id in deleted) id: now},
      otherTombstones: await _readTombstones(),
      otherOrder: !reordered,
      contentOf: _contentOf,
      resolved: _resolved,
    );
    final defaultChanged = base.defaultPreset?.id != mine.defaultPreset?.id;
    final defaultId = defaultChanged ? mine.defaultId : theirs.defaultId;
    _knownRaw = await _write(
      PresetCollection(
        presets: merged.items,
        defaultId: merged.items.any((preset) => preset.id == defaultId)
            ? defaultId
            : null,
        orderUpdatedAt: reordered ? now : theirs.orderUpdatedAt,
        defaultUpdatedAt: defaultChanged ? now : theirs.defaultUpdatedAt,
      ),
    );
    await _tombstones.replace(merged.tombstones);
  }

  /// The stored tombstones; none when they can't be read (best effort).
  Future<Map<String, DateTime>> _readTombstones() async {
    try {
      return await _tombstones.read();
    } on Object {
      return {};
    }
  }

  /// The presets and their tombstones, for a backup.
  Future<({PresetCollection collection, List<Tombstone> tombstones})>
  backupData() => _synchronized(() async {
    final collection = await _read();
    final tombstones = await _tombstones.read();
    return (
      collection: collection,
      tombstones: TombstoneStore.toList(tombstones),
    );
  });

  /// Makes [collection] (with its change times) the presets and
  /// [tombstones] their tombstones: a backup restored with "Replace my
  /// data". What was here before leaves no tombstones.
  Future<void> replaceAll(
    PresetCollection collection, {
    List<Tombstone> tombstones = const [],
  }) => _synchronized(() async {
    await _write(collection);
    await _tombstones.replace(
      TombstoneStore.toMap(tombstones),
      present: [for (final preset in collection.presets) preset.id],
    );
  });

  /// Merges a backup's presets ([backup]) and [tombstones] into the stored
  /// ones (a backup restored with "Merge with my data", and sync), and
  /// returns the result. It reads the stored presets after every change
  /// started before it, also by other repositories over the same store.
  ///
  /// Per id the newer copy wins ([Preset.modifiedAt]). Two different
  /// copies changed at the same time (or both without a change time) are
  /// decided by the SHA-256 of their content, the same on every device,
  /// and the winner without a change time gets [resolvedChangeTime].
  /// A tombstone in either copy at least as new as a preset deletes
  /// it; a preset changed after its tombstone stays. Presets only in one
  /// copy are kept otherwise. The order is that of the copy reordered last
  /// ([PresetCollection.orderUpdatedAt]), with the other copy's presets
  /// after the preset before them there. The default is that of the copy
  /// where it changed last ([PresetCollection.defaultUpdatedAt]). Ties
  /// between different orders, or between two different defaults, are
  /// decided like those between presets ([pickChange]); a default on one
  /// side only wins a tie. A default that was deleted is cleared. Both
  /// copies' tombstones are kept (bounded).
  Future<PresetCollection> mergeBackup(
    PresetCollection backup, {
    List<Tombstone> tombstones = const [],
  }) => _synchronized(() async {
    final local = await _read();
    final order = pickChange(
      localAt: local.orderUpdatedAt,
      otherAt: backup.orderUpdatedAt,
      localKey: _orderKey(local.presets, backup.presets),
      otherKey: _orderKey(backup.presets, local.presets),
    );
    final merged = mergeCopies(
      local: local.presets,
      other: backup.presets,
      idOf: (preset) => preset.id,
      modifiedAt: (preset) => preset.modifiedAt,
      localTombstones: await _tombstones.read(),
      otherTombstones: TombstoneStore.toMap(tombstones),
      otherOrder: order.otherWins,
      contentOf: _contentOf,
      resolved: _resolved,
    );
    final mine = local.defaultPreset?.id;
    final theirs = backup.defaultPreset?.id;
    var defaults = pickChange(
      localAt: local.defaultUpdatedAt,
      otherAt: backup.defaultUpdatedAt,
      localKey: mine ?? '',
      otherKey: theirs ?? '',
    );
    final tie =
        !isLaterChange(local.defaultUpdatedAt, backup.defaultUpdatedAt) &&
        !isLaterChange(backup.defaultUpdatedAt, local.defaultUpdatedAt);
    final String? defaultId;
    if (tie && (mine == null || theirs == null)) {
      defaultId = mine ?? theirs;
      defaults = (
        otherWins: mine == null,
        changedAt: laterOf(local.defaultUpdatedAt, backup.defaultUpdatedAt),
      );
    } else {
      defaultId = defaults.otherWins ? backup.defaultId : local.defaultId;
    }
    final collection = PresetCollection(
      presets: merged.items,
      defaultId: merged.items.any((preset) => preset.id == defaultId)
          ? defaultId
          : null,
      orderUpdatedAt: order.changedAt,
      defaultUpdatedAt: defaults.changedAt,
    );
    await _write(collection);
    await _tombstones.replace(merged.tombstones);
    return collection;
  });

  /// The ids of [presets] that [other] has too, in [presets]' order: two
  /// orders conflict when these differ.
  static String _orderKey(List<Preset> presets, List<Preset> other) {
    final ids = {for (final preset in other) preset.id};
    return [
      for (final preset in presets)
        if (ids.contains(preset.id)) preset.id,
    ].join('\n');
  }

  /// What two copies of a preset are compared by when their change times
  /// tie.
  static String _contentOf(Preset preset) =>
      canonicalJson(preset.withoutChangeTime().toJson());

  /// The winner of a tie, with [resolvedChangeTime] when it has no change
  /// time.
  static Preset _resolved(Preset preset) => preset.updatedAt == null
      ? preset.copyWith(updatedAt: resolvedChangeTime)
      : preset;

  /// [collection] with the order and default stamped as changed now when
  /// they differ from [previous] (see [save]).
  PresetCollection _stamped(
    PresetCollection collection,
    PresetCollection? previous,
  ) {
    if (previous == null) return collection;
    final now = _clock();
    final reordered = !sameRelativeOrder(
      [for (final preset in previous.presets) preset.id],
      [for (final preset in collection.presets) preset.id],
    );
    final defaultChanged =
        previous.defaultPreset?.id != collection.defaultPreset?.id;
    return PresetCollection(
      presets: collection.presets,
      defaultId: collection.defaultId,
      orderUpdatedAt: reordered
          ? now
          : laterOf(previous.orderUpdatedAt, collection.orderUpdatedAt),
      defaultUpdatedAt: defaultChanged
          ? now
          : laterOf(previous.defaultUpdatedAt, collection.defaultUpdatedAt),
    );
  }

  /// Writes [collection] and returns what was written.
  Future<String> _write(PresetCollection collection) async {
    final raw = jsonEncode(collection.toJson());
    await store.write(storageKey, raw);
    return raw;
  }

  Future<T> _synchronized<T>(Future<T> Function() action) =>
      StoreLock.run(store, storageKey, action);

  /// Pretty JSON document in the storage format. With [ids], only those
  /// presets are exported (in collection order). Change times are left
  /// out: the export is for sharing, and an import gets new ones.
  String exportJson(PresetCollection collection, {Set<String>? ids}) {
    final presets = [
      for (final preset in collection.presets)
        if (ids == null || ids.contains(preset.id)) preset.withoutChangeTime(),
    ];
    final defaultId = collection.defaultId;
    return const JsonEncoder.withIndent('  ').convert(
      PresetCollection(
        presets: presets,
        defaultId: presets.any((preset) => preset.id == defaultId)
            ? defaultId
            : null,
      ).toJson(),
    );
  }

  /// Presets from an exported document, a list of presets or a single
  /// preset object, each with a fresh id (so imports never clash).
  ///
  /// Throws [FormatException] when [json] is not valid JSON, has none of
  /// those shapes, or contains no valid preset although it is not empty.
  List<Preset> parseImport(String json) {
    final decoded = jsonDecode(json);
    final Object? document = decoded is Map && decoded['presets'] is! List
        ? [decoded]
        : decoded;
    final collection = PresetCollection.tryParse(document);
    if (collection == null) {
      throw const FormatException('Expected exported presets');
    }
    final count = switch (document) {
      final List<dynamic> list => list.length,
      final Map<dynamic, dynamic> map => (map['presets'] as List).length,
      _ => 0,
    };
    if (collection.presets.isEmpty && count > 0) {
      throw const FormatException('No valid presets found');
    }
    return [
      for (final preset in collection.presets) preset.copyWith(id: newId()),
    ];
  }
}
