@Tags(['golden', 'skip_very_good_optimization'])
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/conversation/conversation.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

import '../conversation/helpers.dart';
import 'helpers/golden_helpers.dart';

/// What each side says, and its translation.
const _lines = {
  'Hi! Where is the train station?': '¡Hola! ¿Dónde está la estación de tren?',
  'Está a dos calles, a la izquierda.': "It's two streets away, on the left.",
  'Thank you so much!': '¡Muchísimas gracias!',
};

/// Pumps the conversation tab on a phone in a hands-free conversation of
/// three turns (English, Spanish, English), listening for the Spanish
/// speaker's answer.
Future<void> _pumpSession(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
}) async {
  useGoldenDevice(tester, GoldenDevice.phone);
  final translate = MockTranslateCubit();
  when(() => translate.state).thenReturn(translateState());
  final settings = MockSettingsCubit();
  when(() => settings.state).thenReturn(const AppSettings());
  final repository = MockTranslationRepository();
  when(() => repository.translate(any(), any())).thenAnswer((invocation) {
    final request = invocation.positionalArguments[1] as TranslationRequest;
    return Stream.value(resultOf(_lines[request.text]!));
  });
  final speech = MockSpeechService();
  final speaking = stubSpeech(speech);
  addTearDown(speaking.close);
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
  final recognizer = FakeConversationRecognizer();
  final timers = FakeTimers();
  final conversation = ConversationCubit(
    repository: repository,
    speech: speech,
    engine: () => deepl,
    languageA: english,
    languageB: spanish,
    clock: () => DateTime(2026, 10, 20, 10, 42),
    recognizer: recognizer,
    timer: timers.call,
  );
  addTearDown(conversation.close);

  await tester.pumpConversation(
    ConversationView(
      micBuilder: (context, request) => const SizedBox.square(dimension: 48),
    ),
    translate: translate,
    settings: settings,
    repository: repository,
    speech: speech,
    conversation: conversation,
    size: GoldenDevice.phone.size,
    theme: goldenTheme(brightness),
  );

  conversation.startSession();
  for (final line in _lines.keys) {
    recognizer.start();
    await tester.pump();
    recognizer.say(line);
    await tester.pump();
    await tester.pump();
    timers.fire(ConversationCubit.defaultEchoDelay);
  }
  recognizer.start();
  // The ring pulses for ever: a fixed moment of it.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUpAll(registerConversationFallbacks);

  goldenGroup('Conversation screen', () {
    testWidgets('a hands-free session on a phone (light)', (tester) async {
      await _pumpSession(tester);
      expect(find.text('Listening in Spanish…'), findsOneWidget);
      await expectScreenGolden('conversation_session_phone_light');
    });

    testWidgets('a hands-free session on a phone (dark)', (tester) async {
      await _pumpSession(tester, brightness: Brightness.dark);
      await expectScreenGolden('conversation_session_phone_dark');
    });
  });
}
