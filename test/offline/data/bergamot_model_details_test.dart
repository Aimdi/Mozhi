import 'dart:convert';
import 'dart:io';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mozhi/offline/data/bergamot_model_details.dart';
import 'package:mozhi/offline/data/offline_model_details.dart';
import 'package:mozhi/offline/data/unavailable_offline_translator.dart';

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

Future<String> _sha256(List<int> bytes) async {
  final hash = await Sha256().hash(bytes);
  return [for (final byte in hash.bytes) byte.toRadixString(16).padLeft(2, '0')]
      .join();
}

/// A tiny catalog (one entry per direction, three small files each) and
/// the gzip bodies its URLs serve.
class _Catalog {
  final models = <Map<String, Object?>>[];
  final bodies = <Uri, List<int>>{};

  /// Bytes on disk of each pair once installed.
  final installedSizes = <String, int>{};

  /// Bytes to download per pair.
  final downloadSizes = <String, int>{};

  Future<void> add(String source, String target, String version) async {
    final pair = '$source-$target';
    final files = <String, Object?>{};
    var installed = 0;
    var download = 0;
    for (final (index, kind) in [
      'model',
      'lexicalShortlist',
      'vocab',
    ].indexed) {
      final raw = utf8.encode('$pair $version $kind ' * (40 + index * 20));
      final gz = gzip.encode(raw);
      final url = Uri.parse('https://models.example/$pair/$version/$kind.gz');
      bodies[url] = gz;
      installed += raw.length;
      download += gz.length;
      files[kind] = {
        'name': '$kind.$pair.bin',
        'url': '$url',
        'size': gz.length,
        'sha256': await _sha256(gz),
        'uncompressedSize': raw.length,
        'uncompressedSha256': await _sha256(raw),
      };
    }
    installedSizes[pair] = installed;
    downloadSizes[pair] = download;
    models
      ..removeWhere((m) => m['source'] == source && m['target'] == target)
      ..add({
        'source': source,
        'target': target,
        'version': version,
        'files': files,
      });
  }

  ModelCatalog build() =>
      ModelCatalog.fromJson({'schemaVersion': 1, 'models': models});
}

void main() {
  late Directory root;
  late _Catalog catalog;
  late List<Uri> requests;
  late http.Client client;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('mozhi_model_details_');
    catalog = _Catalog();
    await catalog.add('de', 'en', 'v1');
    await catalog.add('en', 'de', 'v1');
    await catalog.add('fr', 'en', 'v1');
    await catalog.add('en', 'fr', 'v1');
    requests = [];
    client = MockClient((request) async {
      requests.add(request.url);
      final body = catalog.bodies[request.url];
      return body == null
          ? http.Response('not found', 404)
          : http.Response.bytes(body, 200);
    });
  });
  tearDown(() => root.deleteSync(recursive: true));

  BergamotTranslator translator() => BergamotTranslator(
    catalog: catalog.build(),
    root: root,
    isMeteredConnection: () async => false,
    httpClient: client,
    engine: _Engine(),
    isAvailable: true,
  );

  group('offlineModelDetailsOf', () {
    test('describes Bergamot translators only', () {
      expect(offlineModelDetailsOf(translator()), isA<BergamotModelDetails>());
      expect(
        offlineModelDetailsOf(const UnavailableOfflineTranslator()),
        isNull,
      );
    });
  });

  group(BergamotModelDetails, () {
    test('reports download sizes of both directions', () {
      final details = BergamotModelDetails(translator());

      expect(
        details.downloadSize('de'),
        catalog.downloadSizes['de-en']! + catalog.downloadSizes['en-de']!,
      );
      expect(details.downloadSize('en'), 0);
      expect(details.downloadSize('tlh'), 0);
    });

    test('reports empty storage before any download', () async {
      final details = BergamotModelDetails(translator());

      expect(await details.storage(['de', 'fr', 'en']), const OfflineStorage());
    });

    test('downloads with progress and reports the storage', () async {
      final details = BergamotModelDetails(translator());
      final fractions = <double>[];

      await details.download('de', wifiOnly: true, onProgress: fractions.add);
      // The broadcast stream delivers asynchronously.
      await pumpEventQueue();

      expect(fractions, isNotEmpty);
      expect(fractions.last, 1);
      for (var i = 1; i < fractions.length; i++) {
        expect(fractions[i], greaterThanOrEqualTo(fractions[i - 1]));
      }
      final installed =
          catalog.installedSizes['de-en']! + catalog.installedSizes['en-de']!;
      expect(
        await details.storage(['de', 'fr', 'en']),
        OfflineStorage(
          installedBytes: {'de': installed},
          totalBytes: installed,
        ),
      );
    });

    test('downloads nothing when everything is installed', () async {
      final details = BergamotModelDetails(translator());
      await details.download('de', wifiOnly: true);
      requests.clear();
      final fractions = <double>[];

      await details.download('de', wifiOnly: true, onProgress: fractions.add);
      await pumpEventQueue();

      expect(requests, isEmpty);
      expect(fractions, isEmpty);
    });

    test('finds and installs updates', () async {
      await BergamotModelDetails(translator()).download('de', wifiOnly: true);
      await catalog.add('en', 'de', 'v2');
      final details = BergamotModelDetails(translator());

      final before = await details.storage(['de', 'fr']);
      expect(before.outdated, {'de'});

      requests.clear();
      final fractions = <double>[];
      await details.download('de', wifiOnly: true, onProgress: fractions.add);
      await pumpEventQueue();

      // Only the outdated direction is downloaded again.
      expect(
        requests,
        everyElement(predicate<Uri>((u) => u.path.contains('/en-de/v2/'))),
      );
      expect(fractions.last, 1);
      expect((await details.storage(['de'])).outdated, isEmpty);
    });

    test('passes download errors on', () async {
      catalog.bodies.clear();
      final details = BergamotModelDetails(translator());

      await expectLater(
        details.download('fr', wifiOnly: false),
        throwsA(
          isA<ModelDownloadException>().having(
            (e) => e.statusCode,
            'statusCode',
            404,
          ),
        ),
      );
    });
  });
}
