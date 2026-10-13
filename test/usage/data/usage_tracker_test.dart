import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/usage/usage.dart';

class _FailingWriteStore extends MemoryStore {
  bool fail = true;

  @override
  Future<void> write(String key, String value) async {
    if (fail) throw StateError('disk full');
    await super.write(key, value);
  }
}

void main() {
  late MemoryStore store;
  late DateTime now;
  late UsageTracker tracker;

  UsageTracker newTracker({int keepMonths = 13}) =>
      UsageTracker(store: store, clock: () => now, keepMonths: keepMonths);

  setUp(() {
    store = MemoryStore();
    now = DateTime(2026, 10, 15, 12);
    tracker = newTracker();
  });

  tearDown(() => tracker.dispose());

  Map<String, dynamic> stored() =>
      jsonDecode(store.values[UsageTracker.storageKey]!)
          as Map<String, dynamic>;

  group('record', () {
    test('accumulates requests, characters and estimated tokens', () async {
      await tracker.record('openai', 100, 41);
      final stats = await tracker.record('openai', 3, 0);

      const expected = UsageStats(
        requests: 2,
        inputChars: 103,
        outputChars: 41,
        inputTokens: 25 + 1,
        outputTokens: 11,
      );
      expect(stats, expected);
      expect(tracker.snapshot.statsFor('openai'), expected);
      expect(tracker.snapshot.statsFor('other'), UsageStats.zero);
    });

    test('keeps providers apart', () async {
      await tracker.record('a', 10, 10);
      await tracker.record('b', 20, 20);
      expect(tracker.snapshot.statsFor('a').totalChars, 20);
      expect(tracker.snapshot.statsFor('b').totalChars, 40);
      expect(tracker.snapshot.totalFor().requests, 2);
    });

    test('uses given token counts', () async {
      final stats = await tracker.record(
        'a',
        10,
        10,
        inputTokens: 7,
        outputTokens: 9,
      );
      expect(stats.inputTokens, 7);
      expect(stats.outputTokens, 9);
    });

    test('rejects an empty provider id and negative counts', () {
      expect(() => tracker.record('', 1, 1), throwsArgumentError);
      expect(() => tracker.record('a', -1, 1), throwsArgumentError);
      expect(() => tracker.record('a', 1, -1), throwsArgumentError);
      expect(
        () => tracker.record('a', 1, 1, inputTokens: -1),
        throwsArgumentError,
      );
      expect(
        () => tracker.record('a', 1, 1, outputTokens: -1),
        throwsArgumentError,
      );
    });

    test('recordText counts code points and CJK-aware tokens', () async {
      final stats = await tracker.recordText(
        'a',
        input: 'Good morning',
        output: 'おはようございます',
      );
      expect(stats.inputChars, 12);
      expect(stats.outputChars, 9);
      expect(stats.inputTokens, 3);
      expect(stats.outputTokens, 9);
      expect(stats.estimatedTokens, 12);
    });

    test('notifies changes', () async {
      final snapshots = <UsageSnapshot>[];
      final sub = tracker.changes.listen(snapshots.add);
      await tracker.record('a', 4, 4);
      await pumpEventQueue();
      expect(snapshots.single.statsFor('a').requests, 1);
      await sub.cancel();
    });
  });

  group('months', () {
    test('a new month starts from zero and keeps last month', () async {
      await tracker.record('a', 100, 100);
      now = DateTime(2026, 11, 1, 0, 1);

      expect(tracker.currentMonth, const UsageMonth(2026, 11));
      expect(tracker.snapshot.statsFor('a'), UsageStats.zero);
      expect(
        tracker.snapshot.statsFor('a', month: tracker.snapshot.lastMonth),
        const UsageStats(
          requests: 1,
          inputChars: 100,
          outputChars: 100,
          inputTokens: 25,
          outputTokens: 25,
        ),
      );

      await tracker.record('a', 8, 0);
      expect(tracker.snapshot.statsFor('a').inputChars, 8);
      expect(stored()['months'], {
        '2026-10': {
          'a': {
            'requests': 1,
            'inputChars': 100,
            'outputChars': 100,
            'inputTokens': 25,
            'outputTokens': 25,
          },
        },
        '2026-11': {
          'a': {
            'requests': 1,
            'inputChars': 8,
            'outputChars': 0,
            'inputTokens': 2,
            'outputTokens': 0,
          },
        },
      });
    });

    test('rolls over at the year boundary', () async {
      now = DateTime(2026, 12, 31, 23, 59);
      await tracker.record('a', 1, 1);
      now = DateTime(2027);
      expect(tracker.snapshot.lastMonth, const UsageMonth(2026, 12));
      expect(
        tracker.snapshot.statsFor('a', month: tracker.snapshot.lastMonth),
        isNot(UsageStats.zero),
      );
    });

    test('drops months older than keepMonths', () async {
      tracker = newTracker(keepMonths: 3);
      now = DateTime(2026, 7, 2);
      await tracker.record('a', 1, 1);
      now = DateTime(2026, 8, 2);
      await tracker.record('a', 2, 2);
      now = DateTime(2026, 10, 2);
      await tracker.record('a', 3, 3);

      expect(tracker.snapshot.months.keys, [
        const UsageMonth(2026, 8),
        const UsageMonth(2026, 10),
      ]);
      expect((stored()['months'] as Map).keys, ['2026-08', '2026-10']);
      expect(tracker.snapshot.history('a', count: 3).map((s) => s.inputChars), [
        2,
        0,
        3,
      ]);
    });
  });

  group('persistence', () {
    test('stores JSON under usage.v1 and reloads it', () async {
      await tracker.record('a', 10, 20);
      await tracker.setBudget('a', const UsageBudget(monthlyChars: 500));

      expect(UsageTracker.storageKey, 'usage.v1');
      expect(stored()['version'], 1);
      expect(stored()['budgets'], {
        'a': {'monthlyChars': 500, 'warningThreshold': 0.8},
      });

      final reloaded = newTracker();
      final snapshot = await reloaded.load();
      expect(snapshot.statsFor('a').totalChars, 30);
      expect(snapshot.budgetFor('a'), const UsageBudget(monthlyChars: 500));
      expect(reloaded.snapshot, snapshot);
      await reloaded.dispose();
    });

    test('is empty before loading and without stored data', () async {
      expect(tracker.snapshot.isEmpty, isTrue);
      expect((await tracker.load()).isEmpty, isTrue);
    });

    test('keeps stored usage when recording without loading first', () async {
      await tracker.record('a', 4, 4);
      final other = newTracker();
      await other.record('a', 4, 4);
      expect(other.snapshot.statsFor('a').requests, 2);
      await other.dispose();
    });

    test('load notifies changes', () async {
      final future = tracker.changes.first;
      await tracker.load();
      expect(await future, tracker.snapshot);
    });

    test('unreadable JSON loads as empty', () async {
      for (final raw in ['{not json', '[1, 2]', '"x"']) {
        store.values[UsageTracker.storageKey] = raw;
        expect((await tracker.load()).isEmpty, isTrue, reason: raw);
      }
    });

    test('skips invalid entries', () async {
      store.values[UsageTracker.storageKey] = jsonEncode({
        'months': {
          'garbage': {
            'a': {'requests': 1},
          },
          '2026-10': {
            'a': {'requests': 2, 'inputChars': 8},
            '': {'requests': 1},
            'b': 'x',
          },
          '2026-09': 'x',
          '2026-08': {'b': 'x'},
        },
        'budgets': {
          'a': {'monthlyChars': 10},
          'b': {'monthlyChars': -1},
        },
        'alerts': {
          '2026-10': {'a': 'nearLimit', 'b': 'bogus'},
          '2026-09': 'x',
          'bad': {'a': 'nearLimit'},
        },
      });
      final snapshot = await tracker.load();
      expect(snapshot.months.keys, [const UsageMonth(2026, 10)]);
      expect(
        snapshot.statsFor('a'),
        const UsageStats(requests: 2, inputChars: 8, inputTokens: 2),
      );
      expect(snapshot.budgets, {'a': const UsageBudget(monthlyChars: 10)});

      // The stored nearLimit alert suppresses a repeated warning.
      final warnings = <UsageWarning>[];
      final sub = tracker.warnings.listen(warnings.add);
      await tracker.record('a', 0, 0);
      await pumpEventQueue();
      expect(warnings, isEmpty);
      await sub.cancel();
    });

    test('a write failure propagates, keeps counting and recovers', () async {
      final failing = _FailingWriteStore();
      final t = UsageTracker(store: failing, clock: () => now);
      await expectLater(t.record('a', 1, 1), throwsStateError);
      expect(t.snapshot.statsFor('a').requests, 1);

      failing.fail = false;
      await t.record('a', 1, 1);
      final reloaded = UsageTracker(store: failing, clock: () => now);
      expect((await reloaded.load()).statsFor('a').requests, 2);
      await t.dispose();
      await reloaded.dispose();
    });
  });

  group('budgets', () {
    late List<UsageWarning> warnings;
    late StreamSubscription<UsageWarning> sub;

    setUp(() {
      warnings = [];
      sub = tracker.warnings.listen(warnings.add);
    });

    tearDown(() => sub.cancel());

    Future<void> record(int chars) async {
      await tracker.record('a', chars, 0);
      await pumpEventQueue();
    }

    test('no budget, no warnings', () async {
      await record(1000000);
      expect(warnings, isEmpty);
      expect(tracker.snapshot.budgetStatus('a'), isNull);
    });

    test('warns once at 80 % and once at the limit', () async {
      await tracker.setBudget('a', const UsageBudget(monthlyChars: 1000));
      await record(700);
      expect(warnings, isEmpty);

      await record(100);
      expect(warnings, [
        const UsageWarning(
          providerId: 'a',
          month: UsageMonth(2026, 10),
          level: UsageBudgetLevel.nearLimit,
          usedChars: 800,
          budget: UsageBudget(monthlyChars: 1000),
        ),
      ]);

      await record(100);
      expect(warnings, hasLength(1));

      await record(100);
      expect(warnings, hasLength(2));
      expect(warnings.last.level, UsageBudgetLevel.limitReached);
      expect(warnings.last.usedChars, 1000);

      await record(100);
      expect(warnings, hasLength(2));
      expect(
        tracker.snapshot.budgetStatus('a')?.level,
        UsageBudgetLevel.limitReached,
      );
    });

    test('jumping past the limit only reports the limit', () async {
      await tracker.setBudget('a', const UsageBudget(monthlyChars: 100));
      await record(150);
      expect(warnings.single.level, UsageBudgetLevel.limitReached);
    });

    test('honours a custom threshold', () async {
      await tracker.setBudget(
        'a',
        const UsageBudget(monthlyChars: 100, warningThreshold: 0.5),
      );
      await record(50);
      expect(warnings.single.level, UsageBudgetLevel.nearLimit);
    });

    test('a new month re-arms the warnings', () async {
      await tracker.setBudget('a', const UsageBudget(monthlyChars: 100));
      await record(90);
      expect(warnings, hasLength(1));

      now = DateTime(2026, 11, 3);
      await record(10);
      expect(warnings, hasLength(1));
      await record(75);
      expect(warnings, hasLength(2));
      expect(warnings.last.month, const UsageMonth(2026, 11));
      expect(warnings.last.usedChars, 85);
      // Old months' alerts are pruned.
      expect((stored()['alerts'] as Map).keys, ['2026-11']);
    });

    test('changing the budget re-arms the warnings', () async {
      await tracker.setBudget('a', const UsageBudget(monthlyChars: 100));
      await record(85);
      expect(warnings, hasLength(1));

      await tracker.setBudget('a', const UsageBudget(monthlyChars: 200));
      await record(80);
      expect(warnings, hasLength(2));
      expect(warnings.last.budget.monthlyChars, 200);
      expect(warnings.last.usedChars, 165);
    });

    test('warnings are not repeated after a restart', () async {
      await tracker.setBudget('a', const UsageBudget(monthlyChars: 100));
      await record(85);
      expect(warnings, hasLength(1));

      final restarted = newTracker();
      final later = <UsageWarning>[];
      final laterSub = restarted.warnings.listen(later.add);
      await restarted.record('a', 1, 0);
      await pumpEventQueue();
      expect(later, isEmpty);
      await restarted.record('a', 20, 0);
      await pumpEventQueue();
      expect(later.single.level, UsageBudgetLevel.limitReached);
      await laterSub.cancel();
      await restarted.dispose();
    });

    test('removing a budget stops warnings', () async {
      await tracker.setBudget('a', const UsageBudget(monthlyChars: 100));
      await tracker.setBudget('a', null);
      await record(500);
      expect(warnings, isEmpty);
      expect(tracker.snapshot.budgets, isEmpty);
    });
  });

  group('reset and removeProvider', () {
    setUp(() async {
      await tracker.record('a', 10, 10);
      await tracker.record('b', 10, 10);
      await tracker.setBudget('a', const UsageBudget(monthlyChars: 25));
      await tracker.record('a', 0, 0);
    });

    test('reset clears one provider and keeps budgets', () async {
      await tracker.reset(providerId: 'a');
      expect(tracker.snapshot.statsFor('a'), UsageStats.zero);
      expect(tracker.snapshot.statsFor('b').requests, 1);
      expect(tracker.snapshot.budgetFor('a'), isNotNull);
      expect(stored()['alerts'], isEmpty);
    });

    test('reset without an id clears all usage', () async {
      await tracker.reset();
      expect(tracker.snapshot.months, isEmpty);
      expect(tracker.snapshot.budgetFor('a'), isNotNull);
      expect(stored()['months'], isEmpty);
    });

    test('removeProvider forgets usage and budget', () async {
      await tracker.removeProvider('a');
      expect(tracker.snapshot.providerIds, ['b']);
      expect(stored()['budgets'], isEmpty);
    });
  });

  test('dispose closes the streams', () async {
    final changesDone = tracker.changes.toList();
    final warningsDone = tracker.warnings.toList();
    await tracker.dispose();
    expect(await changesDone, isEmpty);
    expect(await warningsDone, isEmpty);
    // Still usable without listeners.
    await tracker.setBudget('a', const UsageBudget(monthlyChars: 1));
    await tracker.record('a', 5, 5);
    expect(tracker.snapshot.statsFor('a').requests, 1);
  });

  test('defaults to PreferencesStore', () {
    expect(UsageTracker().store, isA<PreferencesStore>());
  });
}
