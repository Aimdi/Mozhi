import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/key_value_instance_health_store.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  group(KeyValueInstanceHealthStore, () {
    const key = KeyValueInstanceHealthStore.storageKey;
    final failedAt = DateTime.utc(2026, 10, 30, 8, 15);

    test('saves and loads the failures as UTC times', () async {
      final prefs = MemoryStore();
      final store = KeyValueInstanceHealthStore(prefs);
      await store.save({
        'https://a.example': failedAt.toLocal(),
        'https://b.example': failedAt,
      });
      expect(jsonDecode(prefs.values[key]!), {
        'https://a.example': '2026-10-30T08:15:00.000Z',
        'https://b.example': '2026-10-30T08:15:00.000Z',
      });
      expect(await store.load(), {
        'https://a.example': failedAt,
        'https://b.example': failedAt,
      });
    });

    test('nothing to keep deletes the entry', () async {
      final prefs = MemoryStore({key: '{}'});
      await KeyValueInstanceHealthStore(prefs).save({});
      expect(prefs.values, isEmpty);
    });

    test('loads nothing from a missing, broken or oversized entry', () async {
      for (final raw in <String?>[
        null,
        'not json',
        '[1, 2]',
        '"text"',
        '{"https://a.example": "${'x' * KeyValueInstanceHealthStore.maxStoredLength}"}',
      ]) {
        final prefs = MemoryStore({key: ?raw});
        expect(
          await KeyValueInstanceHealthStore(prefs).load(),
          isEmpty,
          reason: raw,
        );
      }
    });

    test('skips entries that are no time', () async {
      final prefs = MemoryStore({
        key: jsonEncode({
          'https://a.example': failedAt.toIso8601String(),
          'https://b.example': 'yesterday',
          'https://c.example': 42,
        }),
      });
      expect(await KeyValueInstanceHealthStore(prefs).load(), {
        'https://a.example': failedAt,
      });
    });

    test('backs an InstanceHealth across restarts', () async {
      final prefs = MemoryStore();
      final now = DateTime.now();
      final first = InstanceHealth(
        store: KeyValueInstanceHealthStore(prefs),
        clock: () => now,
      )..markFailed('https://user:secret@a.example');
      await first.saved;
      expect(prefs.values[key], isNot(contains('secret')));

      final second = InstanceHealth(
        store: KeyValueInstanceHealthStore(prefs),
        clock: () => now,
      );
      await second.ready;
      expect(second.isCoolingDown('https://a.example'), isTrue);
    });
  });
}
