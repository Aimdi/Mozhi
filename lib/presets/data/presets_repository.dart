import 'dart:async';
import 'dart:convert';

import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/presets/data/id_generator.dart';
import 'package:mozhi/presets/data/merge_copies.dart';
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
  Future<void> _lock = Future.value();

  /// A new unique preset id.
  String newId() => _generateId();

  Future<PresetCollection> load() async {
    final raw = await store.read(storageKey);
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
  Future<void> save(
    PresetCollection collection, {
    Iterable<String> deleted = const [],
  }) => _synchronized(() async {
    PresetCollection? previous;
    try {
      previous = await load();
    } on Object {
      previous = null;
    }
    await _write(_stamped(collection, previous));
    await _tombstones.update(
      deleted: deleted,
      present: [for (final preset in collection.presets) preset.id],
    );
  });

  /// The presets and their tombstones, for a backup.
  Future<({PresetCollection collection, List<Tombstone> tombstones})>
  backupData() => _synchronized(() async {
    final collection = await load();
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
  /// returns the result.
  ///
  /// Per id the newer copy wins ([Preset.modifiedAt]; this device's on a
  /// tie). A tombstone in either copy at least as new as a preset deletes
  /// it; a preset changed after its tombstone stays. Presets only in one
  /// copy are kept otherwise. The order is that of the copy reordered last
  /// ([PresetCollection.orderUpdatedAt]; this device's on a tie), with the
  /// other copy's presets after the preset before them there. The default
  /// is that of the copy where it changed last
  /// ([PresetCollection.defaultUpdatedAt]); on a tie this device's, or the
  /// backup's when there is none here. A default that was deleted is
  /// cleared. Both copies' tombstones are kept (bounded).
  Future<PresetCollection> mergeBackup(
    PresetCollection backup, {
    List<Tombstone> tombstones = const [],
  }) => _synchronized(() async {
    final local = await load();
    final merged = mergeCopies(
      local: local.presets,
      other: backup.presets,
      idOf: (preset) => preset.id,
      modifiedAt: (preset) => preset.modifiedAt,
      localTombstones: await _tombstones.read(),
      otherTombstones: TombstoneStore.toMap(tombstones),
      otherOrder: isLaterChange(backup.orderUpdatedAt, local.orderUpdatedAt),
    );
    final String? defaultId;
    if (isLaterChange(backup.defaultUpdatedAt, local.defaultUpdatedAt)) {
      defaultId = backup.defaultId;
    } else if (isLaterChange(local.defaultUpdatedAt, backup.defaultUpdatedAt)) {
      defaultId = local.defaultId;
    } else {
      defaultId = local.defaultPreset?.id ?? backup.defaultPreset?.id;
    }
    final collection = PresetCollection(
      presets: merged.items,
      defaultId: merged.items.any((preset) => preset.id == defaultId)
          ? defaultId
          : null,
      orderUpdatedAt: laterOf(local.orderUpdatedAt, backup.orderUpdatedAt),
      defaultUpdatedAt: laterOf(
        local.defaultUpdatedAt,
        backup.defaultUpdatedAt,
      ),
    );
    await _write(collection);
    await _tombstones.replace(merged.tombstones);
    return collection;
  });

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

  Future<void> _write(PresetCollection collection) =>
      store.write(storageKey, jsonEncode(collection.toJson()));

  Future<T> _synchronized<T>(Future<T> Function() action) {
    final result = _lock.then((_) => action());
    _lock = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

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
