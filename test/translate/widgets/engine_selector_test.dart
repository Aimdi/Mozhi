import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';

import '../helpers/helpers.dart';

void main() {
  setUpAll(registerTranslateFallbacks);

  group('EngineSelectorButton', () {
    testWidgets('shows the current engine', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const EngineSelectorButton());
      expect(find.text('DeepL'), findsOneWidget);
      expect(find.text('mozhi.example.org'), findsOneWidget);
      expect(find.byTooltip('Choose translation engine'), findsOneWidget);
    });

    testWidgets('is disabled without engines', (tester) async {
      final harness = TranslateHarness(
        state: const TranslateState(enginesStatus: EnginesStatus.loading),
      );
      await harness.pump(tester, child: const EngineSelectorButton());
      expect(find.text('Translation engine'), findsOneWidget);
      final button = tester.widget<TextButton>(
        find.byKey(const Key('translate_engine_selector')),
      );
      expect(button.onPressed, isNull);
    });
  });

  group('EngineSheet', () {
    Future<TranslateHarness> open(WidgetTester tester) async {
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        child: const EngineSelectorButton(),
        size: const Size(800, 1200),
      );
      await tester.tap(find.byKey(const Key('translate_engine_selector')));
      await tester.pumpAndSettle();
      return harness;
    }

    testWidgets('groups engines with privacy badges', (tester) async {
      await open(tester);
      expect(
        find.text('Mozhi engines (via mozhi.example.org)'),
        findsOneWidget,
      );
      expect(find.text('AI models'), findsOneWidget);
      expect(find.text('Self-hosted'), findsNWidgets(2));
      expect(find.text('Cloud'), findsOneWidget);
      expect(find.text('Local'), findsOneWidget);
      expect(find.text('claude-opus-5-5'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    testWidgets('selecting an engine calls selectEngine', (tester) async {
      final harness = await open(tester);
      await tester.tap(find.text('Claude'));
      await tester.pumpAndSettle();
      verify(() => harness.translate.selectEngine(claude)).called(1);
      expect(find.text('AI models'), findsNothing);
    });

    testWidgets('selecting the current engine just closes', (tester) async {
      final harness = await open(tester);
      await tester.tap(find.text('DeepL').last);
      await tester.pumpAndSettle();
      verifyNever(() => harness.translate.selectEngine(any()));
    });

    testWidgets('"Add AI provider" opens provider settings', (tester) async {
      final harness = await open(tester);
      await tester.tap(find.text('Add AI provider'));
      await tester.pumpAndSettle();
      verify(() => harness.router.go('/settings/providers')).called(1);
    });

    testWidgets('"Manage instances" opens instance settings', (tester) async {
      final harness = await open(tester);
      await tester.tap(find.text('Manage instances'));
      await tester.pumpAndSettle();
      verify(() => harness.router.go('/settings/instances')).called(1);
    });
  });
}
