import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/image_translate/data/tesseract_text_recognition_service.dart';
import 'package:mozhi/offline/data/bergamot_model_details.dart';
import 'package:mozhi/phrasebook/data/starter_phrasebooks.dart';
import 'package:mozhi/phrasebook/models/starter_phrasebook.dart';
import 'package:mozhi/platform/download_foreground_service.dart';
import 'package:mozhi/voice/offline/offline_speech.dart';
import 'package:tesseract_ocr/tesseract_ocr.dart';
import 'package:whisper_speech/whisper_speech.dart';

import '../phrasebook/starter_fixtures.dart';

class _MockOcrEngine extends Mock implements OcrEngine;

class _MockWhisperEngine extends Mock implements WhisperEngine;

class _FakeBergamotEngine implements BergamotEngine {
  @override
  Future<String> translate(
    List<ModelPaths> chain,
    String text, {
    bool html = false,
  }) async => text;

  @override
  Future<void> release(String key) async {}

  @override
  Future<void> dispose() async {}
}

final class _FakeDownloadForegroundService
    implements DownloadForegroundService {
  final List<String> events = [];
  final StreamController<void> _cancels = StreamController<void>.broadcast();

  @override
  Stream<void> get cancelRequests => _cancels.stream;

  void triggerCancel() => _cancels.add(null);

  @override
  Future<void> start({required String title, int? progress}) async {
    events.add('start:$title:$progress');
  }

  @override
  Future<void> update({required String title, int? progress}) async {
    events.add('update:$title:$progress');
  }

  @override
  Future<void> stop() async {
    events.add('stop');
  }

  Future<void> dispose() => _cancels.close();
}

void main() {
  group('DownloadForegroundCoordinator', () {
    late _FakeDownloadForegroundService service;
    late DownloadForegroundCoordinator coordinator;

    setUp(() {
      service = _FakeDownloadForegroundService();
      coordinator = DownloadForegroundCoordinator(service: service);
    });

    tearDown(() async {
      await coordinator.dispose();
      await service.dispose();
    });

    test('starts, throttles progress updates and stops', () async {
      final result = await coordinator.track<String>(
        label: 'Gemma 4',
        run: (report) async {
          report(0.101);
          report(0.109); // Same whole percent -> ignored
          report(0.55);
          return 'ok';
        },
      );
      expect(result, 'ok');
      expect(coordinator.activeCount, 0);
      expect(service.events, [
        'start:Gemma 4:null',
        'update:Gemma 4:10',
        'update:Gemma 4:55',
        'stop',
      ]);
    });

    test('reference-counts overlapping downloads', () async {
      final firstDone = Completer<void>();
      final secondDone = Completer<void>();

      final first = coordinator.track<void>(
        label: 'Model A',
        run: (report) async {
          report(0.5);
          await firstDone.future;
        },
      );
      final second = coordinator.track<void>(
        label: 'Model B',
        run: (report) async {
          report(0.5);
          await secondDone.future;
        },
      );

      expect(coordinator.activeCount, 2);
      expect(service.events.first, 'start:Model A:null');
      expect(service.events, contains('update:Model A (+1):50'));

      firstDone.complete();
      await first;
      expect(coordinator.activeCount, 1);
      expect(service.events.last, isNot('stop'));

      secondDone.complete();
      await second;
      expect(coordinator.activeCount, 0);
      expect(service.events.last, 'stop');
    });

    test('routes notification cancel to active downloads', () async {
      var cancelled = false;
      final blocker = Completer<void>();
      final running = coordinator.track<void>(
        label: 'Whisper Small',
        onCancel: () async {
          cancelled = true;
          if (!blocker.isCompleted) blocker.complete();
        },
        run: (_) => blocker.future,
      );

      service.triggerCancel();
      await running;
      expect(cancelled, isTrue);
      expect(service.events.last, 'stop');
    });

    test(
      'catches sync and async errors from onCancel without leaking exceptions',
      () async {
        final blocker1 = Completer<void>();
        final blocker2 = Completer<void>();
        final blocker3 = Completer<void>();
        var thirdCancelled = false;

        final d1 = coordinator.track<void>(
          label: 'Sync Throw',
          onCancel: () {
            if (!blocker1.isCompleted) blocker1.complete();
            throw StateError('sync cancel failure');
          },
          run: (_) => blocker1.future,
        );
        final d2 = coordinator.track<void>(
          label: 'Async Throw',
          onCancel: () async {
            if (!blocker2.isCompleted) blocker2.complete();
            throw StateError('async cancel failure');
          },
          run: (_) => blocker2.future,
        );
        final d3 = coordinator.track<void>(
          label: 'Healthy Cancel',
          onCancel: () async {
            thirdCancelled = true;
            if (!blocker3.isCompleted) blocker3.complete();
          },
          run: (_) => blocker3.future,
        );

        service.triggerCancel();
        await Future.wait([d1, d2, d3]);
        await pumpEventQueue();

        expect(thirdCancelled, isTrue);
        expect(coordinator.activeCount, 0);
        expect(service.events.last, 'stop');
      },
    );
  });

  group('Downloader foreground tracking integration', () {
    late DownloadForegroundCoordinator original;
    late _FakeDownloadForegroundService service;
    late DownloadForegroundCoordinator coordinator;

    setUp(() {
      original = DownloadForegroundCoordinator.instance;
      service = _FakeDownloadForegroundService();
      coordinator = DownloadForegroundCoordinator(service: service);
      DownloadForegroundCoordinator.instance = coordinator;
    });

    tearDown(() async {
      DownloadForegroundCoordinator.instance = original;
      await coordinator.dispose();
      await service.dispose();
    });

    test(
      'tracks TesseractTextRecognitionService.downloadOcrLanguage',
      () async {
        final root = Directory.systemTemp.createTempSync('fg_ocr_');
        addTearDown(() => root.deleteSync(recursive: true));
        final bytes = List.generate(128, (i) => i);
        final catalog = TessdataCatalog([
          TessdataLanguage(
            code: 'deu',
            name: 'German',
            languages: const ['de'],
            url: Uri.parse('https://example.org/deu.traineddata'),
            size: bytes.length,
            sha256: sha256.convert(bytes).toString(),
          ),
        ]);
        final client = MockClient((_) async => http.Response.bytes(bytes, 200));
        final ocrService = TesseractTextRecognitionService(
          open: () async => TesseractOcr(
            catalog: catalog,
            root: root,
            httpClient: client,
            engine: _MockOcrEngine(),
          ),
          isSupported: true,
          isMeteredConnection: () async => false,
        );

        await ocrService.downloadOcrLanguage('deu', wifiOnly: false);

        expect(service.events.first, 'start:German:null');
        expect(service.events.last, 'stop');
      },
    );

    test('tracks OfflineSpeech.downloadVoiceDetection', () async {
      final root = Directory.systemTemp.createTempSync('fg_vad_');
      addTearDown(() => root.deleteSync(recursive: true));
      final vadBytes = List.generate(128, (i) => i ^ 0x5A);
      final vad = WhisperCatalogModel(
        id: 'silero-vad',
        name: 'ggml-silero-v5.1.2.bin',
        url: Uri.parse('https://example.org/vad.bin'),
        size: vadBytes.length,
        sha256: sha256.convert(vadBytes).toString(),
        sha1: sha1.convert(vadBytes).toString(),
      );
      final client = MockClient(
        (_) async => http.Response.bytes(vadBytes, 200),
      );
      final engine = _MockWhisperEngine();
      when(engine.dispose).thenAnswer((_) async {});
      final whisper = WhisperSpeech(
        catalog: WhisperModelCatalog(models: const [], vad: vad),
        root: root,
        httpClient: client,
        engine: engine,
        isAvailable: true,
      );
      addTearDown(whisper.dispose);
      final speech = OfflineSpeech(whisper: whisper, store: MemoryStore());

      await speech.downloadVoiceDetection();

      expect(service.events.first, 'start:ggml-silero-v5.1.2.bin:null');
      expect(service.events.last, 'stop');
    });

    test('tracks StarterPhrasebooks.install', () async {
      final bytes = starterPackBytes(starterPackJson());
      final pack = starterInfo(bytes);
      final client = MockClient((_) async => http.Response.bytes(bytes, 200));
      final books = StarterPhrasebooks(
        catalog: StarterPhrasebookCatalog([pack]),
        store: MemoryStore(),
        httpClient: client,
      );
      addTearDown(books.close);

      await books.install(pack);

      expect(service.events.first, 'start:Portuguese:null');
      expect(service.events.last, 'stop');
    });

    test(
      'BergamotModelDetails uses human-readable language name instead of zh-CN',
      () async {
        final root = Directory.systemTemp.createTempSync('fg_bergamot_');
        addTearDown(() => root.deleteSync(recursive: true));
        final rawBytes = utf8.encode('model-data-payload' * 16);
        final gzBytes = gzip.encode(rawBytes);
        final rawHash = sha256.convert(rawBytes).toString();
        final gzHash = sha256.convert(gzBytes).toString();
        CatalogFile makeFile(ModelFileKind kind, String pair) => CatalogFile(
          kind: kind,
          name: '${kind.name}.$pair.bin',
          url: Uri.parse('https://example.org/$pair/${kind.name}.bin.gz'),
          size: gzBytes.length,
          sha256: gzHash,
          uncompressedSize: rawBytes.length,
          uncompressedSha256: rawHash,
        );
        final catalog = ModelCatalog([
          CatalogModel(
            source: 'zh',
            target: 'en',
            version: '1.0',
            files: {
              ModelFileKind.model: makeFile(ModelFileKind.model, 'zh-en'),
              ModelFileKind.lexicalShortlist: makeFile(
                ModelFileKind.lexicalShortlist,
                'zh-en',
              ),
              ModelFileKind.vocab: makeFile(ModelFileKind.vocab, 'zh-en'),
            },
          ),
          CatalogModel(
            source: 'en',
            target: 'zh',
            version: '1.0',
            files: {
              ModelFileKind.model: makeFile(ModelFileKind.model, 'en-zh'),
              ModelFileKind.lexicalShortlist: makeFile(
                ModelFileKind.lexicalShortlist,
                'en-zh',
              ),
              ModelFileKind.vocab: makeFile(ModelFileKind.vocab, 'en-zh'),
            },
          ),
        ]);
        final client = MockClient(
          (_) async => http.Response.bytes(gzBytes, 200),
        );
        final translator = BergamotTranslator(
          catalog: catalog,
          root: root,
          isMeteredConnection: () async => false,
          httpClient: client,
          engine: _FakeBergamotEngine(),
          isAvailable: true,
        );
        addTearDown(translator.dispose);
        final details = BergamotModelDetails(translator);

        await details.download('zh-CN', wifiOnly: false);

        expect(service.events.first, 'start:Chinese (Simplified):null');
        expect(service.events.last, 'stop');
      },
    );
  });

  group('Android ModelDownloadService wiring', () {
    test('declares dataSync foreground service, plugin registration, and '
        'start/stop race protection', () {
      final manifest = File('android/app/src/main/AndroidManifest.xml')
          .readAsStringSync();
      expect(
        manifest,
        contains('android.permission.FOREGROUND_SERVICE_DATA_SYNC'),
      );
      expect(manifest, contains('android:name=".ModelDownloadService"'));
      expect(manifest, contains('android:foregroundServiceType="dataSync"'));

      final mainActivity = File(
        'android/app/src/main/kotlin/io/github/aimdi/mozhi/MainActivity.kt',
      ).readAsStringSync();
      expect(mainActivity, contains('ModelDownloadPlugin()'));

      final plugin = File(
        'android/app/src/main/kotlin/io/github/aimdi/mozhi/'
        'ModelDownloadPlugin.kt',
      ).readAsStringSync();
      expect(
        plugin,
        contains(MethodChannelDownloadForegroundService.channelName),
      );

      final service = File(
        'android/app/src/main/kotlin/io/github/aimdi/mozhi/'
        'ModelDownloadService.kt',
      ).readAsStringSync();
      expect(service, contains('pendingStop'));
      expect(service, contains('startRequested'));
      expect(service, contains('stateLock'));
      expect(service, contains('startForegroundSafe'));
      expect(service, contains('stopForegroundCompat'));
    });
  });
}
