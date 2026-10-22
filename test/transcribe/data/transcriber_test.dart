import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/transcribe/transcribe.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:whisper_speech/whisper_speech.dart';

import '../../voice/helpers/fake_speech_recognizer.dart';

class _MockOfflineSpeech extends Mock implements OfflineSpeech;

class _FakeRecorder implements PcmRecorder {
  bool permission = true;
  Exception? startError;
  StreamController<Uint8List>? controller;
  int stops = 0;
  int disposes = 0;

  void emit(Uint8List chunk) => controller!.add(chunk);

  @override
  Future<bool> hasPermission({bool request = true}) async => permission;

  @override
  Future<Stream<Uint8List>> start() async {
    if (startError case final error?) throw error;
    return (controller = StreamController<Uint8List>()).stream;
  }

  @override
  Future<void> stop() async {
    stops++;
    unawaited(controller?.close());
  }

  @override
  Future<void> dispose() async => disposes++;
}

Uint8List pcm(int windows, double amplitude) {
  final data = ByteData(windows * 512 * 2);
  final value = (amplitude * 32767).round();
  for (var i = 0; i < windows * 512; i++) {
    data.setInt16(i * 2, i.isEven ? value : -value, Endian.little);
  }
  return data.buffer.asUint8List();
}

Future<void> settle() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  setUpAll(() => registerFallbackValue(Float32List(0)));

  test('normalizedLevel and formatTranscriptTime', () {
    expect(normalizedLevel(-80), 0);
    expect(normalizedLevel(-35), 0.5);
    expect(normalizedLevel(0), 1);
    expect(formatTranscriptTime(const Duration(seconds: 65)), '1:05');
    expect(
      formatTranscriptTime(const Duration(hours: 1, seconds: 7)),
      '1:00:07',
    );
    expect(formatTranscriptTime(const Duration(seconds: -3)), '0:00');
  });

  group(WhisperTranscriber, () {
    late _MockOfflineSpeech speech;
    late _FakeRecorder recorder;
    late WhisperTranscriber transcriber;
    late List<TranscriberEvent> events;
    late bool done;
    var count = 0;

    setUp(() {
      speech = _MockOfflineSpeech();
      recorder = _FakeRecorder();
      events = [];
      done = false;
      count = 0;
      when(speech.isReady).thenAnswer((_) async => true);
      when(speech.isVadReady).thenAnswer((_) async => true);
      when(speech.resetSpeechDetection).thenAnswer((_) async {});
      when(speech.cancel).thenAnswer((_) async {});
      when(() => speech.detectSpeech(any())).thenAnswer((invocation) async {
        final samples = invocation.positionalArguments.first as Float32List;
        final probabilities = Float32List(samples.length ~/ 512);
        for (var i = 0; i < probabilities.length; i++) {
          probabilities[i] = samples[i * 512].abs() > 0.1 ? 0.95 : 0.02;
        }
        return WhisperVadFrames(probabilities, frameSize: 512);
      });
      when(() => speech.transcribe(any(), language: any(named: 'language')))
          .thenAnswer(
            (_) async =>
                WhisperTranscription('Phrase ${count++}.', language: 'de'),
          );
      transcriber = WhisperTranscriber(speech: speech, recorder: recorder);
    });

    void listen({String? language = 'de'}) {
      transcriber
          .listen(language: language)
          .listen(events.add, onDone: () => done = true);
    }

    test('hears phrase after phrase until stopped', () async {
      expect(transcriber.onDevice, isTrue);
      listen();
      await settle();
      expect(events, [const TranscriberListening()]);
      recorder
        ..emit(pcm(20, 0.5))
        ..emit(pcm(16, 0.001));
      await settle();
      final heard = events.whereType<TranscriberHeard>().single;
      expect(heard.phrase.text, 'Phrase 0.');
      expect(heard.phrase.language, 'de');
      verify(() => speech.transcribe(any(), language: 'de')).called(1);

      // It never stops on its own after a pause.
      recorder.emit(pcm(200, 0.001));
      await settle();
      expect(done, isFalse);
      expect(events.whereType<TranscriberLevel>().last.heardSpeech, isTrue);
      recorder.emit(pcm(20, 0.5));
      await settle();
      await transcriber.stop();
      await settle();
      expect(events.whereType<TranscriberHeard>(), hasLength(2));
      expect(done, isTrue);
      expect(recorder.stops, 1);
    });

    test('reports phrases waiting for the engine', () async {
      final gate = Completer<void>();
      when(() => speech.transcribe(any(), language: any(named: 'language')))
          .thenAnswer((_) async {
            await gate.future;
            return const WhisperTranscription('slow');
          });
      listen();
      await settle();
      recorder
        ..emit(pcm(20, 0.5))
        ..emit(pcm(16, 0.001));
      await settle();
      expect(events.whereType<TranscriberPending>().last.pending, 1);
      gate.complete();
      await settle();
      expect(events.whereType<TranscriberHeard>().single.pending, 0);
      await transcriber.cancel();
    });

    test('without the voice activity model, loudness cuts phrases', () async {
      when(speech.isVadReady).thenAnswer((_) async => false);
      listen(language: null);
      await settle();
      recorder
        ..emit(pcm(20, 0.5))
        ..emit(pcm(23, 0.001));
      await settle();
      expect(events.whereType<TranscriberHeard>(), hasLength(1));
      verifyNever(() => speech.detectSpeech(any()));
      verify(() => speech.transcribe(any())).called(1);
      await transcriber.stop();
    });

    test('a missing model, permission or microphone fails', () async {
      when(speech.isReady).thenAnswer((_) async => false);
      listen();
      await settle();
      expect(events, [
        const TranscriberFailed(SpeechInputFailure.offlineModelMissing),
      ]);
      expect(done, isTrue);

      when(speech.isReady).thenAnswer((_) async => true);
      recorder.permission = false;
      events.clear();
      listen();
      await settle();
      expect(events, [
        const TranscriberFailed(SpeechInputFailure.permissionDenied),
      ]);

      recorder
        ..permission = true
        ..startError = Exception('busy');
      events.clear();
      listen();
      await settle();
      expect(events, [const TranscriberFailed(SpeechInputFailure.audio)]);
    });

    test('a failing microphone stream fails the recording', () async {
      listen();
      await settle();
      recorder.controller!.addError(Exception('gone'));
      await settle();
      expect(events.last, const TranscriberFailed(SpeechInputFailure.audio));
      expect(done, isTrue);
    });

    test('a microphone stream that ends finishes the recording', () async {
      listen();
      await settle();
      recorder.emit(pcm(20, 0.5));
      await settle();
      await recorder.controller!.close();
      await settle();
      expect(events.whereType<TranscriberHeard>(), hasLength(1));
      expect(done, isTrue);
    });

    test('cancel drops the recording; listening again cancels the '
        'previous one', () async {
      listen();
      await settle();
      recorder.emit(pcm(20, 0.5));
      final first = events.length;
      listen();
      await settle();
      expect(done, isTrue);
      expect(events.length, greaterThan(first));
      await transcriber.cancel();
      await transcriber.cancel();
      await transcriber.stop();
      await transcriber.dispose();
      expect(recorder.disposes, 1);
    });

    test('a failing detector reset still listens', () async {
      when(speech.resetSpeechDetection).thenThrow(StateError('vad'));
      listen();
      await settle();
      expect(events, [const TranscriberListening()]);
      await transcriber.cancel();
    });
  });

  group(SystemTranscriber, () {
    late FakeSpeechRecognizer recognizer;
    late SpeechInputService service;
    late SystemTranscriber transcriber;
    late List<TranscriberEvent> events;
    late bool done;
    late DateTime now;

    setUp(() {
      recognizer = FakeSpeechRecognizer();
      service = SpeechInputService(
        store: MemoryStore(),
        adapter: recognizer,
        platformSupported: true,
        onDeviceSupported: false,
      );
      now = DateTime(2026, 10, 22, 9);
      transcriber = SystemTranscriber(
        service,
        clock: () => now,
        restartDelay: Duration.zero,
        stopTimeout: const Duration(milliseconds: 50),
      );
      events = [];
      done = false;
    });

    tearDown(() => service.dispose());

    void listen() => transcriber
        .listen(language: 'en')
        .listen(events.add, onDone: () => done = true);

    test('turns each utterance into a phrase and listens again', () async {
      expect(transcriber.onDevice, isFalse);
      listen();
      await settle();
      expect(events.first, const TranscriberListening());
      expect(events.whereType<TranscriberListening>(), hasLength(1));
      expect(recognizer.requests, hasLength(1));

      recognizer.emitResult('hello');
      await settle();
      expect(events, contains(const TranscriberPartial('hello')));
      now = now.add(const Duration(seconds: 4));
      recognizer.emitResult('hello there', isFinal: true);
      await settle();
      final heard = events.whereType<TranscriberHeard>().single.phrase;
      expect(heard.text, 'hello there');
      expect(heard.start, Duration.zero);
      expect(heard.end, const Duration(seconds: 4));
      // The next utterance.
      expect(recognizer.requests, hasLength(2));

      recognizer.emitLevel(5);
      await settle();
      expect(events.last, isA<TranscriberLevel>());
      // Silence: listen again.
      recognizer.emitError('error_no_match');
      await settle();
      expect(recognizer.requests, hasLength(3));

      await transcriber.stop();
      expect(recognizer.stopCalls, 1);
      recognizer.emitResult('bye', isFinal: true);
      await settle();
      expect(events.whereType<TranscriberHeard>().last.phrase.text, 'bye');
      expect(done, isTrue);
      expect(recognizer.requests, hasLength(3));
    });

    test('a recogniser that ends without a result listens again', () async {
      listen();
      await settle();
      recognizer.emitStatus(SpeechRecognizerStatus.done);
      await settle();
      expect(recognizer.requests, hasLength(2));
      await transcriber.cancel();
      await settle();
      expect(done, isTrue);
      expect(recognizer.cancelCalls, 1);
    });

    test('failures end the recording', () async {
      listen();
      await settle();
      recognizer.emitError('error_network');
      await settle();
      expect(events.last, const TranscriberFailed(SpeechInputFailure.network));
      expect(done, isTrue);
    });

    test('a recogniser that cannot start fails at once', () async {
      recognizer.initResult = false;
      listen();
      await settle();
      expect(events.single, isA<TranscriberFailed>());
      expect(done, isTrue);
    });

    test('a recogniser that never sends the last result is given up '
        'on', () async {
      listen();
      await settle();
      await transcriber.stop();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(done, isTrue);
      // Nothing listening: stop and cancel do nothing.
      await transcriber.stop();
      await transcriber.cancel();
    });
  });

  group(ScreenAwake, () {
    const channel = MethodChannel('test/screen');
    final calls = <Object?>[];
    Exception? error;

    setUp(() {
      calls.clear();
      error = null;
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'setKeepScreenOn');
            if (error case final failure?) throw failure;
            calls.add(call.arguments);
            return null;
          });
    });

    test('asks the platform, and never throws', () async {
      final awake = ScreenAwake(channel: channel, isWeb: false);
      await awake.setEnabled(enabled: true);
      await awake.setEnabled(enabled: false);
      expect(calls, [true, false]);
      error = PlatformException(code: 'refused');
      await awake.setEnabled(enabled: true);
      error = MissingPluginException();
      await awake.setEnabled(enabled: true);
      error = Exception('other');
      await awake.setEnabled(enabled: true);
      // The browser's lock (nothing off the web).
      await ScreenAwake(
        channel: channel,
        isWeb: true,
      ).setEnabled(enabled: true);
      await ScreenAwake(
        channel: channel,
        isWeb: true,
      ).setEnabled(enabled: false);
      expect(calls, [true, false]);
    });
  });
}
