import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

void main() {
  setUpAll(registerTranslateFallbacks);

  group('InputCard', () {
    testWidgets('typing calls setInput', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const InputCard());
      await tester.enterText(
        find.byKey(const Key('translate_input_field')),
        'Hello',
      );
      verify(() => harness.translate.setInput('Hello')).called(1);
    });

    testWidgets('shows the hint and a paste button when empty', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const InputCard());
      expect(find.text('Enter text'), findsOneWidget);
      expect(find.byTooltip('Paste'), findsOneWidget);
      expect(find.byTooltip('Clear'), findsNothing);
    });

    testWidgets('paste puts clipboard text into the input', (tester) async {
      final clipboard = FakeClipboard(tester, pasteText: 'Guten Tag');
      final harness = TranslateHarness();
      await harness.pump(tester, child: const InputCard());
      await tester.tap(find.byTooltip('Paste'));
      await tester.pump();
      verify(() => harness.translate.setInput('Guten Tag')).called(1);
      final field = tester.widget<TextField>(
        find.byKey(const Key('translate_input_field')),
      );
      expect(field.controller!.text, clipboard.pasteText);
    });

    testWidgets('paste ignores an empty clipboard', (tester) async {
      FakeClipboard(tester);
      final harness = TranslateHarness();
      await harness.pump(tester, child: const InputCard());
      await tester.tap(find.byTooltip('Paste'));
      await tester.pump();
      verifyNever(() => harness.translate.setInput(any()));
    });

    testWidgets('clear button clears the input', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const InputCard());
      expect(find.text('11 characters'), findsOneWidget);
      await tester.tap(find.byTooltip('Clear'));
      verify(harness.translate.clear).called(1);
      final field = tester.widget<TextField>(
        find.byKey(const Key('translate_input_field')),
      );
      expect(field.controller!.text, isEmpty);
    });

    testWidgets('keeps the field in sync with external input changes', (
      tester,
    ) async {
      final harness = TranslateHarness(state: readyState(input: 'Hello'));
      whenListen(
        harness.translate,
        Stream.fromIterable([readyState(input: 'Shared text')]),
        initialState: readyState(input: 'Hello'),
      );
      await harness.pump(tester, child: const InputCard());
      await tester.pump();
      final field = tester.widget<TextField>(
        find.byKey(const Key('translate_input_field')),
      );
      expect(field.controller!.text, 'Shared text');
      expect(
        field.controller!.selection,
        const TextSelection.collapsed(offset: 11),
      );
    });

    testWidgets('typing does not reset the cursor', (tester) async {
      final harness = TranslateHarness(state: readyState(input: 'Helo'));
      await harness.pump(tester, child: const InputCard());
      final finder = find.byKey(const Key('translate_input_field'));
      final controller = tester.widget<TextField>(finder).controller!;
      controller.value = const TextEditingValue(
        text: 'Hello',
        selection: TextSelection.collapsed(offset: 4),
      );
      // The cubit echoes the same text back.
      harness.setState(readyState(input: 'Hello'));
      await tester.pump();
      expect(controller.selection.baseOffset, 4);
    });

    testWidgets('hides the translate button when instant translate is on', (
      tester,
    ) async {
      final harness = TranslateHarness(state: readyState(input: 'Hi'));
      await harness.pump(tester, child: const InputCard());
      expect(find.byKey(const Key('translate_translate_button')), findsNothing);
    });

    testWidgets('translate button translates when instant is off for AI', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: readyState(engine: claude, input: 'Hi'),
      );
      await harness.pump(tester, child: const InputCard());
      await tester.tap(find.byKey(const Key('translate_translate_button')));
      verify(harness.translate.translate).called(1);
    });

    testWidgets('translate button is disabled without input', (tester) async {
      final harness = TranslateHarness(
        settings: const AppSettings(instantTranslate: false),
      );
      await harness.pump(tester, child: const InputCard());
      final button = tester.widget<ButtonStyleButton>(
        find.byKey(const Key('translate_translate_button')),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('listen reads the input in the detected language', (
      tester,
    ) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const InputCard());
      await tester.tap(find.byTooltip('Listen'));
      verify(
        () => harness.speech.toggle(
          id: 'source',
          text: 'Hello world',
          languageCode: 'en',
        ),
      ).called(1);
    });

    testWidgets('listen shows a snackbar when playback fails', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      when(
        () => harness.speech.toggle(
          id: any(named: 'id'),
          text: any(named: 'text'),
          languageCode: any(named: 'languageCode'),
        ),
      ).thenThrow(Exception('offline'));
      await harness.pump(tester, child: const InputCard());
      await tester.tap(find.byTooltip('Listen'));
      await tester.pump();
      expect(find.text("Couldn't play audio."), findsOneWidget);
    });

    testWidgets('shows a stop button while the source is playing', (
      tester,
    ) async {
      final harness = TranslateHarness(state: translatedState());
      when(() => harness.speech.current).thenReturn('source');
      await harness.pump(tester, child: const InputCard());
      expect(find.byTooltip('Stop'), findsOneWidget);
    });

    testWidgets('listen is disabled while the language is unknown', (
      tester,
    ) async {
      final harness = TranslateHarness(state: readyState(input: 'Hola'));
      await harness.pump(tester, child: const InputCard());
      final button = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.volume_up_outlined),
          matching: find.byType(IconButton),
        ),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('shows the source transliteration', (tester) async {
      final harness = TranslateHarness(
        state: translatedState(
          input: 'こんにちは',
          result: const TranslationResult(
            engineId: 'mozhi:google',
            engineName: 'Google',
            text: 'Hello',
            sourceTransliteration: "Kon'nichiwa",
          ),
        ),
      );
      await harness.pump(tester, child: const InputCard());
      expect(find.text("Kon'nichiwa"), findsOneWidget);
    });
  });
}
