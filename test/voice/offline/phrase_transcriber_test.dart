import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:whisper_speech/whisper_speech.dart';

class _MockOfflineSpeech extends Mock implements OfflineSpeech;

/// PCM16 bytes of [windows] windows whose samples are all [value].
Uint8List pcm(int windows, double value) {
  final data = ByteData(windows * speechFrameSize * 2);
  final sample = (value * 32767).round();
  for (var i = 0; i < windows * speechFrameSize; i++) {
    data.setInt16(i * 2, i.isEven ? sample : -sample, Endian.little);
  }
  return data.buffer.asUint8List();
}

/// Says a window is speech when its samples are loud (|x| > 0.1).
class _LevelClassifier implements SpeechFrameClassifier {
  int resets = 0;
  Error? error;
  final List<int> calls = [];

  @override
  Future<List<double>> classify(Float32List samples) async {
    calls.add(samples.length);
    if (error case final error?) throw error;
    final probabilities = <double>[];
    for (var i = 0; i < samples.length; i += speechFrameSize) {
      probabilities.add(samples[i].abs() > 0.1 ? 0.9 : 0.05);
    }
    return probabilities;
  }

  @override
  Future<void> reset() async => resets++;
}

void main() {
  late _LevelClassifier classifier;
  late List<(int, String?)> transcribed;
  late List<TranscribedPhrase> phrases;
  late int activity;
  late Map<int, Completer<WhisperTranscription>> gates;
  late List<String> texts;
  var cancels = 0;

  setUp(() {
    classifier = _LevelClassifier();
    transcribed = [];
    phrases = [];
    activity = 0;
    gates = {};
    texts = ['Hello there.', 'How are you?', 'Fine.'];
    cancels = 0;
  });

  PhraseTranscriber build({
    SpeechFrameClassifier? fallback,
    Duration maxBacklog = const Duration(minutes: 2),
    String? language = 'en',
    Error? Function(int index)? failWith,
  }) {
    var count = 0;
    return PhraseTranscriber(
      transcribe: (samples, {language}) async {
        final index = count++;
        transcribed.add((samples.length, language));
        if (gates[index] case final gate?) return await gate.future;
        if (failWith?.call(index) case final error?) throw error;
        return WhisperTranscription(
          index < texts.length ? texts[index] : '',
          language: 'de',
        );
      },
      classifier: classifier,
      fallback: fallback,
      language: language,
      maxBacklog: maxBacklog,
      onPhrase: phrases.add,
      onActivity: () => activity++,
      cancelEngine: () async => cancels++,
    );
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('transcribes each phrase as soon as its pause is over', () async {
    final transcriber = build()..add(pcm(20, 0.5));
    await settle();
    expect(transcriber.heardSpeech, isTrue);
    expect(transcriber.level, closeTo(-6.02, 0.01));
    expect(transcribed, isEmpty);

    transcriber.add(pcm(13, 0.01));
    await settle();
    await settle();
    expect(transcribed.single.$2, 'en');
    expect(phrases.single.text, 'Hello there.');
    expect(phrases.single.language, 'de');
    expect(phrases.single.status, PhraseStatus.transcribed);
    expect(phrases.single.start, Duration.zero);
    expect(transcriber.text, 'Hello there.');
    expect(transcriber.silenceAfterSpeech, const Duration(milliseconds: 416));
    expect(activity, 2);

    transcriber.add(pcm(15, 0.5));
    final all = await transcriber.finish();
    expect(all.map((phrase) => phrase.text), ['Hello there.', 'How are you?']);
    expect(transcriber.text, 'Hello there. How are you?');
    expect(transcriber.heardLanguage, 'de');
    expect(transcriber.pending, 0);
    expect(transcriber.recorded, const Duration(milliseconds: 1536));
    // Later chunks are ignored; finishing again returns the same.
    transcriber.add(pcm(20, 0.5));
    expect(await transcriber.finish(), all);
    expect(transcribed, hasLength(2));
  });

  test('chunks that do not fill a window wait for the next', () async {
    final transcriber = build();
    final bytes = pcm(2, 0.5);
    transcriber
      ..add(bytes.sublist(0, 700))
      ..add(bytes.sublist(700, 1501))
      ..add(bytes.sublist(1501));
    await settle();
    expect(classifier.calls, [512, 512]);
    expect(activity, 3);
  });

  test('silence is never transcribed', () async {
    final transcriber = build()..add(pcm(100, 0.01));
    expect(await transcriber.finish(), isEmpty);
    expect(transcriber.heardSpeech, isFalse);
    expect(transcriber.text, isEmpty);
    expect(transcriber.heardLanguage, isNull);
    expect(transcribed, isEmpty);
  });

  test('a failing classifier hands over to the fallback', () async {
    final fallback = _LevelClassifier();
    final transcriber = build(fallback: fallback);
    classifier.error = StateError('vad');
    transcriber
      ..add(pcm(10, 0.5))
      ..add(pcm(13, 0.01));
    await transcriber.finish();
    expect(transcriber.usesFallback, isTrue);
    expect(classifier.calls, hasLength(1));
    expect(fallback.calls, hasLength(2));
    expect(phrases.single.text, 'Hello there.');
  });

  test('without a fallback every window counts as speech', () async {
    final transcriber = build();
    classifier.error = StateError('vad');
    transcriber.add(pcm(10, 0.01));
    final heard = await transcriber.finish();
    expect(heard.single.text, 'Hello there.');
    expect(transcriber.usesFallback, isFalse);
  });

  test('engine failures fail the phrase only', () async {
    final transcriber =
        build(failWith: (index) => index == 0 ? StateError('engine') : null)
          ..add(pcm(10, 0.5))
          ..add(pcm(13, 0.01))
          ..add(pcm(10, 0.5));
    final heard = await transcriber.finish();
    expect(heard.map((phrase) => phrase.status), [
      PhraseStatus.failed,
      PhraseStatus.transcribed,
    ]);
    expect(heard.first.hasText, isFalse);
    expect(transcriber.text, 'How are you?');
  });

  test('drops phrases beyond the backlog, in order', () async {
    gates[0] = Completer();
    final transcriber = build(maxBacklog: const Duration(milliseconds: 900));
    // Three phrases of 640 ms + padding while the first is transcribed.
    for (var i = 0; i < 3; i++) {
      transcriber
        ..add(pcm(20, 0.5))
        ..add(pcm(13, 0.01));
    }
    await settle();
    expect(transcriber.pending, 3);
    gates[0]!.complete(const WhisperTranscription('first'));
    final heard = await transcriber.finish();
    expect(heard.map((phrase) => phrase.status), [
      PhraseStatus.transcribed,
      PhraseStatus.transcribed,
      PhraseStatus.skipped,
    ]);
    expect(heard.map((phrase) => phrase.index), [0, 1, 2]);
    expect(transcribed, hasLength(2));
  });

  test('cancel stops the running transcription and reports '
      'nothing more', () async {
    gates[0] = Completer();
    final transcriber = build()
      ..add(pcm(10, 0.5))
      ..add(pcm(13, 0.01))
      ..add(pcm(10, 0.5))
      ..add(pcm(13, 0.01));
    await settle();
    await transcriber.cancel();
    expect(cancels, 1);
    gates[0]!.completeError(const WhisperCancelledException());
    expect(await transcriber.finish(), isEmpty);
    expect(phrases, isEmpty);
    expect(transcribed, hasLength(1));
    // Twice is fine.
    await transcriber.cancel();
    expect(cancels, 1);
  });

  test('cancel while nothing is transcribed leaves the engine alone', () async {
    final transcriber = build()..add(pcm(10, 0.5));
    await transcriber.cancel();
    expect(cancels, 0);
    expect(await transcriber.finish(), isEmpty);
  });

  test('detects the language per phrase without one', () async {
    final transcriber = build(language: null)..add(pcm(10, 0.5));
    await transcriber.finish();
    expect(transcribed.single.$2, isNull);
  });

  group('joinPhrases', () {
    test('joins with spaces, but not next to CJK characters', () {
      expect(joinPhrases(['Hello.', ' ', 'World. ']), 'Hello. World.');
      expect(joinPhrases(['你好。', '我很好。']), '你好。我很好。');
      expect(joinPhrases(['こんにちは', 'OK']), 'こんにちはOK');
      expect(joinPhrases(['OK', '世界']), 'OK世界');
      expect(joinPhrases(['안녕하세요.', '반가워요.']), '안녕하세요. 반가워요.');
      expect(joinPhrases(const []), isEmpty);
    });
  });

  group('classifiers', () {
    test('Silero asks the detector and checks its windows', () async {
      final speech = _MockOfflineSpeech();
      when(speech.resetSpeechDetection).thenAnswer((_) async {});
      when(() => speech.detectSpeech(any())).thenAnswer(
        (_) async =>
            WhisperVadFrames(Float32List.fromList([0.5, 1]), frameSize: 512),
      );
      final silero = SileroSpeechClassifier(speech);
      await silero.reset();
      verify(speech.resetSpeechDetection).called(1);
      expect(await silero.classify(Float32List(1024)), [0.5, 1]);
      await expectLater(
        silero.classify(Float32List(512)),
        throwsA(isA<StateError>()),
      );
    });

    test('loudness hears speech above the background', () async {
      final loudness = LoudnessSpeechClassifier();
      final quiet = Float32List(512)..fillRange(0, 512, 0.001);
      final loud = Float32List(512)..fillRange(0, 512, 0.5);
      expect(
        await loudness.classify(Float32List.fromList([...quiet, ...loud])),
        [0, 1],
      );
      await loudness.reset();
      expect(await loudness.classify(quiet), [0]);
    });
  });

  test('phrases compare by value', () {
    const phrase = TranscribedPhrase(
      index: 0,
      start: Duration.zero,
      end: Duration(seconds: 1),
      status: PhraseStatus.skipped,
    );
    expect(phrase.hasText, isFalse);
    expect(
      phrase,
      const TranscribedPhrase(
        index: 0,
        start: Duration.zero,
        end: Duration(seconds: 1),
        status: PhraseStatus.skipped,
      ),
    );
  });

  setUpAll(() => registerFallbackValue(Float32List(0)));
}
