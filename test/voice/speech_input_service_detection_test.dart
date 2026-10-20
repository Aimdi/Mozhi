import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/voice/voice.dart';

import 'helpers/fake_offline_recognizer.dart';
import 'helpers/fake_speech_recognizer.dart';

/// An offline recogniser that detects the spoken language, like Whisper.
class _DetectingRecognizer extends FakeOfflineRecognizer
    implements LanguageDetectingSpeechRecognizer {
  @override
  String? detectedLanguage;
}

void main() {
  late FakeSpeechRecognizer system;
  late _DetectingRecognizer whisper;
  late SpeechInputService service;
  late List<SpeechInputState> states;
  late List<SpeechInputResult> results;
  final owner = Object();

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  setUp(() async {
    system = FakeSpeechRecognizer();
    whisper = _DetectingRecognizer();
    states = [];
    results = [];
    service = SpeechInputService(
      store: MemoryStore(),
      adapter: system,
      offlineAdapter: whisper,
      platformSupported: true,
    );
    service.states.listen(states.add);
    service.results.listen(results.add);
  });

  tearDown(() => service.dispose());

  group('detectLanguage', () {
    test('a detecting recogniser listens without a language and reports '
        'the one it heard', () async {
      await service.setEngine(VoiceInputEngine.whisper);
      expect(
        await service.listen('de', owner: owner, detectLanguage: true),
        isTrue,
      );
      expect(whisper.lastRequest.localeId, isNull);
      expect(
        service.state,
        SpeechInputListening(owner: owner, detectsLanguage: true),
      );
      // Sound levels keep the flag.
      whisper.emitLevel(-30);
      expect((service.state as SpeechInputListening).detectsLanguage, isTrue);

      whisper
        ..emitResult('Hola')
        ..detectedLanguage = 'es'
        ..emitResult('Hola, ¿qué tal?', isFinal: true);
      await flush();
      expect(results, [
        SpeechInputResult('Hola', isFinal: false, owner: owner),
        SpeechInputResult(
          'Hola, ¿qué tal?',
          isFinal: true,
          owner: owner,
          language: 'es',
        ),
      ]);
      expect(states.last, const SpeechInputIdle());
    });

    test('without it the language is asked for; a reported language is '
        'still passed on', () async {
      await service.setEngine(VoiceInputEngine.whisper);
      whisper.detectedLanguage = 'de';
      await service.listen('de', owner: owner);
      expect(whisper.lastRequest.localeId, 'de');
      expect(service.state, SpeechInputListening(owner: owner));
      whisper.emitResult('Hallo', isFinal: true);
      await flush();
      expect(results.single.language, 'de');
    });

    test('a recogniser that cannot detect listens in the language', () async {
      await service.listen('en', owner: owner, detectLanguage: true);
      expect(system.lastRequest.localeId, 'en_US');
      expect(service.state, SpeechInputListening(owner: owner));
      system.emitResult('Hello', isFinal: true);
      await flush();
      expect(results.single.language, isNull);
    });
  });
}
