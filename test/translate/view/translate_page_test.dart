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
      verify(() => harness.router.push<void>('/settings/providers')).called(1);

      await tester.tap(find.text('Manage instances'));
      verify(() => harness.router.push<void>('/settings/instances')).called(1);

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

    group('empty screen', () {
      setUp(() => TranslateHero.clock = () => DateTime(2026, 10, 20, 9));
      tearDown(() => TranslateHero.clock = DateTime.now);

      Finder hero() => find.byKey(const Key('translate_hero'));
      Finder field() => find.byKey(const Key('translate_input_field'));
      Finder toolbar() => find.byKey(const Key('translate_input_toolbar'));
      Finder composer() => find.byKey(const Key('translate_composer'));

      /// Whether the input thread's avatar shows.
      bool avatarShown(WidgetTester tester) => tester
          .widget<TranslateThreadRow>(
            find.byKey(const Key('translate_input_thread')),
          )
          .showAvatar;

      testWidgets('greets, with the composer docked at the bottom', (
        tester,
      ) async {
        final harness = TranslateHarness();
        await harness.pump(tester, size: const Size(400, 800));
        expect(hero(), findsOneWidget);
        expect(find.text('Good morning'), findsOneWidget);
        // The card (with its 12 dp margin) holds the field and the
        // language bar, at the bottom.
        final card = tester.getRect(composer());
        expect(card.bottom, 800);
        expect(
          tester.getRect(find.byType(LanguageBar)).bottom,
          closeTo(800 - 12 - 1 - 6, 1),
        );
        expect(tester.getRect(hero()).bottom, lessThanOrEqualTo(card.top));
        for (final part in [field(), find.byType(LanguageBar)]) {
          final rect = tester.getRect(part);
          expect(card.contains(rect.topLeft), isTrue);
          expect(card.contains(rect.bottomRight - const Offset(1, 1)), isTrue);
        }
        final decoration =
            tester.widget<AnimatedContainer>(composer()).decoration!
                as BoxDecoration;
        expect(decoration.border, isNotNull);
        // No avatar and no tools row yet; paste sits at the top end.
        expect(avatarShown(tester), isFalse);
        expect(toolbar(), findsNothing);
        expect(find.byKey(const Key('translate_paste_button')), findsOneWidget);
        expect(
          tester.getCenter(find.byKey(const Key('translate_paste_button'))).dx,
          greaterThan(tester.getCenter(field()).dx),
        );
      });

      testWidgets('turns into the thread when the field gets the focus, '
          'keeping the field', (tester) async {
        final harness = TranslateHarness();
        await harness.pump(tester, size: const Size(400, 800));
        final editable = tester.state<EditableTextState>(
          find.byType(EditableText),
        );
        await tester.tap(field());
        await tester.pumpAndSettle();
        expect(hero(), findsNothing);
        expect(avatarShown(tester), isTrue);
        expect(toolbar(), findsOneWidget);
        // The same field, still focused (the keyboard stays up).
        expect(
          tester.state<EditableTextState>(find.byType(EditableText)),
          same(editable),
        );
        expect(editable.widget.focusNode.hasFocus, isTrue);
        // The card's outline is gone; the bar docks at the bottom.
        final decoration =
            tester.widget<AnimatedContainer>(composer()).decoration!
                as BoxDecoration;
        expect((decoration.border! as Border).top, BorderSide.none);
        expect(
          tester.getRect(find.byType(LanguageBar)).bottom,
          closeTo(800 - 8, 1),
        );
        expect(tester.getRect(field()).top, lessThan(120));

        // Leaving the empty field brings the greeting back.
        editable.widget.focusNode.unfocus();
        await tester.pumpAndSettle();
        expect(hero(), findsOneWidget);
        expect(
          tester.state<EditableTextState>(find.byType(EditableText)),
          same(editable),
        );
      });

      testWidgets('tapping the card around the field focuses it', (
        tester,
      ) async {
        final harness = TranslateHarness();
        await harness.pump(tester, size: const Size(400, 800));
        final card = tester.getRect(composer());
        // Between the field and the bar.
        await tester.tapAt(
          Offset(
            card.center.dx,
            tester.getRect(find.byType(LanguageBar)).top - 2,
          ),
        );
        await tester.pumpAndSettle();
        expect(hero(), findsNothing);
        expect(
          tester
              .state<EditableTextState>(find.byType(EditableText))
              .widget
              .focusNode
              .hasFocus,
          isTrue,
        );
      });

      testWidgets('a sheet over the focused field keeps the layout', (
        tester,
      ) async {
        final harness = TranslateHarness();
        await harness.pump(tester, size: const Size(400, 800));
        await tester.tap(field());
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('translate_options_button')));
        await tester.pumpAndSettle();
        expect(find.byType(TranslationOptionsSheet), findsOneWidget);
        expect(hero(), findsNothing);
        await tester.tap(find.byKey(const Key('translate_options_done')));
        await tester.pumpAndSettle();
        expect(hero(), findsNothing);
      });

      testWidgets('is not shown with input, in compare mode or for errors', (
        tester,
      ) async {
        for (final state in [
          readyState(input: 'Hi'),
          readyState().copyWith(compareMode: true),
          readyState().copyWith(
            status: TranslateStatus.failure,
            error: () => Exception('x'),
          ),
        ]) {
          final harness = TranslateHarness(state: state);
          await harness.pump(tester, size: const Size(400, 800));
          expect(hero(), findsNothing, reason: '$state');
        }
      });

      testWidgets('is skipped in a low window', (tester) async {
        final harness = TranslateHarness();
        await harness.pump(tester, size: const Size(700, 380));
        expect(hero(), findsNothing);
        expect(avatarShown(tester), isTrue);
        expect(tester.takeException(), isNull);
      });

      testWidgets('centres the composer under the greeting on large screens', (
        tester,
      ) async {
        final harness = TranslateHarness();
        await harness.pump(tester, size: const Size(1280, 800));
        expect(hero(), findsOneWidget);
        final card = tester.getRect(composer());
        expect(card.center.dx, closeTo(640, 1));
        // At most 760 dp, plus its 24 dp margins.
        expect(card.width, lessThanOrEqualTo(760 + 48));
        expect(tester.getRect(hero()).bottom, lessThanOrEqualTo(card.top));
        // The output pane opens once the field has the focus.
        expect(find.byKey(const Key('translate_output_pane')), findsNothing);
        await tester.tap(field());
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('translate_output_pane')), findsOneWidget);
      });

      testWidgets('moves without motion with reduced motion', (tester) async {
        final harness = TranslateHarness();
        await harness.pump(
          tester,
          size: const Size(400, 800),
          disableAnimations: true,
        );
        expect(
          tester.widget<AnimatedContainer>(composer()).duration,
          Duration.zero,
        );
      });
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

    testWidgets('input actions fit at 320 dp with large text', (tester) async {
      final harness = TranslateHarness(
        state: translatedState(
          engine: claude,
          input: 'word ' * 120,
        ).copyWith(inputTruncated: true),
        speechInput: FakeSpeechInput().service,
      );
      final errors = <String>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (details) => errors.add(details.toString());
      addTearDown(() => FlutterError.onError = previous);
      await harness.pump(tester, size: const Size(320, 640), textScale: 2);
      await tester.pump();
      FlutterError.onError = previous;
      expect(errors, isEmpty);
      for (final key in [
        'translate_voice_input',
        'translate_image_button',
        'translate_character_count',
        'translate_token_estimate',
        'translate_input_truncated',
      ]) {
        expect(find.byKey(Key(key)), findsOneWidget, reason: key);
      }
    });

    testWidgets('renders in dark mode', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, themeMode: ThemeMode.dark);
      expect(tester.takeException(), isNull);
      final context = tester.element(find.byType(OutputCard));
      expect(Theme.of(context).brightness, Brightness.dark);
    });

    testWidgets('"Compare engines" in the More area enables compare mode', (
      tester,
    ) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester);
      // Not in the app bar: one task per screen.
      expect(find.byKey(const Key('translate_compare_toggle')), findsNothing);
      await openMore(tester);
      await tester.tap(find.byKey(const Key('translate_compare_toggle')));
      verify(() => harness.translate.setCompareMode(enabled: true)).called(1);
    });

    testWidgets('the More tools menu turns compare mode on before a '
        'translation', (tester) async {
      final harness = TranslateHarness(state: readyState(input: 'Hello'));
      await harness.pump(tester);
      await tester.tap(find.byKey(const Key('translate_more_tools')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Compare engines'));
      await tester.pumpAndSettle();
      verify(() => harness.translate.setCompareMode(enabled: true)).called(1);
    });

    testWidgets('the More tools menu leaves compare mode', (tester) async {
      final harness = TranslateHarness(
        state: translatedState().copyWith(compareMode: true),
      );
      await harness.pump(tester);
      await tester.tap(find.byKey(const Key('translate_more_tools')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Exit compare mode'));
      await tester.pumpAndSettle();
      verify(() => harness.translate.setCompareMode(enabled: false)).called(1);
    });

    testWidgets('compare is not offered with a single engine', (tester) async {
      final harness = TranslateHarness(
        state: translatedState().copyWith(engines: const [deepl]),
      );
      await harness.pump(tester);
      await openMore(tester);
      expect(find.byKey(const Key('translate_compare_toggle')), findsNothing);
      await tester.tap(find.byKey(const Key('translate_more_tools')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('translate_tool_compare')),
        findsNothing,
      );
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

    testWidgets('options and go buttons are in the language bar for every '
        'engine', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester);
      final bar = find.byKey(const Key('translate_language_bar'));
      for (final key in [
        'translate_options_button',
        'translate_translate_button',
      ]) {
        expect(
          find.descendant(of: bar, matching: find.byKey(Key(key))),
          findsOneWidget,
        );
        // Not in the app bar any more.
        expect(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.byKey(Key(key)),
          ),
          findsNothing,
        );
      }
    });

    testWidgets('the go button translates right away', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester);
      await tester.tap(find.byKey(const Key('translate_translate_button')));
      verify(harness.translate.translate).called(1);
    });

    testWidgets('the language bar spans both panes on wide screens', (
      tester,
    ) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, size: const Size(1200, 800));
      final bar = tester.getRect(
        find.byKey(const Key('translate_language_bar')),
      );
      final input = tester.getRect(
        find.byKey(const Key('translate_input_pane')),
      );
      final output = tester.getRect(
        find.byKey(const Key('translate_output_pane')),
      );
      expect(bar.left, closeTo(input.left, 1));
      expect(bar.right, closeTo(output.right, 1));
      // The swap button sits over the line between the panes.
      final swap = tester.getCenter(
        find.byKey(const Key('translate_swap_button')),
      );
      expect(swap.dx, closeTo((input.right + output.left) / 2, 2));
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
