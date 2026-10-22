import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:whisper_speech/whisper_speech.dart';

import '../helpers/fake_models.dart';

class _MockEngine extends Mock implements WhisperEngine;

class _MockVadEngine extends Mock implements WhisperVadEngine;

void main() {
  late Directory root;
  late Uint8List tinyBytes;
  late Uint8List vadBytes;
  late WhisperCatalogModel tiny;
  late WhisperCatalogModel vad;
  late _MockEngine engine;
  late _MockVadEngine detector;
  late WhisperSpeech speech;
  final frames = WhisperVadFrames(
    Float32List.fromList([0.2, 0.9]),
    frameSize: 512,
  );

  setUpAll(() => registerFallbackValue(Float32List(0)));

  setUp(() {
    root = Directory.systemTemp.createTempSync('whisper_speech_vad_');
    tinyBytes = fakeModelBytes(300);
    vadBytes = fakeModelBytes(120, seed: 5);
    tiny = fakeModel('tiny', tinyBytes);
    vad = fakeModel('silero-vad', vadBytes, name: 'ggml-silero-v6.2.0.bin');
    engine = _MockEngine();
    when(() => engine.release(any())).thenAnswer((_) async {});
    when(() => engine.dispose()).thenAnswer((_) async {});
    detector = _MockVadEngine();
    when(() => detector.detect(any(), any())).thenAnswer((_) async => frames);
    when(() => detector.reset()).thenAnswer((_) async {});
    when(() => detector.release(any())).thenAnswer((_) async {});
    when(() => detector.dispose()).thenAnswer((_) async {});
    speech = WhisperSpeech(
      catalog: WhisperModelCatalog(models: [tiny], vad: vad),
      root: root,
      httpClient: MockClient(
        (request) async => http.Response.bytes(
          request.url.path.endsWith('tiny.bin') ? tinyBytes : vadBytes,
          200,
        ),
      ),
      engine: engine,
      vadEngine: detector,
      isAvailable: true,
    );
  });

  tearDown(() async {
    await speech.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('without the VAD model, speech detection is not ready', () async {
    expect(speech.vadModel, vad);
    expect(await speech.installedVad(), isNull);
    expect(await speech.isVadReady(), isFalse);
    await expectLater(
      speech.detectSpeech(Float32List(512)),
      throwsA(isA<WhisperModelMissingException>()),
    );
    verifyNever(() => detector.detect(any(), any()));
  });

  test('a catalog without one has no VAD model', () async {
    final without = WhisperSpeech(
      catalog: WhisperModelCatalog(models: [tiny]),
      root: root,
      engine: engine,
      vadEngine: detector,
      isAvailable: true,
    );
    expect(without.vadModel, isNull);
    expect(await without.installedVad(), isNull);
    expect(await without.isVadReady(), isFalse);
    without.models.close();
  });

  test('downloads the VAD model and detects speech with it', () async {
    await speech.download(vad);
    final installed = await speech.installedVad();
    expect(installed?.id, 'silero-vad');
    expect(await speech.isVadReady(), isTrue);
    // It is no speech model.
    expect(await speech.installedModels(), isEmpty);
    expect(await speech.isReady(), isFalse);
    expect(await speech.modelFor(), isNull);

    final samples = Float32List(1024);
    expect(await speech.detectSpeech(samples), same(frames));
    verify(() => detector.detect(installed!.path, samples)).called(1);
    await speech.resetSpeechDetection();
    verify(() => detector.reset()).called(1);
  });

  test('imports the VAD model with the speech models', () async {
    final files = [
      File(p.join(root.path, 'ggml-tiny.bin'))..writeAsBytesSync(tinyBytes),
      File(p.join(root.path, 'renamed.bin'))..writeAsBytesSync(vadBytes),
    ];
    final result = await speech.importFiles(files);
    expect(result.installed, [tiny, vad]);
    expect(await speech.installedModels(), [tiny]);
    expect(await speech.isVadReady(), isTrue);
  });

  test('delete releases the detector too', () async {
    await speech.download(vad);
    final path = (await speech.installedVad())!.path;
    await speech.delete('silero-vad');
    verify(() => detector.release(path)).called(1);
    verify(() => engine.release(path)).called(1);
    expect(await speech.installedVad(), isNull);
  });

  test('unload and dispose stop the detector', () async {
    await speech.unload();
    verify(() => detector.dispose()).called(1);
    await speech.dispose();
    verify(() => detector.dispose()).called(1);
  });

  test('refuses to detect where the engine cannot run', () async {
    final unavailable = WhisperSpeech(
      catalog: WhisperModelCatalog(models: [tiny], vad: vad),
      root: root,
      engine: engine,
      vadEngine: detector,
      isAvailable: false,
    );
    await expectLater(
      unavailable.detectSpeech(Float32List(512)),
      throwsA(isA<WhisperEngineException>()),
    );
    expect(await unavailable.isVadReady(), isFalse);
    unavailable.models.close();
  });
}
