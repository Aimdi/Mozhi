import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/usage/usage.dart';

import '../../helpers/helpers.dart';

void main() {
  late UsageTracker tracker;

  // Created inside each test body so its futures live in the test's fake
  // async zone.
  Future<void> setUpTracker() async {
    tracker = UsageTracker(
      store: MemoryStore(),
      clock: () => DateTime(2026, 10, 15),
    );
    addTearDown(tracker.dispose);
    await tracker.setBudget('p', const UsageBudget(monthlyChars: 100));
  }

  testWidgets('shows near-limit and limit warnings', (tester) async {
    await setUpTracker();
    final received = <UsageWarning>[];
    await tester.pumpApp(
      UsageWarningListener(
        tracker: tracker,
        providerName: (id) => id == 'p' ? 'OpenAI' : null,
        onWarning: received.add,
        child: const Scaffold(body: SizedBox()),
      ),
    );

    await tracker.record('p', 87, 0);
    await tester.pumpAndSettle();
    expect(
      find.text('OpenAI has used 87% of its monthly budget'),
      findsOneWidget,
    );

    await tracker.record('p', 20, 0);
    await tester.pumpAndSettle();
    expect(find.text('OpenAI has reached its monthly budget'), findsOneWidget);
    expect(received.map((w) => w.level), [
      UsageBudgetLevel.nearLimit,
      UsageBudgetLevel.limitReached,
    ]);
  });

  testWidgets('falls back to a generic provider name', (tester) async {
    await setUpTracker();
    await tester.pumpApp(
      RepositoryProvider.value(
        value: tracker,
        child: const UsageWarningListener(child: Scaffold(body: SizedBox())),
      ),
    );
    await tracker.record('p', 100, 0);
    await tester.pumpAndSettle();
    expect(
      find.text('Your AI provider has reached its monthly budget'),
      findsOneWidget,
    );
  });

  testWidgets('uses the given messenger', (tester) async {
    await setUpTracker();
    final messengerKey = GlobalKey<ScaffoldMessengerState>();
    await tester.pumpWidget(
      MaterialApp(
        scaffoldMessengerKey: messengerKey,
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => UsageWarningListener(
          tracker: tracker,
          messengerKey: messengerKey,
          child: child!,
        ),
        home: const Scaffold(body: SizedBox()),
      ),
    );
    await tracker.record('p', 100, 0);
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('ignores warnings without a messenger', (tester) async {
    await setUpTracker();
    final received = <UsageWarning>[];
    await tester.pumpWidget(
      Localizations(
        locale: const Locale('en'),
        delegates: appLocalizationsDelegates,
        child: UsageWarningListener(
          tracker: tracker,
          onWarning: received.add,
          child: const SizedBox(),
        ),
      ),
    );
    await tracker.record('p', 100, 0);
    await tester.pump();
    expect(received, hasLength(1));
  });

  testWidgets('switches trackers and stops after dispose', (tester) async {
    await setUpTracker();
    final other = UsageTracker(
      store: MemoryStore(),
      clock: () => DateTime(2026, 10, 15),
    );
    addTearDown(other.dispose);
    await other.setBudget('p', const UsageBudget(monthlyChars: 10));
    final received = <UsageWarning>[];

    Widget build(UsageTracker t) => UsageWarningListener(
      tracker: t,
      onWarning: received.add,
      child: const Scaffold(body: SizedBox()),
    );

    await tester.pumpApp(build(tracker));
    await tester.pumpApp(build(other));
    await tracker.record('p', 100, 0);
    await other.record('p', 10, 0);
    await tester.pumpAndSettle();
    expect(received.map((w) => w.budget.monthlyChars), [10]);

    await tester.pumpApp(const SizedBox());
    await tracker.setBudget('p', const UsageBudget(monthlyChars: 100));
    await other.record('p', 10, 0);
    await tester.pump();
    expect(received, hasLength(1));
  });
}
