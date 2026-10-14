import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/conversation/conversation.dart';
import 'package:mozhi/conversation/widgets/widgets.dart';
import 'package:mozhi/settings/models/app_settings.dart';
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
    testWidgets('shows languages, an empty transcript and two composers', (
      tester,
    ) async {
      await pumpPage(tester);
      expect(
        find.byKey(const Key('conversation_standard_layout')),
        findsOneWidget,
      );
      expect(find.text('Start talking'), findsOneWidget);
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
          requests[request.side] = request;
          return IconButton(
            key: Key('mic_${request.side.name}'),
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
          if (value.side == ConversationSide.a) request = value;
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
          if (value.side == ConversationSide.a) request = value;
          return const SizedBox.shrink();
        },
      );
      await tester.pumpWidget(const SizedBox());
      request.onResult('Hello', isFinal: true);
      verifyNever(() => repository.translate(any(), any()));
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
      expect(find.byTooltip('Stop'), findsOneWidget);

      speaking.add(null);
      await tester.pump();
      expect(find.byIcon(Icons.stop_circle_outlined), findsNothing);
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
      await pumpPage(tester);
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
      expect(find.text('Start talking'), findsOneWidget);

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
      expect(find.text('Start talking'), findsOneWidget);
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
