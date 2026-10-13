import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/usage/usage.dart';

import '../../helpers/helpers.dart';

void main() {
  testWidgets('falls back to English for unknown locales', (tester) async {
    late BuildContext captured;
    await tester.pumpWidget(
      Localizations(
        locale: const Locale('zz'),
        delegates: const [DefaultWidgetsLocalizations.delegate],
        child: Builder(
          builder: (context) {
            captured = context;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(captured.usageNumber(1234567), '1,234,567');
    expect(captured.usagePercent(0.42), '42%');
    expect(captured.usageMonthShort(const UsageMonth(2026, 3)), 'Mar');
  });

  testWidgets('formats counts and months', (tester) async {
    late BuildContext captured;
    await tester.pumpApp(
      Builder(
        builder: (context) {
          captured = context;
          return const SizedBox();
        },
      ),
    );
    expect(captured.usageRequests(0), 'No requests');
    expect(captured.usageRequests(1), '1 request');
    expect(captured.usageRequests(1200), '1,200 requests');
    expect(captured.usageCharacters(1), '1 character');
    expect(captured.usageTokens(2), '≈ 2 tokens');
    expect(captured.usageMonthYear(const UsageMonth(2026, 10)), 'October 2026');
  });

  for (final brightness in Brightness.values) {
    testWidgets('level colours in $brightness', (tester) async {
      final theme = ThemeData(useMaterial3: true, brightness: brightness);
      late BuildContext captured;
      await tester.pumpApp(
        Builder(
          builder: (context) {
            captured = context;
            return const SizedBox();
          },
        ),
        theme: theme,
      );
      expect(
        captured.usageLevelColor(UsageBudgetLevel.ok),
        theme.colorScheme.primary,
      );
      expect(
        captured.usageLevelColor(UsageBudgetLevel.limitReached),
        theme.colorScheme.error,
      );
      expect(
        captured.usageLevelColor(UsageBudgetLevel.nearLimit),
        brightness == Brightness.dark
            ? const Color(0xFFFFC870)
            : const Color(0xFF8A5A00),
      );
    });
  }
}
