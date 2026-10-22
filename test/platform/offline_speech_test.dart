import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/platform/native_memory.dart';
import 'package:mozhi/platform/offline_speech_io.dart';
import 'package:mozhi/platform/offline_speech_web.dart' as web;
import 'package:mozhi/voice/voice.dart' show VoiceModelMeteredException;
import 'package:path/path.dart' as p;
import 'package:whisper_speech/whisper_speech.dart';

/// A [WhisperEngine] counting [dispose] calls (unloading the model).
class _Engine implements WhisperEngine {
  int disposed = 0;

  @override
  Future<WhisperTranscription> transcribe(
    String modelPath,
    Float32List samples, {
    String? language,
    int threads = 0,
  }) async => const WhisperTranscription('');

  @override
  Future<void> cancel() async {}

  @override
  Future<void> release(String modelPath) async {}

  @override
  Future<void> dispose() async => disposed++;
}

class _Bundle extends CachingAssetBundle {
  new(this.values);

  final Map<String, String> values;

  @override
  Future<ByteData> load(String key) async {
    final value = values[key];
    if (value == null) throw StateError('Unable to load asset: $key');
    return ByteData.sublistView(utf8.encode(value));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  final catalog = File('packages/whisper_speech/assets/models.json')
      .readAsStringSync();

  setUp(() => support = Directory.systemTemp.createTempSync('support_'));
  tearDown(() => support.deleteSync(recursive: true));

  test('is not created where Whisper cannot run', () async {
    expect(whisperPlatformSupported, isFalse);
    expect(await createOfflineSpeech(store: MemoryStore()), isNull);
    expect(await web.createOfflineSpeech(store: MemoryStore()), isNull);
  });

  test('keeps the models in the support directory and cleans up', () async {
    final staging = Directory(
      p.join(support.path, offlineSpeechFolder, 'models', '.staging', 'x'),
    )..createSync(recursive: true);
    final speech = await createOfflineSpeech(
      store: MemoryStore(),
      bundle: _Bundle({WhisperModelCatalog.assetKey: catalog}),
      supportDirectory: () async => support,
      isAvailable: true,
      isMeteredConnection: () async => true,
    );
    expect(speech, isNotNull);
    expect(speech!.isAvailable, isTrue);
    expect(speech.models.map((m) => m.id), ['tiny', 'base']);
    expect(
      speech.whisper.models.root.path,
      p.join(support.path, offlineSpeechFolder),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(staging.existsSync(), isFalse);
    // The metered check is wired: Wi-Fi only is on by default.
    await expectLater(
      speech.download('tiny'),
      throwsA(isA<VoiceModelMeteredException>()),
    );
    await speech.dispose();
  });

  test('unloads the model in the background and on memory pressure', () async {
    final budget = NativeMemoryBudget();
    final engine = _Engine();
    final speech = await createOfflineSpeech(
      store: MemoryStore(),
      bundle: _Bundle({WhisperModelCatalog.assetKey: catalog}),
      supportDirectory: () async => support,
      isAvailable: true,
      engine: engine,
      memoryBudget: budget,
    );
    expect(speech!.whisper.idleUnloadAfter, speechModelIdleTimeout);

    budget.didChangeAppLifecycleState(AppLifecycleState.paused);
    await pumpEventQueue();
    expect(engine.disposed, 1);

    budget.didHaveMemoryPressure();
    await pumpEventQueue();
    expect(engine.disposed, 2);
    await speech.dispose();
  });

  test('is not created when the catalog cannot be loaded', () async {
    final speech = await createOfflineSpeech(
      store: MemoryStore(),
      bundle: _Bundle(const {}),
      supportDirectory: () async => support,
      isAvailable: true,
    );
    expect(speech, isNull);
  });
}
