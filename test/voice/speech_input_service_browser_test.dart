import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/voice/voice.dart';

import 'helpers/fake_speech_recognizer.dart';

/// The web app in a browser without speech recognition (Firefox and its
/// forks have no `SpeechRecognition`).
void main() {
  late FakeSpeechRecognizer recognizer;
  late List<SpeechInputState> states;

  SpeechInputService build({required bool available, bool isWeb = true}) {
    final service = SpeechInputService(
      store: MemoryStore(),
      adapter: recognizer,
      platformSupported: true,
      isWeb: isWeb,
      browserRecognizerAvailable: available,
    );
    addTearDown(service.dispose);
    service.states.listen(states.add);
    return service;
  }

  setUp(() {
    recognizer = FakeSpeechRecognizer();
    states = [];
  });

  const unavailable = SpeechInputUnavailable(
    failure: SpeechInputFailure.recognizerUnavailable,
  );

  test('is unavailable from the start, before any tap', () {
    final service = build(available: false);

    expect(service.browserRecognizerMissing, isTrue);
    expect(service.usesBrowserRecognizer, isTrue);
    expect(service.isPlatformSupported, isTrue);
    expect(service.state, unavailable);
  });

  test('needs no browser notice: nothing would hear the audio', () async {
    final service = build(available: false);

    expect(await service.needsBrowserNotice(), isFalse);
  });

  test('listening says so at once, without touching the recogniser', () async {
    final service = build(available: false);

    expect(await service.listen('de'), isFalse);
    expect(await service.initialize(), isFalse);
    expect(service.state, unavailable);
    expect(recognizer.initCalls, 0);
  });

  test('stays unavailable when settings or models change', () async {
    final service = build(available: false);

    await service.setEngine(VoiceInputEngine.whisper);
    await service.offlineModelsChanged();
    service.forgetSettings();

    expect(service.state, unavailable);
    expect(states, isEmpty);
  });

  test(
    'a browser with speech recognition starts idle and asks first',
    () async {
      final service = build(available: true);

      expect(service.browserRecognizerMissing, isFalse);
      expect(service.state, const SpeechInputIdle());
      expect(await service.needsBrowserNotice(), isTrue);
    },
  );

  test('the Android app never asks the browser', () {
    final service = build(available: false, isWeb: false);

    expect(service.browserRecognizerMissing, isFalse);
    expect(service.state, const SpeechInputIdle());
  });
}
