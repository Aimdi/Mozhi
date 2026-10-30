import 'dart:convert';

import 'package:mozhi/core/key_value_store.dart';
import 'package:translation_repository/translation_repository.dart';

/// Keeps [InstanceHealth]'s failures (which Mozhi servers failed recently,
/// so they are asked last) in a [KeyValueStore], usually the app's
/// [PreferencesStore], as one JSON object of server address -> time of the
/// last failure (UTC, ISO 8601).
///
/// The addresses come without user names and passwords
/// (`InstanceHealth.keyOf`). The entry stays on the device: it is not part
/// of backups, sync or pairing (those carry named sections only), and
/// **Delete all local data** removes it.
class KeyValueInstanceHealthStore implements InstanceHealthStore {
  new(this._store);

  /// The key of the entry.
  static const storageKey = 'mozhi.instanceHealth.v1';

  /// Longest stored value read; a longer one is ignored (at most
  /// `InstanceHealth.maxEntries` short entries are ever written).
  static const int maxStoredLength = 64 * 1024;

  final KeyValueStore _store;

  @override
  Future<Map<String, DateTime>> load() async {
    final raw = await _store.read(storageKey);
    if (raw == null || raw.length > maxStoredLength) return {};
    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException {
      return {};
    }
    if (json is! Map<String, dynamic>) return {};
    return {
      for (final MapEntry(:key, :value) in json.entries)
        if (value is String) key: ?DateTime.tryParse(value),
    };
  }

  @override
  Future<void> save(Map<String, DateTime> failures) async {
    if (failures.isEmpty) return await _store.delete(storageKey);
    await _store.write(
      storageKey,
      jsonEncode({
        for (final MapEntry(:key, :value) in failures.entries)
          key: value.toUtc().toIso8601String(),
      }),
    );
  }
}
