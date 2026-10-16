import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/usage/usage.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers/helpers.dart';

class _MockStore extends Mock implements KeyValueStore;

AiProviderConfig _provider(String id, String name) => AiProviderConfig(
  id: id,
  name: name,
  provider: LlmProvider.openAiCompatible,
  baseUrl: 'https://example.com/v1',
  model: 'm',
);

void main() {
  late UsageTracker tracker;
  late DateTime now;

  setUp(() {
    now = DateTime(2026, 10, 15);
    tracker = UsageTracker(store: MemoryStore(), clock: () => now);
  });

  void useTallView(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  tearDown(() => tracker.dispose());

  Future<void> pumpPage(
    WidgetTester tester, {
    List<AiProviderConfig> providers = const [],
    ValueChanged<String>? onOpenProvider,
  }) async {
    await tester.pumpApp(
      UsageSummaryPage(
        providers: providers,
        tracker: tracker,
        onOpenProvider: onOpenProvider,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows an empty state', (tester) async {
    await pumpPage(tester);
    expect(find.text('No AI usage yet'), findsOneWidget);
    expect(find.byTooltip('Reset usage'), findsNothing);
    expect(find.textContaining('Counted on this device only'), findsOneWidget);
  });

  testWidgets('shows a spinner while loading', (tester) async {
    final store = _MockStore();
    final pending = Completer<String?>();
    when(() => store.read(any())).thenAnswer((_) => pending.future);
    final slow = UsageTracker(store: store, clock: () => now);
    await tester.pumpApp(UsageSummaryPage(tracker: slow));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    pending.complete(null);
    await tester.pumpAndSettle();
    expect(find.text('No AI usage yet'), findsOneWidget);
    await slow.dispose();
  });

  testWidgets('lists providers with this and last month', (tester) async {
    now = DateTime(2026, 9, 10);
    await tracker.record('a', 500, 500);
    await tracker.record('gone', 50, 0);
    now = DateTime(2026, 10, 15);
    await tracker.record('a', 200, 300);
    await tracker.record('a', 0, 0);
    await tracker.record('gone', 100, 0);
    await tracker.setBudget('a', const UsageBudget(monthlyChars: 600));
    useTallView(tester);

    await pumpPage(
      tester,
      providers: [_provider('a', 'OpenAI'), _provider('b', 'Ollama')],
    );

    // Totals.
    expect(find.text('October 2026'), findsOneWidget);
    Finder stat(String key, String text) =>
        find.descendant(of: find.byKey(Key(key)), matching: find.text(text));
    expect(stat('usage_total_characters', '600'), findsOneWidget);
    expect(stat('usage_total_characters', 'Characters'), findsOneWidget);
    expect(stat('usage_total_requests', '3'), findsOneWidget);
    expect(stat('usage_total_requests', 'Requests'), findsOneWidget);
    expect(stat('usage_total_tokens', '150'), findsOneWidget);
    expect(stat('usage_total_tokens', 'Est. tokens'), findsOneWidget);
    expect(find.bySemanticsLabel('600\nCharacters'), findsOneWidget);
    expect(
      find.text('Last month: 1,050 characters · 2 requests'),
      findsOneWidget,
    );

    // Configured provider with usage and budget.
    expect(find.text('OpenAI'), findsOneWidget);
    expect(find.text('500 characters'), findsOneWidget);
    expect(find.text('1,000 characters'), findsOneWidget);
    expect(find.text('2 requests · ≈ 125 tokens'), findsOneWidget);
    expect(find.text('500 of 600 characters · 83%'), findsOneWidget);
    expect(find.text('Near budget'), findsOneWidget);

    // Configured provider without usage.
    expect(find.text('Ollama'), findsOneWidget);
    expect(find.text('Not used yet'), findsOneWidget);

    // Usage of a deleted provider.
    expect(find.text('Removed provider'), findsOneWidget);

    // Bars are scaled to the largest value (1,000 characters).
    final bars = tester.widgetList<UsageBar>(find.byType(UsageBar)).toList();
    expect(
      bars.map((b) => b.fraction),
      containsAll(<double>[0.5, 1, 0.1, 0.05]),
    );
  });

  testWidgets('opens configured providers only', (tester) async {
    await tracker.record('a', 1, 1);
    await tracker.record('gone', 1, 1);
    useTallView(tester);
    final opened = <String>[];
    await pumpPage(
      tester,
      providers: [_provider('a', 'OpenAI')],
      onOpenProvider: opened.add,
    );

    await tester.tap(find.text('OpenAI'));
    await tester.tap(find.text('Removed provider'));
    expect(opened, ['a']);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
  });

  testWidgets('resets usage after confirmation', (tester) async {
    await tracker.record('a', 10, 10);
    await pumpPage(tester, providers: [_provider('a', 'OpenAI')]);

    await tester.tap(find.byTooltip('Reset usage'));
    await tester.pumpAndSettle();
    expect(find.text('Reset usage?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tracker.snapshot.isEmpty, isFalse);

    await tester.tap(find.byTooltip('Reset usage'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();
    expect(tracker.snapshot.isEmpty, isTrue);
    expect(find.text('Not used yet'), findsOneWidget);
    expect(find.byTooltip('Reset usage'), findsNothing);
  });

  testWidgets('reads the tracker from the context', (tester) async {
    await tracker.record('x', 3, 0);
    await tester.pumpApp(
      RepositoryProvider.value(value: tracker, child: const UsageSummaryPage()),
    );
    await tester.pumpAndSettle();
    expect(find.text('Removed provider'), findsOneWidget);
  });

  testWidgets('fits a wide screen', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tracker.record('a', 10, 10);
    await pumpPage(tester, providers: [_provider('a', 'OpenAI')]);
    final listView = tester.widget<ListView>(find.byType(ListView));
    expect(listView.padding, const EdgeInsets.fromLTRB(424, 8, 424, 32));
  });
}
