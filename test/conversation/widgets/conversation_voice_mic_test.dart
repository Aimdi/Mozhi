import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/conversation/conversation.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers.dart';

class _MemoryStore implements KeyValueStore {
  final _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}

void main() {
  setUpAll(registerConversationFallbacks);

  testWidgets('conversationVoiceMicBuilder dictates per side', (tester) async {
    final translate = MockTranslateCubit();
    final settings = MockSettingsCubit();
    final repository = MockTranslationRepository();
    final speech = MockSpeechService();
    final speaking = stubSpeech(speech);
    addTearDown(speaking.close);
    when(() => translate.state).thenReturn(translateState());
    when(() => settings.state).thenReturn(const AppSettings());
    when(() => repository.translate(any(), any()))
        .thenAnswer((_) => Stream.value(resultOf('Hola')));
    final service = SpeechInputService(
      store: _MemoryStore(),
      platformSupported: false,
    );

    await tester.pumpConversation(
      RepositoryProvider<SpeechInputService>.value(
        value: service,
        child: const ConversationPage(micBuilder: conversationVoiceMicBuilder),
      ),
      translate: translate,
      settings: settings,
      repository: repository,
      speech: speech,
    );

    final micA = tester.widget<VoiceInputButton>(
      find.byKey(const ValueKey('conversation_mic_a')),
    );
    final micB = tester.widget<VoiceInputButton>(
      find.byKey(const ValueKey('conversation_mic_b')),
    );
    expect(micA.languageCode, 'en');
    expect(micB.languageCode, 'es');
    expect(micA.prominent, isFalse);
    // The empty conversation's large microphone dictates for side A.
    final hero = tester.widget<VoiceInputButton>(
      find.byKey(const ValueKey('conversation_hero_mic_a')),
    );
    expect(hero.prominent, isTrue);
    expect(hero.languageCode, 'en');

    micA.onResult('Hello', isFinal: true);
    await tester.pumpAndSettle();
    final request =
        verify(() => repository.translate(any(), captureAny())).captured.single
            as TranslationRequest;
    expect(request.text, 'Hello');
    expect(request.target, spanish);
  });
}
