import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/platform/offline_speech_io.dart';
import 'package:mozhi/platform/offline_speech_web.dart' as web;
import 'package:mozhi/voice/voice.dart' show VoiceModelMeteredException;
import 'package:path/path.dart' as p;
import 'package:whisper_speech/whisper_speech.dart';

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
