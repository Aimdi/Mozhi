import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mozhi/dictionary/data/dictionary_packs.dart';
import 'package:mozhi/platform/free_space.dart';
import 'package:translation_repository/translation_repository.dart';

import 'dictionary_pack_fixtures.dart';

void main() {
  late Uint8List spanish;
  late DictionaryPackInfo es;
  late MemoryDictionaryPackStorage storage;
  late List<String?> ranges;

  setUp(() {
    spanish = spanishPack();
    es = packInfo('es', spanish);
    storage = MemoryDictionaryPackStorage();
    ranges = [];
  });

  DictionaryPacks packs(
    Future<http.StreamedResponse> Function(http.BaseRequest request) answer, {
    List<Uri> Function(DictionaryPackInfo pack)? downloadUrls,
    FreeSpace? freeSpace,
  }) => DictionaryPacks(
    catalog: DictionaryPackCatalog([es]),
    storage: storage,
    httpClient: MockClient.streaming((request, _) {
      ranges.add(request.headers['Range']);
      return answer(request);
    }),
    downloadUrls: downloadUrls,
    freeSpace: freeSpace,
  );

  /// The rest of the pack from byte [from] on, as a `206`.
  http.StreamedResponse rest(int from, {String? contentRange}) =>
      http.StreamedResponse(
        Stream.value(spanish.sublist(from)),
        206,
        headers: {
          'content-range':
              contentRange ??
              'bytes $from-${spanish.length - 1}/${spanish.length}',
        },
      );

  /// [bytes], then a dropped connection.
  Stream<List<int>> cut(List<int> bytes) async* {
    yield bytes;
    throw const SocketException('reset');
  }

  http.StreamedResponse whole() =>
      http.StreamedResponse(Stream.value(spanish), 200);

  /// Keeps the first [count] bytes (or [bytes]) as a download of
  /// [sha256]'s version from [url] (default: the catalogue's).
  void keep(int count, {List<int>? bytes, String? sha256, Uri? url}) =>
      storage.putPartial(
        'es',
        DictionaryPartialDownload(
          url: url ?? es.url,
          size: es.size,
          sha256: sha256 ?? es.sha256,
        ),
        Uint8List.fromList(bytes ?? spanish.sublist(0, count)),
      );

  Future<void> expectInstalled(DictionaryPacks dictionaries) async {
    expect((await dictionaries.installedPack('es'))?.sha256, es.sha256);
    expect(await storage.partial('es'), isNull);
  }

  group('DictionaryPacks resume', () {
    test('resumes a kept download from where it stopped', () async {
      keep(100);
      final fractions = <double>[];
      final dictionaries = packs((request) async => rest(100));

      await dictionaries.install(es, onProgress: fractions.add);

      expect(ranges, ['bytes=100-']);
      expect(fractions.first, closeTo(100 / es.size, 1e-9));
      expect(fractions.last, 1);
      await expectInstalled(dictionaries);
    });

    test('keeps what came when the connection drops', () async {
      var calls = 0;
      final dictionaries = packs((request) async {
        if (++calls == 1) {
          return http.StreamedResponse(cut(spanish.sublist(0, 120)), 200);
        }
        return rest(120);
      });

      await expectLater(
        dictionaries.install(es),
        throwsA(isA<DictionaryPackDownloadException>()),
      );
      expect((await storage.partial('es'))?.received, 120);

      await dictionaries.install(es);
      expect(ranges, [null, 'bytes=120-']);
      await expectInstalled(dictionaries);
    });

    test('downloads the whole file when the server sends it all', () async {
      keep(100);
      final dictionaries = packs((request) async => whole());

      await dictionaries.install(es);

      expect(ranges, ['bytes=100-']);
      await expectInstalled(dictionaries);
    });

    for (final (name, answer) in [
      (
        'a range that does not fit (416)',
        (int from) => http.StreamedResponse(const Stream.empty(), 416),
      ),
      (
        'another range',
        (int from) =>
            rest(from, contentRange: 'bytes 0-${from - 1}/${from * 10}'),
      ),
      (
        'a 206 without its range',
        (int from) => http.StreamedResponse(Stream.value([1]), 206),
      ),
    ]) {
      test('asks again from the start after $name', () async {
        keep(100);
        final dictionaries = packs(
          (request) async =>
              request.headers['Range'] == null ? whole() : answer(100),
        );

        await dictionaries.install(es);

        expect(ranges, ['bytes=100-', null]);
        await expectInstalled(dictionaries);
      });
    }

    test('kept bytes that do not match are downloaded again', () async {
      keep(100, bytes: List.filled(100, 7));
      final dictionaries = packs(
        (request) async =>
            request.headers['Range'] == null ? whole() : rest(100),
      );

      await dictionaries.install(es);

      expect(ranges, ['bytes=100-', null]);
      await expectInstalled(dictionaries);
    });

    test('a mismatch of a whole download still fails', () async {
      final dictionaries = packs(
        (request) async =>
            http.StreamedResponse(Stream.value(List.filled(es.size, 1)), 200),
      );

      await expectLater(
        dictionaries.install(es),
        throwsA(isA<DictionaryPackChecksumException>()),
      );
      expect(await storage.partial('es'), isNull);
    });

    test('another version or URL is not resumed', () async {
      keep(100, sha256: 'a' * 64);
      final dictionaries = packs((request) async => whole());
      await dictionaries.install(es);
      expect(ranges, [null]);
      await expectInstalled(dictionaries);

      await dictionaries.delete('es');
      ranges.clear();
      keep(100, url: Uri.parse('https://elsewhere.example/es.mzd'));
      await dictionaries.install(es);
      expect(ranges, [null]);
    });

    test('a resume needs room for the rest only', () async {
      keep(100);
      final free = requiredFreeSpace(es.size - 100);
      final dictionaries = packs(
        (request) async => rest(100),
        freeSpace: FreeSpace(isWeb: true, browser: () async => free),
      );

      await dictionaries.install(es);

      await expectInstalled(dictionaries);
    });
  });

  group('DictionaryPacks shared installs', () {
    test('lists running installs; a joining caller gets progress', () async {
      final body = StreamController<List<int>>();
      final dictionaries = packs(
        (request) async => http.StreamedResponse(body.stream, 200),
      );
      expect(dictionaries.installing, isEmpty);

      final first = <double>[];
      final started = dictionaries.install(es, onProgress: first.add);
      await pumpEventQueue();
      expect(dictionaries.installing, {'es': 0.0});

      body.add(spanish.sublist(0, 100));
      await pumpEventQueue();
      expect(dictionaries.installing['es'], closeTo(100 / es.size, 1e-9));

      // Another screen joins: it is told the progress so far, then more.
      final second = <double>[];
      final joined = dictionaries.install(es, onProgress: second.add);
      expect(second, [closeTo(100 / es.size, 1e-9)]);
      body.add(spanish.sublist(100));
      await body.close();
      await Future.wait([started, joined]);

      expect(first.last, 1);
      expect(second.last, 1);
      expect(ranges, hasLength(1));
      expect(dictionaries.installing, isEmpty);
    });

    test('a cancelled install is not listed', () async {
      final body = StreamController<List<int>>();
      final dictionaries = packs(
        (request) async => http.StreamedResponse(body.stream, 200),
      );
      final install = expectLater(
        dictionaries.install(es),
        throwsA(isA<OfflineDownloadCancelledException>()),
      );
      await pumpEventQueue();
      final stopping = dictionaries.cancelInstall('es');
      expect(dictionaries.installing, isEmpty);
      await stopping;
      await install;
    });
  });
}
