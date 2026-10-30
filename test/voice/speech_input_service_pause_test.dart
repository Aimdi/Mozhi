import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/voice/voice.dart';

import 'helpers/fake_offline_recognizer.dart';
import 'helpers/fake_speech_recognizer.dart';

void main() {
  group('SpeechInputService.listen offlinePause', () {
    late FakeSpeechRecognizer system;
    late FakeOfflineRecognizer whisper;
    late SpeechInputService service;

    setUp(() {
      system = FakeSpeechRecognizer();
      whisper = FakeOfflineRecognizer();
      service = SpeechInputService(
        store: MemoryStore(),
        adapter: system,
        offlineAdapter: whisper,
        platformSupported: true,
        onDeviceSupported: true,
      );
    });

    tearDown(() => service.dispose());

    const pause = Duration(milliseconds: 800);
    const usual = SpeechListenRequest();

    test('ends an offline session after that pause', () async {
      await service.setEngine(VoiceInputEngine.whisper);
      expect(await service.listen('en', offlinePause: pause), isTrue);
      expect(whisper.lastRequest.pauseFor, pause);
    });

    test('keeps the usual pause without one', () async {
      await service.setEngine(VoiceInputEngine.whisper);
      expect(await service.listen('en'), isTrue);
      expect(whisper.lastRequest.pauseFor, usual.pauseFor);
    });

    test('leaves the system recogniser as it was', () async {
      expect(await service.listen('en', offlinePause: pause), isTrue);
      expect(system.lastRequest.pauseFor, usual.pauseFor);
      expect(usual.pauseFor, const Duration(seconds: 3));
    });
  });
}
