import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:whisper_speech/whisper_speech.dart';

class _MockOfflineSpeech extends Mock implements OfflineSpeech;

/// A microphone that delivers what the test [emit]s.
class _FakeRecorder implements PcmRecorder {
  bool permission = true;
  final List<bool> permissionRequests = [];
  Exception? startError;
  Completer<void>? startGate;
  int starts = 0;
  int stops = 0;
  int disposes = 0;
  StreamController<Uint8List>? controller;

  void emit(Uint8List chunk) => controller!.add(chunk);

  @override
  Future<bool> hasPermission({bool request = true}) async {
    permissionRequests.add(request);
    return permission;
  }

  @override
  Future<Stream<Uint8List>> start() async {
    starts++;
    if (startGate case final gate?) await gate.future;
    if (startError case final error?) throw error;
    return (controller = StreamController<Uint8List>()).stream;
  }

  @override
  Future<void> stop() async {
    stops++;
    // Not awaited: the done event never arrives without a listener.
    unawaited(controller?.close());
  }

  @override
  Future<void> dispose() async => disposes++;
}

/// [samples] samples of a square wave of [amplitude] (0..1): its RMS
/// level is 20·log10(amplitude) dBFS.
Uint8List chunk(double amplitude, {int samples = 1600}) {
  final data = ByteData(samples * 2);
  final value = (amplitude * 32767).round();
  for (var i = 0; i < samples; i++) {
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
  late List<double> levels;

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  /// Delivers a loud chunk to the adapter.
  Future<void> speak() async {
    recorder.emit(chunk(0.5));
    await flush();
  }

  setUpAll(() => registerFallbackValue(Float32List(0)));

  setUp(() {
    speech = _MockOfflineSpeech();
    recorder = _FakeRecorder();
    errors = [];
    statuses = [];
    results = [];
    levels = [];
    when(() => speech.isReady()).thenAnswer((_) async => true);
    // One pass, by loudness (the phrase mode has tests of its own).
    when(() => speech.isVadReady()).thenAnswer((_) async => false);
    when(() => speech.transcribe(any(), language: any(named: 'language')))
        .thenAnswer((_) async => const WhisperTranscription('hello'));
    when(() => speech.cancel()).thenAnswer((_) async {});
    adapter = WhisperSpeechRecognizerAdapter(
      speech: speech,
      recorder: recorder,
    );
  });

  Future<bool> initialize() =>
      adapter.initialize(onError: errors.add, onStatus: statuses.add);

  Future<void> listen({
    String? localeId = 'de',
    Duration pauseFor = const Duration(seconds: 3),
    Duration listenFor = const Duration(seconds: 60),
  }) async {
    await initialize();
    await adapter.listen(
      request: SpeechListenRequest(
        localeId: localeId,
        onDevice: true,
        pauseFor: pauseFor,
        listenFor: listenFor,
      ),
      onResult: (text, {required isFinal}) => results.add((text, isFinal)),
      onSoundLevel: levels.add,
    );
  }

  group('initialize', () {
    test('needs an installed model', () async {
      when(() => speech.isReady()).thenAnswer((_) async => false);
      expect(await initialize(), isFalse);
      expect(
        errors.single.message,
        OfflineSpeechRecognizerAdapter.modelMissingCode,
      );
      expect(errors.single.permanent, isTrue);
      expect(recorder.permissionRequests, isEmpty);
    });

    test('asks for the microphone', () async {
      recorder.permission = false;
      expect(await initialize(), isFalse);
      expect(errors.single.message, 'error_permission');
      expect(recorder.permissionRequests, [true]);
    });

    test('succeeds with a model and the microphone', () async {
      expect(await initialize(), isTrue);
      expect(errors, isEmpty);
    });

    test('isReady treats failures as not ready', () async {
      expect(await adapter.isReady(), isTrue);
      when(() => speech.isReady()).thenThrow(Exception('disk'));
      expect(await adapter.isReady(), isFalse);
    });

    test('hasPermission does not ask', () async {
      expect(await adapter.hasPermission(), isTrue);
      expect(recorder.permissionRequests, [false]);
    });
  });

  test("offers Whisper's languages and lets Whisper detect by "
      'default', () async {
    final locales = await adapter.locales();
    expect(locales, hasLength(99));
    expect(locales.first, const SpeechRecognizerLocale('en', 'English'));
    expect(
      locales.map((l) => l.id),
      containsAll(<String>['jw', 'he', 'no', 'haw']),
    );
    expect(await adapter.systemLocaleId(), isNull);
  });

  group('a session', () {
    test('records, transcribes after stop and delivers one final '
        'result', () async {
      await listen();
      expect(statuses, [SpeechRecognizerStatus.listening]);
      recorder
        ..emit(chunk(0.5))
        ..emit(chunk(0.001));
      await flush();
      expect(levels, [closeTo(-6.02, 0.01), closeTo(-60, 0.1)]);

      await adapter.stop();
      expect(recorder.stops, 1);
      expect(statuses.last, SpeechRecognizerStatus.transcribing);
      await flush();

      final samples =
          verify(() => speech.transcribe(captureAny(), language: 'de'))
                  .captured
                  .single
              as Float32List;
      expect(samples, hasLength(3200));
      expect(samples.first, closeTo(0.5, 1e-3));
      expect(results, [('hello', true)]);
      expect(statuses.last, SpeechRecognizerStatus.done);
      expect(errors, isEmpty);
      // Over: stop and cancel do nothing now.
      await adapter.stop();
      await adapter.cancel();
      expect(recorder.stops, 1);
      verifyNever(() => speech.cancel());
    });

    test('passes the Whisper language, or none to detect it', () async {
      await listen(localeId: 'jw');
      await speak();
      await adapter.stop();
      await flush();
      verify(() => speech.transcribe(any(), language: 'jw')).called(1);

      await listen(localeId: null);
      await speak();
      await adapter.stop();
      await flush();
      verify(() => speech.transcribe(any())).called(1);
    });

    test('reports the language of the final result', () async {
      expect(adapter.detectedLanguage, isNull);
      when(() => speech.transcribe(any(), language: any(named: 'language')))
          .thenAnswer(
            (_) async => const WhisperTranscription('ok', language: 'jw'),
          );
      String? seen;
      await initialize();
      await adapter.listen(
        request: const SpeechListenRequest(onDevice: true),
        onResult: (text, {required isFinal}) => seen = adapter.detectedLanguage,
        onSoundLevel: levels.add,
      );
      await speak();
      await adapter.stop();
      await flush();
      // The app code (Whisper's `jw` is Javanese, `jv`).
      expect(seen, 'jv');
      expect(adapter, isA<LanguageDetectingSpeechRecognizer>());

      when(() => speech.transcribe(any(), language: any(named: 'language')))
          .thenAnswer((_) async => const WhisperTranscription('ok'));
      await listen();
      await speak();
      await adapter.stop();
      await flush();
      expect(adapter.detectedLanguage, isNull);
    });

    test('silence is not transcribed', () async {
      await listen();
      recorder
        ..emit(chunk(0))
        ..emit(chunk(0.0005));
      await adapter.stop();
      await flush();
      verifyNever(
        () => speech.transcribe(any(), language: any(named: 'language')),
      );
      expect(errors.single.message, 'error_no_match');
      expect(errors.single.permanent, isFalse);
      expect(results, isEmpty);
      expect(statuses.last, SpeechRecognizerStatus.done);
    });

    test('an empty transcription is no match', () async {
      when(() => speech.transcribe(any(), language: any(named: 'language')))
          .thenAnswer((_) async => const WhisperTranscription(''));
      await listen();
      await speak();
      await adapter.stop();
      await flush();
      expect(errors.single.message, 'error_no_match');
    });

    test('reports engine failures and a deleted model', () async {
      when(() => speech.transcribe(any(), language: any(named: 'language')))
          .thenThrow(const WhisperEngineException('boom'));
      await listen();
      await speak();
      await adapter.stop();
      await flush();
      expect(
        errors.last.message,
        OfflineSpeechRecognizerAdapter.engineErrorCode,
      );
      expect(errors.last.permanent, isFalse);

      when(() => speech.transcribe(any(), language: any(named: 'language')))
          .thenThrow(const WhisperModelMissingException());
      await listen();
      await speak();
      await adapter.stop();
      await flush();
      expect(
        errors.last.message,
        OfflineSpeechRecognizerAdapter.modelMissingCode,
      );
      expect(errors.last.permanent, isTrue);
    });

    test('a cancelled transcription reports nothing', () async {
      when(() => speech.transcribe(any(), language: any(named: 'language')))
          .thenThrow(const WhisperCancelledException());
      await listen();
      await speak();
      await adapter.stop();
      await flush();
      expect(errors, isEmpty);
      expect(results, isEmpty);
      expect(statuses.last, SpeechRecognizerStatus.transcribing);
    });

    test('stops on its own at the maximum length', () async {
      adapter = WhisperSpeechRecognizerAdapter(
        speech: speech,
        recorder: recorder,
        maxDuration: const Duration(milliseconds: 200),
      );
      await listen();
      recorder
        ..emit(chunk(0.5, samples: 2000))
        ..emit(chunk(0.5, samples: 2000));
      await flush();
      expect(recorder.stops, 1);
      expect(statuses, contains(SpeechRecognizerStatus.transcribing));
      final samples =
          verify(() => speech.transcribe(captureAny(), language: 'de'))
                  .captured
                  .single
              as Float32List;
      expect(samples, hasLength(3200));
    });

    test('a shorter listenFor caps the recording', () async {
      await listen(listenFor: const Duration(milliseconds: 100));
      recorder.emit(chunk(0.5, samples: 3000));
      await flush();
      expect(statuses, contains(SpeechRecognizerStatus.transcribing));
    });

    test('says whether it heard speech, not just noise', () async {
      expect(adapter, isA<VoiceActivitySpeechRecognizer>());
      expect(adapter.heardSpeech, isFalse);
      final heard = <bool>[];
      await initialize();
      await adapter.listen(
        request: const SpeechListenRequest(localeId: 'de', onDevice: true),
        onResult: (text, {required isFinal}) {},
        // Read while the level is reported.
        onSoundLevel: (_) => heard.add(adapter.heardSpeech),
      );
      recorder
        // Digital silence, a noisy room (-60 dBFS), then speech.
        ..emit(chunk(0))
        ..emit(chunk(0.001))
        ..emit(chunk(0.5));
      await flush();
      expect(heard, [false, false, true]);
      await adapter.stop();
      await flush();
      // Between sessions nothing is heard.
      expect(adapter.heardSpeech, isFalse);
    });

    test('stops after a pause following speech', () async {
      await listen(pauseFor: const Duration(milliseconds: 200));
      recorder
        ..emit(chunk(0.001))
        ..emit(chunk(0.001))
        ..emit(chunk(0.001));
      await flush();
      // No speech yet: waiting.
      expect(statuses, [SpeechRecognizerStatus.listening]);
      recorder
        ..emit(chunk(0.3))
        ..emit(chunk(0.001))
        ..emit(chunk(0.001));
      await flush();
      expect(statuses.last, isNot(SpeechRecognizerStatus.listening));
      expect(results, [('hello', true)]);
    });

    test('a microphone stream that ends on its own is transcribed', () async {
      await listen();
      await speak();
      await recorder.controller!.close();
      await flush();
      expect(results, [('hello', true)]);
    });

    test('a failing microphone is an audio error', () async {
      recorder.startError = Exception('busy');
      await listen();
      expect(errors.single.message, 'error_audio_error');
      expect(statuses, isEmpty);

      recorder.startError = null;
      errors.clear();
      await listen();
      recorder.controller!.addError(Exception('lost'));
      await flush();
      expect(errors.single.message, 'error_audio_error');
      expect(recorder.stops, 1);
    });
  });

  group('cancel', () {
    test('drops a recording', () async {
      await listen();
      await speak();
      await adapter.cancel();
      expect(recorder.stops, 1);
      await flush();
      verifyNever(
        () => speech.transcribe(any(), language: any(named: 'language')),
      );
      expect(statuses, [SpeechRecognizerStatus.listening]);
    });

    test('stops a transcription and drops its result', () async {
      final transcription = Completer<WhisperTranscription>();
      when(() => speech.transcribe(any(), language: any(named: 'language')))
          .thenAnswer((_) => transcription.future);
      await listen();
      await speak();
      await adapter.stop();
      await flush();
      await adapter.cancel();
      verify(() => speech.cancel()).called(1);
      transcription.complete(const WhisperTranscription('late'));
      await flush();
      expect(results, isEmpty);
    });

    test('a failing engine cancel is ignored', () async {
      when(() => speech.cancel()).thenThrow(Exception('gone'));
      final transcription = Completer<WhisperTranscription>();
      when(() => speech.transcribe(any(), language: any(named: 'language')))
          .thenAnswer((_) => transcription.future);
      await listen();
      await speak();
      await adapter.stop();
      await adapter.cancel();
      transcription.complete(const WhisperTranscription('late'));
      await flush();
      expect(results, isEmpty);
    });

    test('while the microphone opens releases it', () async {
      recorder.startGate = Completer();
      await initialize();
      final listening = adapter.listen(
        request: const SpeechListenRequest(),
        onResult: (text, {required isFinal}) => results.add((text, isFinal)),
        onSoundLevel: levels.add,
      );
      await flush();
      await adapter.cancel();
      recorder.startGate!.complete();
      await listening;
      expect(recorder.stops, 1);
      expect(statuses, isEmpty);
    });

    test('a new session cancels the previous one', () async {
      await listen();
      await speak();
      final first = recorder.controller!;
      await listen();
      expect(first.isClosed, isTrue);
      await flush();
      verifyNever(
        () => speech.transcribe(any(), language: any(named: 'language')),
      );
    });
  });

  test('dispose releases the microphone', () async {
    await listen();
    await adapter.dispose();
    expect(recorder.stops, 1);
    expect(recorder.disposes, 1);
  });

  test('chunks after the end are ignored', () async {
    await listen();
    final controller = recorder.controller!;
    await adapter.cancel();
    expect(controller.isClosed, isTrue);
    expect(levels, isEmpty);
  });
}
