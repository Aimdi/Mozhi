import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mozhi/offline/data/mirror_hosting.dart';
import 'package:mozhi/settings/models/model_source.dart';

const _thisServer = ModelSource(kind: ModelSourceKind.thisServer);
final Uri _app = Uri.parse('https://translate.example.org/app/?x=1#/settings');

void main() {
  late List<Uri> requests;
  late FutureOr<http.Response> Function(http.Request request) respond;

  setUp(() {
    requests = [];
    respond = (_) => http.Response('{"items": ["de"]}', 200);
  });

  MirrorHostingProbe probe({
    bool isWeb = true,
    Uri? appBase,
    Duration timeout = const Duration(seconds: 10),
  }) => MirrorHostingProbe(
    client: MockClient((request) {
      requests.add(request.url);
      return Future.value(respond(request));
    }),
    isWeb: isWeb,
    appBase: () => appBase ?? _app,
    timeout: timeout,
  );

  group(MirrorDataKind, () {
    test('names the folders of tool/mirror_models.py', () {
      expect(MirrorDataKind.values.map((kind) => kind.folder), [
        'bergamot',
        'tesseract',
        'dictionary',
        'phrasebooks',
      ]);
      expect(MirrorDataKind.textRecognition.originalHostAllowsBrowsers, isTrue);
      expect(MirrorDataKind.dictionary.originalHostAllowsBrowsers, isFalse);
    });
  });

  group('MirrorHostingProbe.downloadsBlocked', () {
    test('asks nothing outside a browser', () async {
      expect(
        await probe(isWeb: false)
            .downloadsBlocked(MirrorDataKind.dictionary, _thisServer),
        isFalse,
      );
      expect(requests, isEmpty);
    });

    test(
      'asks nothing for the original publishers or a custom mirror',
      () async {
        final web = probe();
        expect(
          await web.downloadsBlocked(
            MirrorDataKind.dictionary,
            ModelSource.defaultHosts,
          ),
          isFalse,
        );
        expect(
          await web.downloadsBlocked(
            MirrorDataKind.dictionary,
            const ModelSource(
              kind: ModelSourceKind.custom,
              customUrl: 'https://mirror.example.org/models/',
            ),
          ),
          isFalse,
        );
        expect(requests, isEmpty);
      },
    );

    test("reads the index of this server's folder of the kind", () async {
      final web = probe();
      expect(
        await web.downloadsBlocked(MirrorDataKind.translation, _thisServer),
        isFalse,
      );
      expect(requests, [
        Uri.parse(
          'https://translate.example.org/app/models/bergamot/index.json',
        ),
      ]);
    });

    test('blocks a kind the server has no index of', () async {
      respond = (_) => http.Response('Not Found', 404);
      expect(
        await probe().downloadsBlocked(MirrorDataKind.dictionary, _thisServer),
        isTrue,
      );
    });

    test(
      'blocks a kind whose index is the app page or lists nothing',
      () async {
        respond = (_) => http.Response('<!DOCTYPE html><html></html>', 200);
        expect(
          await probe().downloadsBlocked(
            MirrorDataKind.dictionary,
            _thisServer,
          ),
          isTrue,
        );
        respond = (_) =>
            http.Response('{"schemaVersion": 1, "items": []}', 200);
        expect(
          await probe().downloadsBlocked(
            MirrorDataKind.dictionary,
            _thisServer,
          ),
          isTrue,
        );
      },
    );

    test('does not block when the server cannot be asked', () async {
      for (final status in [500, 503, 408, 429]) {
        respond = (_) => http.Response('', status);
        expect(
          await probe().downloadsBlocked(
            MirrorDataKind.dictionary,
            _thisServer,
          ),
          isFalse,
          reason: '$status',
        );
      }
      respond = (_) => throw http.ClientException('offline');
      expect(
        await probe().downloadsBlocked(MirrorDataKind.dictionary, _thisServer),
        isFalse,
      );
    });

    test('does not block when the index takes too long', () async {
      respond = (_) => Future.delayed(
        const Duration(milliseconds: 200),
        () => http.Response('', 404),
      );
      expect(
        await probe(timeout: const Duration(milliseconds: 10))
            .downloadsBlocked(MirrorDataKind.dictionary, _thisServer),
        isFalse,
      );
    });

    test('text recognition data with the fallback comes from GitHub', () async {
      respond = (_) => http.Response('', 404);
      final web = probe();
      const fallback = ModelSource(
        kind: ModelSourceKind.thisServer,
        fallbackToDefault: true,
      );
      expect(
        await web.downloadsBlocked(MirrorDataKind.textRecognition, fallback),
        isFalse,
      );
      expect(requests, isEmpty);
      // GitHub release downloads do not work in a browser: still blocked.
      expect(
        await web.downloadsBlocked(MirrorDataKind.dictionary, fallback),
        isTrue,
      );
    });

    test('does not block without a web server to ask', () async {
      final web = MirrorHostingProbe(
        client: MockClient((_) async => http.Response('', 404)),
        isWeb: true,
        appBase: () => null,
      );
      expect(
        await web.downloadsBlocked(MirrorDataKind.dictionary, _thisServer),
        isFalse,
      );
    });
  });

  group('MirrorHostingProbe.hosting', () {
    final mirror = Uri.parse('https://example.org/models/');

    test('asks once per folder', () async {
      final web = probe();
      expect(
        await web.hosting(mirror, MirrorDataKind.phrasebook),
        MirrorHosting.hosted,
      );
      expect(
        await web.hosting(mirror, MirrorDataKind.phrasebook),
        MirrorHosting.hosted,
      );
      respond = (_) => http.Response('', 404);
      expect(
        await web.hosting(mirror, MirrorDataKind.dictionary),
        MirrorHosting.notHosted,
      );
      expect(
        await web.hosting(mirror, MirrorDataKind.dictionary),
        MirrorHosting.notHosted,
      );
      expect(requests, [
        Uri.parse('https://example.org/models/phrasebooks/index.json'),
        Uri.parse('https://example.org/models/dictionary/index.json'),
      ]);
    });

    test('asks again after no answer', () async {
      final web = probe();
      respond = (_) => http.Response('', 502);
      expect(
        await web.hosting(mirror, MirrorDataKind.translation),
        MirrorHosting.unknown,
      );
      respond = (_) => http.Response('{"items": ["en-de"]}', 200);
      expect(
        await web.hosting(mirror, MirrorDataKind.translation),
        MirrorHosting.hosted,
      );
      expect(requests, hasLength(2));
    });
  });

  group('MirrorHostingProbe.listsFiles', () {
    test('wants a JSON object with items', () {
      expect(MirrorHostingProbe.listsFiles('{"items": ["ar"]}'), isTrue);
      expect(
        MirrorHostingProbe.listsFiles(
          '{"schemaVersion": 1, "kind": "phrasebook", "items": ["ar", "de"]}',
        ),
        isTrue,
      );
      expect(MirrorHostingProbe.listsFiles('{"items": []}'), isFalse);
      expect(MirrorHostingProbe.listsFiles('{"items": "ar"}'), isFalse);
      expect(MirrorHostingProbe.listsFiles('["ar"]'), isFalse);
      expect(MirrorHostingProbe.listsFiles('<html>'), isFalse);
      expect(MirrorHostingProbe.listsFiles(''), isFalse);
    });
  });
}
