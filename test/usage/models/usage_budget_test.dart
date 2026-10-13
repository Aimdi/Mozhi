import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/usage/models/models.dart';

void main() {
  group('UsageBudget', () {
    const budget = UsageBudget(monthlyChars: 1000);

    test('warns at 80 % by default', () {
      expect(budget.warningThreshold, 0.8);
      expect(budget.warningChars, 800);
    });

    test('levelFor', () {
      expect(budget.levelFor(0), UsageBudgetLevel.ok);
      expect(budget.levelFor(799), UsageBudgetLevel.ok);
      expect(budget.levelFor(800), UsageBudgetLevel.nearLimit);
      expect(budget.levelFor(999), UsageBudgetLevel.nearLimit);
      expect(budget.levelFor(1000), UsageBudgetLevel.limitReached);
      expect(budget.levelFor(5000), UsageBudgetLevel.limitReached);
    });

    test('statusFor measures total characters', () {
      final status = budget.statusFor(
        const UsageStats(inputChars: 300, outputChars: 600),
      );
      expect(status.usedChars, 900);
      expect(status.fraction, closeTo(0.9, 1e-9));
      expect(status.remainingChars, 100);
      expect(status.level, UsageBudgetLevel.nearLimit);
      expect(
        const UsageBudgetStatus(budget: budget, usedChars: 1200).remainingChars,
        0,
      );
    });

    test('round-trips through JSON', () {
      const custom = UsageBudget(monthlyChars: 50, warningThreshold: 0.5);
      expect(UsageBudget.tryFromJson(custom.toJson()), custom);
    });

    test('tryFromJson rejects invalid budgets', () {
      expect(UsageBudget.tryFromJson(null), isNull);
      expect(UsageBudget.tryFromJson('x'), isNull);
      expect(UsageBudget.tryFromJson(const {'monthlyChars': 0}), isNull);
      expect(UsageBudget.tryFromJson(const {'monthlyChars': 'a'}), isNull);
      expect(
        UsageBudget.tryFromJson(const {
          'monthlyChars': 10,
          'warningThreshold': 3,
        }),
        const UsageBudget(monthlyChars: 10),
      );
    });
  });

  test('UsageWarning exposes the used fraction', () {
    const warning = UsageWarning(
      providerId: 'p',
      month: UsageMonth(2026, 10),
      level: UsageBudgetLevel.nearLimit,
      usedChars: 850,
      budget: UsageBudget(monthlyChars: 1000),
    );
    expect(warning.fraction, closeTo(0.85, 1e-9));
  });
}
