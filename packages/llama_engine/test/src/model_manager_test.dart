import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:llama_engine/llama_engine.dart';
import 'package:llama_engine/src/file_hashing.dart';
import 'package:path/path.dart' as p;

import '../helpers/fake_llama_models.dart';

/// Serves [files] by URL path, honouring `Range: bytes=N-` (a 206 with its
/// `Content-Range`) unless [ignoreRange]. [failAfter] cuts a response
/// after that many bytes; [stallAfter] stops sending after that many bytes
/// (until [release]); [status] replaces the status code; [corrupt] flips
/// the last byte. A [contentRange] function replaces the `Content-Range`
/// of 206 responses (null: none), and [rangeFromStart] answers a range
/// request with a 206 of the whole file.
class _Server {
  new(this.files);

  final Map<String, Uint8List> files;
  final List<http.BaseRequest> requests = [];
  bool ignoreRange = false;
  bool rangeFromStart = false;
  String? Function(int start, int total)? contentRange;
  String contentRangeName = 'content-range';
  int? failAfter;
  int? stallAfter;
  int? status;
  bool corrupt = false;
  List<int> extra = const [];
  Completer<void>? gate;
  final release = Completer<void>();

  late final MockClient client = MockClient.streaming((request, _) async {
    requests.add(request);
    if (gate case final gate?) await gate.future;
    final body = files[request.url.path];
    if (status case final status?) {
      return http.StreamedResponse(Stream.value(utf8.encode('error')), status);
    }
    if (body == null) {
      return http.StreamedResponse(Stream.value(utf8.encode('missing')), 404);
    }
    var bytes = Uint8List.fromList([...body, ...extra]);
    if (corrupt) bytes[bytes.length - 1] ^= 0xff;
    var code = 200;
    final headers = <String, String>{};
    final range = request.headers['Range'];
    if (range != null && !ignoreRange) {
      final total = bytes.length;
      final start = rangeFromStart
          ? 0
          : int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)![1]!);
      bytes = bytes.sublist(start);
      code = 206;
      final value = (contentRange ?? _contentRange)(start, total);
      if (value != null) headers[contentRangeName] = value;
    }
    final cut = failAfter;
    final stall = stallAfter;
    Stream<List<int>> stream() async* {
      if (stall != null) {
        yield bytes.sublist(0, stall.clamp(0, bytes.length));
        await release.future;
        yield bytes.sublist(stall.clamp(0, bytes.length));
        return;
      }
      if (cut == null) {
        yield bytes;
        return;
      }
      yield bytes.sublist(0, cut.clamp(0, bytes.length));
      throw const SocketException('connection reset');
    }

    return http.StreamedResponse(stream(), code, headers: headers);
  });

  static String _contentRange(int start, int total) =>
      'bytes $start-${total - 1}/$total';
}

void main() {
  late Directory root;
  late Uint8List hyBytes;
  late Uint8List qwenBytes;
  late LlamaCatalogModel hy;
  late LlamaCatalogModel qwen;
  late LlamaModelCatalog catalog;
  late _Server server;
  late LlamaModelManager manager;

  setUp(() {
    root = Directory.systemTemp.createTempSync('llama_models_');
    hyBytes = fakeModelBytes(5000);
    qwenBytes = fakeModelBytes(9000, seed: 2);
    hy = fakeLlamaModel(
      'hy-mt2-1.8b-q4',
      hyBytes,
      name: 'Hy-MT2-1.8B-Q4_K_M.gguf',
      role: LlamaModelRole.translation,
    );
    qwen = fakeLlamaModel(
      'qwen3-1.7b-q4',
      qwenBytes,
      name: 'Qwen3-1.7B-Q4_K_M.gguf',
    );
    catalog = LlamaModelCatalog(models: [hy, qwen]);
    server = _Server({
      '/repo/resolve/abc/Hy-MT2-1.8B-Q4_K_M.gguf': hyBytes,
      '/repo/resolve/abc/Qwen3-1.7B-Q4_K_M.gguf': qwenBytes,
    });
    manager = LlamaModelManager(root: root, httpClient: server.client);
  });

  tearDown(() {
    manager.close();
    if (!server.release.isCompleted) server.release.complete();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  File part(LlamaCatalogModel model) => File(
    p.join(root.path, 'models', '.downloads', model.id, '${model.name}.part'),
  );

  String hyPath() => '/repo/resolve/abc/Hy-MT2-1.8B-Q4_K_M.gguf';

  group('install', () {
    test('downloads, verifies and installs a model atomically', () async {
      final progress = <LlamaDownloadProgress>[];
      final installed = await manager.install(hy, onProgress: progress.add);

      expect(installed.id, hy.id);
      expect(installed.sizeBytes, hyBytes.length);
      expect(installed.sha256, hy.sha256);
      expect(installed.matches(hy), isTrue);
      expect(installed.matches(qwen), isFalse);
      expect(File(installed.path).readAsBytesSync(), hyBytes);
      expect(
        installed.path,
        p.join(root.path, 'models', hy.id, 'Hy-MT2-1.8B-Q4_K_M.gguf'),
      );
      expect(await manager.pathOf(hy.id), installed.path);
      expect(await manager.pathOf(qwen.id), isNull);
      expect(progress.first.receivedBytes, 0);
      expect(progress.last.receivedBytes, hyBytes.length);
      expect(progress.last.totalBytes, hyBytes.length);
      expect(progress.last.fraction, 1);
      expect(progress.last.model, hy);
      expect(await manager.isInstalled(hy), isTrue);
      expect(await manager.installed(), [installed]);
      expect(installed.toString(), 'InstalledLlamaModel(${hy.id})');
      expect(
        installed.hashCode,
        (await manager.installedModel(hy.id)).hashCode,
      );
      expect(part(hy).existsSync(), isFalse);
      expect(
        Directory(p.join(root.path, 'models', '.staging')).listSync().isEmpty,
        isTrue,
      );
      final manifest = jsonDecode(
        File(p.join(root.path, 'models', hy.id, 'manifest.json'))
            .readAsStringSync(),
      ) as Map<String, Object?>;
      expect(manifest['sha256'], hy.sha256);
      expect(server.requests.single.headers, isNot(contains('Range')));
      expect(manager.isInstalling(hy.id), isFalse);
    });

    test('a zero-byte progress reports a fraction of 1', () {
      expect(
        LlamaDownloadProgress(
          model: hy,
          receivedBytes: 0,
          totalBytes: 0,
        ).fraction,
        1,
      );
    });

    test('returns at once when the model is installed', () async {
      await manager.install(hy);
      await manager.install(hy);
      expect(server.requests, hasLength(1));
    });

    test('shares one download between concurrent calls', () async {
      server.gate = Completer();
      final first = manager.install(hy);
      final second = manager.install(hy);
      expect(manager.isInstalling(hy.id), isTrue);
      server.gate!.complete();
      expect(await first, await second);
      expect(server.requests, hasLength(1));
    });

    test('keeps an interrupted download and resumes it with Range', () async {
      server.failAfter = 1200;
      await expectLater(
        manager.install(hy),
        throwsA(isA<LlamaDownloadException>()),
      );
      expect(part(hy).lengthSync(), 1200);
      expect(await manager.partialBytes(hy), 1200);
      expect(await manager.isInstalled(hy), isFalse);

      server.failAfter = null;
      final progress = <int>[];
      final installed = await manager.install(
        hy,
        onProgress: (event) => progress.add(event.receivedBytes),
      );
      expect(server.requests.last.headers['Range'], 'bytes=1200-');
      expect(progress.first, 1200);
      expect(File(installed.path).readAsBytesSync(), hyBytes);
      expect(await manager.partialBytes(hy), 0);
    });

    test('starts over when the server ignores Range', () async {
      server.failAfter = 100;
      await expectLater(manager.install(hy), throwsA(anything));
      server
        ..failAfter = null
        ..ignoreRange = true;
      final installed = await manager.install(hy);
      expect(server.requests.last.headers['Range'], 'bytes=100-');
      expect(File(installed.path).readAsBytesSync(), hyBytes);
    });

    test('installs a complete partial download without a request', () async {
      part(hy)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(hyBytes);
      await manager.install(hy);
      expect(server.requests, isEmpty);
      expect(await manager.isInstalled(hy), isTrue);
    });

    test('discards a partial download longer than the model', () async {
      part(hy)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(Uint8List(hyBytes.length + 1));
      await manager.install(hy);
      expect(server.requests.single.headers, isNot(contains('Range')));
    });

    test('rejects and discards a corrupt download', () async {
      server.corrupt = true;
      await expectLater(
        manager.install(hy),
        throwsA(
          isA<LlamaChecksumException>()
              .having(
                (error) => error.toString(),
                'toString',
                startsWith('LlamaChecksumException(${hy.id}: '),
              )
              .having((e) => e.message, 'message', contains('SHA-256'))
              .having((e) => e.mirror, 'mirror', isNull),
        ),
      );
      expect(part(hy).existsSync(), isFalse);
      expect(await manager.installed(), isEmpty);
    });

    test('rejects a download with too many bytes', () async {
      server.extra = [1, 2, 3];
      await expectLater(
        manager.install(hy),
        throwsA(isA<LlamaChecksumException>()),
      );
      expect(part(hy).existsSync(), isFalse);
    });

    test('reports HTTP errors with their status', () async {
      server.status = 503;
      await expectLater(
        manager.install(hy),
        throwsA(
          isA<LlamaDownloadException>()
              .having((error) => error.statusCode, 'statusCode', 503)
              .having(
                (error) => error.toString(),
                'toString',
                contains('LlamaDownloadException(${hy.id}: HTTP 503'),
              ),
        ),
      );
    });

    test('reports connection failures', () async {
      final failing = LlamaModelManager(
        root: root,
        httpClient: MockClient((_) async => throw const SocketException('x')),
      );
      await expectLater(
        failing.install(hy),
        throwsA(isA<LlamaDownloadException>()),
      );
    });

    test('times out a stalled server', () async {
      final stalled = LlamaModelManager(
        root: root,
        httpClient: MockClient.streaming(
          (_, _) => Completer<http.StreamedResponse>().future,
        ),
        requestTimeout: const Duration(milliseconds: 10),
      );
      await expectLater(
        stalled.install(hy),
        throwsA(isA<LlamaDownloadException>()),
      );
    });

    test('replaces another file installed under the same id', () async {
      await manager.install(hy);
      final newer = fakeLlamaModel(
        hy.id,
        qwenBytes,
        name: hy.name,
        role: LlamaModelRole.translation,
      );
      server.files[hyPath()] = qwenBytes;
      final installed = await manager.install(newer);
      expect(installed.matches(newer), isTrue);
      expect(await manager.isInstalled(hy), isFalse);
      expect(File(installed.path).readAsBytesSync(), qwenBytes);
      expect(
        Directory(p.join(root.path, 'models', '.trash')).listSync(),
        isEmpty,
      );
    });

    test('rejects unsafe ids', () async {
      final unsafe = LlamaCatalogModel(
        id: '..',
        name: 'x.gguf',
        url: Uri.parse('https://models.example/x.gguf'),
        size: 1,
        sha256: 'a' * 64,
        role: LlamaModelRole.assistant,
        family: 'qwen3',
        promptProfile: 'general',
        displayName: 'X',
        license: 'MIT',
        licenseUrl: hy.licenseUrl,
        sourceUrl: hy.sourceUrl,
      );
      await expectLater(manager.install(unsafe), throwsArgumentError);
      expect(() => manager.delete('../x'), throwsArgumentError);
      expect(() => manager.partialBytes(unsafe), throwsArgumentError);
    });
  });

  group('cancel', () {
    test('stops a running download and keeps it for resuming', () async {
      server.stallAfter = 700;
      final received = <int>[];
      final download = manager.install(
        hy,
        onProgress: (event) => received.add(event.receivedBytes),
      );
      // Wait for the first bytes.
      while (!received.contains(700)) {
        await Future<void>.delayed(Duration.zero);
      }
      manager.cancel(hy.id);
      await expectLater(
        download,
        throwsA(
          isA<LlamaDownloadCancelledException>().having(
            (e) => e.toString(),
            'toString',
            startsWith('LlamaDownloadCancelledException(${hy.id}: '),
          ),
        ),
      );
      expect(await manager.partialBytes(hy), 700);
      expect(manager.isInstalling(hy.id), isFalse);

      server
        ..stallAfter = null
        ..release.complete();
      final installed = await manager.install(hy);
      expect(server.requests.last.headers['Range'], 'bytes=700-');
      expect(File(installed.path).readAsBytesSync(), hyBytes);
    });

    test('stops a download that waits for the server', () async {
      server.gate = Completer();
      final download = manager.install(hy);
      await Future<void>.delayed(Duration.zero);
      manager.cancel(hy.id);
      await expectLater(
        download,
        throwsA(isA<LlamaDownloadCancelledException>()),
      );
      server.gate!.complete();
      expect(await manager.isInstalled(hy), isFalse);
    });

    test('names the mirror of a cancelled download', () async {
      final mirror = Uri.parse('https://mirror.example/models/');
      server
        ..files['/models/llm/Hy-MT2-1.8B-Q4_K_M.gguf'] = hyBytes
        ..stallAfter = 10;
      manager.mirror = mirror;
      var started = false;
      final download = manager.install(hy, onProgress: (_) => started = true);
      while (!started) {
        await Future<void>.delayed(Duration.zero);
      }
      manager.cancel(hy.id);
      await expectLater(
        download,
        throwsA(
          isA<LlamaDownloadCancelledException>().having(
            (e) => e.mirror,
            'mirror',
            mirror,
          ),
        ),
      );
    });

    test('does nothing without a running download', () async {
      manager
        ..cancel(hy.id)
        ..cancel('unknown');
      expect(await manager.install(hy), isNotNull);
    });
  });

  group('mirror', () {
    final mirror = Uri.parse('https://mirror.example/models/');

    List<String> paths() => [
      for (final request in server.requests) request.url.path,
    ];

    test('downloads from <mirror>/llm/<name>', () async {
      server.files['/models/llm/Hy-MT2-1.8B-Q4_K_M.gguf'] = hyBytes;
      manager.mirror = mirror;
      final installed = await manager.install(hy);
      expect(installed.matches(hy), isTrue);
      expect(paths(), ['/models/llm/Hy-MT2-1.8B-Q4_K_M.gguf']);
      expect(server.requests.single.url.host, 'mirror.example');
    });

    test('a model the mirror lacks fails, naming the mirror', () async {
      manager.mirror = mirror;
      await expectLater(
        manager.install(hy),
        throwsA(
          isA<LlamaDownloadException>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.mirror, 'mirror', mirror)
              .having((e) => e.message, 'message', contains('mirror.example')),
        ),
      );
      expect(paths(), ['/models/llm/Hy-MT2-1.8B-Q4_K_M.gguf']);
    });

    test('falls back to the catalog URL when allowed', () async {
      manager
        ..mirror = mirror
        ..fallbackToDefault = true;
      await manager.install(hy);
      expect(paths(), ['/models/llm/Hy-MT2-1.8B-Q4_K_M.gguf', hyPath()]);
      expect(server.requests.last.url.host, 'models.example');
    });

    test('falls back when the mirror cannot be reached', () async {
      final client = _MirrorDownClient(server.client);
      final fallback = LlamaModelManager(root: root, httpClient: client)
        ..mirror = mirror
        ..fallbackToDefault = true;
      await fallback.install(hy);
      expect(paths(), [hyPath()]);
    });

    test('reports a mirror that cannot be reached', () async {
      final failing = LlamaModelManager(
        root: root,
        httpClient: MockClient((_) async => throw const SocketException('x')),
      )..mirror = mirror;
      await expectLater(
        failing.install(hy),
        throwsA(
          isA<LlamaDownloadException>()
              .having((e) => e.mirror, 'mirror', mirror)
              .having((e) => e.message, 'message', contains('mirror.example')),
        ),
      );
    });

    test('rejects another file from the mirror, naming it', () async {
      server.files['/models/llm/Hy-MT2-1.8B-Q4_K_M.gguf'] = qwenBytes.sublist(
        0,
        hyBytes.length,
      );
      manager
        ..mirror = mirror
        ..fallbackToDefault = true;
      await expectLater(
        manager.install(hy),
        throwsA(
          isA<LlamaChecksumException>()
              .having((e) => e.mirror, 'mirror', mirror)
              .having(
                (e) => e.message,
                'message',
                contains('from the mirror https://mirror.example/models/'),
              ),
        ),
      );
      // A mismatch is not a missing file: no fallback.
      expect(paths(), ['/models/llm/Hy-MT2-1.8B-Q4_K_M.gguf']);
      expect(part(hy).existsSync(), isFalse);
    });

    test('an interrupted mirror download names the mirror', () async {
      server
        ..files['/models/llm/Hy-MT2-1.8B-Q4_K_M.gguf'] = hyBytes
        ..failAfter = 100;
      manager.mirror = mirror;
      await expectLater(
        manager.install(hy),
        throwsA(
          isA<LlamaDownloadException>().having(
            (e) => e.mirror,
            'mirror',
            mirror,
          ),
        ),
      );
      expect(await manager.partialBytes(hy), 100);
    });
  });

  group('resume', () {
    final mirror = Uri.parse('https://mirror.example/models/');
    const mirrorPath = '/models/llm/Hy-MT2-1.8B-Q4_K_M.gguf';

    File source(LlamaCatalogModel model) => File('${part(model).path}.source');

    List<String?> ranges() => [
      for (final request in server.requests) request.headers['Range'],
    ];

    /// An interrupted download of [hy] from [from] (null: the catalog's
    /// URL) after [bytes] bytes.
    Future<void> interrupt({Uri? from, int bytes = 1000}) async {
      manager.mirror = from;
      server.failAfter = bytes;
      await expectLater(
        manager.install(hy),
        throwsA(isA<LlamaDownloadException>()),
      );
      server.failAfter = null;
      expect(part(hy).lengthSync(), bytes);
    }

    test('records where the bytes of a partial download came from', () async {
      server.files[mirrorPath] = hyBytes;
      await interrupt(from: mirror);
      final recorded =
          jsonDecode(source(hy).readAsStringSync()) as Map<String, Object?>;
      expect(recorded, {
        'url': 'https://mirror.example$mirrorPath',
        'mirror': mirror.toString(),
        'size': hy.size,
        'sha256': hy.sha256,
      });
      await manager.install(hy);
      expect(ranges(), [null, 'bytes=1000-']);
      expect(source(hy).existsSync(), isFalse);
    });

    test(
      'a poisoned partial download does not survive a change of source',
      () async {
        // The mirror sends bytes of another file, then the connection breaks.
        server.files[mirrorPath] = qwenBytes.sublist(0, hyBytes.length);
        await interrupt(from: mirror);
        // Back to Hugging Face: the whole file again, from there.
        manager.mirror = null;
        final installed = await manager.install(hy);
        expect(File(installed.path).readAsBytesSync(), hyBytes);
        expect(server.requests.last.url.path, hyPath());
        expect(ranges().last, isNull);
      },
    );

    test(
      'resumes from the URL the bytes came from, also as a fallback',
      () async {
        await interrupt();
        manager
          ..mirror = mirror
          ..fallbackToDefault = true;
        // The mirror lacks the file: asked from the start (not its bytes), then
        // the catalog's URL resumes its own.
        await manager.install(hy);
        expect(
          [for (final r in server.requests) r.url.path],
          [hyPath(), mirrorPath, hyPath()],
        );
        expect(ranges(), [null, null, 'bytes=1000-']);
      },
    );

    test('starts over without a record of the source', () async {
      for (final record in [
        null,
        'not json',
        '[]',
        jsonEncode({
          'url': hy.url.toString(),
          'mirror': null,
          'size': hy.size,
          'sha256': 'b' * 64,
        }),
      ]) {
        part(hy)
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(hyBytes.sublist(0, 100));
        if (record != null) source(hy).writeAsStringSync(record);
        server.requests.clear();
        await manager.install(hy);
        expect(ranges(), [null], reason: record);
        await manager.delete(hy.id);
      }
    });

    test('reads Content-Range whatever its case', () async {
      await interrupt();
      server.contentRangeName = 'Content-Range';
      await manager.install(hy);
      expect(ranges(), [null, 'bytes=1000-']);
    });

    test('a 206 from another offset starts over', () async {
      for (final misbehave in <void Function()>[
        // The whole file as "partial content".
        () => server.rangeFromStart = true,
        // No Content-Range at all.
        () => server.contentRange = (_, _) => null,
        // A range of a file of another size.
        () =>
            server.contentRange = (start, total) =>
                'bytes $start-${total - 1}/${total + 1}',
        // Garbage.
        () => server.contentRange = (_, _) => 'bytes */*',
        () => server.contentRange = (start, _) => 'bytes $start-1/*',
      ]) {
        await interrupt();
        misbehave();
        final installed = await manager.install(hy);
        expect(File(installed.path).readAsBytesSync(), hyBytes);
        expect(ranges().sublist(ranges().length - 2), ['bytes=1000-', null]);
        server
          ..rangeFromStart = false
          ..contentRange = null;
        await manager.delete(hy.id);
      }
    });

    test(
      'a complete partial download that does not match names its source',
      () async {
        server
          ..files[mirrorPath] = hyBytes
          ..corrupt = true;
        // Every byte arrives, then the connection breaks.
        await interrupt(from: mirror, bytes: hyBytes.length);
        server.corrupt = false;
        manager.mirror = null;
        final requests = server.requests.length;
        await expectLater(
          manager.install(hy),
          throwsA(
            isA<LlamaChecksumException>()
                .having((e) => e.mirror, 'mirror', mirror)
                .having(
                  (e) => e.message,
                  'message',
                  contains('from the mirror https://mirror.example/models/'),
                ),
          ),
        );
        expect(server.requests, hasLength(requests));
        expect(part(hy).existsSync(), isFalse);
        expect(source(hy).existsSync(), isFalse);
        // The next install downloads it again.
        expect((await manager.install(hy)).matches(hy), isTrue);
      },
    );

    test('fails when the source cannot be recorded', () async {
      Directory(source(hy).path).createSync(recursive: true);
      await expectLater(
        manager.install(hy),
        throwsA(isA<LlamaDownloadException>()),
      );
      expect(await manager.isInstalled(hy), isFalse);
    });
  });

  group('installed', () {
    test('is empty without a models directory', () async {
      expect(await manager.installed(), isEmpty);
      expect(await manager.installedModel(hy.id), isNull);
      expect(await manager.isInstalled(hy), isFalse);
      expect(await manager.partialBytes(hy), 0);
    });

    test('ignores incomplete or foreign installs', () async {
      await manager.install(hy);
      await manager.install(qwen);
      final models = Directory(p.join(root.path, 'models'));
      // A truncated file.
      File(p.join(models.path, qwen.id, qwen.name)).writeAsBytesSync([1, 2, 3]);
      // A folder without a manifest, one with a bad manifest, one with
      // another schema and one whose manifest names another id.
      Directory(p.join(models.path, 'gemma')).createSync();
      Directory(p.join(models.path, 'bad')).createSync();
      File(p.join(models.path, 'bad', 'manifest.json')).writeAsStringSync('[');
      Directory(p.join(models.path, 'future')).createSync();
      File(p.join(models.path, 'future', 'manifest.json'))
          .writeAsStringSync(jsonEncode({'schemaVersion': 2}));
      Directory(p.join(models.path, 'other')).createSync();
      File(p.join(models.path, 'other', 'manifest.json')).writeAsStringSync(
        jsonEncode({
          'schemaVersion': 1,
          'id': hy.id,
          'name': hy.name,
          'size': 1,
          'sha256': 'a' * 64,
        }),
      );
      File(p.join(models.path, 'stray.txt')).writeAsStringSync('x');

      final fresh = LlamaModelManager(root: root, httpClient: server.client);
      expect((await fresh.installed()).map((m) => m.id), [hy.id]);
    });
  });

  group('delete, deleteAll and cleanUp', () {
    test('delete removes the model and its partial download', () async {
      await manager.install(hy);
      server.failAfter = 10;
      await expectLater(manager.install(qwen), throwsA(anything));
      expect(part(qwen).existsSync(), isTrue);

      await manager.delete(hy.id);
      await manager.delete(qwen.id);
      expect(await manager.installed(), isEmpty);
      expect(part(qwen).existsSync(), isFalse);
      // Deleting what is not there is fine.
      await manager.delete(hy.id);
    });

    test('deleteAll removes the models folder, cancelling downloads', () async {
      await manager.install(hy);
      server.stallAfter = 10;
      var started = false;
      final running = manager.install(qwen, onProgress: (_) => started = true);
      while (!started) {
        await Future<void>.delayed(Duration.zero);
      }
      await manager.deleteAll();
      await expectLater(
        running,
        throwsA(isA<LlamaDownloadCancelledException>()),
      );
      expect(manager.modelsDirectory.existsSync(), isFalse);
      expect(await manager.installed(), isEmpty);
      // Nothing to delete is fine too.
      await manager.deleteAll();
    });

    test('cleanUp removes staging and trash but keeps downloads', () async {
      final models = p.join(root.path, 'models');
      Directory(p.join(models, '.staging', 'x-1')).createSync(recursive: true);
      Directory(p.join(models, '.trash', '1')).createSync(recursive: true);
      part(hy)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync([1]);
      await manager.cleanUp();
      expect(Directory(p.join(models, '.staging')).existsSync(), isFalse);
      expect(Directory(p.join(models, '.trash')).existsSync(), isFalse);
      expect(part(hy).existsSync(), isTrue);
    });

    test('close leaves an injected client open', () async {
      manager.close();
      expect(await manager.install(hy), isNotNull);
      LlamaModelManager(root: root).close();
    });
  });

  group('importFiles', () {
    late Directory picked;

    setUp(() {
      picked = Directory(p.join(root.path, 'picked'))..createSync();
    });

    File write(String name, List<int> bytes) =>
        File(p.join(picked.path, name))..writeAsBytesSync(bytes);

    test('installs files named like the catalog, ignoring case', () async {
      final file = write('hy-mt2-1.8b-q4_k_m.GGUF', hyBytes);
      final result = await manager.importFiles([file], catalog: catalog);

      expect(result.models.single.status, LlamaImportStatus.installed);
      expect(result.installed, [hy]);
      expect(result.unmatched, isEmpty);
      expect(await manager.isInstalled(hy), isTrue);
      expect(file.existsSync(), isTrue, reason: 'imported files are kept');
      expect(server.requests, isEmpty);
      expect(
        result.models.single.toString(),
        'LlamaImportOutcome(${hy.id}, installed)',
      );
    });

    test('recognises a renamed copy by size and SHA-256', () async {
      final result = await manager.importFiles([
        write('model (1).gguf', qwenBytes),
      ], catalog: catalog);
      expect(result.installed, [qwen]);
    });

    test('moves a verified file when asked', () async {
      final file = write('copy.gguf', hyBytes);
      final result = await manager.importFiles(
        [file],
        catalog: catalog,
        move: true,
      );
      expect(result.installed, [hy]);
      expect(file.existsSync(), isFalse, reason: 'moved into place');
      expect(File((await manager.pathOf(hy.id))!).readAsBytesSync(), hyBytes);
    });

    test('does not move a file that is not the model', () async {
      final damaged = Uint8List.fromList(hyBytes)..[0] ^= 1;
      final file = write(hy.name, damaged);
      final result = await manager.importFiles(
        [file],
        catalog: catalog,
        move: true,
      );
      expect(result.models.single.status, LlamaImportStatus.checksumMismatch);
      expect(file.existsSync(), isTrue);
    });

    test('reports a damaged file named like a model', () async {
      final damaged = Uint8List.fromList(hyBytes)..[0] ^= 1;
      final file = write(hy.name, damaged);
      final short = write('${hy.name}.bak', [1, 2]);
      final result = await manager.importFiles([file, short], catalog: catalog);
      final outcome = result.models.single;
      expect(outcome.status, LlamaImportStatus.checksumMismatch);
      expect(outcome.damaged, [file]);
      expect(result.unmatched, [short]);
      expect(await manager.installed(), isEmpty);
    });

    test('reports a named file of the wrong size as damaged', () async {
      final file = write(hy.name, [1, 2, 3]);
      final result = await manager.importFiles([file], catalog: catalog);
      expect(result.models.single.status, LlamaImportStatus.checksumMismatch);
      expect(result.models.single.damaged, [file]);
    });

    test('a same-size file that is something else is unmatched', () async {
      final other = Uint8List.fromList(hyBytes)..[10] ^= 1;
      final file = write('notes.gguf', other);
      final result = await manager.importFiles([file], catalog: catalog);
      expect(result.unmatched, [file]);
      expect(result.models, isEmpty);
    });

    test('uses the first verified candidate', () async {
      final damaged = Uint8List.fromList(hyBytes)..[0] ^= 1;
      final result = await manager.importFiles([
        write(hy.name, damaged),
        write('copy.gguf', hyBytes),
      ], catalog: catalog);
      expect(result.models.single.status, LlamaImportStatus.installed);
    });

    test('skips models that are installed already', () async {
      await manager.install(hy);
      final result = await manager.importFiles([
        write(hy.name, hyBytes),
      ], catalog: catalog);
      expect(result.models.single.status, LlamaImportStatus.alreadyInstalled);
      expect(result.installed, isEmpty);
    });

    test('lists unreadable and unknown files as unmatched', () async {
      final missing = File(p.join(picked.path, 'gone.gguf'));
      final unknown = write('notes.txt', [1, 2, 3]);
      final result = await manager.importFiles([
        missing,
        unknown,
      ], catalog: catalog);
      expect(result.models, isEmpty);
      expect(result.unmatched, [missing, unknown]);
    });

    test('waits for a running download of the same model', () async {
      server.gate = Completer();
      final download = manager.install(hy);
      final import = manager.importFiles([
        write(hy.name, hyBytes),
      ], catalog: catalog);
      server.gate!.complete();
      await download;
      final result = await import;
      expect(result.models.single.status, LlamaImportStatus.alreadyInstalled);
    });

    test('installs the file when a running download fails', () async {
      server
        ..gate = Completer()
        ..status = 500;
      final download = manager.install(hy);
      final import = manager.importFiles([
        write(hy.name, hyBytes),
      ], catalog: catalog);
      server.gate!.complete();
      await expectLater(download, throwsA(isA<LlamaDownloadException>()));
      expect((await import).installed, [hy]);
    });

    test('reports a failed install', () async {
      // A file where the models directory should be: staging fails.
      File(p.join(root.path, 'models')).writeAsStringSync('x');
      final result = await manager.importFiles([
        write(hy.name, hyBytes),
      ], catalog: catalog);
      final outcome = result.models.single;
      expect(outcome.status, LlamaImportStatus.failed);
      expect(outcome.error, isA<FileSystemException>());
    });
  });

  group('free space', () {
    late List<String> asked;
    late int? free;

    LlamaModelManager spaced({Exception? error}) => LlamaModelManager(
      root: root,
      httpClient: server.client,
      freeSpace: (path) async {
        asked.add(path);
        if (error != null) throw error;
        return free;
      },
    );

    setUp(() {
      asked = [];
      free = null;
    });

    test('the margin is 5 %, at least 50 MiB', () {
      expect(LlamaModelManager.requiredSpace(0), 50 << 20);
      expect(LlamaModelManager.requiredSpace(1000), 1000 + (50 << 20));
      const gigabytes = 3 << 30;
      expect(
        LlamaModelManager.requiredSpace(gigabytes),
        gigabytes + gigabytes ~/ 20,
      );
    });

    test('refuses a download without room, before any request', () async {
      free = hyBytes.length + 10;
      final spacious = spaced();
      await expectLater(
        spacious.install(hy),
        throwsA(
          isA<LlamaInsufficientSpaceException>()
              .having((e) => e.model, 'model', hy.id)
              .having(
                (e) => e.requiredBytes,
                'requiredBytes',
                LlamaModelManager.requiredSpace(hyBytes.length),
              )
              .having((e) => e.availableBytes, 'availableBytes', free)
              .having(
                (e) => e.toString(),
                'toString',
                startsWith('LlamaInsufficientSpaceException(hy-mt2'),
              ),
        ),
      );
      expect(server.requests, isEmpty);
      expect(asked, [p.join(root.path, 'models')]);
      expect(await spacious.isInstalled(hy), isFalse);
    });

    test('downloads with room, or when the free space is unknown', () async {
      free = LlamaModelManager.requiredSpace(hyBytes.length);
      expect((await spaced().install(hy)).id, hy.id);

      free = null;
      expect((await spaced().install(qwen)).id, qwen.id);

      final failing = spaced(error: const FormatException('no answer'));
      await failing.delete(hy.id);
      expect((await failing.install(hy)).id, hy.id);
    });

    test('a resumed download needs room for the rest only', () async {
      server.failAfter = 3000;
      await expectLater(
        manager.install(hy),
        throwsA(isA<LlamaDownloadException>()),
      );
      server.failAfter = null;
      final rest = hyBytes.length - 3000;
      free = LlamaModelManager.requiredSpace(rest);
      expect((await spaced().install(hy)).id, hy.id);
    });

    test('an import refuses a copy without room', () async {
      free = 1;
      final file = File(p.join(root.path, hy.name))..writeAsBytesSync(hyBytes);
      final result = await spaced().importFiles([file], catalog: catalog);
      final outcome = result.models.single;
      expect(outcome.status, LlamaImportStatus.failed);
      expect(outcome.error, isA<LlamaInsufficientSpaceException>());
      expect(file.existsSync(), isTrue);
    });

    test('an import that moves the file needs no room', () async {
      free = 1;
      final file = File(p.join(root.path, hy.name))..writeAsBytesSync(hyBytes);
      final result = await spaced().importFiles(
        [file],
        catalog: catalog,
        move: true,
      );
      expect(result.installed, [hy]);
      expect(asked, isEmpty);
    });
  });

  group('importSources', () {
    test('copies a picked document into staging and installs it', () async {
      final source = _Source('Hy-MT2-1.8B-Q4_K_M.gguf', hyBytes);
      final result = await manager.importSources([source], catalog: catalog);
      expect(result.installed, [hy]);
      expect(source.copies, 1);
      expect(source.maxBytes, hy.size);
      expect(
        p.isWithin(p.join(root.path, 'models', '.staging'), source.target!),
        isTrue,
      );
      final installed = await manager.installedModel(hy.id);
      expect(File(installed!.path).readAsBytesSync(), hyBytes);
    });

    test('matches a renamed source by size, or by name alone', () async {
      final renamed = _Source('model (1).gguf', qwenBytes);
      final unknown = _Source('Hy-MT2-1.8B-Q4_K_M.gguf', hyBytes, known: false);
      final result = await manager.importSources([
        renamed,
        unknown,
      ], catalog: catalog);
      expect(result.installed, [hy, qwen]);
    });

    test('reports damaged, short and unknown sources', () async {
      final damaged = Uint8List.fromList(hyBytes)..[0] ^= 0xff;
      final result = await manager.importSources([
        _Source('Hy-MT2-1.8B-Q4_K_M.gguf', damaged),
        _Source('Qwen3-1.7B-Q4_K_M.gguf', qwenBytes.sublist(1), known: false),
        _Source('notes.txt', [1, 2, 3]),
      ], catalog: catalog);
      expect(result.installed, isEmpty);
      expect(
        [for (final outcome in result.models) outcome.status],
        [
          LlamaImportStatus.checksumMismatch,
          LlamaImportStatus.checksumMismatch,
        ],
      );
      expect(result.models.first.damaged.single.path, hy.name);
      expect(result.unmatched.single.path, 'notes.txt');
    });

    test('a source that cannot be read fails', () async {
      final result = await manager.importSources([
        _Source(hy.name, hyBytes, error: const FileSystemException('denied')),
      ], catalog: catalog);
      expect(result.models.single.status, LlamaImportStatus.failed);
      expect(result.models.single.error, isA<FileSystemException>());
    });

    test('checks the free space before copying', () async {
      final spaced = LlamaModelManager(
        root: root,
        httpClient: server.client,
        freeSpace: (_) async => 10,
      );
      final source = _Source(hy.name, hyBytes);
      final result = await spaced.importSources([source], catalog: catalog);
      expect(
        result.models.single.error,
        isA<LlamaInsufficientSpaceException>(),
      );
      expect(source.copies, 0);
    });
  });

  group('hashing', () {
    test('works inline as in the background', () async {
      final inline = LlamaModelManager(
        root: root,
        httpClient: server.client,
        hashing: const FileHashing.inline(),
      );
      expect((await inline.install(hy)).id, hy.id);
      server.corrupt = true;
      await expectLater(
        inline.install(qwen),
        throwsA(isA<LlamaChecksumException>()),
      );
    });
  });
}

/// Refuses every request to `mirror.example` as an unreachable host
/// would; others go to [_inner].
class _MirrorDownClient extends http.BaseClient {
  new(this._inner);

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.url.host == 'mirror.example') {
      return Future.error(const SocketException('Connection refused'));
    }
    return _inner.send(request);
  }
}

/// A picked document for [LlamaModelManager.importSources].
class _Source implements LlamaImportSource {
  new(this.name, this.bytes, {this.known = true, this.error});

  @override
  final String name;

  final List<int> bytes;
  final bool known;
  final Exception? error;
  int copies = 0;
  int? maxBytes;
  String? target;

  @override
  int? get length => known ? bytes.length : null;

  @override
  Future<int> copyTo(File destination, {required int maxBytes}) async {
    if (error case final error?) throw error;
    copies++;
    this.maxBytes = maxBytes;
    target = destination.path;
    final written = bytes.length > maxBytes + 1
        ? bytes.sublist(0, maxBytes + 1)
        : bytes;
    await destination.writeAsBytes(written, flush: true);
    return written.length;
  }
}
