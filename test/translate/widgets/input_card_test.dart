import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/image_translate/view/image_translate_page.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:mozhi/usage/usage.dart';
import 'package:mozhi/voice/voice.dart';
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

    group('keyboard learning', () {
      bool learning(WidgetTester tester) => tester
          .widget<TextField>(find.byKey(const Key('translate_input_field')))
          .enableIMEPersonalizedLearning;

      testWidgets('is allowed normally', (tester) async {
        final harness = TranslateHarness();
        await harness.pump(tester, child: const InputCard());
        expect(learning(tester), isTrue);
      });

      testWidgets('is off while incognito', (tester) async {
        final harness = TranslateHarness(
          settings: const AppSettings(incognito: true),
        );
        await harness.pump(tester, child: const InputCard());
        expect(learning(tester), isFalse);
      });
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
      final states = StreamController<TranslateState>.broadcast();
      addTearDown(states.close);
      final harness = TranslateHarness(state: readyState(input: 'Helo'));
      when(() => harness.translate.stream).thenAnswer((_) => states.stream);
      await harness.pump(tester, child: const InputCard());
      final finder = find.byKey(const Key('translate_input_field'));
      final controller = tester.widget<TextField>(finder).controller!
        ..value = const TextEditingValue(
          text: 'Hello',
          selection: TextSelection.collapsed(offset: 4),
        );
      // The cubit echoes the typed text back.
      states.add(readyState(input: 'Hello'));
      await tester.pump();
      expect(controller.text, 'Hello');
      expect(controller.selection.baseOffset, 4);
    });

    testWidgets('has no translate button of its own', (tester) async {
      // The go button at the end of the language bar replaces it, also
      // while instant translation is off.
      final harness = TranslateHarness(
        state: readyState(engine: claude, input: 'Hi'),
        settings: const AppSettings(
          instantTranslate: false,
          instantTranslateAi: false,
        ),
      );
      await harness.pump(tester, child: const InputCard());
      expect(find.byKey(const Key('translate_translate_button')), findsNothing);
    });

    testWidgets('listen reads the input in the detected language', (
      tester,
    ) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const InputCard());
      await tester.tap(findListenTooltip('Listen'));
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
      await tester.tap(findListenTooltip('Listen'));
      await tester.pump();
      expect(find.text("Couldn't play audio."), findsOneWidget);
    });

    testWidgets('shows a stop button while the source is playing', (
      tester,
    ) async {
      final harness = TranslateHarness(state: translatedState());
      when(() => harness.speech.current).thenReturn('source');
      await harness.pump(tester, child: const InputCard());
      expect(findListenTooltip('Stop'), findsOneWidget);
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

    group('length limit', () {
      Finder field() => find.byKey(const Key('translate_input_field'));

      testWidgets('limits the field without a counter of its own', (
        tester,
      ) async {
        final harness = TranslateHarness(state: readyState(input: 'Hi'));
        await harness.pump(tester, child: const InputCard());
        expect(
          tester.widget<TextField>(field()).maxLength,
          TranslateCubit.maxInputLength,
        );
        expect(
          find.textContaining('/${TranslateCubit.maxInputLength}'),
          findsNothing,
        );
        // The card's own count is kept.
        expect(find.text('2 characters'), findsOneWidget);
      });

      testWidgets('passes overlong text on whole so the cubit can cut it', (
        tester,
      ) async {
        final harness = TranslateHarness();
        await harness.pump(tester, child: const InputCard());
        final long = 'a' * (TranslateCubit.maxInputLength + 5);
        await tester.enterText(field(), long);
        verify(() => harness.translate.setInput(long)).called(1);
        expect(
          tester.widget<TextField>(field()).controller!.text,
          hasLength(TranslateCubit.maxInputLength),
        );

        // The next edit within the limit is passed on as typed.
        await tester.enterText(field(), 'Hello');
        verify(() => harness.translate.setInput('Hello')).called(1);
      });

      testWidgets('shows a notice when the input was shortened', (
        tester,
      ) async {
        final harness = TranslateHarness(
          state: readyState(input: 'a' * TranslateCubit.maxInputLength)
              .copyWith(inputTruncated: true),
        );
        await harness.pump(tester, child: const InputCard());
        const message =
            'Text shortened to the maximum length of 20,000 characters.';
        expect(find.text(message), findsOneWidget);
        final announcer = tester.widget<StatusAnnouncer>(
          find.ancestor(
            of: find.byKey(const Key('translate_input_truncated')),
            matching: find.byType(StatusAnnouncer),
          ),
        );
        expect(announcer.message, message);
        expect(announcer.announceInitial, isTrue);
      });

      testWidgets('names the shorter limit for text from other apps', (
        tester,
      ) async {
        final harness = TranslateHarness(
          state: readyState(input: 'a' * TranslateCubit.maxExternalInputLength)
              .copyWith(inputTruncated: true),
        );
        await harness.pump(tester, child: const InputCard());
        expect(
          find.text(
            'Text shortened to the maximum length of 5,000 characters.',
          ),
          findsOneWidget,
        );
      });

      testWidgets('shows no notice for complete input', (tester) async {
        final harness = TranslateHarness(state: readyState(input: 'Hi'));
        await harness.pump(tester, child: const InputCard());
        expect(
          find.byKey(const Key('translate_input_truncated')),
          findsNothing,
        );
      });

      test('truncatedInputLimit tells the two limits apart', () {
        expect(
          truncatedInputLimit(readyState(input: 'a' * 4999)),
          TranslateCubit.maxExternalInputLength,
        );
        expect(
          truncatedInputLimit(readyState(input: 'a' * 19999)),
          TranslateCubit.maxInputLength,
        );
      });
    });

    group('token estimate', () {
      final long = 'word ' * 200;

      testWidgets('is shown next to the count for AI engines', (tester) async {
        final harness = TranslateHarness(
          state: readyState(engine: claude, input: long),
        );
        await harness.pump(tester, child: const InputCard());
        final label = tester.widget<TokenEstimateLabel>(
          find.byKey(const Key('translate_token_estimate')),
        );
        expect(label.text, long);
        expect(find.textContaining('tokens'), findsOneWidget);
      });

      testWidgets('renders nothing for short texts', (tester) async {
        final harness = TranslateHarness(
          state: readyState(engine: claude, input: 'Hello'),
        );
        await harness.pump(tester, child: const InputCard());
        expect(find.byType(TokenEstimateLabel), findsOneWidget);
        expect(find.textContaining('tokens'), findsNothing);
      });

      testWidgets('is not shown for Mozhi engines', (tester) async {
        final harness = TranslateHarness(state: readyState(input: long));
        await harness.pump(tester, child: const InputCard());
        expect(find.byType(TokenEstimateLabel), findsNothing);
      });
    });

    group('voice input', () {
      Finder mic() => find.descendant(
        of: find.byKey(const Key('translate_voice_input')),
        matching: find.byType(IconButton),
      );

      testWidgets('is not offered without a speech service', (tester) async {
        final harness = TranslateHarness();
        await harness.pump(tester, child: const InputCard());
        expect(find.byType(VoiceInputButton), findsNothing);
      });

      testWidgets('dictates in the source language and appends the text', (
        tester,
      ) async {
        final speech = FakeSpeechInput();
        final harness = TranslateHarness(
          state: readyState(input: 'Hello', source: english),
          speechInput: speech.service,
        );
        await harness.pump(tester, child: const InputCard());
        expect(mic(), findsOneWidget);
        expect(find.byTooltip('Speak'), findsOneWidget);

        await tester.tap(mic());
        await tester.pump();
        expect(speech.languages, ['en']);
        expect(find.byTooltip('Stop listening'), findsOneWidget);

        speech.say('wor');
        await tester.pump();
        verify(() => harness.translate.setInput('Hello wor')).called(1);
        speech.say('world', isFinal: true);
        await tester.pump();
        verify(() => harness.translate.setInput('Hello world')).called(1);
        final field = tester.widget<TextField>(
          find.byKey(const Key('translate_input_field')),
        );
        expect(field.controller!.text, 'Hello world');

        // A later utterance of the same session follows the first.
        speech.say('again', isFinal: true);
        await tester.pump();
        verify(() => harness.translate.setInput('Hello world again')).called(1);
        speech.finish();
        await tester.pump();
        expect(find.byTooltip('Speak'), findsOneWidget);
      });

      testWidgets('fills an empty input and ignores silence', (tester) async {
        final speech = FakeSpeechInput();
        final harness = TranslateHarness(speechInput: speech.service);
        await harness.pump(tester, child: const InputCard());
        await tester.tap(mic());
        await tester.pump();
        // `auto` lets the device pick the recognition language.
        expect(speech.languages, ['auto']);
        speech.say('  ');
        await tester.pump();
        verifyNever(() => harness.translate.setInput(any()));
        speech.say('Bonjour', isFinal: true);
        await tester.pump();
        verify(() => harness.translate.setInput('Bonjour')).called(1);
      });

      testWidgets('does not add a space after trailing whitespace', (
        tester,
      ) async {
        final speech = FakeSpeechInput();
        final harness = TranslateHarness(
          state: readyState(input: 'Line\n'),
          speechInput: speech.service,
        );
        await harness.pump(tester, child: const InputCard());
        await tester.tap(mic());
        await tester.pump();
        speech.say('two', isFinal: true);
        await tester.pump();
        verify(() => harness.translate.setInput('Line\ntwo')).called(1);
      });
    });

    group('image translation', () {
      testWidgets('opens the image translator', (tester) async {
        final harness = TranslateHarness();
        await harness.pump(tester, child: const InputCard());
        final button = find.byKey(const Key('translate_image_button'));
        expect(button, findsOneWidget);
        expect(find.byTooltip('Translate an image'), findsOneWidget);
        await tester.tap(button);
        verify(() => harness.router.push<Object?>(ImageTranslatePage.location))
            .called(1);
      });

      testWidgets('keeps 48 dp targets next to the other actions', (
        tester,
      ) async {
        final harness = TranslateHarness(
          state: readyState(input: 'Hello'),
          speechInput: FakeSpeechInput().service,
        );
        await harness.pump(tester, child: const InputCard());
        for (final key in ['translate_image_button', 'translate_voice_input']) {
          final size = tester.getSize(find.byKey(Key(key)));
          expect(size.width, greaterThanOrEqualTo(48), reason: key);
          expect(size.height, greaterThanOrEqualTo(48), reason: key);
        }
      });
    });
  });
}
