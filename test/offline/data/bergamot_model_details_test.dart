import 'dart:convert';
import 'dart:io';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mozhi/offline/data/bergamot_model_details.dart';
import 'package:mozhi/offline/data/offline_model_details.dart';
import 'package:mozhi/offline/data/offline_model_error.dart';
import 'package:mozhi/offline/data/offline_model_import.dart';
import 'package:mozhi/offline/data/unavailable_offline_translator.dart';
import 'package:mozhi/settings/models/model_source.dart';

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

    group('imports', () {
      late Directory inbox;

      setUp(() => inbox = Directory('${root.path}/inbox')..createSync());

      /// Writes the published files of `source -> target` into the inbox
      /// (all of them, or the first [count]) and returns their paths.
      List<String> publish(String source, String target, {int? count}) {
        final model = catalog.build().model(source, target)!;
        final files = model.files.values.take(count ?? model.files.length);
        return [
          for (final file in files)
            (File(
              '${inbox.path}/${file.name}.gz',
            )..writeAsBytesSync(catalog.bodies[file.url]!)).path,
        ];
      }

      test('installs complete directions and reports the rest', () async {
        final details = BergamotModelDetails(translator());
        final notes = File('${inbox.path}/notes.txt')
          ..writeAsStringSync('hello');

        final report = await details.importFiles([
          ...publish('de', 'en'),
          ...publish('en', 'de', count: 1),
          notes.path,
        ]);

        expect(
          report,
          const OfflineImportReport(
            models: [
              OfflineImportedModel(
                source: 'de',
                target: 'en',
                status: OfflineImportStatus.installed,
              ),
              OfflineImportedModel(
                source: 'en',
                target: 'de',
                status: OfflineImportStatus.incomplete,
                missingFiles: ['lexicalShortlist.gz', 'vocab.gz'],
              ),
            ],
            unmatchedFiles: ['notes.txt'],
          ),
        );
        expect(requests, isEmpty);
        expect(
          (await details.storage(['de'])).totalBytes,
          catalog.installedSizes['de-en'],
        );
      });

      test('reports installed models and engine codes', () async {
        await catalog.add('zh_hant', 'en', 'v1');
        final details = BergamotModelDetails(translator());
        await details.importFiles(publish('fr', 'en'));
        final damaged = publish('zh_hant', 'en', count: 1).single;
        File(damaged).writeAsBytesSync([1, 2, 3]);

        final report = await details.importFiles([
          ...publish('fr', 'en'),
          damaged,
        ]);

        expect(report.models, const [
          OfflineImportedModel(
            source: 'fr',
            target: 'en',
            status: OfflineImportStatus.alreadyInstalled,
          ),
          OfflineImportedModel(
            source: 'zh-Hant',
            target: 'en',
            status: OfflineImportStatus.damaged,
            missingFiles: ['model.gz', 'lexicalShortlist.gz', 'vocab.gz'],
          ),
        ]);
      });

      test('classifies why a model could not be installed', () async {
        File('${root.path}/models/.staging')
          ..createSync(recursive: true)
          ..writeAsStringSync('in the way');
        final details = BergamotModelDetails(translator());

        final report = await details.importFiles(publish('de', 'en'));

        expect(report.models.single.status, OfflineImportStatus.failed);
        expect(
          report.models.single.error,
          const OfflineModelError(OfflineModelErrorKind.storage),
        );
      });

      test('lists the files to download by hand', () {
        final details = BergamotModelDetails(translator());
        final model = catalog.build().model('de', 'en')!;

        final files = details.manualFiles('de');

        expect(files, hasLength(6));
        expect(
          files.first,
          OfflineModelFile(
            source: 'de',
            target: 'en',
            name: 'model.gz',
            url: 'https://models.example/de-en/v1/model.gz',
            size: model.files.values.first.size,
          ),
        );
        expect(files.map((file) => '${file.source}-${file.target}').toSet(), {
          'de-en',
          'en-de',
        });
        expect(details.manualFiles('en'), isEmpty);
      });
    });

    group('model source', () {
      const mirror = ModelSource(
        kind: ModelSourceKind.custom,
        customUrl: 'https://mirror.example/models/',
      );

      /// Serves every catalog file at its mirror URL too.
      void mirrorAll() {
        final built = catalog.build();
        for (final model in built.models) {
          for (final file in model.files.values) {
            catalog.bodies[bergamotMirrorUrl(mirror.mirror()!, model, file)] =
                catalog.bodies[file.url]!;
          }
        }
      }

      test('downloads from the mirror of the source in use', () async {
        mirrorAll();
        final details = BergamotModelDetails(
          translator(),
          modelSource: () => mirror,
        );
        await details.download('de', wifiOnly: false);
        expect(requests, isNotEmpty);
        expect(requests.map((url) => url.host).toSet(), {'mirror.example'});
        expect(requests.first.path, startsWith('/models/bergamot/'));
      });

      test('falls back to Mozilla only when allowed', () async {
        final strict = BergamotModelDetails(
          translator(),
          modelSource: () => mirror,
        );
        await expectLater(
          strict.download('de', wifiOnly: false),
          throwsA(
            isA<ModelDownloadException>().having(
              (e) => OfflineModelError.of(e).mirror,
              'mirror',
              'mirror.example',
            ),
          ),
        );
        expect(requests.map((url) => url.host).toSet(), {'mirror.example'});

        requests.clear();
        final lenient = BergamotModelDetails(
          translator(),
          modelSource: () => mirror.copyWith(fallbackToDefault: true),
        );
        await lenient.download('de', wifiOnly: false);
        expect(requests.map((url) => url.host).toSet(), {
          'mirror.example',
          'models.example',
        });
      });

      test("uses the settings' source by default", () async {
        addTearDown(() => ModelSource.current = ModelSource.platformDefault);
        ModelSource.current = ModelSource.defaultHosts;
        await BergamotModelDetails(translator())
            .download('de', wifiOnly: false);
        expect(requests.map((url) => url.host).toSet(), {'models.example'});
      });
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
