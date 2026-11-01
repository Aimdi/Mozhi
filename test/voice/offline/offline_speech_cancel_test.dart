import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:whisper_speech/whisper_speech.dart';

class _MockEngine extends Mock implements WhisperEngine;

/// Cancelling a speech model download ([OfflineSpeech.cancelDownload]).
void main() {
  late Directory root;
  late Uint8List bytes;
  late WhisperCatalogModel tiny;
  late _MockEngine engine;
  late List<http.BaseRequest> requests;
  late bool stall;
  late OfflineSpeech speech;

  setUp(() {
    root = Directory.systemTemp.createTempSync('offline_speech_cancel_');
    bytes = Uint8List.fromList([for (var i = 0; i < 3000; i++) (i * 7) & 0xff]);
    tiny = WhisperCatalogModel(
      id: 'tiny',
      name: 'ggml-tiny.bin',
      url: Uri.parse('https://models.example/ggml-tiny.bin'),
      size: bytes.length,
      sha1: sha1.convert(bytes).toString(),
    );
    engine = _MockEngine();
    when(() => engine.release(any())).thenAnswer((_) async {});
    when(() => engine.dispose()).thenAnswer((_) async {});
    requests = [];
    stall = true;
    speech = OfflineSpeech(
      whisper: WhisperSpeech(
        catalog: WhisperModelCatalog(models: [tiny]),
        root: root,
        httpClient: MockClient.streaming((request, _) async {
          requests.add(request);
          final range = request.headers['Range'];
          final start = range == null
              ? 0
              : int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)![1]!);
          if (!stall) {
            return http.StreamedResponse(
              Stream.value(bytes.sublist(start)),
              start == 0 ? 200 : 206,
            );
          }
          // A slow server: the first 1000 bytes, then nothing.
          final controller = StreamController<List<int>>()
            ..add(bytes.sublist(0, 1000));
          return http.StreamedResponse(controller.stream, 200);
        }),
        engine: engine,
        isAvailable: true,
      ),
      store: MemoryStore(),
      isMeteredConnection: () async => false,
    );
  });

  tearDown(() async {
    await speech.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('stops the download; the next one resumes and installs', () async {
    final progress = <double>[];
    final download = speech.download('tiny', onProgress: progress.add);
    for (var i = 0; i < 500 && (progress.lastOrNull ?? 0) == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(progress.last, closeTo(1000 / 3000, 0.001));

    speech.cancelDownload('tiny');
    await expectLater(
      download,
      throwsA(isA<WhisperDownloadCancelledException>()),
    );
    expect(await speech.installed(), isEmpty);

    stall = false;
    await speech.download('tiny');
    expect(await speech.installed(), {'tiny'});
    expect(requests.last.headers['Range'], 'bytes=1000-');
  });

  test('cancelling when nothing downloads does nothing', () async {
    speech.cancelDownload('tiny');
    stall = false;
    await speech.download('tiny');
    expect(await speech.installed(), {'tiny'});
  });
}
