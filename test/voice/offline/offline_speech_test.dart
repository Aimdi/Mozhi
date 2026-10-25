import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/offline/cubit/offline_models_cubit.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:path/path.dart' as p;
import 'package:whisper_speech/whisper_speech.dart';

class _MockEngine extends Mock implements WhisperEngine;

class _ThrowingStore extends MemoryStore {
  @override
  Future<String?> read(String key) async => throw StateError('read');

  @override
  Future<void> delete(String key) async => throw StateError('delete');
}

Uint8List _bytes(int length, int seed) =>
    Uint8List.fromList([for (var i = 0; i < length; i++) (i * seed) & 0xff]);

WhisperCatalogModel _model(String id, Uint8List bytes) => WhisperCatalogModel(
  id: id,
  name: 'ggml-$id.bin',
  url: Uri.parse('https://models.example/ggml-$id.bin'),
  size: bytes.length,
  sha1: sha1.convert(bytes).toString(),
);

void main() {
  late Directory root;
  late Uint8List tinyBytes;
  late Uint8List baseBytes;
  late _MockEngine engine;
  late MemoryStore store;
  late bool metered;
  late List<Uri> requests;
  late OfflineSpeech speech;

  setUpAll(() => registerFallbackValue(Float32List(0)));

  OfflineSpeech build({
    KeyValueStore? keyValueStore,
    bool available = true,
    Future<int?> Function(String path)? freeSpace,
    WhisperEngineBuild Function()? engineBuild,
  }) => OfflineSpeech(
    whisper: WhisperSpeech(
      catalog: WhisperModelCatalog(
        models: [_model('tiny', tinyBytes), _model('base', baseBytes)],
      ),
      root: root,
      httpClient: MockClient((request) async {
        requests.add(request.url);
        return http.Response.bytes(
          request.url.path.contains('tiny') ? tinyBytes : baseBytes,
          200,
        );
      }),
      engine: engine,
      isAvailable: available,
      freeSpace: freeSpace,
    ),
    store: keyValueStore ?? store,
    isMeteredConnection: () async => metered,
    engineBuild: engineBuild,
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('offline_speech_');
    tinyBytes = _bytes(200, 7);
    baseBytes = _bytes(400, 11);
    engine = _MockEngine();
    when(
      () => engine.transcribe(
        any(),
        any(),
        language: any(named: 'language'),
        threads: any(named: 'threads'),
      ),
    ).thenAnswer((_) async => const WhisperTranscription('hi'));
    when(() => engine.release(any())).thenAnswer((_) async {});
    when(() => engine.cancel()).thenAnswer((_) async {});
    when(() => engine.dispose()).thenAnswer((_) async {});
    store = MemoryStore();
    metered = false;
    requests = [];
    speech = build();
  });

  tearDown(() async {
    await speech.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('lists the catalog models and nothing installed', () async {
    expect(speech.isAvailable, isTrue);
    expect(speech.models.map((m) => m.id), ['tiny', 'base']);
    expect(speech.model('base')!.size, 400);
    expect(speech.model('large'), isNull);
    expect(await speech.installed(), isEmpty);
    expect(await speech.isReady(), isFalse);
    expect(await speech.selected(), isNull);
  });

  test('downloads a model and uses it', () async {
    final progress = <double>[];
    await speech.download('tiny', onProgress: progress.add);
    expect(progress.last, 1);
    expect(requests.single.path, '/ggml-tiny.bin');
    expect(await speech.installed(), {'tiny'});
    expect(await speech.isReady(), isTrue);
    expect(await speech.selected(), 'tiny');
    expect(store.values[OfflineSpeech.modelKey], 'tiny');

    await speech.transcribe(Float32List(4), language: 'de');
    verify(
      () => engine.transcribe(
        p.join(root.path, 'models', 'tiny', 'ggml-tiny.bin'),
        any(),
        language: 'de',
      ),
    ).called(1);
  });

  test('transcribes with the chosen model, detecting by default', () async {
    await speech.download('tiny');
    await speech.download('base');
    await speech.select('tiny');
    expect(await speech.selected(), 'tiny');
    await speech.transcribe(Float32List(4));
    verify(
      () => engine.transcribe(
        p.join(root.path, 'models', 'tiny', 'ggml-tiny.bin'),
        any(),
      ),
    ).called(1);
    await speech.cancel();
    verify(() => engine.cancel()).called(1);
  });

  test('without a stored choice the most accurate model is used', () async {
    await speech.download('tiny');
    await speech.download('base');
    store.values.remove(OfflineSpeech.modelKey);
    expect(await speech.selected(), 'base');
    await speech.delete('base');
    expect(await speech.selected(), 'tiny');
  });

  test('asks before downloading on a metered network', () async {
    metered = true;
    await expectLater(
      speech.download('tiny'),
      throwsA(isA<VoiceModelMeteredException>()),
    );
    expect(requests, isEmpty);
    expect(const VoiceModelMeteredException().toString(), contains('Metered'));

    await speech.download('tiny', overMeteredNetwork: true);
    expect(await speech.installed(), {'tiny'});
  });

  test('follows the Wi-Fi only setting of the offline languages', () async {
    metered = true;
    store.values[OfflineModelsCubit.wifiOnlyKey] = 'false';
    expect(await speech.wifiOnly(), isFalse);
    await speech.download('tiny');
    expect(await speech.installed(), {'tiny'});

    final failing = build(keyValueStore: _ThrowingStore());
    expect(await failing.wifiOnly(), isTrue);
    // The choice cannot be read: the installed model is used.
    expect(await failing.selected(), 'tiny');
  });

  test('rejects unknown models', () async {
    await expectLater(speech.download('large'), throwsArgumentError);
  });

  test('imports files and uses the last model installed', () async {
    final picked = Directory(p.join(root.path, 'picked'))..createSync();
    final tiny = File(p.join(picked.path, 'ggml-tiny.bin'))
      ..writeAsBytesSync(tinyBytes);
    final other = File(p.join(picked.path, 'notes.txt'))
      ..writeAsStringSync('x');
    final result = await speech.importFiles([tiny.path, other.path]);
    expect(result.installed.map((m) => m.id), ['tiny']);
    expect(result.unmatched.map((f) => f.path), [other.path]);
    expect(await speech.selected(), 'tiny');
    expect(requests, isEmpty);

    final nothing = await speech.importFiles([other.path]);
    expect(nothing.installed, isEmpty);
  });

  test('deleteAll removes every model and the choice', () async {
    await speech.download('tiny');
    await speech.download('base');
    await speech.deleteAll();
    expect(await speech.installed(), isEmpty);
    expect(store.values, isNot(contains(OfflineSpeech.modelKey)));
  });

  test('deleteAll reports the first failure', () async {
    final failing = build(keyValueStore: _ThrowingStore());
    await failing.download('tiny');
    await expectLater(failing.deleteAll(), throwsStateError);
    expect(await failing.installed(), isEmpty);
    when(() => engine.release(any())).thenThrow(StateError('busy'));
    await failing.download('tiny');
    await expectLater(failing.deleteAll(), throwsStateError);
  });

  group('free space, picked documents and the engine build', () {
    test('a download that cannot fit fails before the metered check', () async {
      metered = true;
      final tight = build(freeSpace: (_) async => 10);
      addTearDown(tight.dispose);
      await expectLater(
        tight.download('tiny'),
        throwsA(isA<WhisperInsufficientSpaceException>()),
      );
      expect(requests, isEmpty);
    });

    test('installs picked documents and uses the last one', () async {
      final result = await speech.importSources([
        _Document('ggml-base.bin', baseBytes),
      ]);
      expect(result.installed.map((model) => model.id), ['base']);
      expect(await speech.selected(), 'base');
    });

    test('tells which engine build runs here', () async {
      expect(speech.engineBuild, isNull);
      final known = build(
        engineBuild: () => const WhisperEngineBuild(
          variant: WhisperCpuVariant.i8mm,
          library: 'libmozhi_whisper_i8mm.so',
        ),
      );
      addTearDown(known.dispose);
      expect(known.engineBuild?.variant, WhisperCpuVariant.i8mm);
      final failing = build(
        engineBuild: () => throw const FileSystemException('cpuinfo'),
      );
      addTearDown(failing.dispose);
      expect(failing.engineBuild, isNull);
    });
  });
}

/// A picked document for [OfflineSpeech.importSources].
class _Document implements WhisperImportSource {
  new(this.name, this.bytes);

  @override
  final String name;

  final List<int> bytes;

  @override
  int? get length => bytes.length;

  @override
  Future<int> copyTo(File destination, {required int maxBytes}) async {
    await destination.writeAsBytes(bytes, flush: true);
    return bytes.length;
  }
}
