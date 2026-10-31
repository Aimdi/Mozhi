// The real engine (libmozhi_whisper.so from tool/build_native_linux.sh, or
// WHISPER_LIBRARY_PATH) with a real model of the catalogue ("Fast",
// ggml-tiny.bin) on real speech (whisper.cpp's samples/jfk.wav): what the
// phone does, on the build machine. tool/fetch_test_model.py puts the model
// (checked against the catalogue's SHA-256) and the sample in
// build/test_models; CI runs it (.github/workflows/main.yaml, "Analyze and
// test"). Skipped without them.
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper_speech/src/engine/ffi/isolate_engine.dart';
import 'package:whisper_speech/whisper_speech.dart';

import '../helpers/native_library.dart';
import '../helpers/wav.dart';

/// [text] in lower case, without punctuation, single-spaced.
String words(String text) => text
    .toLowerCase()
    .replaceAll(RegExp("[^a-z' ]+"), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

void main() {
  group('real transcription', skip: realTranscriptionSkip(), () {
    late String library;
    late String model;
    late List<int> pcm;

    setUpAll(() {
      library = nativeLibraryPath()!;
      model = speechModelPath()!;
      pcm = wavPcm16(File(speechSamplePath()!).readAsBytesSync());
    });

    test('the sample is 11 s of 16 kHz speech', () {
      expect(pcm.length ~/ 2 / whisperSampleRate, closeTo(11, 0.1));
    });

    test('the Fast model writes down what was said', () async {
      final engine = IsolateWhisperEngine(libraryPath: library);
      addTearDown(engine.dispose);
      final result = await engine.transcribe(
        model,
        pcm16ToFloat32(pcm),
        language: 'en',
      );
      expect(words(result.text), contains('ask not what your country'));
      expect(words(result.text), contains('what you can do for your country'));
      expect(result.language, 'en');
    });

    test('it tells that the speech is English', () async {
      final engine = IsolateWhisperEngine(libraryPath: library);
      addTearDown(engine.dispose);
      final result = await engine.transcribe(model, pcm16ToFloat32(pcm));
      expect(result.language, 'en');
      expect(words(result.text), contains('my fellow americans'));
    });

    test("the app's path: import the catalogue's file, then transcribe "
        'what the microphone delivered, chunk by chunk', () async {
      final root = Directory.systemTemp.createTempSync('whisper_real_');
      addTearDown(() => root.deleteSync(recursive: true));
      final catalog = WhisperModelCatalog.parse(
        File(p.join('assets', 'models.json')).readAsStringSync(),
      );
      final speech = WhisperSpeech(
        catalog: catalog,
        root: root,
        engine: createWhisperEngine(libraryPath: library),
        vadEngine: createWhisperVadEngine(libraryPath: library),
        isAvailable: true,
      );
      addTearDown(speech.dispose);

      // Checked against the catalogue's size, SHA-1 and SHA-256, as on the
      // phone ("Import from files").
      final imported = await speech.importFiles([File(model)]);
      expect(imported.installed.map((model) => model.id), ['tiny']);
      expect(await speech.isReady(), isTrue);

      // 100 ms chunks of 16-bit PCM, some splitting a sample, as `record`
      // delivers them (RecordPcmRecorder).
      final buffer = Pcm16Buffer(
        maxSamples: whisperWindow.inSeconds * whisperSampleRate,
      );
      for (var start = 0; start < pcm.length; start += 3201) {
        final end = start + 3201 > pcm.length ? pcm.length : start + 3201;
        buffer.add(pcm.sublist(start, end));
      }
      final result = await speech.transcribe(
        buffer.toFloat32List(),
        language: 'en',
      );
      expect(words(result.text), contains('ask not what your country'));
    });
  });
}
