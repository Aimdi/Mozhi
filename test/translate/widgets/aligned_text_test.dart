import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';
import 'output_stubs.dart';

const _source = 'Hello world';
const _target = 'Bonjour le monde';

/// "Hello" = "Bonjour", "world" = "le monde".
const _alignment = [
  AlignedSpan(sourceStart: 0, sourceEnd: 5, targetStart: 0, targetEnd: 7),
  AlignedSpan(sourceStart: 6, sourceEnd: 11, targetStart: 8, targetEnd: 16),
];

Finder get _alignedText => find.byKey(const Key('translate_aligned_text'));

/// Global centre of the characters [start, end) of the aligned text.
Offset _centerOf(WidgetTester tester, int start, int end) {
  final paragraph = tester.renderObject<RenderParagraph>(
    find.descendant(of: _alignedText, matching: find.byType(RichText)),
  );
  final box = paragraph
      .getBoxesForSelection(TextSelection(baseOffset: start, extentOffset: end))
      .first;
  return paragraph.localToGlobal(box.toRect().center);
}

/// The [TextSpan] of the aligned text that shows [text].
TextSpan _span(WidgetTester tester, String text) {
  final rich = tester.widget<RichText>(
    find.descendant(of: _alignedText, matching: find.byType(RichText)),
  );
  late TextSpan found;
  rich.text.visitChildren((span) {
    if (span is TextSpan && span.text == text) found = span;
    return true;
  });
  return found;
}

/// An [AlignedText] whose focus is kept in [focus]; every `onFocus` call
/// is recorded in [calls].
class _Host {
  final focus = ValueNotifier<int?>(null);
  final calls = <int?>[];

  Widget build({AlignedSide side = AlignedSide.target}) =>
      ValueListenableBuilder<int?>(
        valueListenable: focus,
        builder: (context, value, _) => AlignedText(
          text: side == AlignedSide.target ? _target : _source,
          other: side == AlignedSide.target ? _source : _target,
          side: side,
          alignment: _alignment,
          focus: value,
          onFocus: (index) {
            calls.add(index);
            focus.value = index;
          },
        ),
      );
}

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final (hi, lo) = la > lb ? (la, lb) : (lb, la);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  setUpAll(registerOutputFallbacks);

  group('AlignedText.ranges', () {
    test('lists target phrases in text order', () {
      expect(AlignedText.ranges(_target, _alignment.reversed.toList()), [
        (0, 7, 1),
        (8, 16, 0),
      ]);
    });

    test('uses source offsets for the source side', () {
      expect(
        AlignedText.ranges(_source, _alignment, side: AlignedSide.source),
        [(0, 5, 0), (6, 11, 1)],
      );
    });

    test('clips, and drops empty, blank and overlapping phrases', () {
      expect(
        AlignedText.ranges('Bonjour le monde', const [
          // Past the end: clipped.
          AlignedSpan(
            sourceStart: 0,
            sourceEnd: 1,
            targetStart: 11,
            targetEnd: 40,
          ),
          // Overlaps the first.
          AlignedSpan(
            sourceStart: 0,
            sourceEnd: 1,
            targetStart: 8,
            targetEnd: 13,
          ),
          // Empty.
          AlignedSpan(
            sourceStart: 0,
            sourceEnd: 1,
            targetStart: 3,
            targetEnd: 3,
          ),
          // Only a space.
          AlignedSpan(
            sourceStart: 0,
            sourceEnd: 1,
            targetStart: 7,
            targetEnd: 8,
          ),
          // Entirely outside.
          AlignedSpan(
            sourceStart: 0,
            sourceEnd: 1,
            targetStart: 50,
            targetEnd: 60,
          ),
        ]),
        [(11, 16, 0)],
      );
    });

    test('never splits a surrogate pair', () {
      // "😀" is two UTF-16 code units (1 and 2).
      const text = 'a😀b';
      expect(
        AlignedText.ranges(text, const [
          AlignedSpan(
            sourceStart: 0,
            sourceEnd: 1,
            targetStart: 2,
            targetEnd: 2,
          ),
        ]),
        isEmpty,
      );
      expect(
        AlignedText.ranges(text, const [
          AlignedSpan(
            sourceStart: 0,
            sourceEnd: 1,
            targetStart: 0,
            targetEnd: 2,
          ),
        ]),
        [(0, 3, 0)],
      );
      expect(
        AlignedText.ranges(text, const [
          AlignedSpan(
            sourceStart: 0,
            sourceEnd: 1,
            targetStart: 2,
            targetEnd: 4,
          ),
        ]),
        [(1, 4, 0)],
      );
    });

    test('phrase returns the trimmed phrase or nothing', () {
      expect(
        AlignedText.phrase(_target, _alignment[1], AlignedSide.target),
        'le monde',
      );
      expect(
        AlignedText.phrase(_source, _alignment[1], AlignedSide.source),
        'world',
      );
      expect(
        AlignedText.phrase('Bonjour', _alignment[1], AlignedSide.target),
        isEmpty,
      );
    });

    test('bounds picks the side', () {
      expect(AlignedText.bounds(_alignment[1], AlignedSide.source), (6, 11));
      expect(AlignedText.bounds(_alignment[1], AlignedSide.target), (8, 16));
    });
  });

  group('AlignedText', () {
    testWidgets('marks aligned phrases and highlights the focused one', (
      tester,
    ) async {
      final host = _Host()..focus.value = 1;
      await TranslateHarness().pump(tester, child: host.build());
      final context = tester.element(_alignedText);
      final scheme = Theme.of(context).colorScheme;
      final focused = _span(tester, 'le monde');
      expect(focused.style?.backgroundColor, scheme.tertiaryContainer);
      expect(focused.style?.color, scheme.onTertiaryContainer);
      final other = _span(tester, 'Bonjour');
      expect(other.style?.backgroundColor, isNull);
      expect(other.style?.decorationStyle, TextDecorationStyle.dotted);
      expect(other.style?.decorationColor, scheme.outline);
    });

    testWidgets('phrases are read in the language of the text only', (
      tester,
    ) async {
      // A label mixing "translates" and the other text would be read with
      // the voice of this text's locale.
      await TranslateHarness().pump(
        tester,
        child: AlignedText(
          text: _target,
          other: _source,
          alignment: _alignment,
          locale: const Locale('fr'),
          onFocus: (_) {},
        ),
      );
      expect(_span(tester, 'le monde').semanticsLabel, isNull);
      expect(_span(tester, 'Bonjour').semanticsLabel, isNull);
      expect(_span(tester, 'le monde').locale, isNull);
      final rich = tester.widget<RichText>(
        find.descendant(of: _alignedText, matching: find.byType(RichText)),
      );
      // One locale, the text's, around all phrases.
      final locales = <Locale>[];
      void collect(InlineSpan span) {
        if (span is! TextSpan) return;
        if (span.locale case final locale?) locales.add(locale);
        span.children?.forEach(collect);
      }

      collect(rich.text);
      expect(locales, [const Locale('fr')]);
    });

    testWidgets('phrases are unlabelled without the other text', (
      tester,
    ) async {
      await TranslateHarness().pump(
        tester,
        child: AlignedText(
          text: _target,
          alignment: _alignment,
          focus: 0,
          onFocus: (_) {},
        ),
      );
      expect(_span(tester, 'le monde').semanticsLabel, isNull);
    });

    testWidgets('a tap focuses a phrase; a second tap clears it', (
      tester,
    ) async {
      final host = _Host();
      await TranslateHarness().pump(tester, child: host.build());
      await tester.tapAt(_centerOf(tester, 8, 16));
      await tester.pump();
      expect(host.calls, [1]);
      await tester.tapAt(_centerOf(tester, 0, 7));
      await tester.pump();
      expect(host.calls, [1, 0]);
      await tester.tapAt(_centerOf(tester, 0, 7));
      await tester.pump();
      expect(host.calls, [1, 0, null]);
    });

    testWidgets('hovering focuses a phrase until the mouse leaves', (
      tester,
    ) async {
      final host = _Host();
      await TranslateHarness().pump(tester, child: host.build());
      // Pinned by a tap.
      await tester.tapAt(_centerOf(tester, 0, 7));
      await tester.pump();
      expect(host.calls, [0]);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: const Offset(700, 500));
      await mouse.moveTo(_centerOf(tester, 8, 16));
      await tester.pump();
      expect(host.calls, [0, 1]);
      // A click while hovering pins it (no change), the exit keeps it.
      await mouse.down(_centerOf(tester, 8, 16));
      await mouse.up();
      await tester.pump();
      await mouse.moveTo(const Offset(700, 500));
      await tester.pump();
      expect(host.calls, [0, 1]);

      // Hovering the other phrase and leaving goes back to the pinned one.
      await mouse.moveTo(_centerOf(tester, 0, 7));
      await tester.pump();
      await mouse.moveTo(const Offset(700, 500));
      await tester.pump();
      expect(host.calls, [0, 1, 0, 1]);
    });

    testWidgets('hovering without a tap clears the focus on exit', (
      tester,
    ) async {
      final host = _Host();
      await TranslateHarness().pump(tester, child: host.build());
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: const Offset(700, 500));
      await mouse.moveTo(_centerOf(tester, 0, 7));
      await tester.pump();
      await mouse.moveTo(const Offset(700, 500));
      await tester.pump();
      expect(host.calls, [0, null]);
    });

    testWidgets('a focus from the other side is kept after hovering', (
      tester,
    ) async {
      final host = _Host();
      await TranslateHarness().pump(tester, child: host.build());
      host.focus.value = 0;
      await tester.pump();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: const Offset(700, 500));
      await mouse.moveTo(_centerOf(tester, 8, 16));
      await tester.pump();
      await mouse.moveTo(const Offset(700, 500));
      await tester.pump();
      expect(host.calls, [1, 0]);
    });

    group('keyboard', () {
      /// The focus node of the aligned text.
      FocusNode node(WidgetTester tester) =>
          Focus.of(tester.element(_alignedText));

      BoxDecoration outline(WidgetTester tester) =>
          tester
                  .widget<DecoratedBox>(
                    find.byKey(const Key('translate_aligned_text_focus')),
                  )
                  .decoration
              as BoxDecoration;

      testWidgets('the text is a tab stop with a visible focus', (
        tester,
      ) async {
        final host = _Host();
        await TranslateHarness().pump(tester, child: host.build());
        expect(outline(tester).border, isNull);

        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(node(tester).hasPrimaryFocus, isTrue);
        final context = tester.element(_alignedText);
        final border = outline(tester).border! as Border;
        expect(border.top.color, Theme.of(context).colorScheme.primary);
        expect(border.top.width, 2);
        // Focusing the text alone focuses no phrase.
        expect(host.calls, isEmpty);
      });

      testWidgets('arrow keys move through the phrases in reading order', (
        tester,
      ) async {
        final host = _Host();
        await TranslateHarness().pump(tester, child: host.build());
        node(tester).requestFocus();
        await tester.pump();

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(host.focus.value, 0);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(host.focus.value, 1);
        // Stays on the last phrase.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(host.focus.value, 1);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump();
        expect(host.focus.value, 0);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
        expect(host.focus.value, 0);
        expect(host.calls, [0, 1, 0]);
        // Each pair is announced as it gets the focus.
        expect(tester.takeAnnouncements().map((a) => a.message), [
          '“Bonjour” translates “Hello”',
          '“le monde” translates “world”',
          '“Bonjour” translates “Hello”',
        ]);
      });

      testWidgets('Escape clears, Enter and Space toggle the first phrase', (
        tester,
      ) async {
        final host = _Host();
        await TranslateHarness().pump(tester, child: host.build());
        node(tester).requestFocus();
        await tester.pump();

        // Nothing to clear: Escape is left to others.
        expect(await tester.sendKeyEvent(LogicalKeyboardKey.escape), isFalse);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(host.focus.value, 0);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pump();
        expect(host.focus.value, isNull);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
        expect(host.focus.value, 1);
        expect(await tester.sendKeyEvent(LogicalKeyboardKey.escape), isTrue);
        await tester.pump();
        expect(host.focus.value, isNull);
        // Other keys are not handled.
        expect(await tester.sendKeyEvent(LogicalKeyboardKey.keyA), isFalse);
        expect(host.calls, [0, null, 1, null]);
      });

      testWidgets('left and right follow a right-to-left text', (tester) async {
        final calls = <int?>[];
        final focus = ValueNotifier<int?>(null);
        await TranslateHarness().pump(
          tester,
          child: ValueListenableBuilder<int?>(
            valueListenable: focus,
            builder: (context, value, _) => AlignedText(
              text: _target,
              alignment: _alignment,
              focus: value,
              textDirection: TextDirection.rtl,
              onFocus: (index) {
                calls.add(index);
                focus.value = index;
              },
            ),
          ),
        );
        node(tester).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(calls, [0, 1, 0]);
      });

      testWidgets('key repeats move but do not toggle', (tester) async {
        final host = _Host();
        await TranslateHarness().pump(tester, child: host.build());
        node(tester).requestFocus();
        await tester.pump();
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(host.focus.value, 0);
        expect(
          await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter),
          isFalse,
        );
        expect(await tester.sendKeyUpEvent(LogicalKeyboardKey.enter), isFalse);
        expect(host.calls, [0]);
      });

      testWidgets('is no tab stop without phrases', (tester) async {
        await TranslateHarness().pump(
          tester,
          child: AlignedText(
            text: _target,
            alignment: const [],
            onFocus: (_) {},
          ),
        );
        expect(node(tester).canRequestFocus, isFalse);
      });
    });

    testWidgets('whitespace between phrases is no screen reader stop', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final host = _Host();
      await TranslateHarness().pump(tester, child: host.build());
      final paragraph = tester.getSemantics(
        find.descendant(of: _alignedText, matching: find.byType(RichText)),
      );
      final children = <SemanticsNode>[];
      paragraph.visitChildren((child) {
        children.add(child);
        return true;
      });
      final stops = [
        for (final child in children)
          if (child.label.isNotEmpty) child.label,
      ];
      expect(stops, ['Bonjour', 'le monde']);
      for (final child in children) {
        final data = child.getSemanticsData();
        if (child.label.isEmpty) {
          // Nothing for the platform to focus: no label, no action.
          expect(data.actions, 0);
        } else {
          expect(data.flagsCollection.isLink, isTrue);
        }
      }
      handle.dispose();
    });

    testWidgets('announces the focused pair', (tester) async {
      final host = _Host();
      await TranslateHarness().pump(
        tester,
        child: host.build(),
        supportsAnnounce: true,
      );
      host.focus.value = 1;
      await tester.pump();
      expect(tester.takeAnnouncements(), [
        isAccessibilityAnnouncement('“le monde” translates “world”'),
      ]);
    });

    testWidgets('the source side announces the pair the same way', (
      tester,
    ) async {
      final host = _Host();
      await TranslateHarness().pump(
        tester,
        child: host.build(side: AlignedSide.source),
        supportsAnnounce: true,
      );
      expect(_span(tester, 'world').semanticsLabel, isNull);
      host.focus.value = 1;
      await tester.pump();
      expect(tester.takeAnnouncements(), [
        isAccessibilityAnnouncement('“le monde” translates “world”'),
      ]);
    });

    testWidgets('an out of range focus is not announced', (tester) async {
      final host = _Host();
      await TranslateHarness().pump(
        tester,
        child: host.build(),
        supportsAnnounce: true,
      );
      host.focus.value = 5;
      await tester.pump();
      expect(tester.takeAnnouncements(), isEmpty);
    });

    test('highlight colours keep their contrast in light and dark', () {
      for (final brightness in Brightness.values) {
        final scheme = ThemeData(brightness: brightness).colorScheme;
        final style = AlignedText.focusStyle(scheme);
        expect(
          _contrast(style.color!, style.backgroundColor!),
          greaterThanOrEqualTo(4.5),
          reason: '$brightness',
        );
      }
    });
  });

  group('OutputCard alignment', () {
    TranslateState aligned({
      ExtraStatus status = ExtraStatus.ready,
      List<AlignedSpan> alignment = _alignment,
      int? focus,
    }) => translatedState(assistEngine: claude).copyWith(
      alignmentStatus: status,
      alignment: alignment,
      alignmentFocus: () => focus,
    );

    Finder button() => find.byKey(const Key('translate_alignment_button'));

    testWidgets('is offered with an AI engine and loads on demand', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: translatedState(assistEngine: claude),
      );
      stubOutputExtras(harness);
      await harness.pump(tester, child: const OutputCard(), more: true);
      expect(find.byTooltip('Show matching phrases'), findsOneWidget);
      await tester.tap(button());
      await tester.pump();
      verify(harness.translate.loadAlignment).called(1);
      expect(find.byTooltip('Hide matching phrases'), findsOneWidget);
      expect(tester.widget<TranslateToolChip>(button()).selected, isTrue);
    });

    testWidgets('is not offered without an AI engine', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const OutputCard(), more: true);
      expect(button(), findsNothing);
    });

    testWidgets('is disabled for an out-of-date translation', (tester) async {
      final harness = TranslateHarness(
        state: translatedState(assistEngine: claude)
            .copyWith(input: 'Hello there', resultInput: () => 'Hello world'),
      );
      await harness.pump(tester, child: const OutputCard(), more: true);
      expect(tester.widget<TranslateToolChip>(button()).onPressed, isNull);
    });

    testWidgets('shows progress while aligning', (tester) async {
      final harness = TranslateHarness(
        state: aligned(status: ExtraStatus.loading),
      );
      stubOutputExtras(harness);
      await harness.pump(tester, child: const OutputCard(), more: true);
      await tester.tap(button());
      await tester.pump();
      verifyNever(harness.translate.loadAlignment);
      final progress = tester.widget<LinearProgressIndicator>(
        find.byKey(const Key('translate_alignment_progress')),
      );
      expect(progress.semanticsLabel, 'Finding matching phrases…');
    });

    testWidgets('shows errors with retry', (tester) async {
      final harness = TranslateHarness(
        state: aligned(status: ExtraStatus.failure).copyWith(
          alignmentError: () => const LlmApiException('x', statusCode: 429),
        ),
      );
      stubOutputExtras(harness);
      await harness.pump(tester, child: const OutputCard(), more: true);
      await tester.tap(button());
      await tester.pump();
      verify(harness.translate.loadAlignment).called(1);
      expect(
        find.byKey(const Key('translate_alignment_error')),
        findsOneWidget,
      );
      await tester.tap(find.text('Retry'));
      verify(harness.translate.loadAlignment).called(1);
    });

    testWidgets('says when nothing could be aligned', (tester) async {
      final harness = TranslateHarness(state: aligned(alignment: const []));
      stubOutputExtras(harness);
      await harness.pump(tester, child: const OutputCard(), more: true);
      await tester.tap(button());
      await tester.pump();
      expect(find.text('No matching phrases found.'), findsOneWidget);
      expect(_alignedText, findsNothing);
    });

    testWidgets('tapping a phrase focuses its pair', (tester) async {
      final harness = TranslateHarness(state: aligned());
      stubOutputExtras(harness);
      await harness.pump(tester, child: const OutputCard(), more: true);
      await tester.tap(button());
      await tester.pump();
      expect(_alignedText, findsOneWidget);
      expect(find.byKey(const Key('translate_output_text')), findsNothing);
      expect(
        find.text('Tap a phrase to see which words it translates.'),
        findsOneWidget,
      );
      await tester.tapAt(_centerOf(tester, 8, 16));
      verify(() => harness.translate.focusAlignment(1)).called(1);
    });

    testWidgets('the phrases can be reached with the keyboard', (tester) async {
      final harness = TranslateHarness(state: aligned());
      stubOutputExtras(harness);
      await harness.pump(tester, child: const OutputCard(), more: true);
      await tester.tap(button());
      await tester.pump();
      // The hint explains the keyboard path too.
      expect(
        find.byKey(const Key('translate_alignment_keyboard_hint')),
        findsOneWidget,
      );
      expect(
        find.text(
          'With a keyboard: focus the translation and use the arrow keys, '
          'or move the cursor in your text.',
        ),
        findsOneWidget,
      );

      // Tabbing through the card reaches the translation.
      final text = Focus.of(tester.element(_alignedText));
      var reached = false;
      for (var i = 0; i < 30 && !reached; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        reached = text.hasPrimaryFocus;
      }
      expect(reached, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      verify(() => harness.translate.focusAlignment(0)).called(1);
    });

    testWidgets('hiding clears the focus', (tester) async {
      final harness = TranslateHarness(state: aligned(focus: 1));
      stubOutputExtras(harness);
      await harness.pump(tester, child: const OutputCard(), more: true);
      await tester.tap(button());
      await tester.pump();
      expect(_alignedText, findsOneWidget);
      await tester.tap(button());
      await tester.pump();
      verify(() => harness.translate.focusAlignment(null)).called(1);
      expect(_alignedText, findsNothing);
      expect(find.byKey(const Key('translate_output_text')), findsOneWidget);
    });

    testWidgets('hiding without a focus leaves the focus alone', (
      tester,
    ) async {
      final harness = TranslateHarness(state: aligned());
      stubOutputExtras(harness);
      await harness.pump(tester, child: const OutputCard(), more: true);
      await tester.tap(button());
      await tester.pump();
      await tester.tap(button());
      await tester.pump();
      verifyNever(() => harness.translate.focusAlignment(any()));
    });

    testWidgets('insights and alignment take turns', (tester) async {
      final harness = TranslateHarness(
        state: aligned(focus: 0).copyWith(
          insightsStatus: ExtraStatus.ready,
          insights: const [
            WordInsight(sourceText: 'world', targetText: 'monde'),
          ],
        ),
      );
      stubOutputExtras(harness);
      await harness.pump(tester, child: const OutputCard(), more: true);
      await tester.tap(button());
      await tester.pump();
      expect(_alignedText, findsOneWidget);

      await tester.tap(find.byKey(const Key('translate_insights_button')));
      await tester.pump();
      verify(() => harness.translate.focusAlignment(null)).called(1);
      expect(_alignedText, findsNothing);
      expect(find.byKey(const Key('translate_insight_text')), findsOneWidget);
      expect(tester.widget<TranslateToolChip>(button()).selected, isFalse);

      await tester.tap(button());
      await tester.pump();
      expect(_alignedText, findsOneWidget);
      expect(find.byKey(const Key('translate_insight_text')), findsNothing);
    });

    testWidgets('reloads for the next translation while shown', (tester) async {
      final initial = translatedState(assistEngine: claude);
      final harness = TranslateHarness(state: initial);
      stubOutputExtras(harness);
      final controller = StreamController<TranslateState>();
      addTearDown(controller.close);
      whenListen(harness.translate, controller.stream, initialState: initial);
      await harness.pump(tester, child: const OutputCard(), more: true);
      await tester.tap(button());
      await tester.pump();
      verify(harness.translate.loadAlignment).called(1);

      final next = translatedState(
        assistEngine: claude,
        input: 'Good night',
        result: const TranslationResult(
          engineId: 'mozhi:deepl',
          engineName: 'DeepL',
          text: 'Bonne nuit',
        ),
      );
      when(() => harness.translate.state).thenReturn(next);
      controller.add(next);
      await tester.pump();
      verify(harness.translate.loadAlignment).called(1);
    });

    testWidgets('turns off after an instant translation instead of '
        'paying for a new alignment', (tester) async {
      final initial = translatedState(assistEngine: claude);
      final harness = TranslateHarness(state: initial);
      stubOutputExtras(harness);
      final controller = StreamController<TranslateState>();
      addTearDown(controller.close);
      whenListen(harness.translate, controller.stream, initialState: initial);
      await harness.pump(tester, child: const OutputCard(), more: true);
      await tester.tap(button());
      await tester.pump();
      verify(harness.translate.loadAlignment).called(1);

      // A typing pause translated the edited text with a free engine.
      final next = translatedState(
        assistEngine: claude,
        input: 'Good night',
        result: const TranslationResult(
          engineId: 'mozhi:deepl',
          engineName: 'DeepL',
          text: 'Bonne nuit',
        ),
      ).copyWith(instantResult: true);
      when(() => harness.translate.state).thenReturn(next);
      controller.add(next);
      await tester.pump();
      verifyNever(harness.translate.loadAlignment);
      expect(tester.widget<TranslateToolChip>(button()).selected, isFalse);
      expect(find.byTooltip('Show matching phrases'), findsOneWidget);

      // The button loads it again.
      await tester.tap(button());
      await tester.pump();
      verify(harness.translate.loadAlignment).called(1);
    });

    testWidgets('reloads after an instant translation with a local engine', (
      tester,
    ) async {
      final initial = translatedState(assistEngine: ollama);
      final harness = TranslateHarness(state: initial);
      stubOutputExtras(harness);
      final controller = StreamController<TranslateState>();
      addTearDown(controller.close);
      whenListen(harness.translate, controller.stream, initialState: initial);
      await harness.pump(tester, child: const OutputCard(), more: true);
      await tester.tap(button());
      await tester.pump();
      verify(harness.translate.loadAlignment).called(1);

      final next = translatedState(
        assistEngine: ollama,
        input: 'Good night',
        result: const TranslationResult(
          engineId: 'mozhi:deepl',
          engineName: 'DeepL',
          text: 'Bonne nuit',
        ),
      ).copyWith(instantResult: true);
      when(() => harness.translate.state).thenReturn(next);
      controller.add(next);
      await tester.pump();
      verify(harness.translate.loadAlignment).called(1);
    });

    testWidgets('the hint is announced for the alignment asked for only', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final initial = translatedState(assistEngine: claude);
      final harness = TranslateHarness(state: initial);
      stubOutputExtras(harness);
      final controller = StreamController<TranslateState>();
      addTearDown(controller.close);
      whenListen(harness.translate, controller.stream, initialState: initial);
      await harness.pump(tester, child: const OutputCard(), more: true);
      await tester.tap(button());
      await tester.pump();

      bool liveHint() => tester
          .widget<Semantics>(
            find
                .ancestor(
                  of: find.byKey(const Key('translate_alignment_hint')),
                  matching: find.byType(Semantics),
                )
                .first,
          )
          .properties
          .liveRegion!;

      final ready = initial.copyWith(
        alignmentStatus: ExtraStatus.ready,
        alignment: _alignment,
      );
      controller.add(ready);
      await tester.pump();
      expect(liveHint(), isTrue);

      // The next translation (asked for) reloads it: not announced again.
      final nextResult = helloResult.copyWith(text: 'Bonjour à tous');
      final next = translatedState(
        assistEngine: claude,
        result: nextResult,
      ).copyWith(alignmentStatus: ExtraStatus.ready, alignment: _alignment);
      controller.add(next);
      await tester.pump();
      expect(liveHint(), isFalse);
      handle.dispose();
    });

    testWidgets('loads once it is idle again while shown', (tester) async {
      final initial = aligned(status: ExtraStatus.loading);
      final harness = TranslateHarness(state: initial);
      stubOutputExtras(harness);
      final controller = StreamController<TranslateState>();
      addTearDown(controller.close);
      whenListen(harness.translate, controller.stream, initialState: initial);
      await harness.pump(tester, child: const OutputCard(), more: true);
      await tester.tap(button());
      await tester.pump();
      verifyNever(harness.translate.loadAlignment);
      final idle = initial.copyWith(
        alignmentStatus: ExtraStatus.idle,
        alignment: const [],
      );
      when(() => harness.translate.state).thenReturn(idle);
      controller.add(idle);
      await tester.pump();
      verify(harness.translate.loadAlignment).called(1);
    });

    testWidgets('does not load on its own while hidden', (tester) async {
      final initial = translatedState(assistEngine: claude);
      final harness = TranslateHarness(state: initial);
      stubOutputExtras(harness);
      whenListen(
        harness.translate,
        Stream.value(initial.copyWith(input: 'Hello')),
        initialState: initial,
      );
      await harness.pump(tester, child: const OutputCard(), more: true);
      await tester.pump();
      verifyNever(harness.translate.loadAlignment);
    });
  });
}
