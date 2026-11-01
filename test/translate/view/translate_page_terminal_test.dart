import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/core/widgets/terminal_rule.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/image_translate/view/image_translate_page.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers/terminal_font.dart';
import '../helpers/helpers.dart';

HistoryEntry _entry(
  String id,
  String text, {
  Language source = english,
  Language target = german,
  bool dictionary = false,
}) => HistoryEntry(
  id: id,
  text: text,
  translation: '$text!',
  source: source,
  target: target,
  engineId: 'mozhi:deepl',
  engineName: 'DeepL',
  createdAt: DateTime(2026, 10, 31),
  kind: dictionary ? HistoryEntryKind.dictionary : HistoryEntryKind.translation,
);

void main() {
  setUpAll(() async {
    registerTranslateFallbacks();
    // The language cells pick what fits in the real font.
    await loadTerminalFont();
  });

  setUp(() => TranslateHero.clock = () => DateTime(2026, 10, 31, 9));
  tearDown(() => TranslateHero.clock = DateTime.now);

  const phone = Size(390, 844);
  const narrowPhone = Size(320, 640);
  const tablet = Size(1100, 900);

  Finder glyph(String text) => find.text(text);

  /// A language pair as shown ("en → de"), its codes bidi-isolated.
  Finder pairText(String text) => find.byWidgetPredicate(
    (widget) =>
        widget is Text &&
        widget.data?.replaceAll(RegExp('[\u2066-\u2069]'), '') == text,
  );

  Future<TranslateHarness> pumpTerminal(
    WidgetTester tester, {
    TranslateState? state,
    HistoryState history = const HistoryState(),
    AppSettings settings = const AppSettings(),
    Size size = phone,
    double textScale = 1,
    Locale? locale,
    FakeSpeechInput? speech,
  }) async {
    final harness = TranslateHarness(
      state: state ?? readyState(source: english, target: german),
      history: history,
      settings: settings,
      speechInput: speech?.service,
    );
    when(() => harness.translate.restoreHistoryEntry(any())).thenReturn(true);
    await harness.pump(
      tester,
      size: size,
      textScale: textScale,
      locale: locale,
      theme: terminalTestTheme(),
    );
    await tester.pump();
    return harness;
  }

  group('TranslateView in the terminal look', () {
    testWidgets('shows the terminal layout from top to bottom', (tester) async {
      await pumpTerminal(tester);

      // 1. The top bar: `● engine`, then [h] and [s], a dashed rule below.
      expect(find.byKey(const Key('translate_engine_selector')), findsOne);
      expect(glyph('●'), findsOneWidget);
      expect(find.text('DeepL'), findsOneWidget);
      expect(glyph('[h]'), findsOneWidget);
      expect(glyph('[s]'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byType(TerminalRule),
        ),
        findsOneWidget,
      );
      expect(tester.getSize(find.byType(AppBar)).height, 61);

      // 2. `// greeting` and the lower-case title in the accent.
      expect(glyph('//'), findsOneWidget);
      expect(find.text('good morning'), findsOneWidget);
      final title = tester.widget<Text>(
        find.byKey(const Key('translate_terminal_title')),
      );
      expect(title.data, 'translate');
      final scheme = Theme.of(
        tester.element(find.byKey(const Key('translate_terminal_title'))),
      ).colorScheme;
      expect(title.style?.color, scheme.primary);
      expect(title.style?.fontWeight, FontWeight.w800);

      // 3. One box: --from English | ⇄ | --to German.
      final bar = find.byKey(const Key('translate_language_bar'));
      expect(bar, findsOneWidget);
      expect(
        find.descendant(of: bar, matching: glyph('--from')),
        findsOneWidget,
      );
      expect(find.descendant(of: bar, matching: glyph('--to')), findsOne);
      expect(find.descendant(of: bar, matching: glyph('↔')), findsOneWidget);
      // The names fit beside the flags.
      expect(
        find.descendant(of: bar, matching: find.text('English')),
        findsOne,
      );
      expect(find.descendant(of: bar, matching: find.text('German')), findsOne);

      // 4. stdin: the prompt, the placeholder with its cursor, the tools
      // and run.
      final input = find.byKey(const Key('translate_input_card'));
      expect(find.descendant(of: input, matching: glyph('stdin')), findsOne);
      expect(find.descendant(of: input, matching: glyph('>')), findsOne);
      final placeholder = tester.widget<Text>(
        find.byKey(const Key('translate_terminal_placeholder')),
      );
      expect(placeholder.data, 'type or paste text_');
      expect(find.descendant(of: input, matching: glyph('cam')), findsOne);
      expect(find.descendant(of: input, matching: glyph('doc')), findsOne);
      expect(find.descendant(of: input, matching: glyph('run ⏎')), findsOne);
      expect(
        find.descendant(
          of: input,
          matching: find.byKey(const Key('translate_options_button')),
        ),
        findsOneWidget,
      );
      // Nothing to show yet: no stdout box.
      expect(glyph('stdout'), findsNothing);

      // In that order, top to bottom.
      double top(Finder finder) => tester.getTopLeft(finder).dy;
      expect(top(find.byType(AppBar)), lessThan(top(glyph('//'))));
      expect(top(glyph('//')), lessThan(top(bar)));
      expect(top(bar), lessThan(top(input)));

      // The classic composer, greeting and app bar title are not there.
      expect(find.byKey(const Key('translate_hero')), findsNothing);
      expect(find.byKey(const Key('translate_composer')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the run button translates', (tester) async {
      final harness = await pumpTerminal(
        tester,
        state: readyState(source: english, target: german, input: 'Hello'),
      );

      final run = find.byKey(const Key('translate_translate_button'));
      expect(find.descendant(of: run, matching: glyph('run ⏎')), findsOne);
      final button = tester.widget<TextButton>(run);
      final scheme = Theme.of(tester.element(run)).colorScheme;
      expect(button.style?.backgroundColor?.resolve(const {}), scheme.primary);
      expect(
        button.style?.foregroundColor?.resolve(const {}),
        scheme.onPrimary,
      );

      await tester.tap(run);
      await tester.pump();
      verify(harness.translate.translate).called(1);
    });

    testWidgets('run is disabled without input', (tester) async {
      await pumpTerminal(tester);

      final button = tester.widget<TextButton>(
        find.byKey(const Key('translate_translate_button')),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('the swap cell swaps the languages', (tester) async {
      final harness = await pumpTerminal(tester);

      await tester.tap(find.byKey(const Key('translate_swap_button')));
      await tester.pump();
      verify(harness.translate.swap).called(1);
    });

    testWidgets('the tools keep their actions', (tester) async {
      final clipboard = FakeClipboard(tester, pasteText: 'Copied text');
      final harness = await pumpTerminal(tester);

      await tester.tap(find.byKey(const Key('translate_hero_camera')));
      await tester.pump();
      verify(() => harness.router.push<void>(ImageTranslatePage.locationFor()))
          .called(1);

      await tester.tap(find.byKey(const Key('translate_hero_document')));
      await tester.pump();
      verify(() => harness.router.push<void>(AppRoutes.documents)).called(1);

      await tester.tap(find.byKey(const Key('translate_paste_button')));
      await tester.pumpAndSettle();
      verify(() => harness.translate.setInput('Copied text', pasted: true))
          .called(1);
      expect(clipboard.pasteText, 'Copied text');

      await tester.tap(find.byKey(const Key('translate_options_button')));
      await tester.pumpAndSettle();
      expect(find.byType(TranslationOptionsSheet), findsOneWidget);
    });

    testWidgets('the microphone dictates into the input', (tester) async {
      final speech = FakeSpeechInput();
      final harness = await pumpTerminal(
        tester,
        speech: speech,
        state: readyState(source: english, target: german, input: 'Hello'),
      );

      final mic = find.descendant(
        of: find.byKey(const Key('translate_voice_input')),
        matching: find.byType(IconButton),
      );
      // A framed tool of the stdin box.
      expect(
        find.descendant(
          of: find.byKey(const Key('translate_input_toolbar')),
          matching: find.byKey(const Key('translate_voice_input')),
        ),
        findsOneWidget,
      );
      await tester.tap(mic);
      await tester.pump();
      expect(speech.languages, ['en']);
      speech.say('world', isFinal: true);
      await tester.pump();
      verify(() => harness.translate.setInput('Hello world', dictated: true))
          .called(1);
      speech.finish();
      await tester.pump();
    });

    testWidgets('clear and the count show with input', (tester) async {
      final harness = await pumpTerminal(
        tester,
        state: readyState(source: english, target: german, input: 'Hello'),
      );

      expect(find.byKey(const Key('translate_character_count')), findsOne);
      expect(find.byKey(const Key('translate_paste_button')), findsNothing);
      await tester.tap(find.byKey(const Key('translate_clear_button')));
      await tester.pump();
      verify(harness.translate.clear).called(1);
    });

    testWidgets('shows the translation in the stdout box', (tester) async {
      await pumpTerminal(
        tester,
        state: translatedState().copyWith(source: english, target: german),
      );

      final stdout = find.byKey(const Key('translate_terminal_stdout'));
      expect(stdout, findsOneWidget);
      expect(find.descendant(of: stdout, matching: glyph('stdout')), findsOne);
      expect(
        find.descendant(of: stdout, matching: find.text('Bonjour le monde')),
        findsOneWidget,
      );
      // Its actions as small framed buttons.
      final actions = find.byKey(const Key('translate_output_actions'));
      expect(
        find.descendant(of: actions, matching: find.byType(TerminalFrame)),
        findsAtLeastNWidgets(4),
      );
      expect(
        find.descendant(
          of: actions,
          matching: find.byKey(const Key('translate_copy_button')),
        ),
        findsOneWidget,
      );
      // Below the input box.
      expect(
        tester.getTopLeft(stdout).dy,
        greaterThan(
          tester
              .getBottomLeft(find.byKey(const Key('translate_input_card')))
              .dy,
        ),
      );
      // No history tail with input.
      expect(find.byKey(const Key('translate_history_tail')), findsNothing);
    });

    testWidgets('brings the stdout box above the keyboard when it appears', (
      tester,
    ) async {
      // A small phone with the keyboard up: the stdout box would open below
      // it, out of sight.
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      addTearDown(tester.view.resetViewInsets);
      final states = StreamController<TranslateState>();
      addTearDown(states.close);
      final typed = readyState(
        source: english,
        target: german,
        input: 'Hello world',
      );
      final harness = TranslateHarness(state: typed);
      whenListen(harness.translate, states.stream, initialState: typed);
      await harness.pump(
        tester,
        size: const Size(320, 600),
        theme: terminalTestTheme(),
      );
      await tester.pump();
      final stdout = find.byKey(const Key('translate_terminal_stdout'));

      final done = translatedState().copyWith(source: english, target: german);
      harness.setState(done);
      states.add(done);
      await tester.pumpAndSettle();

      const visibleBottom = 600.0 - 260;
      expect(
        tester.getTopLeft(stdout).dy + 112,
        lessThanOrEqualTo(visibleBottom + 0.5),
      );

      // Not again while it stays: a later state leaves the scroll alone.
      final scrollable = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      final offset = scrollable.position.pixels;
      states.add(done.copyWith(input: 'Hello world!'));
      await tester.pumpAndSettle();
      expect(scrollable.position.pixels, offset);
    });

    group('history tail', () {
      final entries = [
        _entry('1', 'hacker'),
        _entry('2', 'pair', source: german, target: english),
        _entry('3', 'a look-up', dictionary: true),
        _entry('4', 'third'),
        _entry('5', 'fourth'),
      ];

      testWidgets('lists the newest translations and restores one', (
        tester,
      ) async {
        final harness = await pumpTerminal(
          tester,
          history: HistoryState(entries: entries),
        );

        final tail = find.byKey(const Key('translate_history_tail'));
        expect(tail, findsOneWidget);
        expect(glyph(r'$ history --tail 3'), findsOneWidget);
        expect(find.text('01'), findsOneWidget);
        expect(find.text('02'), findsOneWidget);
        expect(find.text('03'), findsOneWidget);
        expect(find.text('hacker'), findsOneWidget);
        expect(find.text('pair'), findsOneWidget);
        expect(find.text('third'), findsOneWidget);
        // Look-ups are skipped; three rows at most.
        expect(find.text('a look-up'), findsNothing);
        expect(find.text('fourth'), findsNothing);
        expect(pairText('en → de'), findsNWidgets(2));
        expect(pairText('de → en'), findsOneWidget);
        // Under the input box.
        expect(
          tester.getTopLeft(tail).dy,
          greaterThan(
            tester
                .getBottomLeft(find.byKey(const Key('translate_input_card')))
                .dy,
          ),
        );

        await tester.tap(
          find.byKey(const ValueKey('translate_history_tail:1')),
        );
        await tester.pump();
        verify(() => harness.translate.restoreHistoryEntry(entries[1]))
            .called(1);
      });

      testWidgets('opens an entry as History does when it cannot restore '
          'it', (tester) async {
        final harness = await pumpTerminal(
          tester,
          history: HistoryState(entries: entries),
        );
        when(() => harness.translate.restoreHistoryEntry(any()))
            .thenReturn(false);

        await tester.tap(
          find.byKey(const ValueKey('translate_history_tail:0')),
        );
        await tester.pump();
        final opened =
            verify(() => harness.translate.openHistoryEntry(captureAny()))
                    .captured
                    .single
                as HistoryEntry;
        expect(opened.text, 'hacker');
        expect(opened.source, english);
        expect(opened.target, german);
      });

      testWidgets('is hidden without history', (tester) async {
        await pumpTerminal(tester);
        expect(find.byKey(const Key('translate_history_tail')), findsNothing);
      });

      testWidgets('is hidden in Incognito', (tester) async {
        await pumpTerminal(
          tester,
          history: HistoryState(entries: entries),
          settings: const AppSettings(incognito: true),
        );
        expect(find.byKey(const Key('translate_history_tail')), findsNothing);
      });

      testWidgets('is hidden while history is not saved', (tester) async {
        await pumpTerminal(
          tester,
          history: HistoryState(entries: entries),
          settings: const AppSettings(saveHistory: false),
        );
        expect(find.byKey(const Key('translate_history_tail')), findsNothing);
      });

      testWidgets('reads like Continue to screen readers', (tester) async {
        final handle = tester.ensureSemantics();
        await pumpTerminal(
          tester,
          history: HistoryState(entries: [entries.first]),
        );

        expect(
          find.bySemanticsLabel(
            RegExp('^Continue: hacker, .*English.* → .*German'),
          ),
          findsOneWidget,
        );
        expect(find.bySemanticsLabel(RegExp('history --tail')), findsNothing);
        expect(find.bySemanticsLabel('01'), findsNothing);
        handle.dispose();
      });
    });

    testWidgets('keeps the classic semantics labels', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpTerminal(
        tester,
        state: readyState(source: english, target: german, input: 'Hello'),
      );

      expect(
        tester.getSemantics(
          find.byKey(const Key('translate_translate_button')),
        ),
        isSemantics(
          label: 'Translate',
          isButton: true,
          hasTapAction: true,
          isEnabled: true,
          isFocusable: true,
        ),
      );
      expect(findTooltipMessage('Translate (Ctrl+Enter)'), findsOneWidget);
      expect(find.bySemanticsLabel('Source language: English'), findsOne);
      expect(find.bySemanticsLabel('Target language: German'), findsOne);
      expect(find.bySemanticsLabel('Text to translate'), findsOneWidget);
      expect(find.bySemanticsLabel('Camera'), findsOneWidget);
      expect(find.bySemanticsLabel('Document'), findsOneWidget);
      expect(find.bySemanticsLabel('History'), findsOneWidget);
      // The decoration is not read out.
      for (final word in [
        'stdin',
        '>',
        '--from',
        '--to',
        'run',
        'cam',
        'doc',
        '●',
        '//',
        '[h]',
        '[s]',
      ]) {
        expect(
          find.bySemanticsLabel(RegExp('^${RegExp.escape(word)}')),
          findsNothing,
          reason: word,
        );
      }
      handle.dispose();
    });

    testWidgets('greets screen readers like the classic empty screen', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpTerminal(tester);

      final greeting = tester.getSemantics(
        find.byKey(const Key('translate_greeting')),
      );
      expect(greeting.label, 'Good morning');
      expect(greeting.flagsCollection.isHeader, isTrue);
      // A phone's classic app bar has no title: only the run button is
      // named "Translate".
      expect(find.bySemanticsLabel('Translate'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('translate_translate_button')),
          matching: find.bySemanticsLabel('Translate'),
        ),
        findsOneWidget,
      );
      handle.dispose();
    });

    for (final (name, state) in [
      ('empty', readyState(source: english, target: german)),
      (
        'translated',
        translatedState().copyWith(source: english, target: german),
      ),
    ]) {
      testWidgets('does not overflow at 200 % text on a 320 dp phone '
          '($name)', (tester) async {
        await pumpTerminal(
          tester,
          state: state,
          size: narrowPhone,
          textScale: 2,
          history: HistoryState(entries: [_entry('1', 'a long text ' * 8)]),
        );
        expect(tester.takeException(), isNull);
        await tester.drag(
          find.byKey(const Key('translate_narrow_layout')),
          const Offset(0, -600),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('mirrors in right-to-left languages', (tester) async {
      await pumpTerminal(tester, locale: const Locale('ar'));

      expect(find.byKey(const Key('translate_terminal_prompt')), findsOne);
      expect(glyph('<'), findsOneWidget);
      final source = tester.getCenter(
        find.byKey(const Key('translate_source_button')),
      );
      final target = tester.getCenter(
        find.byKey(const Key('translate_target_button')),
      );
      final swap = tester.getCenter(
        find.byKey(const Key('translate_swap_button')),
      );
      // Source on the right, target on the left.
      expect(source.dx, greaterThan(swap.dx));
      expect(swap.dx, greaterThan(target.dx));
      // The prompt at the right of the field.
      expect(
        tester.getCenter(find.byKey(const Key('translate_terminal_prompt'))).dx,
        greaterThan(
          tester.getCenter(find.byKey(const Key('translate_input_field'))).dx,
        ),
      );
      // The flag before the language, on the right ("--to <German>"; the
      // source's name only fits without its flag).
      expect(
        tester.getCenter(glyph('--to')).dx,
        greaterThan(
          tester
              .getCenter(
                find.descendant(
                  of: find.byKey(const Key('translate_target_button')),
                  matching: find.text('الألمانية'),
                ),
              )
              .dx,
        ),
      );
      // The CLI words stay left to right.
      final stdin = tester.widget<Text>(glyph('stdin'));
      expect(stdin.textDirection, TextDirection.ltr);
      expect(tester.takeException(), isNull);
    });

    testWidgets('keeps the input and the translation side by side on '
        'large screens', (tester) async {
      await pumpTerminal(
        tester,
        size: tablet,
        state: translatedState().copyWith(source: english, target: german),
      );

      expect(find.byKey(const Key('translate_wide_layout')), findsOneWidget);
      expect(find.byKey(const Key('translate_language_header')), findsOne);
      final input = tester.getRect(
        find.byKey(const Key('translate_input_pane')),
      );
      final output = tester.getRect(
        find.byKey(const Key('translate_output_pane')),
      );
      expect(input.right, lessThanOrEqualTo(output.left));
      expect(input.top, output.top);
      expect(glyph('stdout'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows an empty stdout box beside the input on large screens', (
      tester,
    ) async {
      await pumpTerminal(tester, size: tablet);

      expect(
        find.descendant(
          of: find.byKey(const Key('translate_output_pane')),
          matching: glyph('stdout'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('translate_output_placeholder')),
        findsOneWidget,
      );
    });

    testWidgets('Ctrl+Enter still translates', (tester) async {
      final harness = await pumpTerminal(
        tester,
        state: readyState(source: english, target: german, input: 'Hello'),
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      verify(harness.translate.translate).called(greaterThanOrEqualTo(1));
    });
  });
}
