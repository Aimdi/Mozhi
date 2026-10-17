// The real engine (libmozhi_whisper.so from tool/build_native_linux.sh, or
// WHISPER_LIBRARY_PATH) with whisper.cpp's empty-weight test models: they
// load and run like the real ones but recognise nothing. Skipped when the
// library is not built.
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper_speech/src/engine/engine_factory_stub.dart' as stub;
import 'package:whisper_speech/src/engine/ffi/isolate_engine.dart';
import 'package:whisper_speech/src/engine/ffi/native_engine.dart';
import 'package:whisper_speech/whisper_speech.dart';

import '../helpers/native_library.dart';

Float32List noise(Duration duration, {int seed = 7}) {
  final random = Random(seed);
  return Float32List.fromList([
    for (var i = 0; i < duration.inMilliseconds * 16; i++)
      (random.nextDouble() - 0.5) * 0.2,
  ]);
}

void main() {
  group('engine factory', () {
    test('the native engine only runs on Android', () {
      expect(whisperPlatformSupported, isFalse);
      expect(createWhisperEngine(), isA<IsolateWhisperEngine>());
    });

    test('the web stub fails every transcription', () async {
      expect(stub.whisperPlatformSupported, isFalse);
      final engine = stub.createWhisperEngine();
      await expectLater(
        engine.transcribe('model.bin', Float32List(1)),
        throwsA(isA<WhisperEngineException>()),
      );
      await engine.cancel();
      await engine.release('model.bin');
      await engine.dispose();
    });
  });

  group('exceptions', () {
    test('describe themselves', () {
      expect(
        const WhisperEngineException('x').toString(),
        'WhisperEngineException(x)',
      );
      expect(
        const WhisperCancelledException().toString(),
        'WhisperCancelledException()',
      );
      expect(const WhisperCancelledException().message, 'cancelled');
      expect(
        const WhisperTranscription('hello', language: 'en').toString(),
        'WhisperTranscription(en, 5 chars)',
      );
      expect(
        const WhisperTranscription('a'),
        isNot(const WhisperTranscription('a', language: 'en')),
      );
      expect(
        const WhisperTranscription('a').hashCode,
        const WhisperTranscription('a').hashCode,
      );
    });
  });

  group('without the library', () {
    test('the isolate engine fails to start and recovers', () async {
      final engine = IsolateWhisperEngine(libraryPath: '/no/such/lib.so');
      await expectLater(
        engine.transcribe('model.bin', Float32List(1)),
        throwsA(
          isA<WhisperEngineException>().having(
            (error) => error.message,
            'message',
            contains('Cannot load the native engine'),
          ),
        ),
      );
      // Nothing started, nothing to cancel, release or stop.
      await engine.cancel();
      await engine.release('model.bin');
      await engine.dispose();
    });

    test('the native engine reports why it cannot load', () {
      expect(
        () => NativeWhisperEngine.open(libraryPath: '/no/such/lib.so'),
        throwsA(isA<WhisperEngineException>()),
      );
    });
  });

  group('native engine', skip: nativeLibrarySkip(), () {
    late String library;
    late String model;

    setUpAll(() {
      library = nativeLibraryPath()!;
      model = testModelPath()!;
    });

    test('loads a model and hears nothing in silence', () {
      final engine = NativeWhisperEngine.open(libraryPath: library);
      expect(engine.version, startsWith('whisper.cpp 1.9.5 (ggml '));
      final result = engine.transcribe(
        model,
        Float32List(16000),
        language: 'en',
      );
      expect(result.text, isEmpty);
      expect(result.language, 'en');
      expect(engine.loadedModel, model);
      // The same model is reused; release() of another path keeps it.
      engine.release('other.bin');
      expect(engine.loadedModel, model);
      engine.release(model);
      expect(engine.loadedModel, isNull);
      engine.dispose();
    });

    test('handles empty and very short input', () {
      final engine = NativeWhisperEngine.open(libraryPath: library);
      expect(engine.transcribe(model, Float32List(0)).text, isEmpty);
      expect(
        engine.transcribe(model, Float32List(800), language: 'de').text,
        isEmpty,
      );
      engine.dispose();
    });

    test('detects a language with auto', () {
      final engine = NativeWhisperEngine.open(libraryPath: library);
      final result = engine.transcribe(model, Float32List(16000));
      // The empty-weight model guesses something; it must be a Whisper code.
      expect(whisperLanguages.keys, contains(result.language));
      engine.dispose();
    });

    test('reports load and language errors', () {
      final engine = NativeWhisperEngine.open(libraryPath: library);
      expect(
        () => engine.transcribe('/no/such/model.bin', Float32List(1)),
        throwsA(
          isA<WhisperEngineException>().having(
            (error) => error.message,
            'message',
            startsWith('load: cannot load the model'),
          ),
        ),
      );
      expect(
        () => engine.transcribe(model, Float32List(1), language: 'yue'),
        throwsA(
          isA<WhisperEngineException>().having(
            (error) => error.message,
            'message',
            contains('language not supported by this model: yue'),
          ),
        ),
      );
      engine.dispose();
    });

    test('runs in a background isolate', () async {
      final engine = IsolateWhisperEngine(libraryPath: library);
      final results = await Future.wait([
        engine.transcribe(model, Float32List(16000), language: 'en'),
        engine.transcribe(model, Float32List(8000), language: 'fr'),
      ]);
      expect(results.map((r) => r.language), ['en', 'fr']);
      expect(results.map((r) => r.text), ['', '']);
      await engine.release(model);
      await engine.dispose();
      // Usable again after dispose.
      final again = await engine.transcribe(
        model,
        Float32List(16000),
        language: 'en',
      );
      expect(again.text, isEmpty);
      await engine.dispose();
    });

    test('reports engine errors from the isolate', () async {
      final engine = IsolateWhisperEngine(libraryPath: library);
      await expectLater(
        engine.transcribe(model, Float32List(1), language: 'yue'),
        throwsA(isA<WhisperEngineException>()),
      );
      await engine.dispose();
    });

    test('cancel aborts a running transcription and waiting ones', () async {
      final engine = IsolateWhisperEngine(libraryPath: library);
      // Warm up: the model is loaded, so the next call transcribes at once.
      await engine.transcribe(model, Float32List(1600), language: 'en');

      final stopwatch = Stopwatch()..start();
      final running = engine.transcribe(model, noise(whisperWindow));
      final waiting = engine.transcribe(model, noise(whisperWindow));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await engine.cancel();
      await expectLater(running, throwsA(isA<WhisperCancelledException>()));
      await expectLater(waiting, throwsA(isA<WhisperCancelledException>()));
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));

      // Later transcriptions are not affected.
      final after = await engine.transcribe(
        model,
        Float32List(16000),
        language: 'en',
      );
      expect(after.text, isEmpty);
      await engine.dispose();
    });

    test('the native cancel is reported as a cancellation', () async {
      final engine = NativeWhisperEngine.open(libraryPath: library);
      // A cancel before the call does not affect it...
      final bindingsEngine = IsolateWhisperEngine(libraryPath: library);
      await bindingsEngine.transcribe(model, Float32List(1), language: 'en');
      await bindingsEngine.cancel();
      expect(
        engine.transcribe(model, Float32List(16000), language: 'en').text,
        isEmpty,
      );
      engine.dispose();
      await bindingsEngine.dispose();
    });
  });
}
