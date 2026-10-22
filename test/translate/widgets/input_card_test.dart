import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/image_translate/view/image_translate_page.dart';
import 'package:mozhi/l10n/gen/app_localizations_en.dart';
import 'package:mozhi/l10n/l10n.dart';
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
      verify(() => harness.translate.setInput('Guten Tag', pasted: true))
          .called(1);
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
        verify(() => harness.translate.setInput('Hello wor', dictated: true))
            .called(1);
        speech.say('world', isFinal: true);
        await tester.pump();
        verify(() => harness.translate.setInput('Hello world', dictated: true))
            .called(1);
        final field = tester.widget<TextField>(
          find.byKey(const Key('translate_input_field')),
        );
        expect(field.controller!.text, 'Hello world');

        // A later utterance of the same session follows the first.
        speech.say('again', isFinal: true);
        await tester.pump();
        verify(
          () => harness.translate.setInput('Hello world again', dictated: true),
        ).called(1);
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
        verify(() => harness.translate.setInput('Bonjour', dictated: true))
            .called(1);
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
        verify(() => harness.translate.setInput('Line\ntwo', dictated: true))
            .called(1);
      });
    });

    group('multiline input', () {
      Finder field() => find.byKey(const Key('translate_input_field'));

      TextField textField(WidgetTester tester) =>
          tester.widget<TextField>(field());

      Future<TranslateHarness> pump(
        WidgetTester tester, {
        bool multiline = true,
        String input = 'Hello',
      }) async {
        final harness = TranslateHarness(
          state: readyState(input: input),
          settings: AppSettings(multilineInput: multiline),
        );
        await harness.pump(tester, child: const InputCard());
        await tester.showKeyboard(field());
        await tester.pump();
        return harness;
      }

      testWidgets('on (the default): Enter adds a new line', (tester) async {
        final harness = await pump(tester);

        expect(textField(tester).textInputAction, TextInputAction.newline);
        expect(textField(tester).keyboardType, TextInputType.multiline);
        expect(textField(tester).onSubmitted, isNull);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();

        verifyNever(harness.translate.translate);
      });

      testWidgets('off: the keyboard shows a go key that translates', (
        tester,
      ) async {
        final harness = await pump(tester, multiline: false);

        expect(textField(tester).textInputAction, TextInputAction.go);
        // Still multiline: pasted text keeps its lines, Shift+Enter adds one.
        expect(textField(tester).keyboardType, TextInputType.multiline);
        await tester.testTextInput.receiveAction(TextInputAction.go);
        await tester.pump();

        verify(harness.translate.translate).called(1);
      });

      testWidgets('off: a hardware Enter translates', (tester) async {
        final harness = await pump(tester, multiline: false);

        final handled = await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        verify(harness.translate.translate).called(1);
        expect(handled, isTrue);

        await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
        await tester.pump();
        verify(harness.translate.translate).called(1);
      });

      testWidgets('off: a held Enter translates once and adds no lines', (
        tester,
      ) async {
        final harness = await pump(tester, multiline: false);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
        final repeat = await tester.sendKeyRepeatEvent(
          LogicalKeyboardKey.enter,
        );
        await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
        await tester.pump();

        expect(repeat, isTrue);
        verify(harness.translate.translate).called(1);
      });

      testWidgets('off: the go key keeps the keyboard open', (tester) async {
        await pump(tester, multiline: false);

        await tester.testTextInput.receiveAction(TextInputAction.go);
        await tester.pump();

        expect(textField(tester).focusNode?.hasFocus, isTrue);
      });

      testWidgets('off: Shift with the keyboard action adds a new line '
          '(browsers report every Enter as the action)', (tester) async {
        final harness = await pump(tester, multiline: false);
        await tester.tap(field());
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'Hello',
            selection: TextSelection.collapsed(offset: 5),
          ),
        );
        await tester.pump();
        clearInteractions(harness.translate);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.testTextInput.receiveAction(TextInputAction.go);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();

        verifyNever(harness.translate.translate);
        verify(() => harness.translate.setInput('Hello\n')).called(1);
        final controller = textField(tester).controller!;
        expect(controller.text, 'Hello\n');
        expect(controller.selection, const TextSelection.collapsed(offset: 6));
      });

      testWidgets('off: Ctrl with the keyboard action is left to the '
          'screen shortcut', (tester) async {
        final harness = await pump(tester, multiline: false);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.testTextInput.receiveAction(TextInputAction.go);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();

        verifyNever(harness.translate.translate);
      });

      testWidgets('off: Shift+Enter is left to the field (a new line)', (
        tester,
      ) async {
        final harness = await pump(tester, multiline: false);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        final handled = await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();

        expect(handled, isFalse);
        verifyNever(harness.translate.translate);
      });

      testWidgets('off: Ctrl+Enter is left to the screen shortcut', (
        tester,
      ) async {
        final harness = await pump(tester, multiline: false);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        final handled = await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();

        expect(handled, isFalse);
        verifyNever(harness.translate.translate);
      });

      testWidgets('off: Enter confirms what an input method composes', (
        tester,
      ) async {
        final harness = await pump(tester, multiline: false, input: '');
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'にほ',
            selection: TextSelection.collapsed(offset: 2),
            composing: TextRange(start: 0, end: 2),
          ),
        );
        await tester.pump();

        final handled = await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();

        expect(handled, isFalse);
        verifyNever(harness.translate.translate);
      });

      testWidgets('off: Enter does nothing without input', (tester) async {
        final harness = await pump(tester, multiline: false, input: '  ');

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.testTextInput.receiveAction(TextInputAction.go);
        await tester.pump();

        verifyNever(harness.translate.translate);
      });

      testWidgets('Esc still clears the field', (tester) async {
        final harness = await pump(tester, multiline: false);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();

        verify(harness.translate.clear).called(1);
      });
    });

    group('empty composer (compact)', () {
      Finder link() => find.byKey(const Key('translate_paste_link'));
      Finder hint() => find.byKey(const Key('translate_composer_hint'));
      Finder field() => find.byKey(const Key('translate_input_field'));

      RenderParagraph sentence(WidgetTester tester) =>
          tester.renderObject<RenderParagraph>(
            find.descendant(of: hint(), matching: find.byType(RichText)),
          );

      /// The centre of the drawn word "paste" (characters 8 to 13).
      Offset wordCentre(WidgetTester tester) {
        final paragraph = sentence(tester);
        final box = paragraph
            .getBoxesForSelection(
              const TextSelection(baseOffset: 8, extentOffset: 13),
            )
            .single;
        return paragraph.localToGlobal(box.toRect().center);
      }

      bool fieldFocused(WidgetTester tester) =>
          tester.widget<TextField>(field()).focusNode!.hasFocus;

      testWidgets('reads "Type or paste text" with "paste" as the link', (
        tester,
      ) async {
        final harness = TranslateHarness();
        await harness.pump(tester, child: const InputCard(compact: true));
        expect(
          find.text('Type or paste text', findRichText: true),
          findsOneWidget,
        );
        expect(find.text('Enter text'), findsNothing);
        // The link replaces the paste icon; no tools row.
        expect(find.byKey(const Key('translate_paste_button')), findsNothing);
        expect(find.byKey(const Key('translate_input_toolbar')), findsNothing);
        // Only "paste" is in the accent colour.
        final span = sentence(tester).text as TextSpan;
        final parts = span.children!.cast<TextSpan>();
        final accent = Theme.of(tester.element(hint())).colorScheme.primary;
        expect(parts.map((part) => part.text), ['Type or ', 'paste', ' text']);
        expect(parts[1].style?.color, accent);
        expect(span.style?.color, isNot(accent));
        // A 48 dp target on the word.
        final target = tester.getRect(link());
        expect(target.height, greaterThanOrEqualTo(48));
        expect(target.width, greaterThanOrEqualTo(48));
        expect(target.center.dx, closeTo(wordCentre(tester).dx, 0.5));
        expect(target.center.dy, closeTo(wordCentre(tester).dy, 0.5));
        // Where the field's own hint would be.
        expect(
          tester.getTopLeft(hint()),
          tester.getTopLeft(find.byType(EditableText)) - const Offset(0, 14),
        );
      });

      testWidgets('the link pastes the clipboard', (tester) async {
        final clipboard = FakeClipboard(tester, pasteText: 'Guten Tag');
        final harness = TranslateHarness();
        await harness.pump(tester, child: const InputCard(compact: true));
        await tester.tap(link());
        await tester.pump();
        verify(() => harness.translate.setInput('Guten Tag', pasted: true))
            .called(1);
        expect(
          tester.widget<TextField>(field()).controller!.text,
          clipboard.pasteText,
        );
        // The text replaces the placeholder; a tap does not focus the
        // field (no keyboard).
        expect(hint(), findsNothing);
        expect(fieldFocused(tester), isFalse);
      });

      testWidgets('from the keyboard the field takes the focus after '
          'pasting', (tester) async {
        FakeClipboard(tester, pasteText: 'Guten Tag');
        final harness = TranslateHarness();
        await harness.pump(tester, child: const InputCard(compact: true));
        tester
            .widget<InkWell>(
              find.descendant(of: link(), matching: find.byType(InkWell)),
            )
            .focusNode!
            .requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        verify(() => harness.translate.setInput('Guten Tag', pasted: true))
            .called(1);
        expect(fieldFocused(tester), isTrue);
      });

      testWidgets('an empty clipboard changes nothing', (tester) async {
        FakeClipboard(tester);
        final harness = TranslateHarness();
        await harness.pump(tester, child: const InputCard(compact: true));
        await tester.tap(link());
        await tester.pump();
        verifyNever(() => harness.translate.setInput(any()));
        expect(hint(), findsOneWidget);
      });

      testWidgets('taps beside the link reach the field', (tester) async {
        FakeClipboard(tester, pasteText: 'Guten Tag');
        final harness = TranslateHarness();
        await harness.pump(tester, child: const InputCard(compact: true));
        // On "Type" and far after "text".
        for (final offset in [const Offset(8, 26), const Offset(300, 26)]) {
          await tester.tapAt(tester.getTopLeft(hint()) + offset);
          await tester.pump();
          expect(fieldFocused(tester), isTrue, reason: '$offset');
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pump();
        }
        verifyNever(() => harness.translate.setInput(any()));
      });

      testWidgets('hides the placeholder while there is text or a '
          'composition', (tester) async {
        final harness = TranslateHarness();
        await harness.pump(tester, child: const InputCard(compact: true));
        Future<void> show(TextEditingValue value) async {
          tester.widget<TextField>(field()).controller!.value = value;
          await tester.pump();
        }

        await show(const TextEditingValue(text: 'Hi'));
        expect(hint(), findsNothing);
        await show(TextEditingValue.empty);
        expect(hint(), findsOneWidget);
        // An input method starting a composition.
        await show(const TextEditingValue(composing: TextRange.collapsed(0)));
        expect(hint(), findsNothing);
      });

      testWidgets('is not shown outside the empty composer', (tester) async {
        final harness = TranslateHarness();
        await harness.pump(tester, child: const InputCard());
        expect(hint(), findsNothing);
        expect(find.text('Enter text'), findsOneWidget);
      });

      testWidgets('screen readers get the field name and a Paste button', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        final harness = TranslateHarness();
        await harness.pump(tester, child: const InputCard(compact: true));
        expect(find.bySemanticsLabel('Text to translate'), findsOneWidget);
        expect(find.bySemanticsLabel(RegExp('Type or')), findsNothing);
        expect(
          tester.getSemantics(link()),
          isSemantics(
            label: 'Paste',
            isButton: true,
            isFocusable: true,
            hasTapAction: true,
          ),
        );
        handle.dispose();
      });

      testWidgets('lies on the word in a right-to-left UI', (tester) async {
        FakeClipboard(tester, pasteText: 'Guten Tag');
        final harness = TranslateHarness();
        await harness.pump(
          tester,
          child: const InputCard(compact: true),
          locale: const Locale('ar'),
        );
        final paragraph = sentence(tester);
        expect(paragraph.textDirection, TextDirection.rtl);
        final parts = (paragraph.text as TextSpan).children!.cast<TextSpan>();
        final start = parts[0].text!.length;
        final box = paragraph
            .getBoxesForSelection(
              TextSelection(
                baseOffset: start,
                extentOffset: start + parts[1].text!.length,
              ),
            )
            .single;
        final centre = paragraph.localToGlobal(box.toRect().center);
        expect(tester.getCenter(link()).dx, closeTo(centre.dx, 0.5));
        await tester.tap(link());
        await tester.pump();
        verify(() => harness.translate.setInput('Guten Tag', pasted: true))
            .called(1);
      });
    });

    group('an unreadable clipboard', () {
      void failClipboard(WidgetTester tester, Exception error) {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.getData') throw error;
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
      }

      const message =
          "Couldn't read the clipboard. Paste into the text field instead.";

      testWidgets('(a browser refusing it) is reported and the field takes '
          'the focus', (tester) async {
        failClipboard(tester, PlatformException(code: 'paste_fail'));
        final harness = TranslateHarness();
        await harness.pump(tester, child: const InputCard());
        await tester.tap(find.byTooltip('Paste'));
        await tester.pump();
        expect(find.text(message), findsOneWidget);
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('translate_input_field')))
              .focusNode!
              .hasFocus,
          isTrue,
        );
        verifyNever(() => harness.translate.setInput(any()));
      });

      testWidgets('the placeholder link reports it the same way', (
        tester,
      ) async {
        failClipboard(tester, PlatformException(code: 'paste_fail'));
        final harness = TranslateHarness();
        await harness.pump(tester, child: const InputCard(compact: true));
        await tester.tap(find.byKey(const Key('translate_paste_link')));
        await tester.pump();
        expect(find.text(message), findsOneWidget);
        verifyNever(() => harness.translate.setInput(any()));
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

  group('InputCard (wave 2)', () {
    group('character count', () {
      const limit = TranslateCubit.maxInputLength;

      testWidgets('shows only the count, without a ring, far from the limit', (
        tester,
      ) async {
        final harness = TranslateHarness(state: readyState(input: 'Hello'));
        await harness.pump(tester, child: const InputCard());
        expect(find.text('5 characters'), findsOneWidget);
        expect(find.byType(CountRing), findsNothing);
      });

      testWidgets('shows the count with the limit and the ring near it', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        final near = 'a' * (limit * 4 ~/ 5);
        final harness = TranslateHarness(state: readyState(input: near));
        await harness.pump(tester, child: const InputCard());
        expect(find.text('16,000 / 20,000'), findsOneWidget);
        expect(
          find.bySemanticsLabel('16,000 of 20,000 characters'),
          findsOneWidget,
        );
        final ring = tester.widget<CountRing>(find.byType(CountRing));
        expect(ring.count, near.length);
        expect(ring.limit, limit);
        handle.dispose();
      });
    });

    group('tapping outside', () {
      Future<FocusNode> pumpFocused(
        WidgetTester tester,
        TranslateHarness harness,
      ) async {
        final focus = FocusNode();
        addTearDown(focus.dispose);
        await harness.pump(
          tester,
          child: Column(
            children: [
              InputCard(focusNode: focus),
              const SizedBox(key: Key('outside'), width: 200, height: 200),
            ],
          ),
        );
        focus.requestFocus();
        await tester.pump();
        expect(focus.hasFocus, isTrue);
        return focus;
      }

      testWidgets('an empty field gives up the focus', (tester) async {
        final harness = TranslateHarness();
        final focus = await pumpFocused(tester, harness);
        await tester.tapAt(
          // A touch, as on Android.
          tester.getCenter(find.byKey(const Key('outside'))),
        );
        await tester.pump();
        expect(focus.hasFocus, isFalse);
      });

      testWidgets('a field with text keeps it on Android (touch)', (
        tester,
      ) async {
        final harness = TranslateHarness(state: readyState(input: 'Hello'));
        final focus = await pumpFocused(tester, harness);
        await tester.tapAt(
          // A touch, as on Android.
          tester.getCenter(find.byKey(const Key('outside'))),
        );
        await tester.pump();
        expect(focus.hasFocus, isTrue);
      });

      testWidgets('a field with text keeps the default for a mouse', (
        tester,
      ) async {
        final harness = TranslateHarness(state: readyState(input: 'Hello'));
        final focus = await pumpFocused(tester, harness);
        await tester.tapAt(
          tester.getCenter(find.byKey(const Key('outside'))),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        expect(focus.hasFocus, isFalse);
      });

      testWidgets('a tap on the card itself is not outside', (tester) async {
        final harness = TranslateHarness();
        final focus = await pumpFocused(tester, harness);
        await tester.tap(find.byKey(const Key('translate_paste_button')));
        await tester.pump();
        expect(focus.hasFocus, isTrue);
      });
    });

    group("the field's own paste", () {
      testWidgets('Ctrl+V marks the edit as a paste', (tester) async {
        FakeClipboard(tester, pasteText: 'Guten Tag');
        final harness = TranslateHarness();
        await harness.pump(tester, child: const InputCard());
        await tester.tap(find.byKey(const Key('translate_input_field')));
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        verify(() => harness.translate.setInput('Guten Tag', pasted: true))
            .called(1);
      });

      testWidgets('the context menu Paste marks the edit as a paste', (
        tester,
      ) async {
        FakeClipboard(tester, pasteText: 'Guten Tag');
        final harness = TranslateHarness();
        await harness.pump(tester, child: const InputCard());
        final field = find.byKey(const Key('translate_input_field'));
        await tester.longPress(field);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Paste'));
        await tester.pumpAndSettle();
        verify(() => harness.translate.setInput('Guten Tag', pasted: true))
            .called(1);
        // Typing afterwards is typing again.
        await tester.enterText(field, 'Guten Tag!');
        verify(() => harness.translate.setInput('Guten Tag!')).called(1);
      });
    });
  });

  group('translateComposerHintParts', () {
    test('splits the sentence around the link', () async {
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      final parts = translateComposerHintParts(l10n);
      expect(parts.before, 'Type or ');
      expect(parts.link, 'paste');
      expect(parts.after, ' text');
    });

    test("follows the translation's word order", () {
      final parts = translateComposerHintParts(
        _ComposerHint('Text tippen oder {paste}'),
      );
      expect(parts.before, 'Text tippen oder ');
      expect(parts.link, 'paste');
      expect(parts.after, '');
    });

    test('puts the link last when a translation lost it', () {
      final parts = translateComposerHintParts(_ComposerHint('Type text'));
      expect(parts.before, 'Type text ');
      expect(parts.link, 'paste');
      expect(parts.after, '');
    });
  });
}

/// English strings with [pattern] as the composer's placeholder (`{paste}`
/// marks the link).
class _ComposerHint extends AppLocalizationsEn {
  new(this.pattern);

  final String pattern;

  @override
  String translateComposerHint(String paste) =>
      pattern.replaceAll('{paste}', paste);
}
