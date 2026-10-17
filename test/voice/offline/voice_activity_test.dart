import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/voice/voice.dart';

void main() {
  VoiceActivityDetector detector() =>
      VoiceActivityDetector(pause: const Duration(milliseconds: 300));

  group(VoiceActivityDetector, () {
    test('hears nothing in a quiet room', () {
      final voice = detector();
      for (var i = 0; i < 20; i++) {
        voice.add(-65 + (i % 3), 1600);
      }
      expect(voice.heardSpeech, isFalse);
      expect(voice.pausedAfterSpeech, isFalse);
    });

    test('hears speech above the background and ends after the '
        'pause', () {
      final voice = detector()
        ..add(-65, 1600)
        ..add(-50, 1600);
      expect(voice.heardSpeech, isTrue);
      expect(voice.pausedAfterSpeech, isFalse);
      voice
        ..add(-64, 1600)
        ..add(-64, 1600);
      expect(voice.pausedAfterSpeech, isFalse);
      voice.add(-64, 1600);
      expect(voice.pausedAfterSpeech, isTrue);
      // Speaking again restarts the pause.
      voice.add(-40, 1600);
      expect(voice.pausedAfterSpeech, isFalse);
    });

    test('loud speech counts from the first chunk', () {
      expect((detector()..add(-30, 1600)).heardSpeech, isTrue);
      // ...but a first chunk that is merely not silent does not.
      expect((detector()..add(-50, 1600)).heardSpeech, isFalse);
    });

    test('needs speech to be louder than the threshold', () {
      final voice = detector()
        ..add(-85, 1600)
        ..add(-58, 1600);
      expect(voice.heardSpeech, isFalse);
    });

    test('digital silence is not the background', () {
      final voice = detector()
        ..add(-100, 1600)
        ..add(-48, 1600);
      // The floor is the -48 chunk itself: not loud enough on its own.
      expect(voice.heardSpeech, isFalse);
      voice.add(-38, 1600);
      expect(voice.heardSpeech, isTrue);
    });

    test('ignores empty and invalid chunks', () {
      final voice = detector()
        ..add(double.nan, 1600)
        ..add(-20, 0);
      expect(voice.heardSpeech, isFalse);
      expect(voice.pause, const Duration(milliseconds: 300));
      expect(voice.sampleRate, 16000);
    });
  });
}
