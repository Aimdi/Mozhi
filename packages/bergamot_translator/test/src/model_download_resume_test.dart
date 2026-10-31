import 'dart:async';
import 'dart:io';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:bergamot_translator/src/file_hashing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:translation_repository/translation_repository.dart'
    show OfflineDownloadCancelledException;

import '../helpers/fake_models.dart';

void main() {
  late Directory root;
  late FakeModel ende;
  late FakeModelServer server;
  late BergamotModelManager manager;

  setUp(() {
    root = Directory.systemTemp.createTempSync('bergamot_resume_');
    ende = FakeModel('en', 'de');
    server = FakeModelServer([ende]);
    manager = BergamotModelManager(
      root: root,
      httpClient: server.client,
      hashing: const FileHashing.inline(),
    );
  });

  tearDown(() => root.deleteSync(recursive: true));

  FakeFile first() => ende.files.first;

  File partOf(FakeFile file) => File(
    p.join(
      root.path,
      'models',
      '.downloads',
      'en-de',
      'run1',
      '${file.name}.gz.part',
    ),
  );

  Directory installedDirectory() =>
      Directory(p.join(root.path, 'models', 'en-de'));

  /// The `Range` headers of the requests for [file], in order.
  List<String?> rangesOf(FakeFile file) => [
    for (final request in server.requests)
      if (request.url == file.entry.url) request.headers['Range'],
  ];

  /// A partial download of [file]: its first [length] bytes, or [bytes].
  void writePart(FakeFile file, {int? length, List<int>? bytes}) {
    partOf(file)
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes ?? file.gz.sublist(0, length));
  }

  Future<void> expectInstalled() async {
    expect(await manager.isInstalled(ende.catalog), isTrue);
    final installed = (await manager.installedModel('en', 'de'))!;
    expect(File(installed.paths.model).readAsBytesSync(), first().raw);
  }

  group('cancel', () {
    test('mid-stream: closes the response, keeps the part, installs '
        'nothing, and the next install resumes it', () async {
      final body = StreamController<List<int>>();
      var closed = false;
      body.onCancel = () => closed = true;
      server.stream = body;
      final abort = Completer<void>();
      final arrived = Completer<void>();
      final install = manager.install(
        ende.catalog,
        abort: abort.future,
        onProgress: (progress) {
          if (progress.receivedBytes >= 400 && !arrived.isCompleted) {
            arrived.complete();
          }
        },
      );
      body.add(first().gz.sublist(0, 400));
      await arrived.future;
      abort.complete();

      await expectLater(
        install,
        throwsA(isA<OfflineDownloadCancelledException>()),
      );
      expect(closed, isTrue);
      expect(await manager.installed(), isEmpty);
      expect(await manager.isInstalled(ende.catalog), isFalse);
      expect(installedDirectory().existsSync(), isFalse);
      expect(
        Directory(p.join(root.path, 'models', '.staging')).listSync(),
        isEmpty,
      );
      expect(partOf(first()).readAsBytesSync(), first().gz.sublist(0, 400));

      server.stream = null;
      await manager.install(ende.catalog);
      await expectInstalled();
      expect(rangesOf(first()), [null, 'bytes=400-']);
    });

    test('before the server answers: no other URL is tried', () async {
      final answer = Completer<http.StreamedResponse>();
      var listened = false;
      final unread = StreamController<List<int>>()
        ..onListen = () => listened = true;
      final requests = <http.BaseRequest>[];
      final manager =
          BergamotModelManager(
              root: root,
              httpClient: _PendingClient(requests, answer.future),
            )
            ..mirror = Uri.parse('https://mirror.test/models/')
            ..fallbackToDefault = true;
      final abort = Completer<void>();
      final install = manager.install(ende.catalog, abort: abort.future);
      await _until(() => requests.isNotEmpty);
      expect(requests, hasLength(1));
      expect(requests.single, isA<http.Abortable>());
      expect((requests.single as http.Abortable).abortTrigger, isNotNull);
      abort.complete();
      await expectLater(
        install,
        throwsA(isA<OfflineDownloadCancelledException>()),
      );
      expect(requests, hasLength(1));
      expect(await manager.installed(), isEmpty);

      // An answer that comes anyway is closed unread.
      answer.complete(http.StreamedResponse(unread.stream, 200));
      await _until(() => listened);
      await pumpEventQueue();
      expect(unread.hasListener, isFalse);
    });

    test('a shared download goes on while another caller waits', () async {
      final body = StreamController<List<int>>();
      server.stream = body;
      final abort = Completer<void>();
      final cancelled = manager.install(ende.catalog, abort: abort.future);
      final waiting = manager.install(ende.catalog);
      body.add(first().gz.sublist(0, 300));
      await _until(() => body.hasListener);
      abort.complete();
      await expectLater(
        cancelled,
        throwsA(isA<OfflineDownloadCancelledException>()),
      );
      expect(body.hasListener, isTrue);
      body.add(first().gz.sublist(300));
      server.stream = null;
      await body.close();
      final installed = await waiting;
      expect(installed.pair, 'en-de');
      await expectInstalled();
    });

    test('a download goes on until every caller with an abort has '
        'cancelled', () async {
      final body = StreamController<List<int>>();
      var closed = false;
      body.onCancel = () => closed = true;
      server.stream = body;
      final first = Completer<void>();
      final second = Completer<void>();
      final one = manager.install(ende.catalog, abort: first.future);
      final two = manager.install(ende.catalog, abort: second.future);
      await _until(() => body.hasListener);
      first.complete();
      await expectLater(one, throwsA(isA<OfflineDownloadCancelledException>()));
      expect(closed, isFalse);
      second.complete();
      await expectLater(two, throwsA(isA<OfflineDownloadCancelledException>()));
      expect(closed, isTrue);
    });

    test('an abort that was complete already stops at once', () async {
      await expectLater(
        manager.install(ende.catalog, abort: Future.value()),
        throwsA(isA<OfflineDownloadCancelledException>()),
      );
      expect(await manager.installed(), isEmpty);
      await manager.install(ende.catalog);
      await expectInstalled();
    });

    test('an abort after the install changes nothing', () async {
      final abort = Completer<void>();
      final installed = await manager.install(
        ende.catalog,
        abort: abort.future,
      );
      abort.complete();
      await pumpEventQueue();
      expect(installed.pair, 'en-de');
      await expectInstalled();
    });

    test('keeps a resumed part', () async {
      writePart(first(), length: first().gz.length - 10);
      server
        ..stream = StreamController<List<int>>()
        ..streamStatus = 206;
      final abort = Completer<void>();
      final install = manager.install(
        ende.catalog,
        abort: abort.future,
        onProgress: (_) {
          if (!abort.isCompleted) abort.complete();
        },
      );
      await expectLater(
        install,
        throwsA(isA<OfflineDownloadCancelledException>()),
      );
      expect(partOf(first()).lengthSync(), first().gz.length - 10);
      expect(await manager.installed(), isEmpty);
    });

    test('an error response is not retried elsewhere once cancelled', () async {
      final abort = Completer<void>();
      final body = StreamController<List<int>>();
      server
        ..stream = body
        ..streamStatus = 500;
      manager
        ..mirror = Uri.parse('https://mirror.test/models/')
        ..fallbackToDefault = true;
      final install = manager.install(ende.catalog, abort: abort.future);
      await _until(() => body.hasListener);
      abort.complete();
      await expectLater(
        install,
        throwsA(isA<OfflineDownloadCancelledException>()),
      );
      expect(server.requests, hasLength(1));
    });
  });

  group('resume', () {
    test('appends the 206 answer for the rest of the file', () async {
      writePart(first(), length: 700);
      await manager.install(ende.catalog);
      await expectInstalled();
      expect(rangesOf(first()), ['bytes=700-']);
    });

    test('accepts an unknown total size', () async {
      writePart(first(), length: 700);
      server.contentRange = (start, size) => 'bytes $start-${size - 1}/*';
      await manager.install(ende.catalog);
      await expectInstalled();
      expect(rangesOf(first()), ['bytes=700-']);
    });

    test('starts over on 200', () async {
      writePart(first(), length: 700);
      server.ignoreRange = true;
      await manager.install(ende.catalog);
      await expectInstalled();
      expect(rangesOf(first()), ['bytes=700-']);
    });

    for (final (name, range) in [
      ('without a Content-Range', null),
      ('for another start', 'bytes 600-%end/%size'),
      ('for another end', 'bytes 700-%size/%size'),
      ('for another size', 'bytes 700-%end/99999'),
      ('that is not a byte range', 'pages 700-%end/%size'),
      (
        'with a number too large for an int',
        'bytes 99999999999999999999-%end/%size',
      ),
    ]) {
      test('starts over on a 206 $name', () async {
        writePart(first(), length: 700);
        server.contentRange = (start, size) => range
            ?.replaceAll('%end', '${size - 1}')
            .replaceAll('%size', '$size');
        await manager.install(ende.catalog);
        await expectInstalled();
        expect(rangesOf(first()), ['bytes=700-', null]);
      });
    }

    test('starts over when a resumed file fails its SHA-256', () async {
      writePart(first(), bytes: List.filled(700, 7));
      await manager.install(ende.catalog);
      await expectInstalled();
      expect(rangesOf(first()), ['bytes=700-', null]);
      expect(partOf(first()).existsSync(), isFalse);
    });

    test('downloads a complete part that fails its SHA-256 again', () async {
      writePart(first(), bytes: List.filled(first().gz.length, 7));
      await manager.install(ende.catalog);
      await expectInstalled();
      expect(rangesOf(first()), [null]);
    });

    test('starts over only once', () async {
      writePart(first(), bytes: List.filled(700, 7));
      server.overrides[first().entry.url.toString()] = List.filled(
        first().gz.length,
        9,
      );
      await expectLater(
        manager.install(ende.catalog),
        throwsA(isA<ModelChecksumException>()),
      );
      expect(rangesOf(first()), ['bytes=700-', null]);
      expect(partOf(first()).existsSync(), isFalse);
      expect(await manager.installed(), isEmpty);
    });

    test('a fresh download that fails its SHA-256 is not repeated', () async {
      server.overrides[first().entry.url.toString()] = List.filled(
        first().gz.length,
        9,
      );
      await expectLater(
        manager.install(ende.catalog),
        throwsA(isA<ModelChecksumException>()),
      );
      expect(rangesOf(first()), [null]);
    });
  });
}

/// Sends every request into [requests] and answers all of them with
/// [answer] (which may never come).
class _PendingClient extends http.BaseClient {
  new(this.requests, this.answer);

  final List<http.BaseRequest> requests;
  final Future<http.StreamedResponse> answer;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    return answer;
  }
}

/// Waits until [condition] holds (real file and HTTP work in between).
Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 500 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(condition(), isTrue, reason: 'condition not reached');
}
