import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:whisper_speech/whisper_speech.dart';

class _MockOfflineSpeech extends Mock implements OfflineSpeech;

class _FakeRecorder implements PcmRecorder {
  StreamController<Uint8List>? controller;

  void emit(Uint8List chunk) => controller!.add(chunk);

  @override
  Future<bool> hasPermission({bool request = true}) async => true;

  @override
  Future<Stream<Uint8List>> start() async =>
      (controller = StreamController<Uint8List>()).stream;

  @override
  Future<void> stop() async => unawaited(controller?.close());

  @override
  Future<void> dispose() async {}
}

/// PCM16 bytes of [windows] windows of 512 samples (32 ms) of a square
/// wave of [amplitude].
Uint8List _pcm(int windows, double amplitude) {
  final data = ByteData(windows * 512 * 2);
  final value = (amplitude * 32767).round();
  for (var i = 0; i < windows * 512; i++) {
    data.setInt16(i * 2, i.isEven ? value : -value, Endian.little);
  }
  return data.buffer.asUint8List();
}

/// A conversation's turn with offline speech ends at a real pause: the
/// pause the conversation asks for (`SpeechInputService.listen`'s
/// `pause`), measured by the voice activity detection.
void main() {
  late _MockOfflineSpeech speech;
  late _FakeRecorder recorder;
  late List<SpeechRecognizerStatus> statuses;
  late List<(String, bool)> results;

  setUpAll(() => registerFallbackValue(Float32List(0)));

  setUp(() {
    speech = _MockOfflineSpeech();
    recorder = _FakeRecorder();
    statuses = [];
    results = [];
    when(speech.isReady).thenAnswer((_) async => true);
    when(speech.resetSpeechDetection).thenAnswer((_) async {});
    when(speech.cancel).thenAnswer((_) async {});
    when(() => speech.detectSpeech(any())).thenAnswer((invocation) async {
      final samples = invocation.positionalArguments.first as Float32List;
      return WhisperVadFrames(
        Float32List.fromList([
          for (var i = 0; i < samples.length; i += 512)
            if (samples[i].abs() > 0.1) 0.95 else 0.02,
        ]),
        frameSize: 512,
      );
    });
    when(() => speech.transcribe(any(), language: any(named: 'language')))
        .thenAnswer(
          (_) async => const WhisperTranscription('Hola', language: 'es'),
        );
  });

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<WhisperSpeechRecognizerAdapter> listen(Duration pause) async {
    final adapter = WhisperSpeechRecognizerAdapter(
      speech: speech,
      recorder: recorder,
    );
    await adapter.initialize(onError: (_) {}, onStatus: statuses.add);
    await adapter.listen(
      request: SpeechListenRequest(onDevice: true, pauseFor: pause),
      onResult: (text, {required isFinal}) => results.add((text, isFinal)),
      onSoundLevel: (_) {},
    );
    return adapter;
  }

  for (final vad in [true, false]) {
    group(vad ? 'with speech detection' : 'by loudness', () {
      setUp(() => when(speech.isVadReady).thenAnswer((_) async => vad));

      test('ends the turn after 0.8 s of silence, not before', () async {
        await listen(const Duration(milliseconds: 800));
        recorder.emit(_pcm(20, 0.5));
        await settle();
        // 736 ms of silence: still listening.
        recorder.emit(_pcm(23, 0));
        await settle();
        expect(statuses, [SpeechRecognizerStatus.listening]);
        // 800 ms: the turn is over.
        recorder.emit(_pcm(2, 0));
        await settle();
        expect(statuses, contains(SpeechRecognizerStatus.transcribing));
        await settle();
        expect(results.last, ('Hola', true));
      });

      test('a longer pause lets the speaker think', () async {
        await listen(const Duration(seconds: 2));
        recorder.emit(_pcm(20, 0.5));
        await settle();
        // 1.5 s of silence, then the speaker goes on.
        recorder
          ..emit(_pcm(47, 0))
          ..emit(_pcm(10, 0.5));
        await settle();
        expect(statuses, [SpeechRecognizerStatus.listening]);
        recorder.emit(_pcm(63, 0));
        await settle();
        expect(statuses, contains(SpeechRecognizerStatus.transcribing));
      });
    });
  }
}
