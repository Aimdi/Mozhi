import 'dart:async';
import 'dart:typed_data';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:translation_repository/translation_repository.dart'
    show OfflineDownloadCancelledException;

import '../../../helpers/fake_models.dart';
import 'fake_bergamot_worker.dart';

void main() {
  late FakeBergamotWorker worker;
  late FakeModel ende;
  late FakeModelServer server;
  late OpfsModelManager manager;

  setUp(() {
    worker = FakeBergamotWorker();
    ende = FakeModel('en', 'de');
    server = FakeModelServer([ende]);
    manager = OpfsModelManager(
      channel: worker,
      httpClient: server.client,
      writeChunkSize: 100,
    );
  });

  FakeFile first() => ende.files.first;

  String partOf(FakeFile file) => '.downloads/en-de/run1/${file.name}.gz.part';

  List<String?> rangesOf(FakeFile file) => [
    for (final request in server.requests)
      if (request.url == file.entry.url) request.headers['Range'],
  ];

  void writePart(FakeFile file, List<int> bytes) =>
      worker.files[partOf(file)] = Uint8List.fromList(bytes);

  Future<void> expectInstalled() async {
    expect(await manager.isInstalled(ende.catalog), isTrue);
    expect(worker.files['models/en-de/run1/${first().name}'], first().raw);
  }

  Iterable<String> modelFiles() =>
      worker.files.keys.where((path) => path.startsWith('models/'));

  group('cancel', () {
    test('mid-stream: closes the response, keeps what arrived, installs '
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
      expect(modelFiles(), isEmpty);
      expect(await manager.isInstalled(ende.catalog), isFalse);
      expect(worker.files[partOf(first())], first().gz.sublist(0, 400));

      server.stream = null;
      await manager.install(ende.catalog);
      await expectInstalled();
      expect(rangesOf(first()), [null, 'bytes=400-']);
    });

    test('before the server answers', () async {
      final answer = Completer<http.StreamedResponse>();
      final requests = <http.BaseRequest>[];
      final manager = OpfsModelManager(
        channel: worker,
        httpClient: _PendingClient(requests, answer.future),
      );
      final abort = Completer<void>();
      final install = manager.install(ende.catalog, abort: abort.future);
      while (requests.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      expect((requests.single as http.Abortable).abortTrigger, isNotNull);
      abort.complete();
      await expectLater(
        install,
        throwsA(isA<OfflineDownloadCancelledException>()),
      );
      expect(requests, hasLength(1));
      var listened = false;
      final unread = StreamController<List<int>>()
        ..onListen = () => listened = true;
      answer.complete(http.StreamedResponse(unread.stream, 200));
      await pumpEventQueue();
      expect(listened, isTrue);
      expect(unread.hasListener, isFalse);
    });

    test('an error response is not retried elsewhere once cancelled', () async {
      final body = StreamController<List<int>>();
      server
        ..stream = body
        ..streamStatus = 503;
      manager
        ..mirror = Uri.parse('https://mirror.test/models/')
        ..fallbackToDefault = true;
      final abort = Completer<void>();
      final install = manager.install(ende.catalog, abort: abort.future);
      while (!body.hasListener) {
        await Future<void>.delayed(Duration.zero);
      }
      abort.complete();
      await expectLater(
        install,
        throwsA(isA<OfflineDownloadCancelledException>()),
      );
      expect(server.requests, hasLength(1));
    });

    test('after the last file, nothing is committed', () async {
      final abort = Completer<void>();
      final install = manager.install(
        ende.catalog,
        abort: abort.future,
        onProgress: (progress) {
          if (progress.receivedBytes == progress.totalBytes) abort.complete();
        },
      );
      await expectLater(
        install,
        throwsA(isA<OfflineDownloadCancelledException>()),
      );
      expect(worker.ops, isNot(contains('commit')));
      expect(await manager.isInstalled(ende.catalog), isFalse);
    });
  });

  group('resume', () {
    test('appends the 206 answer for the rest of the file', () async {
      writePart(first(), first().gz.sublist(0, 700));
      await manager.install(ende.catalog);
      await expectInstalled();
      expect(rangesOf(first()), ['bytes=700-']);
    });

    test('starts over on a 206 for another range', () async {
      writePart(first(), first().gz.sublist(0, 700));
      server.contentRange = (start, size) => 'bytes 0-${size - 1}/$size';
      await manager.install(ende.catalog);
      await expectInstalled();
      expect(rangesOf(first()), ['bytes=700-', null]);
    });

    test('starts over when a resumed file fails the checks', () async {
      writePart(first(), List.filled(700, 7));
      await manager.install(ende.catalog);
      await expectInstalled();
      expect(rangesOf(first()), ['bytes=700-', null]);
    });

    test('downloads a complete part that fails the checks again', () async {
      writePart(first(), List.filled(first().gz.length, 7));
      await manager.install(ende.catalog);
      await expectInstalled();
      expect(rangesOf(first()), [null]);
    });

    test('starts over only once', () async {
      writePart(first(), List.filled(700, 7));
      server.overrides[first().entry.url.toString()] = List.filled(
        first().gz.length,
        9,
      );
      await expectLater(
        manager.install(ende.catalog),
        throwsA(isA<ModelChecksumException>()),
      );
      expect(rangesOf(first()), ['bytes=700-', null]);
      expect(modelFiles(), isEmpty);
    });

    test('a fresh download that fails the checks is not repeated', () async {
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
