import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mozhi/core/network/network.dart';
import 'package:mozhi/core/privacy/egress/egress.dart';
import 'package:mozhi/sync/data/webdav_client.dart';

import '../helpers/fake_webdav_server.dart';
import '../helpers/webdav_samples.dart';

final Uri _server = Uri.parse('https://cloud.example.org/dav/');

WebDavClient _client(
  http.Client httpClient, {
  String folder = 'Mozhi',
  Uri? server,
  String password = 'app-password',
  Duration timeout = WebDavClient.defaultTimeout,
}) => WebDavClient(
  server: server ?? _server,
  username: 'alice',
  password: password,
  httpClient: httpClient,
  folderPath: folder,
  timeout: timeout,
);

Matcher _fails(WebDavFailure failure, {int? status}) => throwsA(
  isA<WebDavException>()
      .having((e) => e.failure, 'failure', failure)
      .having((e) => e.statusCode, 'statusCode', status ?? anything),
);

MockClient _answer(int status, [String body = '']) =>
    MockClient((_) async => http.Response(body, status));

void main() {
  group('folderUrl', () {
    test('joins the server and the folder, ending in a slash', () {
      expect(
        WebDavClient.folderUrl(_server, 'Mozhi').toString(),
        'https://cloud.example.org/dav/Mozhi/',
      );
      expect(
        WebDavClient.folderUrl(
          Uri.parse('https://u:p@h.example:8443/a//b?q#f'),
          '/Apps//My Mozhi/',
        ).toString(),
        'https://h.example:8443/a/b/Apps/My%20Mozhi/',
      );
      expect(
        WebDavClient.folderUrl(Uri.parse('http://192.168.1.2'), '').toString(),
        'http://192.168.1.2/',
      );
    });

    test('fileUrl is in the folder', () {
      final client = _client(MockClient((_) async => http.Response('', 200)));
      expect(
        client.fileUrl('mozhi-sync.mozhibackup').toString(),
        'https://cloud.example.org/dav/Mozhi/mozhi-sync.mozhibackup',
      );
      expect(
        client.withServer(Uri.parse('https://b.example/')).folder,
        Uri.parse('https://b.example/Mozhi/'),
      );
    });

    test('folderSegments drops empty segments', () {
      expect(WebDavClient.folderSegments(' /a/ /b/'), ['a', 'b']);
    });
  });

  group('stat', () {
    for (final (name, body) in [
      ('Nextcloud', nextcloudFolder),
      ('Apache', apacheFolder),
      ('rclone', rcloneFolder),
      ('a default namespace', defaultNamespaceFolder),
    ]) {
      test('reads the folder from $name', () async {
        final resource = await _client(_answer(207, body))
            .stat(Uri.parse('https://cloud.example.org/dav/Mozhi/'));
        expect(resource!.isCollection, isTrue);
      });
    }

    test('sends PROPFIND with Depth 0, Basic auth and no redirects', () async {
      late http.Request sent;
      final client = _client(
        MockClient((request) async {
          sent = request;
          return http.Response(nextcloudFolder, 207);
        }),
      );
      await client.stat(client.folder);
      expect(sent.method, 'PROPFIND');
      expect(sent.headers['Depth'], '0');
      expect(
        sent.headers['Authorization'],
        'Basic ${base64Encode(utf8.encode('alice:app-password'))}',
      );
      expect(sent.followRedirects, isFalse);
      expect(sent.body, contains('<d:getetag/>'));
    });

    test('is null for a missing resource', () async {
      expect(await _client(_answer(404)).stat(_server), isNull);
      expect(await _client(_answer(410)).stat(_server), isNull);
      expect(
        await _client(_answer(207, missingResponse)).stat(_server),
        isNull,
      );
    });

    for (final (status, body) in [
      (405, ''),
      (501, ''),
      (400, ''),
      (200, htmlPage),
      (204, ''),
      (207, htmlPage),
      (207, '<d:multistatus xmlns:d="DAV:"/>'),
      (207, 'not xml <'),
    ]) {
      test('$status ${body.isEmpty ? '' : body.substring(0, 9)} is not '
          'WebDAV', () async {
        await expectLater(
          _client(_answer(status, body)).stat(_server),
          _fails(WebDavFailure.notWebDav, status: status),
        );
      });
    }

    for (final (status, failure) in [
      (401, WebDavFailure.authFailed),
      (403, WebDavFailure.forbidden),
      (429, WebDavFailure.tooManyRequests),
      (500, WebDavFailure.server),
      (503, WebDavFailure.server),
      (301, WebDavFailure.redirected),
      (307, WebDavFailure.redirected),
    ]) {
      test('$status fails as ${failure.name}', () async {
        await expectLater(
          _client(_answer(status, nextcloudNotAuthenticated)).stat(_server),
          _fails(failure, status: status),
        );
      });
    }
  });

  group('ensureFolder', () {
    test('does nothing when the folder exists', () async {
      final server = FakeWebDavServer(folders: {'/dav/', '/dav/Mozhi/'});
      await _client(server.client).ensureFolder();
      expect(server.methods, ['PROPFIND']);
    });

    for (final flavor in WebDavFlavor.values) {
      test('creates missing folders from the top (${flavor.name})', () async {
        final server = FakeWebDavServer(flavor: flavor);
        await _client(server.client, folder: 'Apps/Mozhi').ensureFolder();
        expect(server.folders, containsAll(['/dav/Apps/', '/dav/Apps/Mozhi/']));
        expect(server.methods, ['PROPFIND', 'MKCOL', 'MKCOL']);
      });
    }

    test('creates below a server at the root', () async {
      final server = FakeWebDavServer(folders: {'/'});
      await _client(
        server.client,
        server: Uri.parse('https://cloud.example.org'),
      ).ensureFolder();
      expect(server.folders, contains('/Mozhi/'));
      expect(server.requests.map((r) => r.url.path), ['/Mozhi/', '/Mozhi/']);
    });

    test('accepts folders that already exist (405)', () async {
      final server = FakeWebDavServer(folders: {'/dav/', '/dav/Apps/'});
      await _client(server.client, folder: 'Apps/Mozhi').ensureFolder();
      expect(server.folders, contains('/dav/Apps/Mozhi/'));
    });

    test('refuses a file at the folder address', () async {
      final server = FakeWebDavServer()..put('/dav/Mozhi/', [1]);
      await expectLater(
        _client(server.client).ensureFolder(),
        _fails(WebDavFailure.notAFolder),
      );
    });

    test('accepts a folder listed without resourcetype', () async {
      await _client(_answer(207, noResourceTypeFolder)).ensureFolder();
    });

    test('fails when the server address is missing', () async {
      await expectLater(
        _client(_answer(404), folder: '').ensureFolder(),
        _fails(WebDavFailure.notFound, status: 404),
      );
    });

    test('fails when the parent is missing (409)', () async {
      final server = FakeWebDavServer(folders: {'/other/'});
      await expectLater(
        _client(server.client).ensureFolder(),
        _fails(WebDavFailure.notFound, status: 409),
      );
    });

    test('fails when MKCOL is forbidden', () async {
      final client = _client(
        MockClient(
          (request) async =>
              http.Response('', request.method == 'MKCOL' ? 403 : 404),
        ),
      );
      await expectLater(
        client.ensureFolder(),
        _fails(WebDavFailure.forbidden, status: 403),
      );
    });
  });

  group('download', () {
    test('returns the bytes and the ETag', () async {
      final server = FakeWebDavServer()..put('/dav/Mozhi/f', [1, 2, 3]);
      final file = await _client(server.client).download('f');
      expect(file, isA<WebDavFile>());
      file as WebDavFile;
      expect(file.bytes, [1, 2, 3]);
      expect(file.etag, server.etagOf('/dav/Mozhi/f'));
    });

    test("reads Nextcloud's OC-ETag", () async {
      final client = _client(
        MockClient(
          (_) async => http.Response('x', 200, headers: {'oc-etag': ' "o" '}),
        ),
      );
      expect(((await client.download('f')) as WebDavFile).etag, '"o"');
    });

    test('has no ETag when the server (or the browser) hides it', () async {
      final server = FakeWebDavServer(sendsEtags: false)
        ..put('/dav/Mozhi/f', [1]);
      expect(
        ((await _client(server.client).download('f')) as WebDavFile).etag,
        isNull,
      );
    });

    test('sends If-None-Match and reads 304', () async {
      final server = FakeWebDavServer()..put('/dav/Mozhi/f', [1]);
      final unchanged = await _client(server.client)
          .download('f', ifNoneMatch: server.etagOf('/dav/Mozhi/f'));
      expect(unchanged, isA<WebDavUnchanged>());
      final changed = await _client(server.client)
          .download('f', ifNoneMatch: '"old"');
      expect(changed, isA<WebDavFile>());
    });

    test('reads a missing file', () async {
      expect(await _client(_answer(404)).download('f'), isA<WebDavMissing>());
      expect(await _client(_answer(410)).download('f'), isA<WebDavMissing>());
    });

    test('fails for other statuses', () async {
      await expectLater(
        _client(_answer(401)).download('f'),
        _fails(WebDavFailure.authFailed),
      );
      await expectLater(
        _client(_answer(206)).download('f'),
        _fails(WebDavFailure.server, status: 206),
      );
    });

    test('refuses answers above maxDownloadBytes', () async {
      final chunk = Uint8List(1024 * 1024);
      final client = _client(
        _StreamClient(
          () => http.StreamedResponse(
            Stream.fromIterable(
              List.filled(
                WebDavClient.maxDownloadBytes ~/ chunk.length + 1,
                chunk,
              ),
            ),
            200,
          ),
        ),
      );
      await expectLater(client.download('f'), _fails(WebDavFailure.tooLarge));
    });

    test('etagOf reads getetag with PROPFIND', () async {
      final server = FakeWebDavServer(sendsEtags: false)
        ..put('/dav/Mozhi/f', [1]);
      expect(
        await _client(server.client).etagOf('f'),
        server.etagOf('/dav/Mozhi/f'),
      );
      expect(await _client(server.client).etagOf('missing'), isNull);
    });
  });

  group('upload', () {
    test('creates a file only if it does not exist yet', () async {
      final server = FakeWebDavServer(folders: {'/dav/', '/dav/Mozhi/'});
      final etag = await _client(server.client).upload('f', Uint8List(3));
      expect(server.requests.last.headers['If-None-Match'], '*');
      expect(server.requests.last.headers['If-Match'], isNull);
      expect(
        server.requests.last.headers['Content-Type'],
        'application/octet-stream',
      );
      expect(etag, server.etagOf('/dav/Mozhi/f'));
      await expectLater(
        _client(server.client).upload('f', Uint8List(3)),
        _fails(WebDavFailure.conflict, status: 412),
      );
    });

    test('replaces a file only if it still has the ETag', () async {
      final server = FakeWebDavServer(folders: {'/dav/', '/dav/Mozhi/'})
        ..put('/dav/Mozhi/f', [1]);
      final etag = server.etagOf('/dav/Mozhi/f');
      final written = await _client(server.client)
          .upload('f', Uint8List.fromList([2]), ifMatch: etag);
      expect(server.requests.last.headers['If-Match'], etag);
      expect(server.files['/dav/Mozhi/f'], [2]);
      expect(written, isNot(etag));
      await expectLater(
        _client(server.client).upload('f', Uint8List(1), ifMatch: etag),
        _fails(WebDavFailure.conflict),
      );
    });

    test('writes unconditionally when asked', () async {
      final server = FakeWebDavServer(
        folders: {'/dav/', '/dav/Mozhi/'},
        sendsEtags: false,
      )..put('/dav/Mozhi/f', [1]);
      final written = await _client(server.client)
          .upload('f', Uint8List.fromList([2]), unconditional: true);
      expect(written, isNull);
      expect(server.requests.last.headers['If-Match'], isNull);
      expect(server.requests.last.headers['If-None-Match'], isNull);
    });

    for (final (status, failure) in [
      (409, WebDavFailure.notFound),
      (507, WebDavFailure.insufficientStorage),
      (413, WebDavFailure.tooLarge),
      (423, WebDavFailure.locked),
      (405, WebDavFailure.notWebDav),
      (302, WebDavFailure.redirected),
    ]) {
      test('$status fails as ${failure.name}', () async {
        await expectLater(
          _client(_answer(status)).upload('f', Uint8List(1)),
          _fails(failure, status: status),
        );
      });
    }
  });

  group('delete', () {
    test('deletes, and accepts a file that is gone', () async {
      final server = FakeWebDavServer()..put('/dav/Mozhi/f', [1]);
      await _client(server.client).delete('f');
      expect(server.files, isEmpty);
      await _client(server.client).delete('f');
      await _client(_answer(410)).delete('f');
    });

    test('fails when refused', () async {
      await expectLater(
        _client(_answer(403)).delete('f'),
        _fails(WebDavFailure.forbidden),
      );
    });
  });

  group('errors without an answer', () {
    test('a timeout', () async {
      final never = Completer<http.StreamedResponse>();
      await expectLater(
        _client(
          _StreamClient(() => never.future),
          timeout: const Duration(milliseconds: 10),
        ).stat(_server),
        _fails(WebDavFailure.timeout),
      );
    });

    test('a broken connection is offline', () async {
      await expectLater(
        _client(MockClient((_) async => throw http.ClientException('reset')))
            .stat(_server),
        _fails(WebDavFailure.offline),
      );
      await expectLater(
        _client(MockClient((_) async => throw const SocketException('down')))
            .stat(_server),
        _fails(WebDavFailure.offline),
      );
    });

    test('a failed TLS handshake', () async {
      await expectLater(
        _client(MockClient((_) async => throw const HandshakeException('cert')))
            .stat(_server),
        _fails(WebDavFailure.tls),
      );
    });

    test('an answer cut off midway is offline', () async {
      await expectLater(
        _client(
          _StreamClient(
            () => http.StreamedResponse(
              Stream<List<int>>.error(http.ClientException('cut')),
              200,
            ),
          ),
        ).download('f'),
        _fails(WebDavFailure.offline),
      );
    });

    test('a slow body times out', () async {
      await expectLater(
        _client(
          _StreamClient(() => http.StreamedResponse(_never(), 200)),
          timeout: const Duration(milliseconds: 10),
        ).download('f'),
        _fails(WebDavFailure.timeout),
      );
    });

    test('the network policy refuses plain http to a public server', () async {
      final client = BackendHttpClient(
        _answer(207, nextcloudFolder),
        policy: const NetworkPolicy(hasProxy: false),
      );
      await expectLater(
        _client(
          client,
          server: Uri.parse('http://cloud.example.org/dav/'),
        ).stat(Uri.parse('http://cloud.example.org/dav/Mozhi/')),
        throwsA(
          isA<WebDavException>()
              .having((e) => e.failure, 'failure', WebDavFailure.policy)
              .having(
                (e) => NetworkPolicyError.of(e.cause),
                'cause',
                NetworkPolicyError.cleartext,
              ),
        ),
      );
      // The local network may use plain http.
      final lan = await _client(
        client,
        server: Uri.parse('http://192.168.1.10/dav/'),
      ).stat(Uri.parse('http://192.168.1.10/dav/Mozhi/'));
      expect(lan, isNotNull);
    });

    test('toString names no address or credential', () {
      expect(
        const WebDavException(
          WebDavFailure.authFailed,
          statusCode: 401,
        ).toString(),
        'WebDavException(authFailed, 401)',
      );
      expect(
        const WebDavException(WebDavFailure.offline).toString(),
        'WebDavException(offline)',
      );
    });
  });

  test('requests through the session are listed as sync', () async {
    final server = FakeWebDavServer();
    final session = NetworkSession(httpClient: server.client);
    final client = _client(
      EgressPurposeClient(session.client, purpose: EgressPurpose.sync),
    );
    await client.ensureFolder();
    await client.upload('f', Uint8List(2));
    expect(
      server.requests.map((r) => r.headers.keys.map((k) => k.toLowerCase())),
      everyElement(isNot(contains(EgressRecordingClient.purposeHeader))),
    );
    final entries = session.ledger.entries;
    expect(entries.map((e) => e.purpose), everyElement(EgressPurpose.sync));
    expect(entries.map((e) => e.method), ['PROPFIND', 'MKCOL', 'PUT']);
    expect(entries.map((e) => e.carriedContent), everyElement(isFalse));
  });
}

Stream<List<int>> _never() => StreamController<List<int>>().stream;

/// A client whose answer [respond] makes.
class _StreamClient extends http.BaseClient {
  new(this.respond);

  final FutureOr<http.StreamedResponse> Function() respond;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      await respond();
}
