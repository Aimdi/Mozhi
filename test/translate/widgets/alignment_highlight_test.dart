import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

/// "Hello" ↔ "Bonjour", "world" ↔ "monde".
const _alignment = [
  AlignedSpan(sourceStart: 0, sourceEnd: 5, targetStart: 0, targetEnd: 7),
  AlignedSpan(sourceStart: 6, sourceEnd: 11, targetStart: 11, targetEnd: 16),
];

TranslateState _aligned({int? focus, ExtraStatus status = ExtraStatus.ready}) =>
    translatedState().copyWith(
      alignmentStatus: status,
      alignment: _alignment,
      alignmentFocus: () => focus,
    );

HighlightTextEditingController _controllerOf(WidgetTester tester) =>
    tester
            .widget<TextField>(find.byKey(const Key('translate_input_field')))
            .controller!
        as HighlightTextEditingController;

/// Pumps a field that uses [controller] and returns the span it paints.
Future<TextSpan> _paint(
  WidgetTester tester,
  HighlightTextEditingController controller,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Material(child: TextField(controller: controller)),
    ),
  );
  return controller.buildTextSpan(
    context: tester.element(find.byType(EditableText)),
    withComposing: true,
  );
}

void main() {
  setUpAll(registerTranslateFallbacks);

  group('HighlightTextEditingController', () {
    test('keeps only ranges inside the text', () {
      final controller = HighlightTextEditingController(text: 'Hello world');
      addTearDown(controller.dispose);
      var notified = 0;
      controller
        ..addListener(() => notified++)
        ..showAlignment(
          phrases: const [
            TextRange(start: 0, end: 5),
            TextRange.collapsed(3),
            TextRange(start: 6, end: 40),
            TextRange.empty,
          ],
          highlight: const TextRange(start: 6, end: 11),
        );
      expect(controller.phrases, [const TextRange(start: 0, end: 5)]);
      expect(controller.highlight, const TextRange(start: 6, end: 11));
      expect(notified, 1);

      // The same alignment again does not notify.
      controller.showAlignment(
        phrases: const [TextRange(start: 0, end: 5)],
        highlight: const TextRange(start: 6, end: 11),
      );
      expect(notified, 1);

      controller.showAlignment(highlight: const TextRange(start: 9, end: 12));
      expect(controller.highlight, isNull);
      expect(controller.phrases, isEmpty);
      expect(notified, 2);
    });

    test('an edit clears the alignment, a cursor move keeps it', () {
      final controller = HighlightTextEditingController(text: 'Hello world')
        ..showAlignment(
          phrases: const [TextRange(start: 0, end: 5)],
          highlight: const TextRange(start: 0, end: 5),
        );
      addTearDown(controller.dispose);
      controller.selection = const TextSelection.collapsed(offset: 2);
      expect(controller.highlight, isNotNull);
      expect(controller.phrases, isNotEmpty);

      controller.text = 'Hello world!';
      expect(controller.highlight, isNull);
      expect(controller.phrases, isEmpty);

      controller
        ..showAlignment(highlight: const TextRange(start: 0, end: 5))
        ..clearAlignment();
      expect(controller.highlight, isNull);
    });

    testWidgets('paints the phrases and the highlight', (tester) async {
      final controller = HighlightTextEditingController(text: 'Hello big world')
        ..showAlignment(
          phrases: const [
            TextRange(start: 0, end: 5),
            TextRange(start: 10, end: 15),
          ],
          highlight: const TextRange(start: 10, end: 15),
        );
      addTearDown(controller.dispose);
      final span = await _paint(tester, controller);
      final scheme = Theme.of(tester.element(find.byType(TextField)))
          .colorScheme;
      final parts = span.children!.cast<TextSpan>();
      expect(parts.map((part) => part.text), ['Hello', ' big ', 'world']);
      expect(parts[0].style, AlignedText.phraseStyle(scheme));
      expect(parts[1].style, isNull);
      expect(parts[2].style, AlignedText.focusStyle(scheme));
    });

    testWidgets('paints plain text without an alignment', (tester) async {
      final controller = HighlightTextEditingController(text: 'Hello');
      addTearDown(controller.dispose);
      final span = await _paint(tester, controller);
      expect(span.text, 'Hello');
      expect(span.children, isNull);
    });

    testWidgets('an active composing region wins over the highlight', (
      tester,
    ) async {
      final controller = HighlightTextEditingController(text: 'Hello world')
        ..showAlignment(highlight: const TextRange(start: 0, end: 5));
      addTearDown(controller.dispose);
      controller.value = controller.value.copyWith(
        composing: const TextRange(start: 6, end: 11),
      );
      final span = await _paint(tester, controller);
      final parts = span.children!.cast<TextSpan>();
      expect(parts.map((part) => part.text), ['Hello ', 'world', '']);
      expect(parts[1].style?.decoration, TextDecoration.underline);
      expect(parts[0].style, isNull);
    });
  });

  group('InputCard alignment', () {
    testWidgets('highlights the source phrase of the focused pair', (
      tester,
    ) async {
      final harness = TranslateHarness(state: _aligned(focus: 1));
      await harness.pump(tester, child: const InputCard());
      final controller = _controllerOf(tester);
      expect(controller.highlight, const TextRange(start: 6, end: 11));
      expect(controller.phrases, const [
        TextRange(start: 0, end: 5),
        TextRange(start: 6, end: 11),
      ]);
      expect(
        inputAlignmentHighlight(_aligned(focus: 0), 'Hello world'),
        const TextRange(start: 0, end: 5),
      );
    });

    testWidgets('shows nothing while the alignment is not ready', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: _aligned(focus: 1, status: ExtraStatus.loading),
      );
      await harness.pump(tester, child: const InputCard());
      final controller = _controllerOf(tester);
      expect(controller.highlight, isNull);
      expect(controller.phrases, isEmpty);
    });

    test('ignores an alignment of another text', () {
      expect(inputAlignmentHighlight(_aligned(focus: 0), 'Hello'), isNull);
      expect(inputAlignmentPhrases(_aligned(focus: 0), 'Hello'), isEmpty);
      expect(inputAlignmentHighlight(_aligned(), 'Hello world'), isNull);
    });

    testWidgets('follows the focused pair and clears on an edit', (
      tester,
    ) async {
      final states = StreamController<TranslateState>.broadcast();
      addTearDown(states.close);
      final harness = TranslateHarness(state: translatedState());
      when(() => harness.translate.stream).thenAnswer((_) => states.stream);
      await harness.pump(tester, child: const InputCard());
      final controller = _controllerOf(tester);
      expect(controller.highlight, isNull);

      states.add(_aligned(focus: 0));
      await tester.pump();
      expect(controller.highlight, const TextRange(start: 0, end: 5));

      states.add(_aligned(focus: 1));
      await tester.pump();
      expect(controller.highlight, const TextRange(start: 6, end: 11));

      // A reload hides it until the new alignment is ready.
      states.add(_aligned(focus: 1, status: ExtraStatus.loading));
      await tester.pump();
      expect(controller.highlight, isNull);
      states.add(_aligned(focus: 1));
      await tester.pump();
      expect(controller.highlight, const TextRange(start: 6, end: 11));

      // Typing clears it right away (the cubit resets the alignment too).
      await tester.enterText(
        find.byKey(const Key('translate_input_field')),
        'Hello world!',
      );
      expect(controller.highlight, isNull);
      expect(controller.phrases, isEmpty);
    });

    testWidgets('moving the cursor into a phrase focuses its pair', (
      tester,
    ) async {
      final harness = TranslateHarness(state: _aligned());
      await harness.pump(tester, child: const InputCard());
      final controller = _controllerOf(tester)
        ..selection = const TextSelection.collapsed(offset: 7);
      verify(() => harness.translate.focusAlignment(1)).called(1);

      // Right after a phrase counts as in it.
      controller.selection = const TextSelection.collapsed(offset: 5);
      verify(() => harness.translate.focusAlignment(0)).called(1);

      // A selection or no change of the cursor does nothing.
      controller
        ..selection = const TextSelection(baseOffset: 0, extentOffset: 3)
        ..selection = const TextSelection(baseOffset: 0, extentOffset: 3);
      verifyNever(() => harness.translate.focusAlignment(any()));
    });

    testWidgets('moving the cursor out of every phrase clears the focus', (
      tester,
    ) async {
      final harness = TranslateHarness(state: _aligned(focus: 0));
      await harness.pump(tester, child: const InputCard());
      final controller = _controllerOf(tester)
        // Already focused: nothing to do.
        ..selection = const TextSelection.collapsed(offset: 2);
      verifyNever(() => harness.translate.focusAlignment(any()));

      harness.setState(
        _aligned(focus: 0).copyWith(
          alignment: const [
            AlignedSpan(
              sourceStart: 0,
              sourceEnd: 5,
              targetStart: 0,
              targetEnd: 7,
            ),
          ],
        ),
      );
      controller.selection = const TextSelection.collapsed(offset: 9);
      verify(() => harness.translate.focusAlignment(null)).called(1);
    });

    testWidgets('cursor moves do nothing without an alignment', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const InputCard());
      _controllerOf(tester).selection = const TextSelection.collapsed(
        offset: 2,
      );
      verifyNever(() => harness.translate.focusAlignment(any()));
    });

    test('inputAlignmentIndexAt looks before the cursor too', () {
      final state = _aligned();
      expect(inputAlignmentIndexAt(state, 0), 0);
      expect(inputAlignmentIndexAt(state, 5), 0);
      expect(inputAlignmentIndexAt(state, 6), 1);
      expect(inputAlignmentIndexAt(state, 11), 1);
      expect(inputAlignmentIndexAt(translatedState(), 0), isNull);
    });
  });
}
