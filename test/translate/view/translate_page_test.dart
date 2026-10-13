import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

void main() {
  setUpAll(registerTranslateFallbacks);

  group('TranslatePage', () {
    testWidgets('builds TranslateView', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const TranslatePage());
      expect(find.byType(TranslateView), findsOneWidget);
    });
  });

  group('TranslateView', () {
    testWidgets('shows a skeleton while engines load', (tester) async {
      final harness = TranslateHarness(
        state: const TranslateState(enginesStatus: EnginesStatus.loading),
      );
      await harness.pump(tester);
      expect(find.byType(TranslateSkeleton), findsOneWidget);
      expect(find.byType(InputCard), findsNothing);
    });

    testWidgets('shows the empty state when no engine is available', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: const TranslateState(enginesStatus: EnginesStatus.failure),
      );
      await harness.pump(tester);
      expect(find.byType(NoEnginesView), findsOneWidget);
      expect(find.text('No translation engines available'), findsOneWidget);

      await tester.tap(find.text('Add AI provider'));
      verify(() => harness.router.go('/settings/providers')).called(1);

      await tester.tap(find.text('Manage instances'));
      verify(() => harness.router.go('/settings/instances')).called(1);

      await tester.tap(find.text('Retry'));
      verify(() => harness.translate.loadEngines(refresh: true)).called(1);
    });

    testWidgets('uses a single column on phones', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, size: const Size(400, 800));
      expect(find.byKey(const Key('translate_narrow_layout')), findsOneWidget);
      expect(find.byKey(const Key('translate_wide_layout')), findsNothing);
      final input = tester.getRect(find.byType(InputCard));
      final output = tester.getRect(find.byType(OutputCard));
      expect(output.top, greaterThan(input.bottom));
    });

    testWidgets('shows input and output side by side on wide screens', (
      tester,
    ) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, size: const Size(1200, 800));
      expect(find.byKey(const Key('translate_wide_layout')), findsOneWidget);
      expect(find.byKey(const Key('translate_input_pane')), findsOneWidget);
      expect(find.byKey(const Key('translate_output_pane')), findsOneWidget);
      final input = tester.getRect(find.byType(InputCard));
      final output = tester.getRect(find.byType(OutputCard));
      expect(output.left, greaterThan(input.right));
      expect(output.top, closeTo(input.top, 1));
      // The page title is shown next to the engine selector.
      expect(find.text('Translate'), findsWidgets);
    });

    testWidgets('does not overflow at 320 dp with large text', (tester) async {
      final harness = TranslateHarness(
        state: translatedState(engine: claude).copyWith(
          options: const TranslationOptions(style: TranslationStyle.literal),
        ),
      );
      final errors = <String>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (details) => errors.add(details.toString());
      addTearDown(() => FlutterError.onError = previous);
      await harness.pump(tester, size: const Size(320, 640), textScale: 2);
      await tester.pump();
      // Scroll through the whole page so every section lays out.
      await tester.drag(
        find.byKey(const Key('translate_narrow_layout')),
        const Offset(0, -2000),
      );
      await tester.pump();
      FlutterError.onError = previous;
      expect(errors, isEmpty);
      expect(find.byType(OutputCard), findsOneWidget);
    });

    testWidgets('renders in dark mode', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, themeMode: ThemeMode.dark);
      expect(tester.takeException(), isNull);
      final context = tester.element(find.byType(OutputCard));
      expect(Theme.of(context).brightness, Brightness.dark);
    });

    testWidgets('compare toggle enables compare mode', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester);
      await tester.tap(find.byKey(const Key('translate_compare_toggle')));
      verify(() => harness.translate.setCompareMode(enabled: true)).called(1);
    });

    testWidgets('compare mode replaces the output card', (tester) async {
      final harness = TranslateHarness(
        state: translatedState().copyWith(compareMode: true),
      );
      await harness.pump(tester);
      expect(find.byType(ComparePanel), findsOneWidget);
      expect(find.byType(OutputCard), findsNothing);
      await tester.tap(find.byKey(const Key('translate_compare_toggle')));
      verify(() => harness.translate.setCompareMode(enabled: false)).called(1);
    });

    testWidgets('options button is hidden for Mozhi engines', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester);
      expect(find.byKey(const Key('translate_options_button')), findsNothing);
    });

    testWidgets('options button is shown for AI engines', (tester) async {
      final harness = TranslateHarness(state: translatedState(engine: claude));
      await harness.pump(tester);
      expect(find.byKey(const Key('translate_options_button')), findsOneWidget);
      expect(find.byTooltip('Translation options'), findsOneWidget);
    });

    testWidgets('options button shows a badge when options are modified', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: translatedState(engine: claude).copyWith(
          options: const TranslationOptions(formality: Formality.more),
        ),
      );
      await harness.pump(tester);
      expect(find.byTooltip('Translation options (modified)'), findsOneWidget);
      final badge = tester.widget<Badge>(
        find.descendant(
          of: find.byKey(const Key('translate_options_button')),
          matching: find.byType(Badge),
        ),
      );
      expect(badge.isLabelVisible, isTrue);
    });

    group('keyboard shortcuts', () {
      testWidgets('Ctrl+Enter translates', (tester) async {
        final harness = TranslateHarness(state: translatedState());
        await harness.pump(tester);
        await tester.tap(find.byKey(const Key('translate_input_field')));
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        verify(harness.translate.translate).called(1);
      });

      testWidgets('Cmd+Enter runs compare in compare mode', (tester) async {
        final harness = TranslateHarness(
          state: translatedState().copyWith(compareMode: true),
        );
        await harness.pump(tester);
        await tester.tap(find.byKey(const Key('translate_input_field')));
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        verify(harness.translate.runCompare).called(1);
        verifyNever(harness.translate.translate);
      });

      testWidgets('Ctrl+Enter does nothing without input', (tester) async {
        final harness = TranslateHarness();
        await harness.pump(tester);
        await tester.tap(find.byKey(const Key('translate_input_field')));
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        verifyNever(harness.translate.translate);
      });

      testWidgets('Ctrl+Shift+S swaps languages', (tester) async {
        final harness = TranslateHarness(state: translatedState());
        await harness.pump(tester);
        await tester.tap(find.byKey(const Key('translate_input_field')));
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        verify(harness.translate.swap).called(1);
      });

      testWidgets('Ctrl+Shift+S does not swap into a custom source', (
        tester,
      ) async {
        final harness = TranslateHarness(
          state: readyState(
            engine: claude,
            input: 'Hi',
            target: const Language.custom('Pirate speak'),
          ),
        );
        await harness.pump(tester);
        await tester.tap(find.byKey(const Key('translate_input_field')));
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        verifyNever(harness.translate.swap);
      });
    });

    testWidgets('switches from skeleton to content when engines load', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: const TranslateState(enginesStatus: EnginesStatus.loading),
      );
      whenListen(
        harness.translate,
        Stream.fromIterable([readyState()]),
        initialState: const TranslateState(
          enginesStatus: EnginesStatus.loading,
        ),
      );
      await harness.pump(tester);
      await tester.pump();
      expect(find.byType(InputCard), findsOneWidget);
      expect(find.byType(TranslateSkeleton), findsNothing);
    });
  });
}
