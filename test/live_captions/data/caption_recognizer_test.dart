import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/live_captions/data/caption_recognizer.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:whisper_speech/whisper_speech.dart';

class _MockOfflineSpeech extends Mock implements OfflineSpeech;

/// [windows] windows (32 ms each) of samples of [value].
Float32List _samples(int windows, double value) => Float32List.fromList([
  for (var i = 0; i < windows * speechFrameSize; i++)
    if (i.isEven) value else -value,
]);

void main() {
  late _MockOfflineSpeech speech;
  late List<String?> languages;

  setUpAll(() => registerFallbackValue(Float32List(0)));

  setUp(() {
    speech = _MockOfflineSpeech();
    languages = [];
    when(speech.isReady).thenAnswer((_) async => true);
    when(speech.isVadReady).thenAnswer((_) async => true);
    when(speech.resetSpeechDetection).thenAnswer((_) async {});
    when(speech.cancel).thenAnswer((_) async {});
    when(() => speech.detectSpeech(any())).thenAnswer((invocation) async {
      final samples = invocation.positionalArguments.first as Float32List;
      return WhisperVadFrames(
        Float32List.fromList([
          for (var i = 0; i < samples.length; i += speechFrameSize)
            if (samples[i].abs() > 0.1) 0.95 else 0.02,
        ]),
        frameSize: speechFrameSize,
      );
    });
    when(() => speech.transcribe(any(), language: any(named: 'language')))
        .thenAnswer((invocation) async {
          languages.add(invocation.namedArguments[#language] as String?);
          return const WhisperTranscription('Hola', language: 'es');
        });
  });

  group('isReady', () {
    test('is the speech model being there', () async {
      final recognizer = WhisperCaptionRecognizer(speech);
      expect(await recognizer.isReady(), isTrue);
      when(speech.isReady).thenAnswer((_) async => false);
      expect(await recognizer.isReady(), isFalse);
      when(speech.isReady).thenThrow(StateError('engine'));
      expect(await recognizer.isReady(), isFalse);
    });
  });

  test('cuts phrases at pauses and transcribes each', () async {
    final phrases = <TranscribedPhrase>[];
    final recording = await WhisperCaptionRecognizer(speech)
        .start(onPhrase: phrases.add, language: 'es-MX');
    verify(speech.resetSpeechDetection).called(1);
    recording
      ..add(_samples(20, 0.5))
      // 0.5 s of silence ends the phrase.
      ..add(_samples(20, 0));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await recording.finish();
    expect(phrases, hasLength(1));
    expect(phrases.single.text, 'Hola');
    expect(phrases.single.language, 'es');
    expect(languages, ['es']);
    expect(recording.pending, 0);
  });

  test('a long phrase is cut at 8 s for the captions to keep up', () async {
    final phrases = <TranscribedPhrase>[];
    final recording = await WhisperCaptionRecognizer(speech)
        .start(onPhrase: phrases.add);
    // 10 s of speech without a pause.
    for (var i = 0; i < 10; i++) {
      recording.add(_samples(32, 0.5));
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await recording.finish();
    expect(phrases, hasLength(2));
    expect(
      phrases.first.end - phrases.first.start,
      lessThanOrEqualTo(WhisperCaptionRecognizer.maxPhrase),
    );
    expect(languages, [null, null]);
  });

  test('without speech detection, loudness cuts the phrases', () async {
    when(speech.isVadReady).thenAnswer((_) async => false);
    final phrases = <TranscribedPhrase>[];
    final recording = await WhisperCaptionRecognizer(speech)
        .start(onPhrase: phrases.add);
    recording
      ..add(_samples(20, 0.5))
      ..add(_samples(30, 0));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await recording.finish();
    expect(phrases, hasLength(1));
    verifyNever(speech.resetSpeechDetection);
    verifyNever(() => speech.detectSpeech(any()));
  });

  test('a detector that fails to reset still records', () async {
    when(speech.resetSpeechDetection).thenThrow(StateError('vad'));
    final recording = await WhisperCaptionRecognizer(speech)
        .start(onPhrase: (_) {});
    recording.add(_samples(4, 0.5));
    await recording.cancel();
  });

  test('cancel drops what waits for the engine', () async {
    final phrases = <TranscribedPhrase>[];
    final recording = await WhisperCaptionRecognizer(speech)
        .start(onPhrase: phrases.add);
    recording.add(_samples(20, 0.5));
    await recording.cancel();
    await recording.finish();
    expect(phrases, isEmpty);
  });
}
