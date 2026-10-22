import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/settings/models/model_source.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:whisper_speech/whisper_speech.dart';

class _MockEngine extends Mock implements WhisperEngine;

/// [OfflineSpeech.download] with the settings' model source (W3-B).
void main() {
  late Directory root;
  late Uint8List bytes;
  late List<Uri> requests;

  const mirror = ModelSource(
    kind: ModelSourceKind.custom,
    customUrl: 'https://mirror.example/models/',
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('offline_speech_source_');
    bytes = Uint8List.fromList([for (var i = 0; i < 300; i++) i & 0xff]);
    requests = [];
  });
  tearDown(() => root.deleteSync(recursive: true));

  OfflineSpeech build({ModelSource Function()? modelSource}) => OfflineSpeech(
    whisper: WhisperSpeech(
      catalog: WhisperModelCatalog(
        models: [
          WhisperCatalogModel(
            id: 'tiny',
            name: 'ggml-tiny.bin',
            url: Uri.parse('https://models.example/ggml-tiny.bin'),
            size: bytes.length,
            sha1: sha1.convert(bytes).toString(),
            sha256: sha256.convert(bytes).toString(),
          ),
        ],
      ),
      root: root,
      httpClient: MockClient((request) async {
        requests.add(request.url);
        return request.url.host == 'mirror.example' ||
                request.url.host == 'models.example'
            ? http.Response.bytes(bytes, 200)
            : http.Response('missing', 404);
      }),
      engine: _MockEngine(),
      isAvailable: true,
    ),
    store: MemoryStore(),
    modelSource: modelSource,
  );

  test('downloads from the mirror of the model source', () async {
    await build(modelSource: () => mirror).download('tiny');
    expect(requests, [
      Uri.parse('https://mirror.example/models/whisper/ggml-tiny.bin'),
    ]);
  });

  test("uses the settings' source by default", () async {
    addTearDown(() => ModelSource.current = ModelSource.platformDefault);
    ModelSource.current = ModelSource.defaultHosts;
    await build().download('tiny');
    expect(requests, [Uri.parse('https://models.example/ggml-tiny.bin')]);
  });
}
