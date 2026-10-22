import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/presets/data/tombstone_store.dart';
import 'package:mozhi/presets/models/tombstone.dart';

const _key = 'things.tombstones';

/// Counts writes; fails them while [failure] is set (a full quota when
/// [quotaLimit] is set and the value is longer).
class _Store extends MemoryStore {
  int writes = 0;
  Object? failure;
  int? quotaLimit;

  @override
  Future<void> write(String key, String value) async {
    writes++;
    if (quotaLimit case final limit? when value.length > limit) {
      throw StateError('QuotaExceededError');
    }
    if (failure case final failure?) throw failure;
    await super.write(key, value);
  }
}

void main() {
  var now = DateTime.utc(2026, 10, 20, 9);
  late _Store store;

  TombstoneStore build({int maxCount = 100, Duration? maxAge}) =>
      TombstoneStore(
        store: store,
        key: _key,
        maxCount: maxCount,
        maxAge: maxAge ?? const Duration(days: 180),
        clock: () => now,
      );

  Map<String, Object?> stored() =>
      Map.from(jsonDecode(store.values[_key]!) as Map);

  setUp(() {
    now = DateTime.utc(2026, 10, 20, 9);
    store = _Store();
  });

  test('reads none when nothing is stored', () async {
    expect(await build().read(), isEmpty);
  });

  test('update records deleted ids now and drops present ones', () async {
    final tombstones = build();
    await tombstones.update(deleted: ['a', 'b']);

    expect(stored(), {
      'a': now.millisecondsSinceEpoch,
      'b': now.millisecondsSinceEpoch,
    });

    now = now.add(const Duration(hours: 1));
    await tombstones.update(deleted: ['c'], present: ['a', 'unknown']);

    expect(await tombstones.read(), {
      'b': now.subtract(const Duration(hours: 1)),
      'c': now,
    });
  });

  test('update writes nothing when nothing changes', () async {
    await build().update(present: ['a']);

    expect(store.writes, 0);
    expect(store.values, isEmpty);
  });

  test('the last one gone deletes the stored value', () async {
    final tombstones = build();
    await tombstones.update(deleted: ['a']);
    await tombstones.update(present: ['a']);

    expect(store.values, isNot(contains(_key)));
  });

  test('update never throws', () async {
    store.failure = StateError('disk full');

    await build().update(deleted: ['a']);

    expect(store.values, isEmpty);
  });

  test('replace stores the given ones without the present ids', () async {
    final tombstones = build();
    await tombstones.update(deleted: ['old']);

    await tombstones.replace(
      {'a': now.subtract(const Duration(days: 1)), 'b': now},
      present: ['b'],
    );

    expect(await tombstones.read(), {
      'a': now.subtract(const Duration(days: 1)),
    });
  });

  test('replace never throws', () async {
    store.failure = StateError('disk full');

    await build().replace({'a': now});

    expect(store.values, isEmpty);
  });

  test('are bounded by age and count, the newest kept', () async {
    final tombstones = build(maxCount: 2, maxAge: const Duration(days: 10));
    await tombstones.replace({
      'too old': now.subtract(const Duration(days: 11)),
      'oldest kept out': now.subtract(const Duration(days: 3)),
      'newer': now.subtract(const Duration(days: 2)),
      'newest': now.subtract(const Duration(days: 1)),
    });

    expect(
      (await tombstones.read()).keys,
      unorderedEquals(['newer', 'newest']),
    );

    now = now.add(const Duration(days: 8, hours: 1));
    expect((await tombstones.read()).keys, ['newest']);
  });

  test('damaged ones read as none and invalid entries are skipped', () async {
    store.values[_key] = '{not json';
    expect(await build().read(), isEmpty);

    store.values[_key] = '[1, 2]';
    expect(await build().read(), isEmpty);

    store.values[_key] = jsonEncode({
      'a': now.millisecondsSinceEpoch,
      'b': 'yesterday',
      '': now.millisecondsSinceEpoch,
    });
    expect(await build().read(), {'a': now});
  });

  test('a full quota drops the older half and retries', () async {
    final tombstones = build();
    final many = {
      for (var i = 0; i < 8; i++) 'id$i': now.subtract(Duration(minutes: i)),
    };
    store.quotaLimit = jsonEncode({
      for (final MapEntry(:key, :value) in many.entries.take(4))
        key: value.millisecondsSinceEpoch,
    }).length;

    await tombstones.replace(many);

    expect(
      (await tombstones.read()).keys,
      unorderedEquals(['id0', 'id1', 'id2', 'id3']),
    );
  });

  test('another error is not retried', () async {
    store.failure = StateError('disk full');

    await build().update(deleted: ['a']);

    expect(store.writes, 1);
  });

  test('toList and toMap convert, the latest per id', () {
    final earlier = now.subtract(const Duration(days: 1));
    final tombstones = [
      Tombstone(id: 'a', deletedAt: earlier),
      Tombstone(id: 'a', deletedAt: now.toLocal()),
      Tombstone(id: 'b', deletedAt: earlier),
      Tombstone(id: 'b', deletedAt: earlier.subtract(const Duration(days: 1))),
    ];

    final map = TombstoneStore.toMap(tombstones);

    expect(map, {'a': now, 'b': earlier});
    expect(map['a']!.isUtc, isTrue);
    expect(TombstoneStore.toList(map), [
      Tombstone(id: 'a', deletedAt: now),
      Tombstone(id: 'b', deletedAt: earlier),
    ]);
  });
}
