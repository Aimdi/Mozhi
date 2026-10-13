import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/usage/usage.dart';

import '../../helpers/helpers.dart';

void main() {
  late UsageTracker tracker;
  late DateTime now;

  setUp(() {
    now = DateTime(2026, 10, 15);
    tracker = UsageTracker(store: MemoryStore(), clock: () => now);
  });

  tearDown(() => tracker.dispose());

  Future<void> pumpCard(WidgetTester tester, {VoidCallback? onShowAll}) async {
    await tester.pumpApp(
      Scaffold(
        body: SingleChildScrollView(
          child: UsageCard(
            providerId: 'p',
            tracker: tracker,
            onShowAll: onShowAll,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows this and last month and no budget', (tester) async {
    now = DateTime(2026, 9, 3);
    await tracker.record('p', 400, 0);
    now = DateTime(2026, 10, 15);
    await tracker.record('p', 1000, 234);
    await tracker.record('p', 0, 0);

    await pumpCard(tester);

    expect(find.text('Usage'), findsOneWidget);
    expect(find.text('This month'), findsOneWidget);
    expect(
      find.text('2 requests · 1,234 characters · ≈ 309 tokens'),
      findsOneWidget,
    );
    expect(find.text('1,000 sent · 234 received'), findsOneWidget);
    expect(
      find.text('Last month: 1 request · 400 characters · ≈ 100 tokens'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        'Characters per month: May: 0, Jun: 0, Jul: 0, Aug: 0, Sep: 400, '
        'Oct: 1,234',
      ),
      findsOneWidget,
    );
    expect(find.byType(UsageHistoryChart), findsOneWidget);
    expect(
      find.text('No budget set. Add one to get a warning before a big bill.'),
      findsOneWidget,
    );
    expect(find.text('Set budget'), findsOneWidget);
    expect(find.text('All providers'), findsNothing);
    expect(find.byType(UsageLevelBadge), findsNothing);
  });

  testWidgets('shows an unused provider', (tester) async {
    await pumpCard(tester);
    expect(
      find.text('No requests · 0 characters · ≈ 0 tokens'),
      findsOneWidget,
    );
  });

  testWidgets('shows budget progress and level', (tester) async {
    await tracker.setBudget('p', const UsageBudget(monthlyChars: 1000));
    await tracker.record('p', 857, 0);
    await pumpCard(tester);

    expect(find.text('857 of 1,000 characters · 85%'), findsOneWidget);
    expect(find.text('Near budget'), findsOneWidget);
    expect(find.text('Edit budget'), findsOneWidget);

    await tracker.record('p', 200, 0);
    await tester.pumpAndSettle();
    expect(find.text('Budget reached'), findsOneWidget);
    expect(find.text('1,057 of 1,000 characters · 105%'), findsOneWidget);
  });

  testWidgets('sets a budget through the dialog', (tester) async {
    await tracker.record('p', 100, 0);
    await pumpCard(tester);

    await tester.tap(find.text('Set budget'));
    await tester.pumpAndSettle();
    expect(find.text('Monthly character budget'), findsOneWidget);
    expect(find.text('Remove budget'), findsNothing);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a whole number above 0'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField), '2000');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(
      tracker.snapshot.budgetFor('p'),
      const UsageBudget(monthlyChars: 2000),
    );
    expect(find.text('100 of 2,000 characters · 5%'), findsOneWidget);
    expect(find.text('Edit budget'), findsOneWidget);
  });

  testWidgets('removes a budget through the dialog', (tester) async {
    await tracker.setBudget('p', const UsageBudget(monthlyChars: 500));
    await pumpCard(tester);

    await tester.tap(find.text('Edit budget'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextFormField>(find.byType(TextFormField)).controller?.text,
      '500',
    );
    await tester.tap(find.text('Remove budget'));
    await tester.pumpAndSettle();

    expect(tracker.snapshot.budgetFor('p'), isNull);
    expect(find.text('Set budget'), findsOneWidget);
  });

  testWidgets('cancelling the dialog keeps the budget', (tester) async {
    await tracker.setBudget('p', const UsageBudget(monthlyChars: 500));
    await pumpCard(tester);

    await tester.tap(find.text('Edit budget'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '9');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(
      tracker.snapshot.budgetFor('p'),
      const UsageBudget(monthlyChars: 500),
    );
  });

  testWidgets('submitting the field saves', (tester) async {
    await pumpCard(tester);
    await tester.tap(find.text('Set budget'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '42');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(tracker.snapshot.budgetFor('p')?.monthlyChars, 42);
  });

  testWidgets('shows all providers on request', (tester) async {
    var shown = 0;
    await pumpCard(tester, onShowAll: () => shown++);
    await tester.tap(find.text('All providers'));
    expect(shown, 1);
  });

  testWidgets('reads the tracker from the context', (tester) async {
    await tracker.record('p', 7, 0);
    await tester.pumpApp(
      RepositoryProvider.value(
        value: tracker,
        child: const Scaffold(
          body: SingleChildScrollView(child: UsageCard(providerId: 'p')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('7 characters'), findsOneWidget);
  });

  testWidgets('renders in dark mode', (tester) async {
    await tracker.setBudget('p', const UsageBudget(monthlyChars: 10));
    await tracker.record('p', 9, 0);
    await tester.pumpApp(
      Scaffold(
        body: SingleChildScrollView(
          child: UsageCard(providerId: 'p', tracker: tracker),
        ),
      ),
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
    );
    await tester.pumpAndSettle();
    final badge = tester.widget<Icon>(
      find.descendant(
        of: find.byType(UsageLevelBadge),
        matching: find.byType(Icon),
      ),
    );
    expect(badge.color, const Color(0xFFFFC870));
  });

  testWidgets('UsageLevelBadge is empty when ok', (tester) async {
    await tester.pumpApp(const UsageLevelBadge(level: UsageBudgetLevel.ok));
    expect(find.byType(Text), findsNothing);
  });
}
