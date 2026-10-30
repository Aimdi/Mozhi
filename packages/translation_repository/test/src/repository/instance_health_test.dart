import 'dart:async';

import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

import 'test_helpers.dart';

/// A store whose load and save can fail or wait.
class _ScriptedStore implements InstanceHealthStore {
  Completer<Map<String, DateTime>>? pendingLoad;
  Error? loadError;
  Error? saveError;
  final List<Map<String, DateTime>> saved = [];

  @override
  Future<Map<String, DateTime>> load() async {
    if (loadError case final error?) throw error;
    return await pendingLoad?.future ?? const {};
  }

  @override
  Future<void> save(Map<String, DateTime> failures) async {
    if (saveError case final error?) throw error;
    saved.add(failures);
  }
}

void main() {
  group(InstanceHealth, () {
    late DateTime now;
    DateTime clock() => now;

    setUp(() => now = DateTime.utc(2026, 10, 30, 12));

    test('keeps the order when nothing failed', () {
      final health = InstanceHealth(clock: clock);
      final order = health.order([instanceA, instanceB, instanceC]);
      expect(order, [instanceA, instanceB, instanceC]);
      expect(health.isCoolingDown(instanceA.url), isFalse);
      expect(health.failedAt(instanceA.url), isNull);
    });

    test('moves failed servers to the back in the user order', () {
      final health = InstanceHealth(clock: clock)
        ..markFailed(instanceA.url)
        ..markFailed(instanceB.url);
      expect(health.order([instanceA, instanceB, instanceC]), [
        instanceC,
        instanceA,
        instanceB,
      ]);
      expect(health.failedAt(instanceA.url), now);
    });

    test('markWorked ends the cool-down', () {
      final health = InstanceHealth(clock: clock)
        ..markFailed(instanceA.url)
        ..markWorked(instanceA.url);
      expect(health.order([instanceA, instanceB]), [instanceA, instanceB]);
    });

    test('a failure counts for the cool-down only', () {
      final health = InstanceHealth(
        clock: clock,
        coolDown: const Duration(hours: 1),
      )..markFailed(instanceA.url);
      now = now.add(const Duration(minutes: 59));
      expect(health.isCoolingDown(instanceA.url), isTrue);
      now = now.add(const Duration(minutes: 1));
      expect(health.isCoolingDown(instanceA.url), isFalse);
      expect(health.order([instanceA, instanceB]), [instanceA, instanceB]);
    });

    test('a failure in the future (clock set back) counts for at most the '
        'cool-down', () {
      final health = InstanceHealth(clock: clock)..markFailed(instanceA.url);
      now = now.subtract(const Duration(hours: 11));
      expect(health.isCoolingDown(instanceA.url), isTrue);
      now = now.subtract(const Duration(hours: 2));
      expect(health.isCoolingDown(instanceA.url), isFalse);
    });

    test('defaults to 12 hours and the system clock', () {
      final health = InstanceHealth()..markFailed(instanceA.url);
      expect(health.coolDown, const Duration(hours: 12));
      expect(health.isCoolingDown(instanceA.url), isTrue);
    });

    test('an address with credentials is the same server', () {
      final health = InstanceHealth(clock: clock)
        ..markFailed('https://user:secret@a.example');
      expect(health.isCoolingDown(instanceA.url), isTrue);
      expect(
        InstanceHealth.keyOf('https://user:secret@a.example/?q=1#x'),
        'https://a.example/',
      );
      expect(
        InstanceHealth.keyOf('https://a.example:8443/mozhi'),
        'https://a.example:8443/mozhi',
      );
    });

    test('ignores what is no address', () {
      final store = MemoryInstanceHealthStore();
      InstanceHealth(store: store, clock: clock)
        ..markFailed('not a url')
        ..markFailed('')
        ..markFailed('::');
      expect(store.saves, 0);
      expect(InstanceHealth.keyOf('mozhi'), isEmpty);
    });

    test('forget clears one server or all', () async {
      final store = MemoryInstanceHealthStore();
      final health = InstanceHealth(store: store, clock: clock)
        ..markFailed(instanceA.url)
        ..markFailed(instanceB.url)
        ..forget(instanceA.url);
      expect(health.isCoolingDown(instanceA.url), isFalse);
      expect(health.isCoolingDown(instanceB.url), isTrue);
      health.forget();
      expect(health.isCoolingDown(instanceB.url), isFalse);
      await health.saved;
      expect(store.failures, isEmpty);
    });

    test('forgetting all without a store or failures saves nothing', () {
      expect(InstanceHealth(clock: clock).forget, returnsNormally);
    });

    group('with a store', () {
      test('loads recent failures and drops old ones', () async {
        final store = MemoryInstanceHealthStore({
          instanceA.url: now.subtract(const Duration(hours: 1)),
          instanceB.url: now.subtract(const Duration(hours: 13)),
          'nonsense': now,
        });
        final health = InstanceHealth(store: store, clock: clock);
        await health.ready;
        expect(health.isCoolingDown(instanceA.url), isTrue);
        expect(health.isCoolingDown(instanceB.url), isFalse);
        expect(store.saves, 0, reason: 'loading writes nothing');
      });

      test('saves each change, without expired entries', () async {
        final store = MemoryInstanceHealthStore();
        final health = InstanceHealth(
          store: store,
          clock: clock,
          coolDown: const Duration(hours: 1),
        )..markFailed(instanceA.url);
        await health.saved;
        expect(store.failures, {instanceA.url: now});

        now = now.add(const Duration(hours: 2));
        health.markFailed(instanceB.url);
        await health.saved;
        expect(store.failures, {instanceB.url: now});

        health.markWorked(instanceB.url);
        await health.saved;
        expect(store.failures, isEmpty);
      });

      test('a success where nothing failed writes nothing', () async {
        final store = MemoryInstanceHealthStore();
        final health = InstanceHealth(store: store, clock: clock)
          ..markWorked(instanceA.url);
        await health.saved;
        expect(store.saves, 0);
      });

      test('keeps the most recent failures only', () async {
        final store = MemoryInstanceHealthStore();
        final health = InstanceHealth(store: store, clock: clock);
        for (var i = 0; i < InstanceHealth.maxEntries + 5; i++) {
          now = now.add(const Duration(seconds: 1));
          health.markFailed('https://s$i.example');
        }
        await health.saved;
        expect(store.failures, hasLength(InstanceHealth.maxEntries));
        expect(store.failures.containsKey('https://s0.example'), isFalse);
        expect(
          store.failures.containsKey(
            'https://s${InstanceHealth.maxEntries + 4}.example',
          ),
          isTrue,
        );
      });

      test('what happened before the store answered wins', () async {
        final store = _ScriptedStore()
          ..pendingLoad = Completer<Map<String, DateTime>>();
        final earlier = now.subtract(const Duration(hours: 1));
        final health = InstanceHealth(store: store, clock: clock)
          ..markWorked(instanceA.url)
          ..markFailed(instanceB.url);
        store.pendingLoad!.complete({
          instanceA.url: earlier,
          instanceB.url: earlier,
          instanceC.url: earlier,
        });
        await health.ready;
        expect(health.isCoolingDown(instanceA.url), isFalse);
        expect(health.failedAt(instanceB.url), now);
        expect(health.failedAt(instanceC.url), earlier);
        await health.saved;
        expect(store.saved.last, {
          instanceB.url: now,
          instanceC.url: earlier,
        }, reason: 'saving waits for the load');
      });

      test('forgetting all before the store answered ignores it', () async {
        final store = _ScriptedStore()
          ..pendingLoad = Completer<Map<String, DateTime>>();
        final health = InstanceHealth(store: store, clock: clock)..forget();
        store.pendingLoad!.complete({instanceA.url: now});
        await health.ready;
        expect(health.isCoolingDown(instanceA.url), isFalse);
        await health.saved;
        expect(store.saved.single, isEmpty);
      });

      test('ignores store failures', () async {
        final store = _ScriptedStore()
          ..loadError = StateError('locked')
          ..saveError = StateError('full');
        final health = InstanceHealth(store: store, clock: clock);
        await health.ready;
        health.markFailed(instanceA.url);
        await health.saved;
        expect(health.isCoolingDown(instanceA.url), isTrue);
      });
    });
  });
}
