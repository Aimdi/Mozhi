import 'dart:async';
import 'dart:convert';

import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/presets/data/id_generator.dart';
import 'package:mozhi/presets/models/preset.dart';

/// Persists presets as JSON under [storageKey]:
/// `{"version": 1, "defaultId": "...", "presets": [...]}`.
///
/// When nothing is stored yet, [load] returns the built-in examples
/// ([PresetCollection.examples]). Unreadable or unknown data also loads as
/// the examples and is only overwritten by the next [save]. Writes are
/// serialised.
class PresetsRepository {
  new({KeyValueStore? store, IdGenerator? generateId})
    : store = store ?? PreferencesStore(),
      _generateId = generateId ?? generateLocalId;

  /// Key of the presets JSON in [store].
  static const storageKey = 'presets.v1';

  final KeyValueStore store;
  final IdGenerator _generateId;
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

  Future<void> save(PresetCollection collection) {
    final json = jsonEncode(collection.toJson());
    final result = _lock.then((_) => store.write(storageKey, json));
    _lock = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// Pretty JSON document in the storage format. With [ids], only those
  /// presets are exported (in collection order).
  String exportJson(PresetCollection collection, {Set<String>? ids}) {
    final presets = [
      for (final preset in collection.presets)
        if (ids == null || ids.contains(preset.id)) preset,
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
