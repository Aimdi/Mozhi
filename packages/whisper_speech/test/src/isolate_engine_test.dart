// The real engine (libmozhi_whisper.so from tool/build_native_linux.sh, or
// WHISPER_LIBRARY_PATH) with whisper.cpp's empty-weight test models: they
// load and run like the real ones but recognise nothing. Skipped when the
// library is not built.
//
// Every transcription runs the encoder over a full 30 s window: a few
// seconds each, more on a busy build machine.
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper_speech/src/engine/engine_factory_stub.dart' as stub;
import 'package:whisper_speech/src/engine/ffi/bindings.dart';
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
      expect(await engine.library, isNull);
      await engine.cancel();
      await engine.release('model.bin');
      await engine.dispose();
    });

    test('a library resolver that fails is reported', () async {
      final engine = IsolateWhisperEngine(
        resolveLibrary: (_) => throw StateError('no CPU'),
      );
      final transcription = engine.transcribe('model.bin', Float32List(1));
      // Asked while the isolate starts: none, once it failed.
      final library = engine.library;
      await expectLater(
        transcription,
        throwsA(
          isA<WhisperEngineException>().having(
            (error) => error.message,
            'message',
            'Cannot load the native engine: Bad state: no CPU',
          ),
        ),
      );
      expect(await library, isNull);
      final vad = IsolateWhisperVadEngine(libraryPath: '/no/such/lib.so');
      await expectLater(
        vad.detect('vad.bin', Float32List(1)),
        throwsA(isA<WhisperEngineException>()),
      );
      expect(await vad.library, isNull);
      await engine.dispose();
      await vad.dispose();
    });

    test('the resolver gets the explicit path', () async {
      String? asked;
      final engine = IsolateWhisperEngine(
        libraryPath: '/no/such/lib.so',
        resolveLibrary: (path) {
          asked = path;
          return '/no/such/variant.so';
        },
      );
      await expectLater(
        engine.transcribe('model.bin', Float32List(1)),
        throwsA(
          isA<WhisperEngineException>().having(
            (error) => error.message,
            'message',
            contains('/no/such/variant.so'),
          ),
        ),
      );
      // In the worker isolate: this one's copy is untouched.
      expect(asked, isNull);
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

    test('reports the library its isolates opened', () async {
      final engine = IsolateWhisperEngine(libraryPath: library);
      final vad = IsolateWhisperVadEngine(libraryPath: library);
      expect(await engine.library, isNull);
      await engine.transcribe(model, Float32List(1600), language: 'en');
      await vad.reset();
      expect(await engine.library, library);
      expect(await vad.library, isNull);
      await engine.dispose();
      expect(await engine.library, isNull);
      await vad.dispose();
    });

    test('opens the variant the resolver picks and cancels in it', () async {
      // A copy of the library under a variant's name: another library in
      // the process (its own cancel state), as the variants are on a phone.
      final directory = Directory.systemTemp.createTempSync('whisper_cpu_');
      addTearDown(() => directory.deleteSync(recursive: true));
      final variant = p.join(
        directory.path,
        WhisperLibraryVariant.dotprod.fileName,
      );
      File(library).copySync(variant);
      final engine = IsolateWhisperEngine(resolveLibrary: (_) => variant);

      // Two windows. The engine checks for a cancel between its graph
      // computations (a window's encoder is a few): a cancel that reaches
      // the library ends the call within the first window.
      final samples = noise(whisperWindow * 2);
      final full = Stopwatch()..start();
      await engine.transcribe(model, samples, language: 'en');
      full.stop();
      expect(await engine.library, variant);

      final running = engine.transcribe(model, samples);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await engine.cancel();
      await expectLater(running, throwsA(isA<WhisperCancelledException>()));
      // The worker is free again within a window, not after both: the
      // cancel reached the library it runs (a cancel in the baseline
      // leaves it running to the end).
      final afterCancel = Stopwatch()..start();
      await engine.release(model);
      afterCancel.stop();
      expect(afterCancel.elapsed, lessThan(full.elapsed * 0.6));
      await engine.dispose();
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
      // Failed at once on this side, without waiting for the engine.
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 20)));

      // Later transcriptions are not affected.
      final after = await engine.transcribe(
        model,
        Float32List(16000),
        language: 'en',
      );
      expect(after.text, isEmpty);
      await engine.dispose();
    });

    test('the native cancel aborts a transcription that is running', () async {
      // In another isolate, as in the app; cancelled from this one until it
      // returns (a cancel only affects transcriptions already running).
      final libraryPath = library;
      final modelPath = model;
      var done = false;
      final outcome = Isolate.run(() {
        final engine = NativeWhisperEngine.open(libraryPath: libraryPath);
        try {
          engine.transcribe(modelPath, noise(whisperWindow));
          return 'finished';
        } on WhisperCancelledException {
          return 'cancelled';
        } finally {
          engine.dispose();
        }
      }).whenComplete(() => done = true);
      final bindings = WhisperBindings(WhisperBindings.open(library));
      while (!done) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        bindings.cancel();
      }
      expect(await outcome, 'cancelled');

      // A cancel before a call does not affect it.
      bindings.cancel();
      final engine = NativeWhisperEngine.open(libraryPath: library);
      expect(
        engine.transcribe(model, Float32List(1600), language: 'en').text,
        isEmpty,
      );
      engine.dispose();
    });
  });
}
