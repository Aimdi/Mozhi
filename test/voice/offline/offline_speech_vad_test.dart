import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:path/path.dart' as p;
import 'package:whisper_speech/whisper_speech.dart';

class _MockEngine extends Mock implements WhisperEngine;

class _MockVadEngine extends Mock implements WhisperVadEngine;

Uint8List _bytes(int length, int seed) =>
    Uint8List.fromList([for (var i = 0; i < length; i++) (i * seed) & 0xff]);

WhisperCatalogModel _model(String id, Uint8List bytes, {String? name}) =>
    WhisperCatalogModel(
      id: id,
      name: name ?? 'ggml-$id.bin',
      url: Uri.parse('https://models.example/${name ?? 'ggml-$id.bin'}'),
      size: bytes.length,
      sha1: sha1.convert(bytes).toString(),
    );

void main() {
  late Directory root;
  late Uint8List tinyBytes;
  late Uint8List baseBytes;
  late Uint8List vadBytes;
  late _MockEngine engine;
  late _MockVadEngine detector;
  late bool metered;
  late List<Uri> requests;
  late OfflineSpeech speech;

  setUpAll(() => registerFallbackValue(Float32List(0)));

  OfflineSpeech build({bool withVad = true}) => OfflineSpeech(
    whisper: WhisperSpeech(
      catalog: WhisperModelCatalog(
        models: [_model('tiny', tinyBytes), _model('base', baseBytes)],
        vad: withVad
            ? _model('silero-vad', vadBytes, name: 'ggml-silero-v6.2.0.bin')
            : null,
      ),
      root: root,
      httpClient: MockClient((request) async {
        requests.add(request.url);
        final path = request.url.path;
        return http.Response.bytes(
          path.contains('tiny')
              ? tinyBytes
              : path.contains('silero')
              ? vadBytes
              : baseBytes,
          200,
        );
      }),
      engine: engine,
      vadEngine: detector,
      isAvailable: true,
    ),
    store: MemoryStore(),
    isMeteredConnection: () async => metered,
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('offline_speech_vad_');
    tinyBytes = _bytes(200, 7);
    baseBytes = _bytes(400, 11);
    vadBytes = _bytes(100, 13);
    engine = _MockEngine();
    when(() => engine.release(any())).thenAnswer((_) async {});
    when(() => engine.dispose()).thenAnswer((_) async {});
    detector = _MockVadEngine();
    when(() => detector.detect(any(), any())).thenAnswer(
      (_) async => WhisperVadFrames(Float32List.fromList([1]), frameSize: 512),
    );
    when(() => detector.reset()).thenAnswer((_) async {});
    when(() => detector.release(any())).thenAnswer((_) async {});
    when(() => detector.dispose()).thenAnswer((_) async {});
    metered = false;
    requests = [];
    speech = build();
  });

  tearDown(() async {
    await speech.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('a speech model download brings the voice activity model', () async {
    expect(speech.vadModel?.id, 'silero-vad');
    expect(await speech.isVadReady(), isFalse);
    final progress = <double>[];
    await speech.download('tiny', onProgress: progress.add);
    expect(requests.map((url) => url.path), [
      '/ggml-silero-v6.2.0.bin',
      '/ggml-tiny.bin',
    ]);
    // One progress for both files: 100 + 200 bytes.
    expect(progress.first, lessThanOrEqualTo(100 / 300));
    expect(progress, contains(closeTo(100 / 300, 1e-9)));
    expect(progress.last, 1);
    expect(await speech.isVadReady(), isTrue);
    expect(await speech.installed(), {'tiny'});
    expect(await speech.selected(), 'tiny');

    // The next model comes alone.
    requests.clear();
    await speech.download('base');
    expect(requests.map((url) => url.path), ['/ggml-base.bin']);
  });

  test('downloads the voice activity model alone', () async {
    final progress = <double>[];
    await speech.downloadVoiceDetection(onProgress: progress.add);
    expect(requests.single.path, '/ggml-silero-v6.2.0.bin');
    expect(progress.last, 1);
    expect(await speech.isVadReady(), isTrue);
    expect(await speech.installed(), isEmpty);
    // Installed: nothing to do.
    await speech.downloadVoiceDetection();
    expect(requests, hasLength(1));
  });

  test('the voice activity download follows Wi-Fi only', () async {
    metered = true;
    await expectLater(
      speech.downloadVoiceDetection(),
      throwsA(isA<VoiceModelMeteredException>()),
    );
    expect(requests, isEmpty);
    await speech.downloadVoiceDetection(overMeteredNetwork: true);
    expect(requests, hasLength(1));
  });

  test('without one in the catalog there is nothing to download', () async {
    await speech.dispose();
    speech = build(withVad: false);
    expect(speech.vadModel, isNull);
    await speech.downloadVoiceDetection();
    await speech.download('tiny');
    expect(requests.map((url) => url.path), ['/ggml-tiny.bin']);
    expect(await speech.isVadReady(), isFalse);
  });

  test('detects speech and starts recordings afresh', () async {
    await speech.downloadVoiceDetection();
    final frames = await speech.detectSpeech(Float32List(512));
    expect(frames.probabilities, [1]);
    await speech.resetSpeechDetection();
    verify(() => detector.reset()).called(1);
  });

  test('isVadReady treats failures as not ready', () async {
    final broken = OfflineSpeech(
      whisper: _ThrowingWhisper(),
      store: MemoryStore(),
    );
    expect(await broken.isVadReady(), isFalse);
  });

  test('the voice activity model goes with the last speech model', () async {
    await speech.download('tiny');
    await speech.download('base');
    await speech.delete('tiny');
    expect(await speech.isVadReady(), isTrue);
    await speech.delete('base');
    expect(await speech.isVadReady(), isFalse);
    // Deleting it alone is fine too.
    await speech.downloadVoiceDetection();
    await speech.delete('silero-vad');
    expect(await speech.isVadReady(), isFalse);
  });

  test('imports it and keeps the speech model in use', () async {
    final files = [
      File(p.join(root.path, 'ggml-base.bin'))..writeAsBytesSync(baseBytes),
      File(p.join(root.path, 'ggml-silero-v6.2.0.bin'))
        ..writeAsBytesSync(vadBytes),
    ];
    final result = await speech.importFiles([
      for (final file in files) file.path,
    ]);
    expect(result.installed.map((m) => m.id), ['base', 'silero-vad']);
    expect(await speech.selected(), 'base');
    expect(await speech.isVadReady(), isTrue);

    // The voice activity model alone selects nothing.
    await speech.delete('base');
    await speech.importFiles([files.last.path]);
    expect(await speech.selected(), isNull);
  });
}

class _ThrowingWhisper extends Fake implements WhisperSpeech {
  @override
  Future<bool> isVadReady() async => throw StateError('broken');
}
