import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:whisper_speech/whisper_speech.dart';

class _MockOfflineSpeech extends Mock implements OfflineSpeech;

class _FakeRecorder implements PcmRecorder {
  StreamController<Uint8List>? controller;
  int stops = 0;

  void emit(Uint8List chunk) => controller!.add(chunk);

  @override
  Future<bool> hasPermission({bool request = true}) async => true;

  @override
  Future<Stream<Uint8List>> start() async =>
      (controller = StreamController<Uint8List>()).stream;

  @override
  Future<void> stop() async {
    stops++;
    unawaited(controller?.close());
  }

  @override
  Future<void> dispose() async {}
}

/// PCM16 bytes of [windows] windows of 512 samples of a square wave of
/// [amplitude].
Uint8List pcm(int windows, double amplitude) {
  final data = ByteData(windows * 512 * 2);
  final value = (amplitude * 32767).round();
  for (var i = 0; i < windows * 512; i++) {
    data.setInt16(i * 2, i.isEven ? value : -value, Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  late _MockOfflineSpeech speech;
  late _FakeRecorder recorder;
  late WhisperSpeechRecognizerAdapter adapter;
  late List<SpeechRecognizerError> errors;
  late List<SpeechRecognizerStatus> statuses;
  late List<(String, bool)> results;
  late List<String> texts;
  late List<String?> languages;
  late Completer<void>? transcribeGate;
  var transcriptions = 0;

  setUpAll(() => registerFallbackValue(Float32List(0)));

  setUp(() {
    speech = _MockOfflineSpeech();
    recorder = _FakeRecorder();
    errors = [];
    statuses = [];
    results = [];
    texts = ['Guten Tag.', 'Wie geht es?', 'Gut.'];
    languages = ['de', 'de', 'en'];
    transcribeGate = null;
    transcriptions = 0;
    when(speech.isReady).thenAnswer((_) async => true);
    when(speech.isVadReady).thenAnswer((_) async => true);
    when(speech.resetSpeechDetection).thenAnswer((_) async {});
    when(speech.cancel).thenAnswer((_) async {});
    // Loud windows are speech.
    when(() => speech.detectSpeech(any())).thenAnswer((invocation) async {
      final samples = invocation.positionalArguments.first as Float32List;
      return WhisperVadFrames(
        Float32List.fromList([
          for (var i = 0; i < samples.length; i += 512)
            0.02 + (samples[i].abs() > 0.1 ? 0.93 : 0),
        ]),
        frameSize: 512,
      );
    });
    when(() => speech.transcribe(any(), language: any(named: 'language')))
        .thenAnswer((_) async {
          final index = transcriptions++;
          if (transcribeGate case final gate?) await gate.future;
          return WhisperTranscription(
            index < texts.length ? texts[index] : '',
            language: index < languages.length ? languages[index] : null,
          );
        });
    adapter = WhisperSpeechRecognizerAdapter(
      speech: speech,
      recorder: recorder,
    );
  });

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> listen({
    String? localeId = 'de',
    Duration pauseFor = const Duration(seconds: 1),
    Duration listenFor = const Duration(seconds: 60),
  }) async {
    await adapter.initialize(onError: errors.add, onStatus: statuses.add);
    await adapter.listen(
      request: SpeechListenRequest(
        localeId: localeId,
        onDevice: true,
        pauseFor: pauseFor,
        listenFor: listenFor,
      ),
      onResult: (text, {required isFinal}) => results.add((text, isFinal)),
      onSoundLevel: (_) {},
    );
  }

  test(
    'text arrives phrase by phrase; the final result is all of it',
    () async {
      await listen();
      verify(speech.resetSpeechDetection).called(1);
      expect(statuses, [SpeechRecognizerStatus.listening]);
      recorder.emit(pcm(20, 0.5));
      await settle();
      expect(adapter.heardSpeech, isTrue);
      expect(results, isEmpty);
      // A 416 ms pause ends the phrase: transcribed while recording goes on.
      recorder.emit(pcm(13, 0.001));
      await settle();
      expect(results, [('Guten Tag.', false)]);
      expect(statuses, [SpeechRecognizerStatus.listening]);

      recorder
        ..emit(pcm(20, 0.5))
        ..emit(pcm(13, 0.001));
      await settle();
      expect(results.last, ('Guten Tag. Wie geht es?', false));

      // A second of silence after speech ends the recording.
      recorder.emit(pcm(19, 0.001));
      await settle();
      expect(recorder.stops, 1);
      expect(results.last, ('Guten Tag. Wie geht es?', true));
      expect(adapter.detectedLanguage, 'de');
      expect(statuses, [
        SpeechRecognizerStatus.listening,
        SpeechRecognizerStatus.transcribing,
        SpeechRecognizerStatus.done,
      ]);
      verify(() => speech.transcribe(any(), language: 'de')).called(2);
      expect(errors, isEmpty);
    },
  );

  test('stop transcribes the phrase in progress', () async {
    await listen(localeId: null);
    recorder.emit(pcm(20, 0.5));
    await settle();
    await adapter.stop();
    await settle();
    expect(results, [('Guten Tag.', true)]);
    verify(() => speech.transcribe(any())).called(1);
  });

  test('silence is no match and never transcribed', () async {
    await listen();
    recorder.emit(pcm(30, 0.001));
    await settle();
    await adapter.stop();
    await settle();
    expect(errors.single.message, 'error_no_match');
    verifyNever(
      () => speech.transcribe(any(), language: any(named: 'language')),
    );
  });

  test('gives up after the no-speech timeout without speech', () async {
    adapter = WhisperSpeechRecognizerAdapter(
      speech: speech,
      recorder: recorder,
      noSpeechTimeout: const Duration(seconds: 1),
    );
    await listen();
    // 0.96 s of a quiet room: still waiting.
    recorder.emit(pcm(30, 0.001));
    await settle();
    expect(recorder.stops, 0);
    recorder.emit(pcm(2, 0.001));
    await settle();
    expect(recorder.stops, 1);
    expect(errors.single.message, 'error_no_match');
    verifyNever(
      () => speech.transcribe(any(), language: any(named: 'language')),
    );
  });

  test('a phrase the engine fails is an engine error', () async {
    when(() => speech.transcribe(any(), language: any(named: 'language')))
        .thenThrow(const WhisperEngineException('boom'));
    await listen();
    recorder.emit(pcm(20, 0.5));
    await settle();
    await adapter.stop();
    await settle();
    expect(
      errors.single.message,
      OfflineSpeechRecognizerAdapter.engineErrorCode,
    );
  });

  test('records up to listenFor, not one 30 s window', () async {
    await listen(listenFor: const Duration(seconds: 2));
    // 1.6 s of speech: no pause, no end yet.
    recorder.emit(pcm(50, 0.5));
    await settle();
    expect(recorder.stops, 0);
    recorder.emit(pcm(20, 0.5));
    await settle();
    expect(recorder.stops, 1);
    expect(results.single.$2, isTrue);
  });

  test('cancel while a phrase is transcribed stops the engine', () async {
    transcribeGate = Completer();
    await listen();
    recorder
      ..emit(pcm(20, 0.5))
      ..emit(pcm(13, 0.001));
    await settle();
    await adapter.cancel();
    verify(speech.cancel).called(1);
    transcribeGate!.complete();
    await settle();
    expect(results, isEmpty);
    expect(errors, isEmpty);
  });

  test('a cancel while it checks for the detector starts nothing', () async {
    final ready = Completer<bool>();
    when(speech.isVadReady).thenAnswer((_) => ready.future);
    await adapter.initialize(onError: errors.add, onStatus: statuses.add);
    final listening = adapter.listen(
      request: const SpeechListenRequest(),
      onResult: (text, {required isFinal}) {},
      onSoundLevel: (_) {},
    );
    await settle();
    await adapter.cancel();
    ready.complete(true);
    await listening;
    expect(recorder.controller, isNull);
    expect(statuses, isEmpty);
  });

  test('without the detector it records in one pass', () async {
    when(speech.isVadReady).thenAnswer((_) async => false);
    await listen();
    recorder
      ..emit(pcm(20, 0.5))
      ..emit(pcm(13, 0.001));
    await settle();
    expect(results, isEmpty);
    await adapter.stop();
    await settle();
    expect(results, [('Guten Tag.', true)]);
    verifyNever(() => speech.detectSpeech(any()));
  });

  test('a failing detector hands over to loudness', () async {
    when(speech.resetSpeechDetection).thenThrow(StateError('vad'));
    when(() => speech.detectSpeech(any())).thenThrow(StateError('vad'));
    await listen();
    recorder
      ..emit(pcm(20, 0.5))
      ..emit(pcm(13, 0.001));
    await settle();
    expect(results, [('Guten Tag.', false)]);
  });
}
