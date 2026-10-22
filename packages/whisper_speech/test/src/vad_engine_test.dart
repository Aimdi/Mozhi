// Voice activity detection with the real engine (libmozhi_whisper.so from
// tool/build_native_linux.sh, or WHISPER_LIBRARY_PATH) and whisper.cpp's
// Silero test model, which is the real model (it finds JFK's phrases in
// samples/jfk.wav). Skipped when the library is not built.
@Timeout(Duration(minutes: 2))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper_speech/src/engine/engine_factory_stub.dart' as stub;
import 'package:whisper_speech/src/engine/ffi/isolate_engine.dart';
import 'package:whisper_speech/src/engine/ffi/native_engine.dart';
import 'package:whisper_speech/whisper_speech.dart';

import '../helpers/native_library.dart';

const _vadModel = 'for-tests-silero-v6.2.0-ggml.bin';

/// The samples of a 16-bit mono PCM WAV file.
Float32List readWav(String path) {
  final bytes = File(path).readAsBytesSync();
  final data = ByteData.sublistView(bytes);
  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final size = data.getUint32(offset + 4, Endian.little);
    if (id == 'data') {
      return pcm16ToFloat32(bytes.sublist(offset + 8, offset + 8 + size));
    }
    offset += 8 + size + (size & 1);
  }
  throw FormatException('No data chunk', path);
}

/// The speech probabilities of [samples] fed in chunks of [chunk].
List<double> detectAll(
  NativeWhisperEngine engine,
  String model,
  Float32List samples,
  int chunk,
) => [
  for (var offset = 0; offset < samples.length; offset += chunk)
    ...engine
        .detectSpeech(
          model,
          Float32List.sublistView(
            samples,
            offset,
            (offset + chunk).clamp(0, samples.length),
          ),
        )
        .probabilities,
];

/// The mean probability of the windows from [from] to [to] seconds.
double meanBetween(List<double> probabilities, double from, double to) {
  final first = (from * 16000 / 512).floor();
  final last = (to * 16000 / 512).floor();
  final window = probabilities.sublist(first, last);
  return window.reduce((a, b) => a + b) / window.length;
}

void main() {
  group('factory', () {
    test('creates the isolate detector', () {
      expect(createWhisperVadEngine(), isA<IsolateWhisperVadEngine>());
    });

    test('the web stub fails detection', () async {
      final engine = stub.createWhisperVadEngine();
      await expectLater(
        engine.detect('vad.bin', Float32List(512)),
        throwsA(isA<WhisperEngineException>()),
      );
      await engine.reset();
      await engine.release('vad.bin');
      await engine.dispose();
    });
  });

  test('WhisperVadFrames describes itself', () {
    final frames = WhisperVadFrames(
      Float32List.fromList([0.1, 0.9]),
      frameSize: 512,
    );
    expect(frames.length, 2);
    expect(frames.toString(), 'WhisperVadFrames(2 x 512)');
    expect(WhisperVadFrames.empty.length, 0);
  });

  group('without the library', () {
    test('the isolate detector fails to start and recovers', () async {
      final engine = IsolateWhisperVadEngine(libraryPath: '/no/such/lib.so');
      // Nothing started: nothing to reset, release or stop.
      await engine.reset();
      await engine.release('vad.bin');
      await expectLater(
        engine.detect('vad.bin', Float32List(512)),
        throwsA(
          isA<WhisperEngineException>().having(
            (error) => error.message,
            'message',
            contains('Cannot load the native engine'),
          ),
        ),
      );
      await engine.dispose();
      await expectLater(
        engine.detect('vad.bin', Float32List(512)),
        throwsA(isA<WhisperEngineException>()),
      );
      await engine.dispose();
    });
  });

  group('native detector', skip: nativeLibrarySkip(), () {
    late String library;
    late String vad;
    late Float32List jfk;

    setUpAll(() {
      library = nativeLibraryPath()!;
      vad = testModelPath(_vadModel)!;
      jfk = readWav(
        p.absolute(
          'native',
          'third_party',
          'whisper.cpp',
          'samples',
          'jfk.wav',
        ),
      );
    });

    test('hears the phrases of a speech and the pauses between', () {
      final engine = NativeWhisperEngine.open(libraryPath: library);
      final probabilities = detectAll(engine, vad, jfk, 1600);
      // 11 s at 16 kHz in windows of 512 samples.
      expect(probabilities, hasLength(jfk.length ~/ 512));
      expect(probabilities.every((value) => value >= 0 && value <= 1), isTrue);
      // "And so my fellow Americans" ... "ask not".
      expect(meanBetween(probabilities, 0.5, 2), greaterThan(0.8));
      expect(meanBetween(probabilities, 2.5, 3.2), lessThan(0.2));
      expect(meanBetween(probabilities, 5.6, 7.4), greaterThan(0.8));
      engine.dispose();
    });

    test('gives the same probabilities however the stream is cut', () {
      final engine = NativeWhisperEngine.open(libraryPath: library);
      final whole = detectAll(engine, vad, jfk, 16000);
      engine.resetSpeech();
      final small = detectAll(engine, vad, jfk, 511);
      expect(small, whole);
      // A fresh stream after reset: the same again.
      engine.resetSpeech();
      expect(detectAll(engine, vad, jfk, 4096), whole);
      // Fewer samples than a window: nothing yet, kept for later.
      engine.resetSpeech();
      expect(engine.detectSpeech(vad, Float32List(300)).length, 0);
      expect(engine.detectSpeech(vad, Float32List(300)).length, 1);
      expect(engine.detectSpeech(vad, Float32List(0)).length, 0);
      engine.dispose();
    });

    test('silence is no speech', () {
      final engine = NativeWhisperEngine.open(libraryPath: library);
      final frames = engine.detectSpeech(vad, Float32List(16000));
      expect(frames.frameSize, 512);
      expect(frames.length, 31);
      expect(frames.probabilities.every((value) => value < 0.2), isTrue);
      engine.dispose();
    });

    test('refuses files that are no Silero model', () {
      final engine = NativeWhisperEngine.open(libraryPath: library);
      expect(
        () => engine.detectSpeech(testModelPath()!, Float32List(512)),
        throwsA(
          isA<WhisperEngineException>().having(
            (error) => error.message,
            'message',
            startsWith('load: not a Silero VAD model'),
          ),
        ),
      );
      expect(
        () => engine.detectSpeech('/no/such/vad.bin', Float32List(512)),
        throwsA(isA<WhisperEngineException>()),
      );
      engine.dispose();
    });

    test('release unloads the detector or the model at a path', () {
      final engine = NativeWhisperEngine.open(libraryPath: library);
      final first = engine.detectSpeech(
        vad,
        Float32List.sublistView(jfk, 0, 8000),
      );
      engine
        ..release('other.bin')
        ..release(vad);
      // Loaded again with a new stream: the same probabilities.
      final again = engine.detectSpeech(
        vad,
        Float32List.sublistView(jfk, 0, 8000),
      );
      expect(again.probabilities, first.probabilities);
      engine.dispose();
    });

    test('runs in a background isolate of its own', () async {
      final native = NativeWhisperEngine.open(libraryPath: library);
      final expected = detectAll(native, vad, jfk, 1600);
      native.dispose();

      final engine = IsolateWhisperVadEngine(libraryPath: library);
      final heard = <double>[];
      for (var offset = 0; offset < jfk.length; offset += 1600) {
        final frames = await engine.detect(
          vad,
          Float32List.sublistView(
            jfk,
            offset,
            (offset + 1600).clamp(0, jfk.length),
          ),
        );
        heard.addAll(frames.probabilities);
      }
      expect(heard, expected);
      await engine.reset();
      final first = await engine.detect(
        vad,
        Float32List.sublistView(jfk, 0, 1600),
      );
      expect(first.probabilities, expected.sublist(0, 3));
      await expectLater(
        engine.detect(testModelPath()!, Float32List(512)),
        throwsA(isA<WhisperEngineException>()),
      );
      await engine.release(vad);
      await engine.dispose();
      // Usable again after dispose.
      expect((await engine.detect(vad, Float32List(1024))).length, 2);
      await engine.dispose();
    });
  });
}
