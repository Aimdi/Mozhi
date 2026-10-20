import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/quick_translate/quick_translate.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart'
    show TranslateLayout;
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

void main() {
  setUpAll(registerQuickTranslateFallbacks);

  late MockQuickTranslateCubit cubit;

  final done = readyState(translation: result('Bonjour le monde'));

  setUp(() {
    cubit = MockQuickTranslateCubit();
    when(() => cubit.retry()).thenAnswer((_) async {});
    when(() => cubit.setTarget(any())).thenAnswer((_) async {});
    when(() => cubit.selectEngine(any())).thenAnswer((_) async {});
    when(
      () => cubit.pickerLanguages(preferredCodes: any(named: 'preferredCodes')),
    ).thenReturn(
      const QuickLanguages(
        recent: [german],
        common: [english, japanese],
        all: mozhiTargets,
      ),
    );
  });

  void stub(QuickTranslateState state) {
    whenListen(
      cubit,
      const Stream<QuickTranslateState>.empty(),
      initialState: state,
    );
  }

  Finder byKey(String key) => find.byKey(Key(key));

  group('QuickTranslateView', () {
    testWidgets('shows the text, detected language, chips and translation', (
      tester,
    ) async {
      stub(done);
      await tester.pumpQuick(quickView(cubit));

      expect(find.text('Quick translate'), findsOneWidget);
      expect(find.text('Hello world'), findsOneWidget);
      expect(find.text('Detected: English'), findsOneWidget);
      expect(
        find.descendant(
          of: byKey('quick_translate_target_chip'),
          matching: find.byType(LanguageAvatar),
        ),
        findsOneWidget,
      );
      expect(find.text('French'), findsOneWidget);
      expect(find.text('Google'), findsOneWidget);
      expect(find.text('Bonjour le monde'), findsOneWidget);
      expect(byKey('quick_translate_progress'), findsNothing);
      expect(byKey('quick_translate_streaming'), findsNothing);
      // No listen button without a SpeechService.
      expect(byKey('quick_translate_listen'), findsNothing);
    });

    testWidgets('renders in dark mode', (tester) async {
      stub(done);
      await tester.pumpQuick(
        quickView(cubit),
        theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      );
      expect(find.text('Bonjour le monde'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('lays out right-to-left targets right to left', (tester) async {
      stub(readyState(target: arabic, translation: result('مرحبا بالعالم')));
      await tester.pumpQuick(quickView(cubit));
      final text = tester.widget<SelectableText>(
        byKey('quick_translate_translation'),
      );
      expect(text.textDirection, TextDirection.rtl);
    });

    testWidgets('uses a smaller style for long translations', (tester) async {
      final long = List.filled(20, 'Une phrase assez longue.').join(' ');
      stub(
        readyState(
          engine: claude,
          target: const Language.custom('Pirate speak'),
          translation: result(long),
        ),
      );
      await tester.pumpQuick(quickView(cubit));
      final text = tester.widget<SelectableText>(
        byKey('quick_translate_translation'),
      );
      final context = tester.element(byKey('quick_translate_translation'));
      expect(text.style, TranslateLayout.outputTextStyle(context, long.length));
      expect(text.style?.fontSize, 17);
      expect(text.textDirection, isNull);
    });

    testWidgets('shows short translations large, not as a heading', (
      tester,
    ) async {
      stub(readyState(translation: result('Bonjour')));
      await tester.pumpQuick(quickView(cubit));
      final text = tester.widget<SelectableText>(
        byKey('quick_translate_translation'),
      );
      // The translate screen's text style (the bold headline styles of the
      // theme are for headings).
      expect(text.style?.fontSize, 20);
      expect(text.style?.fontWeight, FontWeight.w400);
    });

    group('progress', () {
      testWidgets('while loading engines', (tester) async {
        stub(const QuickTranslateState(text: 'Hello world'));
        await tester.pumpQuick(quickView(cubit));
        expect(byKey('quick_translate_progress'), findsOneWidget);
        expect(find.text('Loading engines…'), findsOneWidget);
      });

      testWidgets('while waiting for the first result', (tester) async {
        stub(readyState(status: QuickTranslateStatus.translating));
        await tester.pumpQuick(quickView(cubit));
        expect(byKey('quick_translate_progress'), findsOneWidget);
        expect(find.text('Translating to French…'), findsOneWidget);
      });

      testWidgets('streams partial results', (tester) async {
        final states = StreamController<QuickTranslateState>();
        addTearDown(states.close);
        final translating = readyState(
          status: QuickTranslateStatus.translating,
        );
        whenListen(cubit, states.stream, initialState: translating);
        await tester.pumpQuick(
          quickView(cubit, canReplace: true, onReplace: (_) {}),
        );

        final partial = readyState(
          status: QuickTranslateStatus.translating,
          translation: result('Bonjour', isComplete: false),
        );
        states.add(partial);
        await tester.pump();
        expect(find.text('Bonjour'), findsOneWidget);
        expect(byKey('quick_translate_streaming'), findsOneWidget);
        // Nothing to copy or replace until the translation is complete.
        expect(
          tester
              .widget<ButtonStyleButton>(byKey('quick_translate_replace'))
              .enabled,
          isFalse,
        );
        expect(
          tester.widget<XActionButton>(byKey('quick_translate_copy')).onPressed,
          isNull,
        );

        states.add(done);
        await tester.pumpAndSettle();
        expect(find.text('Bonjour le monde'), findsOneWidget);
        expect(byKey('quick_translate_streaming'), findsNothing);
        expect(
          tester
              .widget<ButtonStyleButton>(byKey('quick_translate_replace'))
              .enabled,
          isTrue,
        );
      });
    });

    group('error', () {
      testWidgets('shows the error and retries', (tester) async {
        stub(
          readyState(
            status: QuickTranslateStatus.failure,
            error: Exception('boom'),
          ),
        );
        await tester.pumpQuick(quickView(cubit));
        expect(find.text('Something went wrong. Try again.'), findsOneWidget);

        await tester.tap(byKey('quick_translate_retry'));
        verify(() => cubit.retry()).called(1);
      });

      testWidgets('describes known errors', (tester) async {
        stub(
          readyState(
            status: QuickTranslateStatus.failure,
            error: TimeoutException('slow'),
          ),
        );
        await tester.pumpQuick(quickView(cubit));
        expect(find.text('The request timed out. Try again.'), findsOneWidget);
      });

      testWidgets('explains that no engine is available', (tester) async {
        stub(
          const QuickTranslateState(
            text: 'Hello world',
            status: QuickTranslateStatus.noEngines,
          ),
        );
        await tester.pumpQuick(quickView(cubit, onOpenInApp: () {}));
        expect(find.text('No translation engines available'), findsOneWidget);
        expect(byKey('quick_translate_target_chip'), findsNothing);
        expect(byKey('quick_translate_open_in_app'), findsOneWidget);
      });

      testWidgets('reports an empty translation', (tester) async {
        stub(readyState());
        await tester.pumpQuick(quickView(cubit));
        expect(find.text('No translation was returned.'), findsOneWidget);
      });
    });

    group('replace', () {
      testWidgets('is hidden without a replaceable request', (tester) async {
        stub(done);
        await tester.pumpQuick(quickView(cubit, onReplace: (_) {}));
        expect(byKey('quick_translate_replace'), findsNothing);
      });

      testWidgets('is hidden without a callback', (tester) async {
        stub(done);
        await tester.pumpQuick(quickView(cubit, canReplace: true));
        expect(byKey('quick_translate_replace'), findsNothing);
      });

      testWidgets('closes and hands over the translation', (tester) async {
        stub(done);
        final events = <String>[];
        await tester.pumpQuick(
          quickView(
            cubit,
            canReplace: true,
            onReplace: (text) => events.add('replace:$text'),
            onClose: () => events.add('close'),
          ),
        );
        expect(find.text('Replace'), findsOneWidget);

        await tester.tap(byKey('quick_translate_replace'));
        expect(events, ['close', 'replace:Bonjour le monde']);
      });

      testWidgets('is disabled until there is a translation', (tester) async {
        stub(
          readyState(
            status: QuickTranslateStatus.failure,
            error: Exception('boom'),
          ),
        );
        await tester.pumpQuick(
          quickView(cubit, canReplace: true, onReplace: (_) {}),
        );
        expect(
          tester
              .widget<ButtonStyleButton>(byKey('quick_translate_replace'))
              .enabled,
          isFalse,
        );
      });
    });

    group('copy', () {
      String? clipboard;

      setUp(() {
        clipboard = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              if (call.method == 'Clipboard.setData') {
                clipboard =
                    (call.arguments as Map<Object?, Object?>)['text']
                        as String?;
              }
              return null;
            });
      });

      tearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      testWidgets('copies the translation and confirms', (tester) async {
        stub(done);
        await tester.pumpQuick(quickView(cubit));

        await tester.tap(byKey('quick_translate_copy'));
        await tester.pump();
        expect(clipboard, 'Bonjour le monde');
        expect(find.text('Copied'), findsOneWidget);
        expect(
          tester.widget<XActionButton>(byKey('quick_translate_copy')).active,
          isTrue,
        );
        expect(find.text('Copied to clipboard'), findsOneWidget);

        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(find.text('Copied'), findsNothing);
        expect(find.text('Copy'), findsOneWidget);

        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(find.text('Copied to clipboard'), findsNothing);
      });

      testWidgets('copying twice restarts the confirmation', (tester) async {
        stub(done);
        await tester.pumpQuick(
          quickView(cubit, canReplace: true, onReplace: (_) {}),
        );
        await tester.tap(byKey('quick_translate_copy'));
        await tester.pump(const Duration(seconds: 1));
        await tester.tap(byKey('quick_translate_copy'));
        await tester.pump(const Duration(milliseconds: 1500));
        expect(find.text('Copied'), findsOneWidget);
        await tester.pumpAndSettle(const Duration(seconds: 5));
        expect(find.text('Copied'), findsNothing);
      });

      testWidgets('is disabled without a translation', (tester) async {
        stub(readyState(status: QuickTranslateStatus.translating));
        await tester.pumpQuick(quickView(cubit));
        await tester.tap(byKey('quick_translate_copy'));
        await tester.pump();
        expect(clipboard, isNull);
      });
    });

    group('target picker', () {
      testWidgets('opens the compact picker and picks a chip', (tester) async {
        stub(done);
        await tester.pumpQuick(quickView(cubit));

        await tester.tap(byKey('quick_translate_target_chip'));
        await tester.pumpAndSettle();
        expect(byKey('quick_translate_language_panel'), findsOneWidget);
        expect(find.text('Translate to'), findsOneWidget);
        expect(find.text('Recent'), findsOneWidget);
        expect(find.text('Common'), findsOneWidget);
        expect(byKey('quick_translate_copy'), findsNothing);
        verify(
          () => cubit.pickerLanguages(
            preferredCodes: any(named: 'preferredCodes'),
          ),
        ).called(greaterThanOrEqualTo(1));

        await tester.tap(find.widgetWithText(ChoiceChip, 'German'));
        await tester.pumpAndSettle();
        verify(() => cubit.setTarget(german)).called(1);
        expect(byKey('quick_translate_language_panel'), findsNothing);
      });

      testWidgets('back closes the picker', (tester) async {
        stub(done);
        await tester.pumpQuick(quickView(cubit));
        await tester.tap(byKey('quick_translate_target_chip'));
        await tester.pumpAndSettle();

        await tester.tap(byKey('quick_translate_language_back'));
        await tester.pumpAndSettle();
        expect(byKey('quick_translate_language_panel'), findsNothing);
        verifyNever(() => cubit.setTarget(any()));
      });

      testWidgets('system back closes the picker first', (tester) async {
        stub(done);
        await tester.pumpQuick(quickView(cubit));
        await tester.tap(byKey('quick_translate_target_chip'));
        await tester.pumpAndSettle();

        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(byKey('quick_translate_language_panel'), findsNothing);
        expect(find.text('Bonjour le monde'), findsOneWidget);
      });

      testWidgets('searches all languages', (tester) async {
        stub(done);
        await tester.pumpQuick(quickView(cubit));
        await tester.tap(byKey('quick_translate_target_chip'));
        await tester.pumpAndSettle();

        await tester.enterText(byKey('quick_translate_language_search'), 'ja');
        await tester.pump();
        expect(find.text('Recent'), findsNothing);
        expect(find.widgetWithText(ListTile, 'Japanese'), findsOneWidget);
        expect(find.text('日本語'), findsOneWidget);

        await tester.tap(find.widgetWithText(ListTile, 'Japanese'));
        await tester.pumpAndSettle();
        verify(() => cubit.setTarget(japanese)).called(1);
      });

      testWidgets('marks the selected language and clears the search', (
        tester,
      ) async {
        stub(done);
        await tester.pumpQuick(quickView(cubit));
        await tester.tap(byKey('quick_translate_target_chip'));
        await tester.pumpAndSettle();

        await tester.enterText(byKey('quick_translate_language_search'), 'fr');
        await tester.pump();
        expect(
          tester
              .widget<ListTile>(find.widgetWithText(ListTile, 'French'))
              .selected,
          isTrue,
        );
        await tester.tap(find.byTooltip('Clear'));
        await tester.pump();
        expect(find.text('Recent'), findsOneWidget);
      });

      testWidgets('submitting picks the first match', (tester) async {
        stub(done);
        await tester.pumpQuick(quickView(cubit));
        await tester.tap(byKey('quick_translate_target_chip'));
        await tester.pumpAndSettle();

        await tester.showKeyboard(byKey('quick_translate_language_search'));
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pump();
        verifyNever(() => cubit.setTarget(any()));

        await tester.enterText(byKey('quick_translate_language_search'), 'ger');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        verify(() => cubit.setTarget(german)).called(1);
      });

      testWidgets('reports no matches on Mozhi engines', (tester) async {
        stub(done);
        await tester.pumpQuick(quickView(cubit));
        await tester.tap(byKey('quick_translate_target_chip'));
        await tester.pumpAndSettle();

        await tester.enterText(
          byKey('quick_translate_language_search'),
          'Pirate',
        );
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pump();
        expect(find.text('No languages match “Pirate”'), findsOneWidget);
        expect(byKey('quick_translate_custom_language'), findsNothing);
        verifyNever(() => cubit.setTarget(any()));
      });

      testWidgets('offers custom targets on AI engines', (tester) async {
        stub(readyState(engine: claude, translation: result('Bonjour')));
        await tester.pumpQuick(quickView(cubit));
        await tester.tap(byKey('quick_translate_target_chip'));
        await tester.pumpAndSettle();

        await tester.enterText(
          byKey('quick_translate_language_search'),
          'Pirate speak',
        );
        await tester.pump();
        await tester.tap(byKey('quick_translate_custom_language'));
        await tester.pumpAndSettle();
        verify(() => cubit.setTarget(const Language.custom('Pirate speak')))
            .called(1);
      });

      testWidgets('submitting a custom target on AI engines', (tester) async {
        stub(readyState(engine: claude, translation: result('Bonjour')));
        await tester.pumpQuick(quickView(cubit));
        await tester.tap(byKey('quick_translate_target_chip'));
        await tester.pumpAndSettle();

        await tester.enterText(
          byKey('quick_translate_language_search'),
          'Yoda',
        );
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        verify(() => cubit.setTarget(const Language.custom('Yoda'))).called(1);
      });

      testWidgets('is unavailable before an engine is selected', (
        tester,
      ) async {
        stub(const QuickTranslateState(text: 'Hello world'));
        await tester.pumpQuick(quickView(cubit));
        await tester.tap(byKey('quick_translate_target_chip'));
        await tester.pump();
        expect(byKey('quick_translate_language_panel'), findsNothing);
      });
    });

    testWidgets('selects another engine from the menu', (tester) async {
      stub(done);
      await tester.pumpQuick(quickView(cubit));

      await tester.tap(byKey('quick_translate_engine_chip'));
      await tester.pumpAndSettle();
      expect(byKey('quick_translate_engine_ai:claude'), findsOneWidget);
      expect(find.text('claude-opus-5-5'), findsOneWidget);

      await tester.tap(byKey('quick_translate_engine_mozhi:deepl'));
      await tester.pumpAndSettle();
      verify(() => cubit.selectEngine(deepl)).called(1);
      expect(byKey('quick_translate_engine_mozhi:deepl'), findsNothing);
    });

    testWidgets('tapping the engine chip again closes the menu', (
      tester,
    ) async {
      stub(done);
      await tester.pumpQuick(quickView(cubit));
      await tester.tap(byKey('quick_translate_engine_chip'));
      await tester.pumpAndSettle();
      await tester.tap(byKey('quick_translate_engine_chip'));
      await tester.pumpAndSettle();
      expect(byKey('quick_translate_engine_mozhi:deepl'), findsNothing);
    });

    group('source text', () {
      testWidgets('collapses long text and expands on demand', (tester) async {
        final long = List.filled(40, 'A rather long sentence.').join(' ');
        stub(readyState(text: long, translation: result('Bonjour')));
        await tester.pumpQuick(quickView(cubit));

        Text source() =>
            tester.widget<Text>(byKey('quick_translate_source_text'));
        expect(source().maxLines, 2);
        expect(find.byTooltip('Show more'), findsOneWidget);

        await tester.tap(byKey('quick_translate_source_toggle'));
        await tester.pumpAndSettle();
        expect(source().maxLines, isNull);
        expect(find.byTooltip('Show less'), findsOneWidget);

        await tester.tap(byKey('quick_translate_source_toggle'));
        await tester.pumpAndSettle();
        expect(source().maxLines, 2);
      });

      testWidgets('has no toggle for short text', (tester) async {
        stub(done);
        await tester.pumpQuick(quickView(cubit));
        expect(byKey('quick_translate_source_toggle'), findsNothing);
      });

      testWidgets('hides the detected language until known', (tester) async {
        stub(readyState(status: QuickTranslateStatus.translating));
        await tester.pumpQuick(quickView(cubit));
        expect(byKey('quick_translate_detected'), findsNothing);
      });
    });

    group('listen', () {
      late MockSpeechService speech;
      late StreamController<String?> speaking;

      setUp(() {
        speech = MockSpeechService();
        speaking = StreamController<String?>.broadcast();
        when(() => speech.speaking).thenAnswer((_) => speaking.stream);
        when(
          () => speech.toggle(
            id: any(named: 'id'),
            text: any(named: 'text'),
            languageCode: any(named: 'languageCode'),
          ),
        ).thenAnswer((_) async {});
      });

      tearDown(() => speaking.close());

      testWidgets('reads the translation aloud and stops', (tester) async {
        stub(done);
        await tester.pumpQuick(quickView(cubit, speech: speech));
        expect(findTooltipMessage(listenTooltip('Listen')), findsOneWidget);

        await tester.tap(byKey('quick_translate_listen'));
        await tester.pump();
        verify(
          () => speech.toggle(
            id: QuickListenButton.defaultId,
            text: 'Bonjour le monde',
            languageCode: 'fr',
          ),
        ).called(1);

        speaking.add(QuickListenButton.defaultId);
        await tester.pump();
        await tester.pump();
        expect(findTooltipMessage(listenTooltip('Stop')), findsOneWidget);

        speaking.add('other');
        await tester.pump();
        await tester.pump();
        expect(findTooltipMessage(listenTooltip('Listen')), findsOneWidget);
      });

      testWidgets('stops playback when closed', (tester) async {
        stub(done);
        await tester.pumpQuick(quickView(cubit, speech: speech));
        speaking.add(QuickListenButton.defaultId);
        await tester.pump();
        await tester.pump();

        await tester.pumpWidget(const SizedBox());
        verify(
          () => speech.toggle(
            id: QuickListenButton.defaultId,
            text: 'Bonjour le monde',
            languageCode: any(named: 'languageCode'),
          ),
        ).called(1);
      });

      testWidgets('shows a notice when audio fails', (tester) async {
        when(
          () => speech.toggle(
            id: any(named: 'id'),
            text: any(named: 'text'),
            languageCode: any(named: 'languageCode'),
          ),
        ).thenThrow(Exception('no audio'));
        stub(done);
        await tester.pumpQuick(quickView(cubit, speech: speech));

        await tester.tap(byKey('quick_translate_listen'));
        await tester.pump();
        expect(find.text("Couldn't play audio."), findsOneWidget);
        await tester.pumpAndSettle(const Duration(seconds: 5));
        expect(find.text("Couldn't play audio."), findsNothing);
      });

      testWidgets('a long press reads slowly; failures show a notice', (
        tester,
      ) async {
        when(
          () => speech.speak(
            id: any(named: 'id'),
            text: any(named: 'text'),
            languageCode: any(named: 'languageCode'),
            slow: any(named: 'slow'),
          ),
        ).thenThrow(Exception('no audio'));
        stub(done);
        await tester.pumpQuick(quickView(cubit, speech: speech));

        await tester.longPress(byKey('quick_translate_listen'));
        await tester.pump();
        verify(
          () => speech.speak(
            id: QuickListenButton.defaultId,
            text: 'Bonjour le monde',
            languageCode: 'fr',
            slow: true,
          ),
        ).called(1);
        expect(find.text("Couldn't play audio."), findsOneWidget);
        await tester.pumpAndSettle(const Duration(seconds: 5));
      });

      testWidgets('is disabled for custom targets', (tester) async {
        stub(
          readyState(
            engine: claude,
            target: const Language.custom('Pirate speak'),
            translation: result('Ahoy'),
          ),
        );
        await tester.pumpQuick(quickView(cubit, speech: speech));
        expect(
          tester.widget<IconButton>(byKey('quick_translate_listen')).onPressed,
          isNull,
        );
      });

      testWidgets('follows a replaced speech service', (tester) async {
        await tester.pumpQuick(
          QuickListenButton(
            speech: speech,
            text: 'Bonjour',
            languageCode: 'fr',
          ),
        );
        final other = MockSpeechService();
        final otherSpeaking = StreamController<String?>.broadcast();
        addTearDown(otherSpeaking.close);
        when(() => other.speaking).thenAnswer((_) => otherSpeaking.stream);
        when(
          () => other.toggle(
            id: any(named: 'id'),
            text: any(named: 'text'),
            languageCode: any(named: 'languageCode'),
          ),
        ).thenAnswer((_) async {});
        await tester.pumpQuick(
          QuickListenButton(speech: other, text: 'Bonjour', languageCode: 'fr'),
        );
        otherSpeaking.add(QuickListenButton.defaultId);
        await tester.pump();
        await tester.pump();
        expect(
          tester.widget<IconButton>(byKey('quick_translate_listen')).isSelected,
          isTrue,
        );
        expect(speaking.hasListener, isFalse);
      });
    });

    testWidgets('open in app closes first', (tester) async {
      stub(done);
      final events = <String>[];
      await tester.pumpQuick(
        quickView(
          cubit,
          onOpenInApp: () => events.add('open'),
          onClose: () => events.add('close'),
        ),
      );
      await tester.tap(find.text('Open in app'));
      expect(events, ['close', 'open']);
    });

    testWidgets('close button closes', (tester) async {
      stub(done);
      var closed = 0;
      await tester.pumpQuick(quickView(cubit, onClose: () => closed++));
      await tester.tap(find.byTooltip('Close'));
      expect(closed, 1);
      expect(byKey('quick_translate_open_in_app'), findsNothing);
    });
  });
}
