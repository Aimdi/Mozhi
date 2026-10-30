import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

final Finder _field = find.byKey(const Key('translate_input_field'));
final Finder _card = find.byKey(const Key('word_lookup_sheet'));

EditableTextState _editable(WidgetTester tester) => tester.state(
  find.descendant(of: _field, matching: find.byType(EditableText)),
);

/// Selects [start] to [end] of the input and shows the field's menu.
Future<void> _select(WidgetTester tester, int start, int end) async {
  final editable = _editable(tester);
  editable.userUpdateTextEditingValue(
    editable.textEditingValue.copyWith(
      selection: TextSelection(baseOffset: start, extentOffset: end),
    ),
    SelectionChangedCause.keyboard,
  );
  await tester.pump();
  editable.showToolbar();
  await tester.pumpAndSettle();
}

String? _headword(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const Key('word_lookup_headword')))
    .textSpan
    ?.toPlainText();

void main() {
  setUpAll(registerTranslateFallbacks);

  group('InputCard "Look up"', () {
    testWidgets('opens the card of the selected word, in the source '
        'language', (tester) async {
      final harness = TranslateHarness(
        state: readyState(input: 'Hello big world', source: english),
      );
      await harness.pump(tester, child: const InputCard());
      await _select(tester, 6, 9);
      // The system's items stay.
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Cut'), findsOneWidget);
      expect(find.text('Look up'), findsOneWidget);

      await tester.tap(find.text('Look up'));
      await tester.pumpAndSettle();
      expect(_card, findsOneWidget);
      expect(_headword(tester), 'big');
      // The menu is gone and the text is unchanged.
      expect(find.text('Copy'), findsNothing);
      expect(_editable(tester).textEditingValue.text, 'Hello big world');
      verifyNever(() => harness.translate.setInput(any()));
    });

    testWidgets('looks up a short phrase, trimmed', (tester) async {
      final harness = TranslateHarness(
        state: readyState(input: 'Hello big world', source: english),
      );
      await harness.pump(tester, child: const InputCard());
      await _select(tester, 5, 15);
      await tester.tap(find.text('Look up'));
      await tester.pumpAndSettle();
      expect(_headword(tester), 'big world');
    });

    testWidgets('uses the detected language with "Detect language"', (
      tester,
    ) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const InputCard());
      await _select(tester, 6, 11);
      await tester.tap(find.text('Look up'));
      await tester.pumpAndSettle();
      expect(_headword(tester), 'world');
    });

    testWidgets('is not offered without a known language', (tester) async {
      final harness = TranslateHarness(
        state: readyState(input: 'Hello big world'),
      );
      await harness.pump(tester, child: const InputCard());
      await _select(tester, 6, 9);
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Look up'), findsNothing);

      harness.setState(
        readyState(
          input: 'Hello big world',
          source: const Language.custom('Pirate'),
        ),
      );
      await _select(tester, 0, 5);
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Look up'), findsNothing);
    });

    testWidgets('is not offered for long selections or no word', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: readyState(input: 'one two three four !!', source: english),
      );
      await harness.pump(tester, child: const InputCard());
      await _select(tester, 0, 18);
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Look up'), findsNothing);
      await _select(tester, 19, 21);
      expect(find.text('Look up'), findsNothing);
      await _select(tester, 0, 13);
      expect(find.text('Look up'), findsOneWidget);
    });

    testWidgets('a tap still puts the cursor in the field', (tester) async {
      final harness = TranslateHarness(
        state: readyState(input: 'Hello big world', source: english),
      );
      await harness.pump(tester, child: const InputCard());
      await tester.tap(_field);
      await tester.pumpAndSettle();
      expect(_card, findsNothing);
      final value = _editable(tester).textEditingValue;
      expect(value.selection.isCollapsed, isTrue);
      expect(_editable(tester).widget.focusNode.hasFocus, isTrue);
    });
  });
}
