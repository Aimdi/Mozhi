import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/widgets/composer_card.dart';
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
      Finder link() => find.byKey(const Key('translate_paste_link'));

      /// The composer card's box (its outline, fill and motion).
      AnimatedContainer cardBox(WidgetTester tester) =>
          tester.widget<AnimatedContainer>(
            find
                .descendant(
                  of: composer(),
                  matching: find.byType(AnimatedContainer),
                )
                .first,
          );

      bool fieldFocused(WidgetTester tester) => tester
          .state<EditableTextState>(find.byType(EditableText))
          .widget
          .focusNode
          .hasFocus;

      /// The screen's Back handling.
      PopScope<Object?> popScope(WidgetTester tester) =>
          tester.widget<PopScope<Object?>>(
            find.byWidgetPredicate((widget) => widget is PopScope<Object?>),
          );

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
        expect(tester.widget<ComposerCard>(composer()).outlined, isTrue);
        final decoration = cardBox(tester).decoration! as BoxDecoration;
        expect(decoration.border, isNotNull);
        // No avatar and no tools row yet; the placeholder's "paste" link
        // pastes (no separate paste icon).
        expect(avatarShown(tester), isFalse);
        expect(toolbar(), findsNothing);
        expect(find.byKey(const Key('translate_paste_button')), findsNothing);
        expect(link(), findsOneWidget);
        expect(
          tester.getRect(field()).contains(tester.getCenter(link())),
          isTrue,
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
        expect(tester.widget<ComposerCard>(composer()).outlined, isFalse);
        final decoration = cardBox(tester).decoration! as BoxDecoration;
        expect((decoration.border! as Border).top, BorderSide.none);
        // The field's own hint replaces the placeholder with the link.
        expect(link(), findsNothing);
        expect(find.text('Enter text'), findsOneWidget);
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
        // The language picker takes the focus (its shortcut: a tap on a
        // button outside the empty field would take the focus itself).
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(find.byType(LanguagePickerSheet), findsOneWidget);
        expect(hero(), findsNothing);
        await tester.tap(find.byTooltip('Close'));
        await tester.pumpAndSettle();
        expect(hero(), findsNothing);
      });

      testWidgets('Back first takes the focus from the empty field', (
        tester,
      ) async {
        final harness = TranslateHarness();
        await harness.pump(tester, size: const Size(400, 800));
        await tester.tap(field());
        await tester.pumpAndSettle();
        expect(hero(), findsNothing);
        expect(popScope(tester).canPop, isFalse);
        final handled = await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(handled, isTrue);
        expect(fieldFocused(tester), isFalse);
        expect(hero(), findsOneWidget);
        // Now Back leaves the screen.
        expect(popScope(tester).canPop, isTrue);
      });

      testWidgets('Back leaves the screen with text in the field', (
        tester,
      ) async {
        final harness = TranslateHarness(state: readyState(input: 'Hi'));
        await harness.pump(tester, size: const Size(400, 800));
        await tester.tap(field());
        await tester.pumpAndSettle();
        expect(popScope(tester).canPop, isTrue);
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

      group('large screens', () {
        Finder inputPane() => find.byKey(const Key('translate_input_pane'));
        Finder outputPane() => find.byKey(const Key('translate_output_pane'));
        Finder header() => find.byKey(const Key('translate_language_header'));
        Finder placeholder() =>
            find.byKey(const Key('translate_output_placeholder'));

        /// Where the panes, the languages and the field are.
        List<Rect> layout(WidgetTester tester) => [
          tester.getRect(inputPane()),
          tester.getRect(outputPane()),
          tester.getRect(header()),
          tester.getRect(find.byKey(const Key('translate_source_button'))),
          tester.getRect(find.byKey(const Key('translate_target_button'))),
          tester.getRect(field()),
        ];

        testWidgets('show two panes with the languages above them from the '
            'first frame', (tester) async {
          final harness = TranslateHarness();
          await harness.pump(tester, size: const Size(1280, 800));
          expect(
            find.byKey(const Key('translate_wide_layout')),
            findsOneWidget,
          );
          final input = tester.getRect(inputPane());
          final output = tester.getRect(outputPane());
          expect(output.left, greaterThan(input.right));
          expect(output.top, input.top);
          expect(input.width, closeTo(output.width, 1));
          // The source above the input pane, the target above the output
          // pane, the swap button over the line between them.
          final languages = tester.getRect(header());
          expect(languages.bottom, lessThanOrEqualTo(input.top));
          final source = tester.getRect(
            find.byKey(const Key('translate_source_button')),
          );
          final target = tester.getRect(
            find.byKey(const Key('translate_target_button')),
          );
          expect(source.left, closeTo(input.left, 1));
          expect(target.left, greaterThanOrEqualTo(output.left - 1));
          expect(target.left, lessThan(output.left + 24));
          final swap = tester.getCenter(
            find.byKey(const Key('translate_swap_button')),
          );
          expect(swap.dx, closeTo((input.right + output.left) / 2, 2));
          // No bottom bar: the options and go buttons are under the input
          // pane.
          expect(find.byType(LanguageBar), findsNothing);
          final footer = tester.getRect(
            find.byKey(const Key('translate_pane_footer')),
          );
          expect(footer.top, greaterThanOrEqualTo(input.bottom));
          for (final key in [
            'translate_options_button',
            'translate_translate_button',
          ]) {
            final button = tester.getRect(find.byKey(Key(key)));
            expect(footer.contains(button.center), isTrue, reason: key);
          }
          // The greeting is the empty input pane's placeholder, without
          // an avatar; the output pane says where the translation goes.
          expect(hero(), findsOneWidget);
          final greeting = tester.getRect(hero());
          expect(greeting.left, greaterThanOrEqualTo(input.left));
          expect(greeting.right, lessThanOrEqualTo(input.right));
          expect(greeting.top, greaterThan(tester.getRect(field()).top));
          expect(avatarShown(tester), isFalse);
          expect(link(), findsOneWidget);
          expect(placeholder(), findsOneWidget);
          expect(find.text('Translation'), findsOneWidget);
          expect(tester.takeException(), isNull);
        });

        testWidgets('focusing the field moves nothing', (tester) async {
          final harness = TranslateHarness();
          await harness.pump(tester, size: const Size(1280, 800));
          final before = layout(tester);
          await tester.tap(field());
          await tester.pumpAndSettle();
          expect(fieldFocused(tester), isTrue);
          expect(layout(tester), before);
          // The greeting stays until there is text.
          expect(hero(), findsOneWidget);
          expect(avatarShown(tester), isFalse);
        });

        testWidgets('show the input and the translation without avatars', (
          tester,
        ) async {
          final harness = TranslateHarness(state: translatedState());
          await harness.pump(tester, size: const Size(1280, 800));
          expect(hero(), findsNothing);
          expect(placeholder(), findsNothing);
          expect(avatarShown(tester), isFalse);
          expect(
            find.byKey(const Key('translate_output_thread')),
            findsNothing,
          );
          expect(find.text('Bonjour le monde'), findsOneWidget);
          final output = tester.getRect(find.byType(OutputCard));
          expect(output.left, greaterThan(tester.getRect(inputPane()).right));
        });

        testWidgets('keep the quality toggle in the app bar', (tester) async {
          final harness = TranslateHarness(
            state: readyState(engine: google).copyWith(
              qualityMode: QualityMode.fast,
              fastEngine: () => google,
              bestEngine: () => claude,
            ),
          );
          await harness.pump(tester, size: const Size(1280, 800));
          // From the first frame on.
          expect(
            find.descendant(
              of: find.byType(AppBar),
              matching: find.byKey(const Key('translate_quality_toggle')),
            ),
            findsOneWidget,
          );
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('translate_quality_chip')), findsNothing);
          expect(hero(), findsOneWidget);
        });

        testWidgets('fit a low window', (tester) async {
          final harness = TranslateHarness();
          await harness.pump(tester, size: const Size(900, 420));
          expect(tester.takeException(), isNull);
          expect(
            find.byKey(const Key('translate_wide_layout')),
            findsOneWidget,
          );
        });

        testWidgets('show compare mode in the output pane', (tester) async {
          final harness = TranslateHarness(
            state: translatedState().copyWith(compareMode: true),
          );
          await harness.pump(tester, size: const Size(1280, 800));
          expect(
            find.descendant(
              of: outputPane(),
              matching: find.byType(ComparePanel),
            ),
            findsOneWidget,
          );
          expect(placeholder(), findsNothing);
        });

        testWidgets('the picker drops down under the target button', (
          tester,
        ) async {
          final harness = TranslateHarness();
          await harness.pump(tester, size: const Size(1280, 800));
          final target = tester.getRect(
            find.byKey(const Key('translate_target_button')),
          );
          await tester.tap(find.byKey(const Key('translate_target_button')));
          await tester.pumpAndSettle();
          final dropdown = find.byKey(const Key('translate_language_dropdown'));
          expect(dropdown, findsOneWidget);
          final panel = tester.getRect(dropdown);
          expect(panel.top, closeTo(target.bottom + 4, 1));
          // Languages in columns, the search field ready to type.
          expect(find.byType(SliverGrid), findsWidgets);
          final search = tester.widget<EditableText>(
            find.descendant(
              of: find.byKey(const Key('translate_language_search')),
              matching: find.byType(EditableText),
            ),
          );
          expect(search.focusNode.hasFocus, isTrue);
          await tester.tap(
            find.descendant(of: dropdown, matching: find.text('German')),
          );
          await tester.pumpAndSettle();
          verify(() => harness.translate.setTarget(german)).called(1);
          expect(dropdown, findsNothing);
        });

        testWidgets('the shortcut drops the source picker down under its '
            'button', (tester) async {
          final harness = TranslateHarness();
          await harness.pump(tester, size: const Size(1280, 800));
          final source = tester.getRect(
            find.byKey(const Key('translate_source_button')),
          );
          await tester.tap(field());
          await tester.pump();
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pumpAndSettle();
          final panel = tester.getRect(
            find.byKey(const Key('translate_language_dropdown')),
          );
          expect(panel.left, closeTo(source.left, 1));
          expect(panel.top, closeTo(source.bottom + 4, 1));
          expect(find.text('Translate from'), findsOneWidget);
          // Esc closes it.
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(find.text('Translate from'), findsNothing);
          verifyNever(() => harness.translate.setSource(any()));
        });
      });

      testWidgets('moves without motion with reduced motion', (tester) async {
        final harness = TranslateHarness();
        await harness.pump(
          tester,
          size: const Size(400, 800),
          disableAnimations: true,
        );
        expect(cardBox(tester).duration, Duration.zero);
      });

      testWidgets('the placeholder link pastes the clipboard', (tester) async {
        FakeClipboard(tester, pasteText: 'Guten Tag');
        final harness = TranslateHarness();
        await harness.pump(tester, size: const Size(400, 800));
        await tester.tap(link());
        await tester.pump();
        verify(
          () => harness.translate.setInput(
            'Guten Tag',
            pasted: any(named: 'pasted'),
            dictated: any(named: 'dictated'),
          ),
        ).called(1);
        // A tap pastes without opening the keyboard.
        expect(fieldFocused(tester), isFalse);
      });

      testWidgets('taps on the placeholder beside the link focus the field', (
        tester,
      ) async {
        FakeClipboard(tester, pasteText: 'Guten Tag');
        final harness = TranslateHarness();
        await harness.pump(tester, size: const Size(400, 800));
        final hint = tester.getRect(
          find.byKey(const Key('translate_composer_hint')),
        );
        // On "Type", at the start of the first line.
        await tester.tapAt(hint.topLeft + const Offset(8, 26));
        await tester.pumpAndSettle();
        verifyNever(
          () => harness.translate.setInput(
            any(),
            pasted: any(named: 'pasted'),
            dictated: any(named: 'dictated'),
          ),
        );
        expect(hero(), findsNothing);
        expect(fieldFocused(tester), isTrue);
      });

      group('quality modes', () {
        TranslateHarness qualityHarness({String input = ''}) {
          final harness = TranslateHarness(
            state: readyState(engine: google, input: input).copyWith(
              qualityMode: QualityMode.fast,
              fastEngine: () => google,
              bestEngine: () => claude,
            ),
          );
          when(() => harness.translate.setQualityMode(any()))
              .thenAnswer((_) async {});
          return harness;
        }

        Finder chip() => find.byKey(const Key('translate_quality_chip'));

        /// The quality toggle of the app bar, in any of its layouts.
        Finder appBarToggle() => find.descendant(
          of: find.byType(AppBar),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget.key == const Key('translate_quality_toggle') ||
                widget.key == const Key('translate_quality_menu'),
          ),
        );

        setUpAll(() => registerFallbackValue(QualityMode.off));

        testWidgets('the greeting holds the chip, not the app bar', (
          tester,
        ) async {
          final harness = qualityHarness();
          await harness.pump(tester, size: const Size(400, 800));
          await tester.pump();
          expect(chip(), findsOneWidget);
          expect(appBarToggle(), findsNothing);
          expect(
            tester.getRect(chip()).bottom,
            lessThan(tester.getRect(find.text('Good morning')).top),
          );

          // Active: the toggle is back in the app bar.
          await tester.tap(field());
          await tester.pumpAndSettle();
          expect(chip(), findsNothing);
          expect(appBarToggle(), findsOneWidget);

          // Empty again: back in the greeting.
          tester
              .state<EditableTextState>(find.byType(EditableText))
              .widget
              .focusNode
              .unfocus();
          await tester.pumpAndSettle();
          expect(chip(), findsOneWidget);
          expect(appBarToggle(), findsNothing);
        });

        testWidgets('the toggle stays in the app bar with input', (
          tester,
        ) async {
          final harness = qualityHarness(input: 'Hello');
          await harness.pump(tester, size: const Size(400, 800));
          // From the first frame on.
          expect(appBarToggle(), findsOneWidget);
          await tester.pumpAndSettle();
          expect(appBarToggle(), findsOneWidget);
          expect(chip(), findsNothing);
        });

        testWidgets('a low window keeps the toggle in the app bar', (
          tester,
        ) async {
          final harness = qualityHarness();
          await harness.pump(tester, size: const Size(700, 411));
          await tester.pumpAndSettle();
          expect(hero(), findsNothing);
          expect(chip(), findsNothing);
          expect(appBarToggle(), findsOneWidget);
          expect(tester.takeException(), isNull);
        });

        testWidgets('a greeting without room for the chip leaves the toggle '
            'in the app bar', (tester) async {
          final harness = qualityHarness();
          await harness.pump(
            tester,
            size: const Size(320, 568),
            textScale: 1.3,
          );
          await tester.pumpAndSettle();
          expect(hero(), findsOneWidget);
          expect(chip(), findsNothing);
          expect(appBarToggle(), findsOneWidget);
          expect(tester.takeException(), isNull);
        });

        testWidgets('the engine choice keeps the toggle in the app bar', (
          tester,
        ) async {
          final harness = TranslateHarness(
            state: readyState().copyWith(
              engine: () => null,
              fastEngine: () => google,
              bestEngine: () => claude,
            ),
          );
          await harness.pump(tester, size: const Size(400, 800));
          await tester.pumpAndSettle();
          expect(find.byType(ChooseEngineView), findsOneWidget);
          expect(appBarToggle(), findsOneWidget);
        });

        testWidgets('the chip switches the mode', (tester) async {
          final harness = qualityHarness();
          await harness.pump(tester, size: const Size(400, 800));
          await tester.pump();
          await tester.tap(chip());
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('translate_quality_best')),
          );
          await tester.pumpAndSettle();
          verify(() => harness.translate.setQualityMode(QualityMode.best))
              .called(1);
          // The greeting stays.
          expect(hero(), findsOneWidget);
        });
      });
    });

    group('swapping', () {
      /// The lowest opacity the input is drawn with.
      double inputOpacity(WidgetTester tester) => tester
          .widgetList<FadeTransition>(
            find.ancestor(
              of: find.byType(InputCard),
              matching: find.byType(FadeTransition),
            ),
          )
          .map((fade) => fade.opacity.value)
          .fold(1, (lowest, value) => value < lowest ? value : lowest);

      Future<void> swap(WidgetTester tester, {bool reduced = false}) async {
        final states = StreamController<TranslateState>();
        addTearDown(states.close);
        final initial = readyState(
          source: english,
          target: german,
          input: 'Hello',
        );
        final harness = TranslateHarness(state: initial);
        whenListen(harness.translate, states.stream, initialState: initial);
        await harness.pump(
          tester,
          size: const Size(400, 800),
          disableAnimations: reduced,
        );
        expect(inputOpacity(tester), 1);
        states.add(readyState(source: german, target: english, input: 'Hallo'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
      }

      testWidgets('fades the texts in again', (tester) async {
        await swap(tester);
        expect(inputOpacity(tester), lessThan(1));
        await tester.pumpAndSettle();
        expect(inputOpacity(tester), 1);
      });

      testWidgets('without motion with reduced motion', (tester) async {
        await swap(tester, reduced: true);
        expect(inputOpacity(tester), 1);
      });
    });

    test('a queued translation joins the thread', () {
      expect(outputJoinsThread(readyState(input: 'Hi')), isFalse);
      expect(
        outputJoinsThread(readyState(input: 'Hi').copyWith(queued: true)),
        isTrue,
      );
    });

    testWidgets('the output placeholder gives way to a queued translation', (
      tester,
    ) async {
      final states = StreamController<TranslateState>();
      addTearDown(states.close);
      final initial = readyState(input: 'Hi');
      final harness = TranslateHarness(state: initial);
      whenListen(harness.translate, states.stream, initialState: initial);
      await harness.pump(tester, size: const Size(1280, 800));
      final placeholder = find.byKey(const Key('translate_output_placeholder'));
      expect(placeholder, findsOneWidget);
      states.add(initial.copyWith(queued: true));
      await tester.pump();
      expect(placeholder, findsNothing);
    });

    test('translateComposerFill is the shared composer fill', () {
      final scheme = ColorScheme.fromSeed(seedColor: Colors.teal);
      const quiet = Color(0xFF536471);
      expect(translateComposerFill(scheme, quiet), composerFill(scheme, quiet));
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
      final toggle = find.byKey(const Key('translate_compare_toggle'));
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      verify(() => harness.translate.setCompareMode(enabled: true)).called(1);
    });

    testWidgets('the More tools menu has no compare entry (it is under the '
        'translation)', (tester) async {
      final harness = TranslateHarness(state: readyState(input: 'Hello'));
      await harness.pump(tester);
      await tester.tap(find.byKey(const Key('translate_more_tools')));
      await tester.pumpAndSettle();
      expect(find.text('Compare engines'), findsNothing);
      expect(find.text('Exit compare mode'), findsNothing);
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
