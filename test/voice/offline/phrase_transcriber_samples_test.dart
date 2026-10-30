import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:whisper_speech/whisper_speech.dart';

/// Says a window is speech when its samples are loud (|x| > 0.1).
class _LevelClassifier implements SpeechFrameClassifier {
  @override
  Future<List<double>> classify(Float32List samples) async => [
    for (var i = 0; i < samples.length; i += speechFrameSize)
      if (samples[i].abs() > 0.1) 0.9 else 0.05,
  ];

  @override
  Future<void> reset() async {}
}

/// [windows] windows of float samples of [value] (alternating sign).
Float32List _samples(int windows, double value) => Float32List.fromList([
  for (var i = 0; i < windows * speechFrameSize; i++)
    if (i.isEven) value else -value,
]);

void main() {
  group('PhraseTranscriber.addSamples', () {
    test('cuts float samples into phrases like PCM16 chunks', () async {
      final phrases = <TranscribedPhrase>[];
      final lengths = <int>[];
      final transcriber =
          PhraseTranscriber(
              transcribe: (samples, {language}) async {
                lengths.add(samples.length);
                return const WhisperTranscription('Hola.', language: 'es');
              },
              classifier: _LevelClassifier(),
              segmenter: UtteranceSegmenter(
                pause: const Duration(milliseconds: 96),
              ),
              onPhrase: phrases.add,
            )
            // Not a whole window yet: kept for the next block.
            ..addSamples(Float32List.sublistView(_samples(1, 0.5), 0, 300))
            ..addSamples(Float32List.sublistView(_samples(20, 0.5), 300))
            ..addSamples(_samples(10, 0));
      expect(transcriber.level, lessThan(-90));
      await transcriber.finish();
      expect(phrases, hasLength(1));
      expect(phrases.single.text, 'Hola.');
      expect(phrases.single.language, 'es');
      expect(lengths.single, greaterThanOrEqualTo(20 * speechFrameSize));
      expect(transcriber.heardSpeech, isTrue);
    });

    test('is ignored after cancel', () async {
      final transcriber = PhraseTranscriber(
        transcribe: (samples, {language}) async =>
            const WhisperTranscription('x'),
        classifier: _LevelClassifier(),
      );
      await transcriber.cancel();
      transcriber.addSamples(_samples(4, 0.5));
      expect(transcriber.recorded, Duration.zero);
      expect(await transcriber.finish(), isEmpty);
    });
  });
}
