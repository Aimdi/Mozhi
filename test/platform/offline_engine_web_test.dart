import 'dart:convert';
import 'dart:io';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mozhi/offline/data/unavailable_offline_translator.dart';
import 'package:mozhi/platform/offline_engine_web.dart';

/// The app's real catalog (assets of packages/bergamot_translator).
final String _catalog = File('packages/bergamot_translator/assets/catalog.json')
    .readAsStringSync();

class _Bundle extends CachingAssetBundle {
  new({this.fail = false});

  final bool fail;

  @override
  Future<ByteData> load(String key) async {
    if (fail || key != ModelCatalog.assetKey) {
      throw StateError('Unable to load asset: $key');
    }
    return ByteData.sublistView(utf8.encode(_catalog));
  }
}

/// A worker answering `probe` with [probe] and recording requests.
class _Worker implements BergamotWorkerChannel {
  new([Map<String, Object?>? probe])
    : probe =
          probe ??
          {
            'simd': true,
            'opfs': true,
            'syncAccess': true,
            'decompression': true,
            'digest': true,
            'segmenter': true,
            'engine': true,
            'secure': true,
          };

  final Map<String, Object?> probe;
  final requests = <(String, Map<String, Object?>)>[];
  int terminated = 0;

  @override
  Future<Object?> request(
    String op, [
    Map<String, Object?> arguments = const {},
  ]) async {
    requests.add((op, arguments));
    return switch (op) {
      'probe' => probe,
      'list' => const <Object?>[],
      _ => null,
    };
  }

  @override
  void terminate() => terminated++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final client = MockClient((_) async => http.Response('', 404));

  group('createWebOfflineTranslator', () {
    test('a capable browser gets the WebAssembly engine', () async {
      final worker = _Worker();
      final translator = await createWebOfflineTranslator(
        bundle: _Bundle(),
        channel: worker,
        httpClient: client,
        isMeteredConnection: () async => false,
        requestPersistence: () async => true,
      );
      expect(translator, isA<BergamotTranslator>());
      translator as BergamotTranslator;
      expect(translator.isAvailable, isTrue);
      expect(translator.models, isA<OpfsModelManager>());
      expect(translator.engine, isA<WorkerBergamotEngine>());
      expect(translator.supportedLanguages, contains('de'));
      await pumpEventQueue();
      // Leftovers of interrupted installs are cleaned up in the background.
      expect([for (final (op, _) in worker.requests) op], ['probe', 'cleanUp']);
      expect(worker.terminated, 0);
    });

    test('a browser lacking something keeps the app online only', () async {
      final worker = _Worker({'engine': true, 'secure': true, 'digest': true});
      final translator = await createWebOfflineTranslator(
        bundle: _Bundle(),
        channel: worker,
        httpClient: client,
      );
      expect(translator, isA<UnavailableOfflineTranslator>());
      expect(translator.isAvailable, isFalse);
      expect(
        (translator as UnavailableOfflineTranslator).webRequirement,
        BergamotWebRequirement.storage,
      );
      expect(worker.terminated, 1);
    });

    test('a catalog that does not load gives no engine', () async {
      final worker = _Worker();
      final translator = await createWebOfflineTranslator(
        bundle: _Bundle(fail: true),
        channel: worker,
        httpClient: client,
      );
      expect(translator, isA<UnavailableOfflineTranslator>());
      expect(
        (translator as UnavailableOfflineTranslator).webRequirement,
        isNull,
      );
      expect(worker.terminated, 1);
    });

    test(
      'without a worker (not a browser) the engine files are missing',
      () async {
        final translator = await createOfflineTranslator();
        expect(
          (translator as UnavailableOfflineTranslator).webRequirement,
          BergamotWebRequirement.engineFiles,
        );
      },
    );
  });

  group('deleteOfflineModelFiles', () {
    test('removes the models and the partial downloads', () async {
      final worker = _Worker();
      await deleteOfflineModelFiles(channel: worker);
      expect(
        [for (final (op, arguments) in worker.requests) '$op $arguments'],
        ['remove {path: models}', 'remove {path: .downloads}'],
      );
    });

    test('does nothing without a worker', () async {
      await deleteOfflineModelFiles();
    });
  });
}
