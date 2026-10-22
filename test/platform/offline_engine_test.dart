import 'dart:convert';
import 'dart:io';

import 'package:bergamot_translator/bergamot_translator.dart';
// The engine createBergamotEngine makes, to check its cache size.
import 'package:bergamot_translator/src/engine/ffi/isolate_engine.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mozhi/core/network/network_session.dart';
import 'package:mozhi/offline/data/unavailable_offline_translator.dart';
import 'package:mozhi/platform/native_memory.dart';
import 'package:mozhi/platform/offline_engine.dart' as engine;
import 'package:mozhi/platform/offline_engine_io.dart';
import 'package:translation_repository/translation_repository.dart';

/// The app's real catalog (assets of packages/bergamot_translator).
final String _catalog = File('packages/bergamot_translator/assets/catalog.json')
    .readAsStringSync();

class _Bundle extends CachingAssetBundle {
  new(this.assets);

  final Map<String, String> assets;
  final requested = <String>[];

  @override
  Future<ByteData> load(String key) async {
    requested.add(key);
    final value = assets[key];
    if (value == null) throw StateError('Unable to load asset: $key');
    return ByteData.sublistView(utf8.encode(value));
  }

  @override
  Future<String> loadString(String key, {bool cache = true}) async =>
      utf8.decode((await load(key)).buffer.asUint8List());
}

class _Engine implements BergamotEngine {
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

/// A [BergamotBatchEngine] counting [trim] calls.
class _BatchEngine extends _Engine implements BergamotBatchEngine {
  int trims = 0;

  @override
  Future<List<OfflineTranslation>> translateBatch(
    List<ModelPaths> chain,
    List<String> texts, {
    bool html = false,
    bool details = false,
    Future<void>? abort,
  }) async => [for (final text in texts) OfflineTranslation(text: text)];

  @override
  Future<void> preload(List<ModelPaths> chain) async {}

  @override
  Future<void> trim() async => trims++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  late _Bundle bundle;

  setUp(() {
    support = Directory.systemTemp.createTempSync('mozhi_offline_engine_');
    bundle = _Bundle({ModelCatalog.assetKey: _catalog});
  });
  tearDown(() => support.deleteSync(recursive: true));

  Future<BergamotTranslator> create({
    bool isAvailable = true,
    Future<bool> Function()? isMetered,
    http.Client? client,
  }) async => await createBergamotOfflineTranslator(
    bundle: bundle,
    supportDirectory: () async => support,
    isMeteredConnection: isMetered ?? () async => false,
    httpClient: client,
    isAvailable: isAvailable,
    engine: _Engine(),
  ) as BergamotTranslator;

  group('createBergamotOfflineTranslator', () {
    test('creates Bergamot with the bundled catalog in the support '
        'directory', () async {
      final translator = await create();

      expect(bundle.requested, [ModelCatalog.assetKey]);
      expect(translator.isAvailable, isTrue);
      expect(translator.supportedLanguages, containsAll(['en', 'de', 'es']));
      expect(
        translator.models.root.path,
        '${support.path}${Platform.pathSeparator}$offlineModelsFolder',
      );
      expect(translator.downloadSize('de'), greaterThan(0));
    });

    test(
      'removes leftovers of interrupted installs in the background',
      () async {
        final staging = Directory(
          '${support.path}/$offlineModelsFolder/models/.staging/en-de-1',
        )..createSync(recursive: true);
        final part = File(
          '${support.path}/$offlineModelsFolder/models/.downloads/en-de/v/'
          'model.gz.part',
        )..createSync(recursive: true);

        await create();
        // Deleting runs on the I/O thread: wait for it (up to 5 s).
        for (var i = 0; i < 250 && staging.existsSync(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }

        expect(staging.existsSync(), isFalse);
        // Partial downloads are kept for resuming.
        expect(part.existsSync(), isTrue);
      },
    );

    test('cleans nothing up where the engine cannot run', () async {
      final staging = Directory(
        '${support.path}/$offlineModelsFolder/models/.staging/x',
      )..createSync(recursive: true);

      final translator = await create(isAvailable: false);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(translator.isAvailable, isFalse);
      expect(staging.existsSync(), isTrue);
    });

    test('asks the metered check before a Wi-Fi-only download', () async {
      var asked = 0;
      final translator = await create(
        isMetered: () async {
          asked++;
          return true;
        },
      );

      await expectLater(
        translator.downloadLanguage('de'),
        throwsA(isA<MeteredConnectionException>()),
      );
      expect(asked, 1);
    });

    group('downloads', () {
      late NetworkSession previous;
      late List<Uri> requested;

      setUp(() {
        previous = NetworkSession.current;
        requested = [];
        NetworkSession.current = NetworkSession(
          httpClient: MockClient((request) async {
            requested.add(request.url);
            return http.Response('gone', 404);
          }),
        );
      });
      tearDown(() => NetworkSession.current = previous);

      test('go through the current network session by default', () async {
        final translator = await create();

        await expectLater(
          translator.downloadLanguage('de', wifiOnly: false),
          throwsA(
            isA<ModelDownloadException>().having(
              (e) => e.statusCode,
              'statusCode',
              404,
            ),
          ),
        );
        expect(requested, isNotEmpty);
        expect(requested.first.host, 'storage.googleapis.com');
        expect(requested.first.scheme, 'https');
      });

      test('use a given client instead', () async {
        final client = MockClient((request) async => http.Response('', 503));
        final translator = await create(client: client);

        await expectLater(
          translator.downloadLanguage('de', wifiOnly: false),
          throwsA(
            isA<ModelDownloadException>().having(
              (e) => e.statusCode,
              'statusCode',
              503,
            ),
          ),
        );
        expect(requested, isEmpty);
      });
    });

    test('checks the network with MeteredNetwork by default', () async {
      final translator = await createBergamotOfflineTranslator(
        bundle: bundle,
        supportDirectory: () async => support,
        httpClient: MockClient((request) async => http.Response('', 404)),
        isAvailable: true,
        engine: _Engine(),
      );

      // Off Android MeteredNetwork reports unmetered, so a Wi-Fi-only
      // download goes ahead (and fails at the mock server).
      await expectLater(
        translator.downloadLanguage('de'),
        throwsA(isA<ModelDownloadException>()),
      );
    });

    group('memory', () {
      const gib = 1024 * 1024 * 1024;

      Future<BergamotTranslator> sized(DeviceMemory? memory) async =>
          await createBergamotOfflineTranslator(
            bundle: bundle,
            supportDirectory: () async => support,
            isMeteredConnection: () async => false,
            isAvailable: true,
            deviceMemory: () async => memory,
            memoryBudget: NativeMemoryBudget(),
          ) as BergamotTranslator;

      Matcher caching(int models) => isA<IsolateBergamotEngine>().having(
        (engine) => engine.maxLoadedModels,
        'maxLoadedModels',
        models,
      );

      test('sizes the model cache from the device memory', () async {
        expect(
          (await sized(const DeviceMemory(totalBytes: 8 * gib))).engine,
          caching(4),
        );
        expect(
          (await sized(const DeviceMemory(isLowRam: true))).engine,
          caching(2),
        );
        expect((await sized(null)).engine, caching(3));
      });

      test('trims the engine on memory pressure', () async {
        final budget = NativeMemoryBudget();
        final batches = _BatchEngine();
        await createBergamotOfflineTranslator(
          bundle: bundle,
          supportDirectory: () async => support,
          isAvailable: true,
          engine: batches,
          memoryBudget: budget,
        );

        budget.didHaveMemoryPressure();
        await pumpEventQueue();

        expect(batches.trims, 1);
      });

      test('registers nothing where the engine cannot run', () async {
        final budget = NativeMemoryBudget();
        final batches = _BatchEngine();
        await createBergamotOfflineTranslator(
          bundle: bundle,
          supportDirectory: () async => support,
          isAvailable: false,
          engine: batches,
          memoryBudget: budget,
        );

        budget.didHaveMemoryPressure();
        await pumpEventQueue();

        expect(batches.trims, 0);
      });
    });

    test('is unavailable when the catalog cannot be loaded', () async {
      final translator = await createBergamotOfflineTranslator(
        bundle: _Bundle(const {}),
        supportDirectory: () async => support,
      );

      expect(translator, isA<UnavailableOfflineTranslator>());
    });

    test('is unavailable without a support directory', () async {
      final translator = await createBergamotOfflineTranslator(
        bundle: bundle,
        supportDirectory: () async => throw MissingPluginException('none'),
      );

      expect(translator, isA<UnavailableOfflineTranslator>());
      expect(translator.isAvailable, isFalse);
    });
  });

  group('deleteOfflineModelFiles', () {
    test('deletes the whole models folder', () async {
      final models = Directory('${support.path}/$offlineModelsFolder');
      File('${models.path}/models/.downloads/de-en/model.part')
        ..createSync(recursive: true)
        ..writeAsStringSync('partial');
      final other = File('${support.path}/other.txt')..writeAsStringSync('x');

      await deleteOfflineModelFiles(supportDirectory: () async => support);

      expect(models.existsSync(), isFalse);
      expect(other.existsSync(), isTrue);
    });

    test('does nothing without the folder', () async {
      await deleteOfflineModelFiles(supportDirectory: () async => support);

      expect(support.existsSync(), isTrue);
    });
  });

  group('createOfflineTranslator', () {
    test('falls back to the unavailable engine on a desktop host', () async {
      // No path_provider implementation in unit tests.
      final translator = await engine.createOfflineTranslator();

      expect(translator, isA<UnavailableOfflineTranslator>());
    });
  });

  group(CurrentSessionClient, () {
    late NetworkSession previous;

    setUp(() => previous = NetworkSession.current);
    tearDown(() => NetworkSession.current = previous);

    test('sends with the session current at request time', () async {
      final first = <Uri>[];
      final second = <Uri>[];
      final client = CurrentSessionClient();
      NetworkSession.current = NetworkSession(
        httpClient: MockClient((request) async {
          first.add(request.url);
          return http.Response('one', 200);
        }),
      );
      expect((await client.get(Uri.parse('https://a.example/x'))).body, 'one');

      NetworkSession.current = NetworkSession(
        httpClient: MockClient((request) async {
          second.add(request.url);
          return http.Response('two', 200);
        }),
      );
      expect((await client.get(Uri.parse('https://b.example/y'))).body, 'two');
      client.close();

      expect(first, [Uri.parse('https://a.example/x')]);
      expect(second, [Uri.parse('https://b.example/y')]);
    });
  });
}
