import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/usage/models/models.dart';

void main() {
  const october = UsageMonth(2026, 10);
  const september = UsageMonth(2026, 9);
  const a = UsageStats(requests: 1, inputChars: 10, outputChars: 20);
  const b = UsageStats(requests: 2, inputChars: 5, outputChars: 5);

  final snapshot = UsageSnapshot(
    currentMonth: october,
    months: {
      october: {'a': a, 'b': b},
      september: {'a': b, 'empty': UsageStats.zero},
    },
    budgets: const {'c': UsageBudget(monthlyChars: 100)},
  );

  test('statsFor defaults to the current month and zero', () {
    expect(snapshot.statsFor('a'), a);
    expect(snapshot.statsFor('a', month: september), b);
    expect(snapshot.statsFor('x'), UsageStats.zero);
    expect(snapshot.lastMonth, september);
  });

  test('totalFor sums all providers', () {
    expect(snapshot.totalFor(), a + b);
    expect(
      snapshot.totalFor(month: const UsageMonth(2020, 1)),
      UsageStats.zero,
    );
  });

  test('budgets and their status', () {
    expect(snapshot.budgetFor('c'), const UsageBudget(monthlyChars: 100));
    expect(snapshot.budgetStatus('a'), isNull);
    expect(snapshot.budgetStatus('c')?.usedChars, 0);
  });

  test('history lists the last months, oldest first', () {
    expect(snapshot.history('a', count: 3), [UsageStats.zero, b, a]);
  });

  test('providerIds includes usage and budgets, not empty entries', () {
    expect(snapshot.providerIds, ['a', 'b', 'c']);
  });

  test('isEmpty', () {
    expect(snapshot.isEmpty, isFalse);
    expect(const UsageSnapshot(currentMonth: october).isEmpty, isTrue);
    expect(
      UsageSnapshot(
        currentMonth: october,
        months: {
          october: const {'a': UsageStats.zero},
        },
      ).isEmpty,
      isTrue,
    );
  });
}
