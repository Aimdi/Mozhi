import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/conversation/conversation.dart';
import 'package:mozhi/conversation/widgets/widgets.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/widgets/status_announcer.dart';
import 'package:mozhi/voice/speech_input_state.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers.dart';

Widget _fakeMic(BuildContext context, ConversationMicRequest request) =>
    SizedBox.square(
      key: Key('mic_${request.side.name}${request.prominent ? '_hero' : ''}'),
      dimension: 48,
    );

const String _hint = 'Tap the microphone to start or stop';
const Key _micKey = ConversationSessionMic.buttonKey;

void main() {
  setUpAll(registerConversationFallbacks);

  late MockTranslateCubit translate;
  late MockSettingsCubit settings;
  late MockTranslationRepository repository;
  late MockSpeechService speech;
  late StreamController<String?> speaking;
  late FakeConversationRecognizer recognizer;

  setUp(() {
    translate = MockTranslateCubit();
    settings = MockSettingsCubit();
    repository = MockTranslationRepository();
    speech = MockSpeechService();
    speaking = stubSpeech(speech);
    recognizer = FakeConversationRecognizer();
    when(() => translate.state).thenReturn(translateState());
    when(() => settings.state).thenReturn(const AppSettings());
    when(() => speech.current).thenReturn(null);
    when(
      () => speech.speak(
        id: any(named: 'id'),
        text: any(named: 'text'),
        languageCode: any(named: 'languageCode'),
        slow: any(named: 'slow'),
        allowOnline: any(named: 'allowOnline'),
      ),
    ).thenAnswer((_) async {});
    when(() => repository.translate(any(), any())).thenAnswer((invocation) {
      final request = invocation.positionalArguments[1] as TranslationRequest;
      return Stream.value(resultOf('${request.text}!'));
    });
  });

  tearDown(() => speaking.close());

  Future<void> pumpPage(
    WidgetTester tester, {
    Size size = const Size(400, 800),
    ThemeData? theme,
    Widget Function(Widget page)? wrap,
  }) async {
    final page = ConversationPage(
      micBuilder: _fakeMic,
      recognizer: (_) => recognizer,
    );
    await tester.pumpConversation(
      wrap?.call(page) ?? page,
      translate: translate,
      settings: settings,
      repository: repository,
      speech: speech,
      size: size,
      theme: theme,
    );
    await tester.pumpAndSettle();
  }

  /// Pumps while something animates for ever (the pulsing ring).
  Future<void> pumpFor(WidgetTester tester, [int milliseconds = 300]) async {
    await tester.pump();
    await tester.pump(Duration(milliseconds: milliseconds));
  }

  Future<void> tapMic(WidgetTester tester) async {
    await tester.tap(find.byKey(_micKey));
    await pumpFor(tester);
  }

  /// Side A says [text]; the translation is read aloud and side B is
  /// listened for.
  Future<void> hear(
    WidgetTester tester,
    String text, {
    String? language,
  }) async {
    recognizer.start();
    await pumpFor(tester);
    recognizer.say(text, language: language);
    await pumpFor(tester, 800);
    recognizer.start();
    await pumpFor(tester);
  }

  String statusText(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const Key('conversation_session_status_text')))
      .data!;

  group('empty', () {
    testWidgets('shows a Beta badge, the title, how to start and the mic', (
      tester,
    ) async {
      await pumpPage(tester);
      expect(find.byKey(const Key('conversation_beta_badge')), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
      expect(find.text("Let's talk!"), findsOneWidget);
      expect(statusText(tester), _hint);
      expect(find.byKey(_micKey), findsOneWidget);
      expect(find.bySemanticsLabel('Start conversation'), findsOneWidget);
      // The old dictation microphone of the hero is replaced.
      expect(find.byKey(const Key('mic_a_hero')), findsNothing);
      // The microphone sits above the language pair.
      expect(
        tester.getCenter(find.byKey(_micKey)).dy,
        lessThan(
          tester
              .getCenter(find.byKey(const Key('conversation_language_pill')))
              .dy,
        ),
      );
    });

    testWidgets('keeps the text fields behind the keyboard button', (
      tester,
    ) async {
      await pumpPage(tester);
      expect(find.byKey(const Key('conversation_input_a')), findsNothing);
      await tester.tap(find.byKey(const Key('conversation_keyboard_toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('conversation_input_a')), findsOneWidget);
      expect(find.byKey(const Key('conversation_input_b')), findsOneWidget);
      expect(find.byKey(const Key('mic_a')), findsOneWidget);
      expect(find.byTooltip('Hide text fields'), findsOneWidget);
      await tester.tap(find.byKey(const Key('conversation_keyboard_toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('conversation_input_a')), findsNothing);
      expect(find.byTooltip('Type a message'), findsOneWidget);
    });

    testWidgets('wide: text fields stay, Beta sits next to the title', (
      tester,
    ) async {
      await pumpPage(tester, size: const Size(1000, 800));
      expect(find.byKey(const Key('conversation_input_a')), findsOneWidget);
      expect(
        find.byKey(const Key('conversation_keyboard_toggle')),
        findsNothing,
      );
      // In the app bar and in the hero.
      expect(find.text('Beta'), findsNWidgets(2));
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('Conversation'),
        ),
        findsOneWidget,
      );
    });
  });

  group('a session', () {
    testWidgets('listens for side A, with a pulsing ring', (tester) async {
      await pumpPage(tester);
      await tapMic(tester);
      expect(recognizer.listens.single.language, english);
      expect(find.byKey(ConversationSessionMic.progressKey), findsOneWidget);
      recognizer.start();
      await pumpFor(tester);
      expect(statusText(tester), 'Listening in English…');
      expect(find.byKey(ConversationSessionMic.pulseKey), findsOneWidget);
      expect(
        tester.getSemantics(find.bySemanticsLabel('Stop conversation')),
        isSemantics(
          label: 'Stop conversation',
          value: 'Listening in English…',
          isButton: true,
          hasTapAction: true,
        ),
      );
      recognizer.partial('Good mor');
      await pumpFor(tester);
      expect(statusText(tester), 'Good mor');
    });

    testWidgets('screen readers start it with a tap action', (tester) async {
      await pumpPage(tester);
      tester.semantics.tap(find.semantics.byLabel('Start conversation'));
      await pumpFor(tester);
      expect(recognizer.listens, hasLength(1));
    });

    testWidgets('a still ring replaces the pulse with reduced motion', (
      tester,
    ) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await pumpPage(tester);
      await tapMic(tester);
      recognizer.start();
      await tester.pump();
      expect(find.byKey(ConversationSessionMic.pulseKey), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(ConversationSessionMic.pulseKey),
          matching: find.byType(AnimatedBuilder),
        ),
        findsNothing,
      );
    });

    testWidgets('a turn becomes a bubble; then side B is listened for', (
      tester,
    ) async {
      await pumpPage(tester);
      await tapMic(tester);
      await hear(tester, 'Hello');
      expect(find.text('Hello'), findsOneWidget);
      expect(find.text('Hello!'), findsOneWidget);
      expect(find.text("Let's talk!"), findsNothing);
      expect(statusText(tester), 'Listening in Spanish…');
      expect(recognizer.language, spanish);
      // The microphone stays docked above the language pair.
      expect(find.byKey(_micKey), findsOneWidget);
      expect(
        tester.getCenter(find.byKey(_micKey)).dy,
        lessThan(
          tester
              .getCenter(find.byKey(const Key('conversation_language_pill')))
              .dy,
        ),
      );
    });

    testWidgets('detecting recognisers say both languages', (tester) async {
      await pumpPage(tester);
      await tapMic(tester);
      recognizer.start(detectsLanguage: true);
      await pumpFor(tester);
      expect(statusText(tester), 'Listening in English or Spanish…');
    });

    testWidgets('tapping the mic again stops everything', (tester) async {
      await pumpPage(tester);
      await tapMic(tester);
      recognizer.start();
      await pumpFor(tester);
      await tapMic(tester);
      await tester.pumpAndSettle();
      expect(recognizer.open, isFalse);
      expect(statusText(tester), _hint);
      expect(find.bySemanticsLabel('Start conversation'), findsOneWidget);
    });

    testWidgets('the pill shows whose turn it is and switches turns', (
      tester,
    ) async {
      await pumpPage(tester);
      await tapMic(tester);
      expect(
        tester.getSemantics(find.bySemanticsLabel('English speaks next')),
        isSemantics(isSelected: true, hasLongPressAction: true),
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel('Spanish speaks next')),
        isSemantics(isSelected: false),
      );
      await tester.tap(find.byKey(const Key('conversation_language_b')));
      await pumpFor(tester);
      expect(recognizer.language, spanish);
      expect(
        tester.getSemantics(find.bySemanticsLabel('Spanish speaks next')),
        isSemantics(isSelected: true),
      );
      // A long press still changes the language.
      await tester.longPress(find.byKey(const Key('conversation_language_a')));
      await pumpFor(tester, 600);
      expect(find.text('Choose a language'), findsOneWidget);
    });

    testWidgets("hides the text fields' microphones while active", (
      tester,
    ) async {
      await pumpPage(tester);
      await tester.tap(find.byKey(const Key('conversation_keyboard_toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mic_a')), findsOneWidget);
      await tapMic(tester);
      expect(find.byKey(const Key('mic_a')), findsNothing);
      await tapMic(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mic_a')), findsOneWidget);
    });

    testWidgets('pauses after silence with a gentle prompt', (tester) async {
      await pumpPage(tester);
      await tapMic(tester);
      recognizer.start();
      await pumpFor(tester);
      await tester.pump(ConversationCubit.defaultSilenceTimeout);
      await tester.pumpAndSettle();
      expect(
        statusText(tester),
        "Didn't hear anything. Tap the microphone to continue.",
      );
      expect(find.bySemanticsLabel('Continue conversation'), findsOneWidget);
      await tapMic(tester);
      expect(recognizer.listens, hasLength(2));
    });

    testWidgets('explains voice input errors', (tester) async {
      await pumpPage(tester);
      await tapMic(tester);
      recognizer.fail(SpeechInputFailure.permissionDenied);
      await tester.pumpAndSettle();
      final l10n = lookupAppLocalizations(const Locale('en'));
      expect(find.text(l10n.voiceErrorPermission), findsOneWidget);
      expect(
        statusText(tester),
        '${l10n.voiceErrorPermission} Tap the microphone to try again.',
      );
      expect(find.byIcon(Icons.mic_off_outlined), findsOneWidget);
    });

    testWidgets('stops when the app is hidden', (tester) async {
      await pumpPage(tester);
      await tapMic(tester);
      tester.binding
        ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
        ..handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pumpAndSettle();
      expect(statusText(tester), _hint);
      expect(recognizer.open, isFalse);
      tester.binding
        ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
        ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });

    testWidgets('stops when the tab changes', (tester) async {
      final shown = ValueNotifier(true);
      addTearDown(shown.dispose);
      await pumpPage(
        tester,
        wrap: (page) => ValueListenableBuilder<bool>(
          valueListenable: shown,
          builder: (context, enabled, child) =>
              TickerMode(enabled: enabled, child: child!),
          child: page,
        ),
      );
      await tapMic(tester);
      expect(recognizer.open, isTrue);
      shown.value = false;
      await tester.pump();
      expect(recognizer.open, isFalse);
      shown.value = true;
      await tester.pumpAndSettle();
      expect(statusText(tester), _hint);
    });

    testWidgets('face-to-face mode keeps working and stops the session', (
      tester,
    ) async {
      await pumpPage(tester);
      await tapMic(tester);
      await tester.tap(find.byKey(const Key('conversation_layout_toggle')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('conversation_face_to_face_layout')),
        findsOneWidget,
      );
      expect(recognizer.open, isFalse);
      await tester.tap(
        find.byKey(const Key('conversation_layout_toggle')).last,
      );
      await tester.pumpAndSettle();
      expect(statusText(tester), _hint);
    });
  });

  group('announcements', () {
    testWidgets('new translations are announced when not read aloud', (
      tester,
    ) async {
      await pumpPage(tester);
      await tester.tap(find.byKey(const Key('conversation_keyboard_toggle')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('conversation_input_a')),
        'Hello',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('conversation_send_a')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<StatusAnnouncer>(find.byType(StatusAnnouncer)).message,
        'Spanish: Hello!',
      );
    });

    testWidgets('translations read aloud are not announced', (tester) async {
      await pumpPage(tester);
      await tapMic(tester);
      await hear(tester, 'Hello');
      expect(
        tester.widget<StatusAnnouncer>(find.byType(StatusAnnouncer)).message,
        isNull,
      );
    });

    String? announced(WidgetTester tester) =>
        tester.widget<StatusAnnouncer>(find.byType(StatusAnnouncer)).message;

    /// Side A says "Hello" in a conversation that does not read aloud.
    Future<void> sayUnread(WidgetTester tester) async {
      await pumpPage(tester);
      tester
          .element(find.byType(ConversationView))
          .read<ConversationCubit>()
          .setAutoSpeak(enabled: false);
      await tapMic(tester);
      recognizer.start();
      await pumpFor(tester);
      recognizer.say('Hello');
      await pumpFor(tester);
      expect(announced(tester), 'Spanish: Hello!');
    }

    testWidgets('with a screen reader the microphone waits until a '
        'translation was announced', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(accessibleNavigation: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await sayUnread(tester);
      // The echo delay alone would have opened it by now.
      await tester.pump(const Duration(milliseconds: 1000));
      expect(recognizer.listens, hasLength(1));
      await tester.pump(const Duration(milliseconds: 600));
      expect(recognizer.listens, hasLength(2));
      expect(recognizer.language, spanish);
    });

    testWidgets('without a screen reader it opens after the echo delay', (
      tester,
    ) async {
      await sayUnread(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(recognizer.listens, hasLength(2));
    });

    testWidgets('a paused conversation says why', (tester) async {
      await pumpPage(tester);
      await tapMic(tester);
      recognizer.start();
      await pumpFor(tester);
      await tester.pump(ConversationCubit.defaultSilenceTimeout);
      await tester.pump();
      expect(
        announced(tester),
        "Didn't hear anything. Tap the microphone to continue.",
      );
    });

    testWidgets('a failed translation pauses and says so', (tester) async {
      when(() => repository.translate(any(), any()))
          .thenAnswer((_) => Stream.error(Exception('offline')));
      await pumpPage(tester);
      await tapMic(tester);
      recognizer.start();
      await pumpFor(tester);
      recognizer.say('Hello');
      await pumpFor(tester);
      expect(
        announced(tester),
        'The translation failed. Retry it, or tap the microphone to '
        'continue.',
      );
    });
  });

  group('adapts', () {
    testWidgets('to 320 dp with 200 % text during a session', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpPage(tester, size: const Size(320, 640));
      await tapMic(tester);
      await hear(tester, 'Hello, how are you today?');
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('conversation_keyboard_toggle')));
      await pumpFor(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('to little height with a single-row dock', (tester) async {
      await pumpPage(tester, size: const Size(400, 500));
      expect(
        find.byKey(const Key('conversation_session_dock')),
        findsOneWidget,
      );
      expect(
        tester.getSize(find.byKey(_micKey)).width,
        ConversationSessionMic.compactSize,
      );
      await tapMic(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('to right-to-left languages', (tester) async {
      await pumpPage(
        tester,
        wrap: (page) =>
            Directionality(textDirection: TextDirection.rtl, child: page),
      );
      await tapMic(tester);
      // Side A's language sits at the start, the right.
      expect(
        tester.getCenter(find.byKey(const Key('conversation_language_a'))).dx,
        greaterThan(
          tester.getCenter(find.byKey(const Key('conversation_language_b'))).dx,
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('to dark mode', (tester) async {
      await pumpPage(
        tester,
        theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      );
      await tapMic(tester);
      await hear(tester, 'Hello');
      expect(tester.takeException(), isNull);
    });
  });

  group('conversationSessionStatus', () {
    final l10n = lookupAppLocalizations(const Locale('en'));

    String status(
      ConversationSession session, {
      List<ConversationTurn>? turns,
    }) => conversationSessionStatus(
      l10n,
      ConversationState(
        languageA: english,
        languageB: spanish,
        session: session,
        turns: turns ?? const [],
      ),
    );

    test('describes every stage', () {
      expect(status(ConversationSession.idle), _hint);
      expect(
        status(
          const ConversationSessionListening(
            side: ConversationSide.b,
            stage: ConversationListenStage.transcribing,
          ),
        ),
        'Transcribing what was said…',
      );
      expect(
        status(
          const ConversationSessionTranslating(
            turnId: 0,
            speaker: ConversationSide.a,
            next: ConversationSide.b,
          ),
        ),
        'Translating…',
      );
      expect(
        status(
          const ConversationSessionSpeaking(
            turnId: 0,
            next: ConversationSide.b,
          ),
          turns: [turnOf()],
        ),
        'Reading aloud in Spanish…',
      );
      // Something else read aloud.
      expect(
        status(const ConversationSessionSpeaking(next: ConversationSide.a)),
        'Reading aloud in Spanish…',
      );
    });

    test('says why a session paused', () {
      String paused(ConversationPauseReason reason) => status(
        ConversationSessionPaused(next: ConversationSide.a, reason: reason),
      );
      expect(
        paused(ConversationPauseReason.silence),
        "Didn't hear anything. Tap the microphone to continue.",
      );
      expect(
        paused(ConversationPauseReason.interrupted),
        'Paused. Tap the microphone to continue.',
      );
      expect(
        paused(ConversationPauseReason.consent),
        'Allow the translation above, or tap the microphone to continue.',
      );
      expect(
        paused(ConversationPauseReason.speechConsent),
        'Allow reading aloud, or tap the microphone to continue.',
      );
      expect(
        paused(ConversationPauseReason.translationFailed),
        'The translation failed. Retry it, or tap the microphone to '
        'continue.',
      );
    });

    test('offers an offline model when one would help', () {
      expect(
        status(
          const ConversationSessionFailed(
            next: ConversationSide.a,
            failure: SpeechInputFailure.recognizerUnavailable,
            offlineSupported: true,
          ),
        ),
        '${l10n.voiceErrorUnavailableOfflineModel} '
        'Tap the microphone to try again.',
      );
    });
  });
}
