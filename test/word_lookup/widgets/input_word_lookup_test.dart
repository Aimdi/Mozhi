import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/word_lookup/word_lookup.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers.dart';

TextEditingValue _selected(String text, int start, int end) => TextEditingValue(
  text: text,
  selection: TextSelection(baseOffset: start, extentOffset: end),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('inputWordLookupLanguage', () {
    test('is the source language', () {
      expect(
        inputWordLookupLanguage(const TranslateState(source: spanish)),
        spanish,
      );
    });

    test('is the detected one with "Detect language"', () {
      const detected = TranslateState(
        result: TranslationResult(
          engineId: 'e',
          engineName: 'E',
          text: 'cat',
          detectedSource: 'es',
        ),
      );
      expect(inputWordLookupLanguage(detected)?.code, 'es');
      expect(inputWordLookupLanguage(const TranslateState()), isNull);
      expect(
        inputWordLookupLanguage(
          const TranslateState(
            result: TranslationResult(
              engineId: 'e',
              engineName: 'E',
              text: 'cat',
              detectedSource: ' ',
            ),
          ),
        ),
        isNull,
      );
    });

    test('is null for a custom language', () {
      expect(
        inputWordLookupLanguage(
          const TranslateState(source: Language.custom('Pirate')),
        ),
        isNull,
      );
    });
  });

  group('inputWordLookupInto', () {
    test('is the target language, unless auto or custom', () {
      expect(
        inputWordLookupInto(const TranslateState(source: spanish)),
        english,
      );
      expect(
        inputWordLookupInto(const TranslateState(target: Language.auto)),
        isNull,
      );
      expect(
        inputWordLookupInto(
          const TranslateState(target: Language.custom('Pirate')),
        ),
        isNull,
      );
    });
  });

  group('inputSelectedWord', () {
    test('is the selected word or phrase, trimmed, with its offsets', () {
      expect(
        inputSelectedWord(_selected('el gato negro', 2, 8)),
        const TextWord(3, 7, 'gato'),
      );
      expect(
        inputSelectedWord(_selected('el gato negro', 0, 13)),
        const TextWord(0, 13, 'el gato negro'),
      );
      // Backwards selections too.
      expect(
        inputSelectedWord(_selected('el gato negro', 7, 3)),
        const TextWord(3, 7, 'gato'),
      );
      expect(
        inputSelectedWord(_selected('猫が好きです', 0, 1)),
        const TextWord(0, 1, '猫'),
      );
    });

    test('is null without a word', () {
      expect(inputSelectedWord(const TextEditingValue(text: 'gato')), isNull);
      expect(inputSelectedWord(_selected('gato', 2, 2)), isNull);
      expect(inputSelectedWord(_selected('gato ?!', 4, 7)), isNull);
      expect(inputSelectedWord(_selected('a b c d', 0, 7)), isNull);
      expect(inputSelectedWord(_selected('gato', 0, 9)), isNull);
      final long = 'a' * (WordLookupCubit.maxWordLength + 1);
      expect(inputSelectedWord(_selected(long, 0, long.length)), isNull);
      // A sentence without spaces is no word.
      const sentence = '私は毎朝公園で犬と一緒に長い散歩をします';
      expect(
        inputSelectedWord(_selected(sentence, 0, sentence.length)),
        isNull,
      );
    });
  });

  group('WebFieldContextMenu', () {
    late List<bool> switched;
    late FocusNode focus;

    Future<void> record({required bool enabled}) async => switched.add(enabled);

    setUp(() {
      switched = [];
      focus = FocusNode();
    });

    tearDown(() => focus.dispose());

    testWidgets('turns the browser menu off while the field is used', (
      tester,
    ) async {
      final menu = WebFieldContextMenu(
        focusNode: focus,
        web: true,
        switchMenu: record,
      );
      await tester.pumpWidget(Focus(focusNode: focus, child: const SizedBox()));
      expect(menu.isOff, isFalse);

      menu.onPointerDown(const PointerDownEvent());
      expect(menu.isOff, isTrue);
      expect(switched, [false]);
      // Once.
      menu.onPointerDown(const PointerDownEvent());
      expect(switched, [false]);

      focus.requestFocus();
      await tester.pump();
      menu.onPointerUp(const PointerUpEvent());
      await tester.pump(WebFieldContextMenu.settle);
      // Kept off while focused.
      expect(switched, [false]);

      focus.unfocus();
      await tester.pump();
      expect(switched, [false, true]);
      expect(menu.isOff, isFalse);

      // Focus alone turns it off too.
      focus.requestFocus();
      await tester.pump();
      expect(switched, [false, true, false]);
      menu.dispose();
      expect(switched, [false, true, false, true]);
      // Nothing after dispose.
      menu.onPointerDown(const PointerDownEvent());
      expect(switched, hasLength(4));
    });

    testWidgets('a pointer that did not focus the field gives it back', (
      tester,
    ) async {
      final menu = WebFieldContextMenu(
        focusNode: focus,
        web: true,
        switchMenu: record,
      );
      addTearDown(menu.dispose);
      await tester.pumpWidget(Focus(focusNode: focus, child: const SizedBox()));
      menu
        ..onPointerUp(const PointerUpEvent())
        ..onPointerDown(const PointerDownEvent())
        ..onPointerUp(const PointerUpEvent());
      expect(switched, [false]);
      await tester.pump(WebFieldContextMenu.settle);
      expect(switched, [false, true]);
    });

    testWidgets('does nothing off the web', (tester) async {
      final menu = WebFieldContextMenu(focusNode: focus, switchMenu: record);
      await tester.pumpWidget(Focus(focusNode: focus, child: const SizedBox()));
      menu.onPointerDown(const PointerDownEvent());
      focus.requestFocus();
      await tester.pump();
      focus.unfocus();
      await tester.pump();
      menu.dispose();
      expect(switched, isEmpty);
      expect(menu.web, isFalse);
    });
  });
}
