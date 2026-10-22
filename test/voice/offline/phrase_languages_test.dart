import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:whisper_speech/whisper_speech.dart';

/// Says a window is speech when its samples are loud.
class _LevelClassifier implements SpeechFrameClassifier {
  @override
  Future<List<double>> classify(Float32List samples) async {
    final probabilities = <double>[];
    for (var i = 0; i < samples.length; i += speechFrameSize) {
      probabilities.add(samples[i].abs() > 0.1 ? 0.9 : 0.05);
    }
    return probabilities;
  }

  @override
  Future<void> reset() async {}
}

Uint8List pcm(int windows, double value) {
  final data = ByteData(windows * speechFrameSize * 2);
  final sample = (value * 32767).round();
  for (var i = 0; i < windows * speechFrameSize; i++) {
    data.setInt16(i * 2, i.isEven ? sample : -sample, Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  test('the language of most of the speech wins', () async {
    final languages = ['fr', 'de', 'de'];
    var count = 0;
    final transcriber =
        PhraseTranscriber(
            transcribe: (samples, {language}) async =>
                WhisperTranscription('phrase', language: languages[count++]),
            classifier: _LevelClassifier(),
          )
          // A long French phrase, then two short German ones.
          ..add(pcm(60, 0.5))
          ..add(pcm(13, 0.01))
          ..add(pcm(10, 0.5))
          ..add(pcm(13, 0.01))
          ..add(pcm(10, 0.5));
    await transcriber.finish();
    expect(transcriber.heardLanguage, 'fr');
  });

  test('a long phrase is cut and the silent rest starts the next', () {
    final segmenter = UtteranceSegmenter(
      maxSegment: const Duration(seconds: 1),
      cutSearch: const Duration(milliseconds: 300),
    );
    final segments = <SpeechSegment>[];
    void feed(int count, double p) {
      for (var i = 0; i < count; i++) {
        final frame = Float32List(speechFrameSize);
        if (segmenter.add(frame, p) case final segment?) segments.add(segment);
      }
    }

    // 26 windows of speech, a dip, then quiet windows up to the limit.
    feed(26, 0.9);
    feed(1, 0.1);
    feed(5, 0.3);
    expect(segments.single.end, const Duration(microseconds: 32000 * 27));
    expect(segmenter.inPhrase, isTrue);
    // The quiet rest counts towards the next pause.
    feed(8, 0.1);
    expect(segments, hasLength(1));
    expect(segmenter.inPhrase, isFalse);
  });
}
