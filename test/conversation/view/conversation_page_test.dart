import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/view/top_level_actions.dart';
import 'package:mozhi/conversation/conversation.dart';
import 'package:mozhi/conversation/widgets/widgets.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/no_engines_view.dart';
import 'package:mozhi/usage/usage.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers.dart';

class _MockUsageTracker extends Mock implements UsageTracker;

void main() {
  setUpAll(registerConversationFallbacks);

  late MockTranslateCubit translate;
  late MockSettingsCubit settings;
  late MockTranslationRepository repository;
  late MockSpeechService speech;
  late StreamController<String?> speaking;
  late List<String> clipboard;

  setUp(() {
    translate = MockTranslateCubit();
    settings = MockSettingsCubit();
    repository = MockTranslationRepository();
    speech = MockSpeechService();
    speaking = stubSpeech(speech);
    when(() => translate.state).thenReturn(translateState());
    when(() => settings.state).thenReturn(const AppSettings());
    when(() => repository.translate(any(), any()))
        .thenAnswer((_) => Stream.value(resultOf('Hola')));

    clipboard = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            final arguments = call.arguments as Map<Object?, Object?>;
            clipboard.add(arguments['text']! as String);
          }
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    await speaking.close();
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    ConversationMicBuilder? micBuilder,
    ConversationShareCallback? share,
    Size size = const Size(400, 800),
    ThemeData? theme,
    UsageTracker? usageTracker,
  }) => tester.pumpConversation(
    share == null
        ? ConversationPage(micBuilder: micBuilder)
        : ConversationPage(micBuilder: micBuilder, share: share),
    translate: translate,
    settings: settings,
    repository: repository,
    speech: speech,
    usageTracker: usageTracker,
    size: size,
    theme: theme,
  );

  Future<void> send(
    WidgetTester tester,
    ConversationSide side,
    String text,
  ) async {
    await tester.enterText(
      find.byKey(Key('conversation_input_${side.name}')),
      text,
    );
    await tester.pump();
    await tester.tap(find.byKey(Key('conversation_send_${side.name}')));
    await tester.pumpAndSettle();
  }

  Future<void> openMenuItem(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(const Key('conversation_menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  group('standard layout', () {
    testWidgets('shows the hero, the language pill and two composers', (
      tester,
    ) async {
      await pumpPage(tester);
      expect(
        find.byKey(const Key('conversation_standard_layout')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('conversation_hero')), findsOneWidget);
      expect(find.text("Let's talk!"), findsOneWidget);
      // Without voice input it explains typing instead of the microphone.
      expect(
        find.text(
          'Type or use the microphone. Each message is translated for the '
          'other person.',
        ),
        findsOneWidget,
      );
      expect(find.text('Tap the microphone to start or stop'), findsNothing);
      // The pair as one pill: A, swap, B.
      final pill = find.byKey(const Key('conversation_language_pill'));
      for (final key in [
        'conversation_language_a',
        'conversation_swap',
        'conversation_language_b',
      ]) {
        expect(
          find.descendant(of: pill, matching: find.byKey(Key(key))),
          findsOneWidget,
        );
      }
      expect(
        tester.getCenter(find.byKey(const Key('conversation_language_a'))).dx,
        lessThan(
          tester.getCenter(find.byKey(const Key('conversation_language_b'))).dx,
        ),
      );
      // The pill sits between the hero and the composers.
      expect(
        tester.getCenter(pill).dy,
        lessThan(
          tester.getCenter(find.byKey(const Key('conversation_input_a'))).dy,
        ),
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('conversation_language_a')),
          matching: find.text('English'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('conversation_language_b')),
          matching: find.text('Spanish'),
        ),
        findsOneWidget,
      );
      expect(find.text('Type in English'), findsOneWidget);
      expect(find.text('Type in Spanish'), findsOneWidget);
      expect(find.byType(RotatedBox), findsNothing);
      // Engine selector in the app bar.
      expect(find.text('DeepL'), findsOneWidget);
    });

    testWidgets('sending from either side translates in that direction', (
      tester,
    ) async {
      await pumpPage(tester);
      await send(tester, ConversationSide.a, 'Hello');

      expect(find.text('Hello'), findsOneWidget);
      expect(find.text('Hola'), findsOneWidget);
      final first =
          verify(() => repository.translate(deepl, captureAny()))
                  .captured
                  .single
              as TranslationRequest;
      expect(first.source, english);
      expect(first.target, spanish);
      final field = tester.widget<TextField>(
        find.byKey(const Key('conversation_input_a')),
      );
      expect(field.controller!.text, isEmpty);

      when(() => repository.translate(any(), any()))
          .thenAnswer((_) => Stream.value(resultOf('Thanks')));
      await send(tester, ConversationSide.b, 'Gracias');
      final second =
          verify(() => repository.translate(deepl, captureAny()))
                  .captured
                  .single
              as TranslationRequest;
      expect(second.source, spanish);
      expect(second.target, english);
      expect(find.text('Thanks'), findsOneWidget);
      expect(find.byType(ConversationTurnBubble), findsNWidgets(2));
    });

    testWidgets('styles messages like direct messages', (tester) async {
      await pumpPage(tester);
      await send(tester, ConversationSide.a, 'Hello');
      when(() => repository.translate(any(), any()))
          .thenAnswer((_) => Stream.value(resultOf('Thanks')));
      await send(tester, ConversationSide.b, 'Gracias');
      final scheme = Theme.of(
        tester.element(find.byType(ConversationTurnBubble).first),
      ).colorScheme;
      Color bubbleOf(String text) => tester
          .widget<Material>(
            find
                .ancestor(of: find.text(text), matching: find.byType(Material))
                .first,
          )
          .color!;
      // Side A sits at the start in a neutral bubble, side B at the end in
      // the primary container.
      expect(bubbleOf('Hello'), scheme.surfaceContainerHigh);
      expect(bubbleOf('Gracias'), scheme.primaryContainer);
      expect(
        tester.getCenter(find.text('Hello')).dx,
        lessThan(tester.getCenter(find.text('Gracias')).dx),
      );
      // Each message carries its speaker's language avatar.
      expect(
        find.descendant(
          of: find.byType(ConversationTurnBubble),
          matching: find.byType(LanguageAvatar),
        ),
        findsNWidgets(2),
      );
    });

    testWidgets('the keyboard send action submits', (tester) async {
      await pumpPage(tester);
      await tester.enterText(
        find.byKey(const Key('conversation_input_b')),
        'Buenos días',
      );
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      verify(() => repository.translate(any(), any())).called(1);
      expect(find.text('Buenos días'), findsOneWidget);
    });

    testWidgets('send is disabled for blank text and without an engine', (
      tester,
    ) async {
      when(() => translate.state).thenReturn(
        translateState(engine: null, enginesStatus: EnginesStatus.loading),
      );
      await pumpPage(tester);
      IconButton sendButton() => tester.widget<IconButton>(
        find.byKey(const Key('conversation_send_a')),
      );
      expect(sendButton().onPressed, isNull);

      await tester.enterText(
        find.byKey(const Key('conversation_input_a')),
        'Hello',
      );
      await tester.pump();
      expect(sendButton().onPressed, isNull);
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      verifyNever(() => repository.translate(any(), any()));
      // The text is kept for later.
      expect(find.text('Hello'), findsOneWidget);
    });

    testWidgets('lays the composers side by side on wide screens', (
      tester,
    ) async {
      await pumpPage(tester, size: const Size(1200, 800));
      final a = tester.getCenter(find.byKey(const Key('conversation_input_a')));
      final b = tester.getCenter(find.byKey(const Key('conversation_input_b')));
      expect(a.dy, b.dy);
      expect(a.dx, lessThan(b.dx));
      expect(find.text('Conversation'), findsOneWidget);
    });

    testWidgets('stacks the composers on phones', (tester) async {
      await pumpPage(tester);
      final a = tester.getCenter(find.byKey(const Key('conversation_input_a')));
      final b = tester.getCenter(find.byKey(const Key('conversation_input_b')));
      expect(a.dy, lessThan(b.dy));
    });

    testWidgets('shows the no-engines view when nothing is configured', (
      tester,
    ) async {
      when(() => translate.state)
          .thenReturn(translateState(engine: null, engines: const []));
      await pumpPage(tester);
      expect(find.byType(NoEnginesView), findsOneWidget);
      expect(find.text('Conversation'), findsOneWidget);
      expect(find.byKey(const Key('conversation_menu')), findsNothing);
    });

    testWidgets('shows the no-engines view when loading engines failed', (
      tester,
    ) async {
      when(() => translate.state).thenReturn(
        translateState(
          engine: null,
          engines: const [],
          enginesStatus: EnginesStatus.failure,
        ),
      );
      await pumpPage(tester);
      expect(find.byType(NoEnginesView), findsOneWidget);
    });

    testWidgets('keeps the conversation while engines load', (tester) async {
      when(() => translate.state).thenReturn(
        translateState(
          engine: null,
          engines: const [],
          enginesStatus: EnginesStatus.loading,
        ),
      );
      await pumpPage(tester);
      expect(find.byType(NoEnginesView), findsNothing);
      expect(
        find.byKey(const Key('conversation_standard_layout')),
        findsOneWidget,
      );
    });

    testWidgets('renders in dark mode', (tester) async {
      await pumpPage(
        tester,
        theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      );
      await send(tester, ConversationSide.a, 'Hello');
      expect(tester.takeException(), isNull);
      expect(find.text('Hola'), findsOneWidget);
    });
  });

  group('face-to-face layout', () {
    testWidgets('turns side B upside down and back', (tester) async {
      await pumpPage(tester);
      await send(tester, ConversationSide.a, 'Hello');

      await tester.tap(find.byKey(const Key('conversation_layout_toggle')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('conversation_face_to_face_layout')),
        findsOneWidget,
      );
      expect(find.byType(AppBar), findsNothing);
      final rotated = tester.widget<RotatedBox>(
        find.byKey(const Key('conversation_rotated_half')),
      );
      expect(rotated.quarterTurns, 2);
      expect(
        find.descendant(
          of: find.byKey(const Key('conversation_rotated_half')),
          matching: find.byKey(const Key('conversation_panel_b')),
        ),
        findsOneWidget,
      );
      expect(
        find.ancestor(
          of: find.byKey(const Key('conversation_panel_a')),
          matching: find.byType(RotatedBox),
        ),
        findsNothing,
      );
      // Side B's half sits above side A's.
      expect(
        tester.getCenter(find.byKey(const Key('conversation_panel_b'))).dy,
        lessThan(
          tester.getCenter(find.byKey(const Key('conversation_panel_a'))).dy,
        ),
      );
      // Each half shows the message, from its own point of view.
      expect(find.text('Hello'), findsNWidgets(2));
      expect(find.text('Hola'), findsNWidgets(2));
      expect(find.text('Type in English'), findsOneWidget);
      expect(find.text('Type in Spanish'), findsOneWidget);

      await tester.tap(find.byKey(const Key('conversation_layout_toggle')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('conversation_standard_layout')),
        findsOneWidget,
      );
      expect(find.byType(RotatedBox), findsNothing);
    });

    testWidgets('side B types into its own half', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.byKey(const Key('conversation_layout_toggle')));
      await tester.pumpAndSettle();
      await send(tester, ConversationSide.b, 'Gracias');
      final request =
          verify(() => repository.translate(any(), captureAny()))
                  .captured
                  .single
              as TranslationRequest;
      expect(request.source, spanish);
      expect(request.target, english);
    });

    testWidgets('the language picker of side B is turned around', (
      tester,
    ) async {
      await pumpPage(tester);
      await tester.tap(find.byKey(const Key('conversation_layout_toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('conversation_language_b')));
      await tester.pumpAndSettle();
      expect(
        find.ancestor(
          of: find.byType(ConversationLanguagePicker),
          matching: find.byType(RotatedBox),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('German'));
      await tester.pumpAndSettle();
      expect(find.text('Type in German'), findsOneWidget);

      await tester.tap(find.byKey(const Key('conversation_language_a')));
      await tester.pumpAndSettle();
      expect(
        find.ancestor(
          of: find.byType(ConversationLanguagePicker),
          matching: find.byType(RotatedBox),
        ),
        findsNothing,
      );
    });
  });

  group('languages', () {
    testWidgets('the picker changes a side and records a recent language', (
      tester,
    ) async {
      await pumpPage(tester);
      await tester.tap(find.byKey(const Key('conversation_language_a')));
      await tester.pumpAndSettle();
      expect(find.text('Choose a language'), findsOneWidget);
      await tester.tap(find.text('French'));
      await tester.pumpAndSettle();
      expect(find.text('Type in French'), findsOneWidget);
      verify(() => settings.addRecentLanguage(french)).called(1);
    });

    testWidgets('dismissing the picker keeps the language', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.byKey(const Key('conversation_language_a')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Type in English'), findsOneWidget);
      verifyNever(() => settings.addRecentLanguage(any()));
    });

    testWidgets('falls back to the catalogue without engine languages', (
      tester,
    ) async {
      when(() => translate.state)
          .thenReturn(translateState(targetLanguages: const []));
      await pumpPage(tester);
      await tester.tap(find.byKey(const Key('conversation_language_b')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('conversation_language_search')),
        'japan',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Japanese'));
      await tester.pumpAndSettle();
      expect(find.text('Type in Japanese'), findsOneWidget);
    });

    testWidgets('swap exchanges the languages', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.byKey(const Key('conversation_swap')));
      await tester.pump();
      final a = tester.getCenter(find.text('Type in Spanish'));
      final b = tester.getCenter(find.text('Type in English'));
      expect(a.dy, lessThan(b.dy));
    });
  });

  group('voice input', () {
    testWidgets('builds a mic per side; final dictation is sent', (
      tester,
    ) async {
      final requests = <ConversationSide, ConversationMicRequest>{};
      await pumpPage(
        tester,
        micBuilder: (context, request) {
          if (!request.prominent) requests[request.side] = request;
          return IconButton(
            key: Key(
              'mic_${request.side.name}${request.prominent ? '_hero' : ''}',
            ),
            onPressed: () {},
            icon: const Icon(Icons.mic),
          );
        },
      );
      expect(find.byKey(const Key('mic_a')), findsOneWidget);
      expect(find.byKey(const Key('mic_b')), findsOneWidget);
      expect(requests[ConversationSide.a]!.language, english);
      expect(requests[ConversationSide.b]!.language, spanish);
      expect(requests[ConversationSide.b]!.owner, ConversationSide.b);

      requests[ConversationSide.b]!.onResult('Buenos', isFinal: false);
      await tester.pump();
      expect(find.text('Buenos'), findsOneWidget);
      verifyNever(() => repository.translate(any(), any()));

      requests[ConversationSide.b]!.onResult('Buenos días', isFinal: true);
      await tester.pumpAndSettle();
      final request =
          verify(() => repository.translate(any(), captureAny()))
                  .captured
                  .single
              as TranslationRequest;
      expect(request.text, 'Buenos días');
      expect(request.source, spanish);
      final field = tester.widget<TextField>(
        find.byKey(const Key('conversation_input_b')),
      );
      expect(field.controller!.text, isEmpty);
    });

    testWidgets('a blank final result sends nothing', (tester) async {
      late ConversationMicRequest request;
      await pumpPage(
        tester,
        micBuilder: (context, value) {
          if (value.side == ConversationSide.a && !value.prominent) {
            request = value;
          }
          return const SizedBox.shrink();
        },
      );
      request.onResult('  ', isFinal: true);
      await tester.pump();
      verifyNever(() => repository.translate(any(), any()));
    });

    testWidgets('dictation after the composer is gone is ignored', (
      tester,
    ) async {
      late ConversationMicRequest request;
      await pumpPage(
        tester,
        micBuilder: (context, value) {
          if (value.side == ConversationSide.a && !value.prominent) {
            request = value;
          }
          return const SizedBox.shrink();
        },
      );
      await tester.pumpWidget(const SizedBox());
      request.onResult('Hello', isFinal: true);
      verifyNever(() => repository.translate(any(), any()));
    });
  });

  group('hero microphone', () {
    ConversationMicRequest? hero;

    Future<void> pumpWithMics(WidgetTester tester) => pumpPage(
      tester,
      micBuilder: (context, request) {
        if (request.prominent) hero = request;
        return IconButton(
          key: Key(
            'mic_${request.side.name}${request.prominent ? '_hero' : ''}',
          ),
          onPressed: () {},
          icon: const Icon(Icons.mic),
        );
      },
    );

    setUp(() => hero = null);

    testWidgets('is a prominent mic for the first language', (tester) async {
      await pumpWithMics(tester);
      expect(find.text("Let's talk!"), findsOneWidget);
      expect(find.text('Tap the microphone to start or stop'), findsOneWidget);
      expect(find.text('Speak English'), findsOneWidget);
      expect(find.byKey(const Key('mic_a_hero')), findsOneWidget);
      expect(hero!.side, ConversationSide.a);
      expect(hero!.language, english);
      // Its own owner token: it never reacts to side A's composer mic.
      expect(hero!.owner, isNot(ConversationSide.a));
      expect(identical(hero!.owner, hero!.owner), isTrue);
      // The hero sits above the language pill.
      expect(
        tester.getCenter(find.byKey(const Key('mic_a_hero'))).dy,
        lessThan(
          tester
              .getCenter(find.byKey(const Key('conversation_language_pill')))
              .dy,
        ),
      );
    });

    testWidgets('shows what is heard and sends it from side A', (tester) async {
      await pumpWithMics(tester);
      hero!.onResult('Good', isFinal: false);
      await tester.pump();
      expect(find.text('Good'), findsOneWidget);
      expect(find.text('Tap the microphone to start or stop'), findsNothing);
      verifyNever(() => repository.translate(any(), any()));

      hero!.onResult('Good morning', isFinal: true);
      await tester.pumpAndSettle();
      final request =
          verify(() => repository.translate(any(), captureAny()))
                  .captured
                  .single
              as TranslationRequest;
      expect(request.text, 'Good morning');
      expect(request.source, english);
      expect(request.target, spanish);
      // The transcript replaces the hero.
      expect(find.byKey(const Key('conversation_hero')), findsNothing);
      expect(find.byType(ConversationTurnBubble), findsOneWidget);
    });

    testWidgets('sends nothing for silence or without an engine', (
      tester,
    ) async {
      await pumpWithMics(tester);
      hero!.onResult('  ', isFinal: true);
      await tester.pump();
      expect(find.text('Tap the microphone to start or stop'), findsOneWidget);

      when(() => translate.state).thenReturn(
        translateState(
          engine: null,
          engines: const [],
          enginesStatus: EnginesStatus.loading,
        ),
      );
      hero!.onResult('Hello', isFinal: true);
      await tester.pump();
      verifyNever(() => repository.translate(any(), any()));
    });

    testWidgets('follows the first language', (tester) async {
      await pumpWithMics(tester);
      await tester.tap(find.byKey(const Key('conversation_swap')));
      await tester.pump();
      expect(find.text('Speak Spanish'), findsOneWidget);
      expect(hero!.language, spanish);
    });
  });

  group('translations', () {
    testWidgets('streams AI output with progress', (tester) async {
      when(() => translate.state).thenReturn(translateState(engine: claude));
      final controller = StreamController<TranslationResult>();
      when(() => repository.translate(any(), any()))
          .thenAnswer((_) => controller.stream);
      await pumpPage(tester);
      await tester.enterText(
        find.byKey(const Key('conversation_input_a')),
        'Hello',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('conversation_send_a')));
      await tester.pump();
      expect(find.text('Translating…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      controller.add(resultOf('Ho', engine: claude, isComplete: false));
      await tester.pump();
      expect(find.text('Ho'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      controller.add(resultOf('Hola', engine: claude));
      await controller.close();
      await tester.pumpAndSettle();
      expect(find.text('Hola'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.textContaining('Claude'), findsWidgets);
    });

    testWidgets("counts AI requests with the app's usage tracker", (
      tester,
    ) async {
      when(() => translate.state).thenReturn(translateState(engine: claude));
      when(() => repository.translate(any(), any()))
          .thenAnswer((_) => Stream.value(resultOf('Hola', engine: claude)));
      final tracker = _MockUsageTracker();
      when(
        () => tracker.recordText(
          any(),
          input: any(named: 'input'),
          output: any(named: 'output'),
        ),
      ).thenAnswer((_) async => const UsageStats(requests: 1));
      await pumpPage(tester, usageTracker: tracker);

      await send(tester, ConversationSide.a, 'Hello');

      expect(find.text('Hola'), findsOneWidget);
      final input =
          verify(
                () => tracker.recordText(
                  'claude',
                  input: captureAny(named: 'input'),
                  output: 'Hola',
                ),
              ).captured.single
              as String;
      expect(input, startsWith('Hello\n'));
    });

    testWidgets('a failed turn explains the error and can be retried', (
      tester,
    ) async {
      var attempt = 0;
      when(() => repository.translate(any(), any())).thenAnswer(
        (_) => attempt++ == 0
            ? Stream.error(const MozhiApiException('down'))
            : Stream.value(resultOf('Hola')),
      );
      await pumpPage(tester);
      await send(tester, ConversationSide.a, 'Hello');
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(find.byKey(const Key('conversation_retry_0')), findsOneWidget);

      await tester.tap(find.byKey(const Key('conversation_retry_0')));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.error_outline), findsNothing);
      expect(find.text('Hola'), findsOneWidget);
    });

    testWidgets('listen reads the translation aloud and shows stop', (
      tester,
    ) async {
      await pumpPage(tester);
      await send(tester, ConversationSide.a, 'Hello');
      await tester.tap(find.byKey(const Key('conversation_listen_0')));
      await tester.pump();
      final id =
          verify(
                () => speech.toggle(
                  id: captureAny(named: 'id'),
                  text: 'Hola',
                  languageCode: 'es',
                ),
              ).captured.single
              as String;

      speaking.add(id);
      await tester.pump();
      expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);
      expect(findTooltipMessage(listenTooltip('Stop')), findsOneWidget);

      speaking.add(null);
      await tester.pump();
      expect(find.byIcon(Icons.stop_circle_outlined), findsNothing);
    });

    testWidgets('a long press on listen reads slowly; failures show', (
      tester,
    ) async {
      await pumpPage(tester);
      await send(tester, ConversationSide.a, 'Hello');
      await tester.longPress(find.byKey(const Key('conversation_listen_0')));
      await tester.pump();
      verify(
        () => speech.speak(
          id: any(named: 'id'),
          text: 'Hola',
          languageCode: 'es',
          slow: true,
        ),
      ).called(1);
      verifyNever(
        () => speech.toggle(
          id: any(named: 'id'),
          text: any(named: 'text'),
          languageCode: any(named: 'languageCode'),
        ),
      );

      when(
        () => speech.speak(
          id: any(named: 'id'),
          text: any(named: 'text'),
          languageCode: any(named: 'languageCode'),
          slow: any(named: 'slow'),
        ),
      ).thenThrow(const MozhiApiException('no audio'));
      await tester.pumpAndSettle(const Duration(seconds: 3));
      await tester.longPress(find.byKey(const Key('conversation_listen_0')));
      await tester.pump();
      expect(find.text("Couldn't play audio."), findsOneWidget);
    });

    testWidgets('auto-speak reads new translations and reports failures', (
      tester,
    ) async {
      when(
        () => speech.toggle(
          id: any(named: 'id'),
          text: any(named: 'text'),
          languageCode: any(named: 'languageCode'),
        ),
      ).thenThrow(const MozhiApiException('no audio'));
      // A wide app bar has the toggle (a narrow one moves it to the menu).
      await pumpPage(tester, size: const Size(800, 800));
      await tester.tap(find.byKey(const Key('conversation_auto_speak')));
      await tester.pump();
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const Key('conversation_auto_speak')),
            )
            .isSelected,
        isTrue,
      );
      await send(tester, ConversationSide.a, 'Hello');
      verify(
        () => speech.toggle(
          id: any(named: 'id'),
          text: 'Hola',
          languageCode: 'es',
        ),
      ).called(1);
      expect(find.text("Couldn't play audio."), findsOneWidget);
    });

    testWidgets('a message the privacy settings stopped asks inline', (
      tester,
    ) async {
      const consent = ConsentRequiredException(
        kind: ConsentKind.pair,
        destination: PublicInstanceDestination(
          'mozhi.example.org',
          engine: 'google',
        ),
        engineId: 'mozhi:google',
        source: 'en',
        target: 'es',
      );
      var refused = false;
      when(() => repository.translate(any(), any())).thenAnswer((_) {
        if (refused) return Stream.value(resultOf('Hola'));
        refused = true;
        return Stream.error(consent);
      });
      when(() => repository.instances).thenReturn(const []);
      await pumpPage(tester);
      await send(tester, ConversationSide.a, 'Hello');
      expect(find.byKey(const Key('conversation_consent_0')), findsOneWidget);
      await tester.tap(find.text('Once'));
      await tester.pumpAndSettle();
      verify(() => repository.allowOnce(consent)).called(1);
      expect(find.byKey(const Key('conversation_consent_0')), findsNothing);
      expect(find.text('Hola'), findsWidgets);
    });

    testWidgets('a voice the privacy settings stopped can be allowed', (
      tester,
    ) async {
      const online = ConsentRequiredException(
        kind: ConsentKind.pair,
        destination: PublicInstanceDestination('mozhi.example.org'),
        engineId: 'mozhi:google',
        source: 'es',
        target: 'es',
      );
      when(
        () => speech.toggle(
          id: any(named: 'id'),
          text: any(named: 'text'),
          languageCode: any(named: 'languageCode'),
          allowOnline: any(named: 'allowOnline'),
        ),
      ).thenAnswer((invocation) async {
        if (invocation.namedArguments[#allowOnline] == null) {
          throw const SpeechUnavailableException('es', cause: online);
        }
      });
      await pumpPage(tester, size: const Size(800, 800));
      await send(tester, ConversationSide.a, 'Hello');
      await tester.tap(find.byKey(const Key('conversation_listen_0')));
      await tester.pumpAndSettle();
      expect(find.text('Listen online'), findsOneWidget);
      await tester.tap(find.text('Listen online'));
      await tester.pumpAndSettle();
      verify(
        () => speech.toggle(
          id: any(named: 'id'),
          text: 'Hola',
          languageCode: 'es',
          allowOnline: online,
        ),
      ).called(1);
    });

    testWidgets('copy puts the translation on the clipboard', (tester) async {
      await pumpPage(tester);
      await send(tester, ConversationSide.a, 'Hello');
      await tester.tap(find.byKey(const Key('conversation_copy_0')));
      await tester.pump();
      expect(clipboard, ['Hola']);
      expect(find.text('Copied to clipboard'), findsOneWidget);
    });

    testWidgets('more options copy the original or delete the message', (
      tester,
    ) async {
      await pumpPage(tester);
      await send(tester, ConversationSide.a, 'Hello');

      await tester.tap(find.byKey(const Key('conversation_more_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy original'));
      await tester.pumpAndSettle();
      expect(clipboard, ['Hello']);

      await tester.tap(find.byKey(const Key('conversation_more_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy translation'));
      await tester.pumpAndSettle();
      expect(clipboard, ['Hello', 'Hola']);

      await tester.tap(find.byKey(const Key('conversation_more_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete message'));
      await tester.pumpAndSettle();
      expect(find.byType(ConversationTurnBubble), findsNothing);
      expect(find.text("Let's talk!"), findsOneWidget);

      // Dismissing the dialog does nothing.
      await send(tester, ConversationSide.a, 'Hi');
      await tester.tap(find.byKey(const Key('conversation_more_1')));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byType(ConversationTurnBubble), findsOneWidget);
    });

    testWidgets('message bubbles have a spoken summary', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpPage(tester);
      await send(tester, ConversationSide.a, 'Hello');
      expect(
        find.bySemanticsLabel('English: Hello. Spanish: Hola'),
        findsOneWidget,
      );
      semantics.dispose();
    });
  });

  group('app bar', () {
    testWidgets('has History and Settings in every state', (tester) async {
      await pumpPage(tester);
      expect(find.byType(TopLevelActions), findsOneWidget);

      when(() => translate.state)
          .thenReturn(translateState(engine: null, engines: const []));
      await pumpPage(tester);
      expect(find.byType(NoEnginesView), findsOneWidget);
      expect(find.byType(TopLevelActions), findsOneWidget);
    });

    testWidgets('narrow: "Read translations aloud" is in the menu', (
      tester,
    ) async {
      await pumpPage(tester);
      expect(find.byKey(const Key('conversation_auto_speak')), findsNothing);
      expect(
        find.byKey(const Key('conversation_layout_toggle')),
        findsOneWidget,
      );

      await openMenuItem(tester, 'conversation_menu_auto_speak');
      await tester.tap(find.byKey(const Key('conversation_menu')));
      await tester.pumpAndSettle();
      final item = tester.widget<CheckedPopupMenuItem<Object?>>(
        find.byKey(const Key('conversation_menu_auto_speak')),
      );
      expect(item.checked, isTrue);
      expect(item.enabled, isTrue);
      await tester.tap(find.byKey(const Key('conversation_menu_auto_speak')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('conversation_menu')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckedPopupMenuItem<Object?>>(
              find.byKey(const Key('conversation_menu_auto_speak')),
            )
            .checked,
        isFalse,
      );
    });

    testWidgets('wide: the toggle is in the bar, not the menu', (tester) async {
      await pumpPage(tester, size: const Size(800, 800));
      expect(find.byKey(const Key('conversation_auto_speak')), findsOneWidget);
      await tester.tap(find.byKey(const Key('conversation_menu')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('conversation_menu_auto_speak')),
        findsNothing,
      );
    });

    testWidgets('fits 320 dp with 200 % text', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpPage(tester, size: const Size(320, 640));
      expect(tester.takeException(), isNull);
      expect(find.text("Let's talk!"), findsOneWidget);
    });
  });

  group('face-to-face route', () {
    testWidgets('back leaves face-to-face mode', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.byKey(const Key('conversation_layout_toggle')));
      await tester.pumpAndSettle();
      expect(find.byType(ConversationFaceToFaceView), findsOneWidget);

      final handled = await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(handled, isTrue);
      expect(find.byType(ConversationFaceToFaceView), findsNothing);
      // The toggle shows the standard layout's state again.
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const Key('conversation_layout_toggle')),
            )
            .isSelected,
        isFalse,
      );
    });

    testWidgets('opens when the conversation starts face to face', (
      tester,
    ) async {
      final cubit = ConversationCubit(
        repository: repository,
        speech: speech,
        engine: () => deepl,
        options: () => const TranslationOptions(),
        availableLanguages: () => languages,
        languageA: english,
        languageB: spanish,
      )..setFaceToFace(enabled: true);
      addTearDown(cubit.close);
      await tester.pumpConversation(
        const ConversationView(),
        translate: translate,
        settings: settings,
        repository: repository,
        speech: speech,
        conversation: cubit,
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('conversation_face_to_face_layout')),
        findsOneWidget,
      );
    });

    testWidgets('closes with the page', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.byKey(const Key('conversation_layout_toggle')));
      await tester.pumpAndSettle();

      await tester.pumpConversation(
        const Scaffold(body: Text('elsewhere')),
        translate: translate,
        settings: settings,
      );
      await tester.pumpAndSettle();
      expect(find.byType(ConversationFaceToFaceView), findsNothing);
      expect(find.text('elsewhere'), findsOneWidget);
    });

    testWidgets('shows the no-engines view if the engines go away', (
      tester,
    ) async {
      final states = StreamController<TranslateState>.broadcast();
      addTearDown(states.close);
      whenListen(translate, states.stream, initialState: translateState());
      await pumpPage(tester);
      await tester.tap(find.byKey(const Key('conversation_layout_toggle')));
      await tester.pumpAndSettle();

      final none = translateState(engine: null, engines: const []);
      when(() => translate.state).thenReturn(none);
      states.add(none);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(ConversationFaceToFaceView),
          matching: find.byType(NoEnginesView),
        ),
        findsOneWidget,
      );
    });
  });

  group('transcript menu', () {
    testWidgets('is disabled while the conversation is empty', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.byKey(const Key('conversation_menu')));
      await tester.pumpAndSettle();
      final item = tester.widget<PopupMenuItem<Object?>>(
        find.byKey(const Key('conversation_menu_copy')),
      );
      expect(item.enabled, isFalse);
    });

    testWidgets('copies the formatted transcript', (tester) async {
      await pumpPage(tester);
      await send(tester, ConversationSide.a, 'Hello');
      await openMenuItem(tester, 'conversation_menu_copy');
      expect(clipboard.single, startsWith('Conversation: English ↔ Spanish'));
      expect(clipboard.single, contains('English: Hello\n→ Spanish: Hola'));
      expect(find.text('Copied to clipboard'), findsOneWidget);
    });

    testWidgets('shares the formatted transcript', (tester) async {
      String? shared;
      String? sharedSubject;
      Rect? sharedOrigin;
      await pumpPage(
        tester,
        share: (text, {subject, origin}) async {
          shared = text;
          sharedSubject = subject;
          sharedOrigin = origin;
        },
      );
      await send(tester, ConversationSide.a, 'Hello');
      await openMenuItem(tester, 'conversation_menu_share');
      expect(shared, contains('English: Hello\n→ Spanish: Hola'));
      expect(sharedSubject, 'Conversation');
      expect(sharedOrigin, isNotNull);
    });

    testWidgets('shares with the platform share sheet by default', (
      tester,
    ) async {
      final calls = <MethodCall>[];
      const channel = MethodChannel('dev.fluttercommunity.plus/share');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return 'dev.fluttercommunity.plus/share/success';
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await pumpPage(tester);
      await send(tester, ConversationSide.a, 'Hello');
      await openMenuItem(tester, 'conversation_menu_share');
      expect(calls, hasLength(1));
      final arguments = calls.single.arguments as Map<Object?, Object?>;
      expect(arguments['text'], contains('English: Hello\n→ Spanish: Hola'));
      expect(arguments['subject'], 'Conversation');
    });

    testWidgets('clear asks first, then empties the conversation', (
      tester,
    ) async {
      await pumpPage(tester);
      await send(tester, ConversationSide.a, 'Hello');

      await openMenuItem(tester, 'conversation_menu_clear');
      expect(find.text('Clear conversation?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(ConversationTurnBubble), findsOneWidget);

      await openMenuItem(tester, 'conversation_menu_clear');
      await tester.tap(find.byKey(const Key('conversation_clear_confirm')));
      await tester.pumpAndSettle();
      expect(find.byType(ConversationTurnBubble), findsNothing);
      expect(find.text("Let's talk!"), findsOneWidget);
    });

    testWidgets('works from the face-to-face controls', (tester) async {
      await pumpPage(tester);
      await send(tester, ConversationSide.a, 'Hello');
      await tester.tap(find.byKey(const Key('conversation_layout_toggle')));
      await tester.pumpAndSettle();
      await openMenuItem(tester, 'conversation_menu_copy');
      expect(clipboard, hasLength(1));
    });
  });

  testWidgets('ConversationModeButton opens conversation mode', (tester) async {
    var opened = 0;
    await tester.pumpConversation(
      Scaffold(
        appBar: AppBar(
          actions: [ConversationModeButton(onPressed: () => opened++)],
        ),
      ),
      translate: translate,
      settings: settings,
    );
    await tester.tap(find.byTooltip('Conversation mode'));
    expect(opened, 1);
  });
}
