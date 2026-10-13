import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/usage/usage.dart';

class _MockStore extends Mock implements KeyValueStore {}

void main() {
  final now = DateTime(2026, 10, 15);
  const october = UsageMonth(2026, 10);
  late MemoryStore store;
  late UsageTracker tracker;

  setUp(() {
    store = MemoryStore();
    tracker = UsageTracker(store: store, clock: () => now);
  });

  tearDown(() => tracker.dispose());

  test('starts with the tracker snapshot', () {
    final cubit = UsageCubit(tracker);
    expect(cubit.state.status, UsageStatus.initial);
    expect(cubit.state.snapshot, tracker.snapshot);
    addTearDown(cubit.close);
  });

  blocTest<UsageCubit, UsageState>(
    'load emits loading then ready',
    setUp: () async {
      final other = UsageTracker(store: store, clock: () => now);
      await other.record('a', 4, 4);
      await other.dispose();
    },
    build: () => UsageCubit(tracker),
    act: (cubit) => cubit.load(),
    verify: (cubit) {
      expect(cubit.state.status, UsageStatus.ready);
      expect(cubit.state.snapshot.statsFor('a').requests, 1);
    },
    expect: () => [
      isA<UsageState>().having((s) => s.status, 'status', UsageStatus.loading),
      isA<UsageState>().having((s) => s.status, 'status', UsageStatus.ready),
    ],
  );

  blocTest<UsageCubit, UsageState>(
    'load emits failure when the store throws',
    build: () {
      final failing = _MockStore();
      when(() => failing.read(any())).thenThrow(StateError('no storage'));
      return UsageCubit(UsageTracker(store: failing, clock: () => now));
    },
    act: (cubit) => cubit.load(),
    expect: () => [
      isA<UsageState>().having((s) => s.status, 'status', UsageStatus.loading),
      isA<UsageState>().having((s) => s.status, 'status', UsageStatus.failure),
    ],
    errors: () => [isA<StateError>()],
  );

  blocTest<UsageCubit, UsageState>(
    'follows tracker changes',
    build: () => UsageCubit(tracker),
    act: (cubit) => tracker.record('a', 8, 0),
    expect: () => [
      UsageState(
        status: UsageStatus.ready,
        snapshot: UsageSnapshot(
          currentMonth: october,
          months: {
            october: const {
              'a': UsageStats(requests: 1, inputChars: 8, inputTokens: 2),
            },
          },
        ),
      ),
    ],
  );

  blocTest<UsageCubit, UsageState>(
    'setBudget sets, keeps the threshold and removes budgets',
    build: () => UsageCubit(tracker),
    act: (cubit) async {
      await tracker.setBudget(
        'a',
        const UsageBudget(monthlyChars: 10, warningThreshold: 0.5),
      );
      await cubit.setBudget('a', 500);
      expect(
        tracker.snapshot.budgetFor('a'),
        const UsageBudget(monthlyChars: 500, warningThreshold: 0.5),
      );
      await cubit.setBudget('b', 300);
      expect(
        tracker.snapshot.budgetFor('b'),
        const UsageBudget(monthlyChars: 300),
      );
      await cubit.setBudget('a', null);
      await cubit.setBudget('b', 0);
    },
    verify: (cubit) => expect(cubit.state.snapshot.budgets, isEmpty),
  );

  blocTest<UsageCubit, UsageState>(
    'reset clears usage',
    setUp: () => tracker.record('a', 8, 0),
    build: () => UsageCubit(tracker),
    act: (cubit) => cubit.reset(),
    verify: (cubit) => expect(cubit.state.snapshot.months, isEmpty),
  );

  blocTest<UsageCubit, UsageState>(
    'reports storage errors without throwing',
    build: () {
      final failing = _MockStore();
      when(() => failing.read(any())).thenAnswer((_) async => null);
      when(() => failing.write(any(), any())).thenThrow(StateError('full'));
      return UsageCubit(UsageTracker(store: failing, clock: () => now));
    },
    act: (cubit) => cubit.reset(providerId: 'a'),
    errors: () => [isA<StateError>()],
  );

  test('load after close does not emit', () async {
    final cubit = UsageCubit(tracker);
    final future = cubit.load();
    await cubit.close();
    await future;
    expect(cubit.isClosed, isTrue);
  });

  test('load failure after close does not emit', () async {
    final failing = _MockStore();
    when(() => failing.read(any())).thenAnswer((_) async {
      throw StateError('x');
    });
    final cubit = UsageCubit(UsageTracker(store: failing, clock: () => now));
    final future = cubit.load();
    await cubit.close();
    await future;
    expect(cubit.isClosed, isTrue);
  });
}
