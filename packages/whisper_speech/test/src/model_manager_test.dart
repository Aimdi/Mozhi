import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:whisper_speech/src/file_hashing.dart';
import 'package:whisper_speech/whisper_speech.dart';

import '../helpers/fake_models.dart';

/// Serves [files] by URL path, honouring `Range: bytes=N-` unless
/// [ignoreRange]. [failAfter] cuts a response after that many bytes;
/// [status] replaces the status code; [corrupt] flips the last byte.
class _Server {
  new(this.files);

  final Map<String, Uint8List> files;
  final List<http.BaseRequest> requests = [];
  bool ignoreRange = false;
  int? failAfter;
  int? status;
  bool corrupt = false;
  List<int> extra = const [];
  Completer<void>? gate;

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
    final range = request.headers['Range'];
    if (range != null && !ignoreRange) {
      final start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)![1]!);
      bytes = bytes.sublist(start);
      code = 206;
    }
    final cut = failAfter;
    Stream<List<int>> stream() async* {
      if (cut == null) {
        yield bytes;
        return;
      }
      yield bytes.sublist(0, cut.clamp(0, bytes.length));
      throw const SocketException('connection reset');
    }

    return http.StreamedResponse(stream(), code);
  });
}

void main() {
  late Directory root;
  late Uint8List tinyBytes;
  late Uint8List baseBytes;
  late WhisperCatalogModel tiny;
  late WhisperCatalogModel base;
  late WhisperModelCatalog catalog;
  late _Server server;
  late WhisperModelManager manager;

  setUp(() {
    root = Directory.systemTemp.createTempSync('whisper_models_');
    tinyBytes = fakeModelBytes(5000);
    baseBytes = fakeModelBytes(9000, seed: 2);
    tiny = fakeModel('tiny', tinyBytes);
    base = fakeModel('base', baseBytes);
    catalog = WhisperModelCatalog(models: [tiny, base]);
    server = _Server({
      '/ggml-tiny.bin': tinyBytes,
      '/ggml-base.bin': baseBytes,
    });
    manager = WhisperModelManager(root: root, httpClient: server.client);
  });

  tearDown(() {
    manager.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  File part(WhisperCatalogModel model) => File(
    p.join(root.path, 'models', '.downloads', model.id, '${model.name}.part'),
  );

  group('install', () {
    test('downloads, verifies and installs a model atomically', () async {
      final progress = <WhisperDownloadProgress>[];
      final installed = await manager.install(tiny, onProgress: progress.add);

      expect(installed.id, 'tiny');
      expect(installed.sizeBytes, tinyBytes.length);
      expect(installed.sha1, tiny.sha1);
      expect(installed.matches(tiny), isTrue);
      expect(installed.matches(base), isFalse);
      expect(File(installed.path).readAsBytesSync(), tinyBytes);
      expect(
        installed.path,
        p.join(root.path, 'models', 'tiny', 'ggml-tiny.bin'),
      );
      expect(progress.first.receivedBytes, 0);
      expect(progress.last.receivedBytes, tinyBytes.length);
      expect(progress.last.totalBytes, tinyBytes.length);
      expect(progress.last.fraction, 1);
      expect(await manager.isInstalled(tiny), isTrue);
      expect(await manager.installed(), [installed]);
      expect(installed.toString(), 'InstalledWhisperModel(tiny)');
      expect(part(tiny).existsSync(), isFalse);
      expect(
        Directory(p.join(root.path, 'models', '.staging')).listSync().isEmpty,
        isTrue,
      );
      final manifest = jsonDecode(
        File(p.join(root.path, 'models', 'tiny', 'manifest.json'))
            .readAsStringSync(),
      ) as Map<String, Object?>;
      expect(manifest['sha1'], tiny.sha1);
      expect(server.requests.single.headers, isNot(contains('Range')));
    });

    test('returns at once when the model is installed', () async {
      await manager.install(tiny);
      await manager.install(tiny);
      expect(server.requests, hasLength(1));
    });

    test('shares one download between concurrent calls', () async {
      server.gate = Completer();
      final first = manager.install(tiny);
      final second = manager.install(tiny);
      server.gate!.complete();
      expect(await first, await second);
      expect(server.requests, hasLength(1));
    });

    test('keeps an interrupted download and resumes it with Range', () async {
      server.failAfter = 1200;
      await expectLater(
        manager.install(tiny),
        throwsA(isA<WhisperDownloadException>()),
      );
      expect(part(tiny).lengthSync(), 1200);
      expect(await manager.partialBytes(tiny), 1200);
      expect(await manager.isInstalled(tiny), isFalse);

      server.failAfter = null;
      final progress = <int>[];
      final installed = await manager.install(
        tiny,
        onProgress: (event) => progress.add(event.receivedBytes),
      );
      expect(server.requests.last.headers['Range'], 'bytes=1200-');
      expect(progress.first, 1200);
      expect(File(installed.path).readAsBytesSync(), tinyBytes);
      expect(await manager.partialBytes(tiny), 0);
    });

    test('starts over when the server ignores Range', () async {
      part(tiny)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(tinyBytes.sublist(0, 100));
      server.ignoreRange = true;
      final installed = await manager.install(tiny);
      expect(File(installed.path).readAsBytesSync(), tinyBytes);
    });

    test('installs a complete partial download without a request', () async {
      part(tiny)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(tinyBytes);
      await manager.install(tiny);
      expect(server.requests, isEmpty);
      expect(await manager.isInstalled(tiny), isTrue);
    });

    test('discards a partial download longer than the model', () async {
      part(tiny)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(Uint8List(tinyBytes.length + 1));
      await manager.install(tiny);
      expect(server.requests.single.headers, isNot(contains('Range')));
    });

    test('rejects and discards a corrupt download', () async {
      server.corrupt = true;
      await expectLater(
        manager.install(tiny),
        throwsA(
          isA<WhisperChecksumException>().having(
            (error) => error.toString(),
            'toString',
            startsWith('WhisperChecksumException(tiny: '),
          ),
        ),
      );
      expect(part(tiny).existsSync(), isFalse);
      expect(await manager.installed(), isEmpty);
    });

    test('rejects a download with too many bytes', () async {
      server.extra = [1, 2, 3];
      await expectLater(
        manager.install(tiny),
        throwsA(isA<WhisperChecksumException>()),
      );
      expect(part(tiny).existsSync(), isFalse);
    });

    test('reports HTTP errors with their status', () async {
      server.status = 503;
      await expectLater(
        manager.install(tiny),
        throwsA(
          isA<WhisperDownloadException>()
              .having((error) => error.statusCode, 'statusCode', 503)
              .having(
                (error) => error.toString(),
                'toString',
                contains('WhisperDownloadException(tiny: HTTP 503'),
              ),
        ),
      );
    });

    test('reports connection failures', () async {
      final failing = WhisperModelManager(
        root: root,
        httpClient: MockClient((_) async => throw const SocketException('x')),
      );
      await expectLater(
        failing.install(tiny),
        throwsA(isA<WhisperDownloadException>()),
      );
    });

    test('times out a stalled server', () async {
      final stalled = WhisperModelManager(
        root: root,
        httpClient: MockClient.streaming(
          (_, _) => Completer<http.StreamedResponse>().future,
        ),
        requestTimeout: const Duration(milliseconds: 10),
      );
      await expectLater(
        stalled.install(tiny),
        throwsA(isA<WhisperDownloadException>()),
      );
    });

    test('replaces another file installed under the same id', () async {
      await manager.install(tiny);
      final newer = fakeModel('tiny', baseBytes);
      server.files['/ggml-tiny.bin'] = baseBytes;
      final installed = await manager.install(newer);
      expect(installed.matches(newer), isTrue);
      expect(await manager.isInstalled(tiny), isFalse);
      expect(File(installed.path).readAsBytesSync(), baseBytes);
      expect(
        Directory(p.join(root.path, 'models', '.trash')).listSync(),
        isEmpty,
      );
    });

    test('rejects unsafe ids', () async {
      final unsafe = WhisperCatalogModel(
        id: '..',
        name: 'x.bin',
        url: Uri.parse('https://models.example/x.bin'),
        size: 1,
        sha1: 'a' * 40,
      );
      await expectLater(manager.install(unsafe), throwsArgumentError);
      expect(() => manager.delete('../x'), throwsArgumentError);
      expect(() => manager.partialBytes(unsafe), throwsArgumentError);
    });
  });

  group('mirror', () {
    final mirror = Uri.parse('https://mirror.example/models/');

    List<String> paths() => [
      for (final request in server.requests) request.url.path,
    ];

    test('downloads from <mirror>/whisper/<name>', () async {
      server.files['/models/whisper/ggml-tiny.bin'] = tinyBytes;
      manager.mirror = mirror;
      final installed = await manager.install(tiny);
      expect(installed.matches(tiny), isTrue);
      expect(paths(), ['/models/whisper/ggml-tiny.bin']);
      expect(server.requests.single.url.host, 'mirror.example');
    });

    test('a model the mirror lacks fails, naming the mirror', () async {
      manager.mirror = mirror;
      await expectLater(
        manager.install(tiny),
        throwsA(
          isA<WhisperDownloadException>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.mirror, 'mirror', mirror)
              .having((e) => e.message, 'message', contains('mirror.example')),
        ),
      );
      expect(paths(), ['/models/whisper/ggml-tiny.bin']);
    });

    test('falls back to the catalog URL when allowed', () async {
      manager
        ..mirror = mirror
        ..fallbackToDefault = true;
      await manager.install(tiny);
      expect(paths(), ['/models/whisper/ggml-tiny.bin', '/ggml-tiny.bin']);
      expect(server.requests.last.url.host, 'models.example');
    });

    test('falls back when the mirror cannot be reached', () async {
      final client = _MirrorDownClient(server.client);
      final fallback = WhisperModelManager(root: root, httpClient: client)
        ..mirror = mirror
        ..fallbackToDefault = true;
      await fallback.install(tiny);
      expect(paths(), ['/ggml-tiny.bin']);
    });

    test('reports a mirror that cannot be reached', () async {
      final failing = WhisperModelManager(
        root: root,
        httpClient: MockClient((_) async => throw const SocketException('x')),
      )..mirror = mirror;
      await expectLater(
        failing.install(tiny),
        throwsA(
          isA<WhisperDownloadException>()
              .having((e) => e.mirror, 'mirror', mirror)
              .having((e) => e.message, 'message', contains('mirror.example')),
        ),
      );
    });

    test('rejects another file from the mirror, naming it', () async {
      server.files['/models/whisper/ggml-tiny.bin'] = baseBytes.sublist(
        0,
        tinyBytes.length,
      );
      manager
        ..mirror = mirror
        ..fallbackToDefault = true;
      await expectLater(
        manager.install(tiny),
        throwsA(
          isA<WhisperChecksumException>()
              .having((e) => e.mirror, 'mirror', mirror)
              .having(
                (e) => e.message,
                'message',
                contains('from the mirror https://mirror.example/models/'),
              ),
        ),
      );
      // A mismatch is not a missing file: no fallback.
      expect(paths(), ['/models/whisper/ggml-tiny.bin']);
      expect(part(tiny).existsSync(), isFalse);
    });

    test('an interrupted mirror download names the mirror', () async {
      server
        ..files['/models/whisper/ggml-tiny.bin'] = tinyBytes
        ..failAfter = 100;
      manager.mirror = mirror;
      await expectLater(
        manager.install(tiny),
        throwsA(
          isA<WhisperDownloadException>().having(
            (e) => e.mirror,
            'mirror',
            mirror,
          ),
        ),
      );
      expect(await manager.partialBytes(tiny), 100);
    });

    test('rejects a mirror that sends more than the file', () async {
      server
        ..files['/models/whisper/ggml-tiny.bin'] = tinyBytes
        ..extra = [1];
      manager.mirror = mirror;
      await expectLater(
        manager.install(tiny),
        throwsA(
          isA<WhisperChecksumException>().having(
            (e) => e.mirror,
            'mirror',
            mirror,
          ),
        ),
      );
    });
  });

  group('SHA-256', () {
    WhisperCatalogModel withSha256(String digest) => WhisperCatalogModel(
      id: tiny.id,
      name: tiny.name,
      url: tiny.url,
      size: tiny.size,
      sha1: tiny.sha1,
      sha256: digest,
    );

    test('a download must match it as well as the SHA-1', () async {
      final pinned = withSha256(sha256.convert(tinyBytes).toString());
      final installed = await manager.install(pinned);
      expect(installed.matches(pinned), isTrue);
    });

    test('a download with another SHA-256 is rejected', () async {
      await expectLater(
        manager.install(withSha256('0' * 64)),
        throwsA(
          isA<WhisperChecksumException>().having(
            (e) => e.message,
            'message',
            allOf(contains('SHA-256'), contains('0' * 64)),
          ),
        ),
      );
      expect(part(tiny).existsSync(), isFalse);
      expect(await manager.installed(), isEmpty);
    });

    test('an imported file with another SHA-256 is damaged', () async {
      final picked = Directory(p.join(root.path, 'picked'))..createSync();
      final file = File(p.join(picked.path, 'ggml-tiny.bin'))
        ..writeAsBytesSync(tinyBytes);
      final model = withSha256('0' * 64);
      final result = await manager.importFiles([
        file,
      ], catalog: WhisperModelCatalog(models: [model]));
      expect(result.models.single.status, WhisperImportStatus.checksumMismatch);
      expect(await manager.installed(), isEmpty);
    });
  });

  group('installed', () {
    test('is empty without a models directory', () async {
      expect(await manager.installed(), isEmpty);
      expect(await manager.installedModel('tiny'), isNull);
      expect(await manager.isInstalled(tiny), isFalse);
    });

    test('ignores incomplete or foreign installs', () async {
      await manager.install(tiny);
      await manager.install(base);
      final models = Directory(p.join(root.path, 'models'));
      // A truncated file.
      File(p.join(models.path, 'base', 'ggml-base.bin'))
          .writeAsBytesSync([1, 2, 3]);
      // A folder without a manifest, one with a bad manifest and one whose
      // manifest names another id.
      Directory(p.join(models.path, 'small')).createSync();
      Directory(p.join(models.path, 'bad')).createSync();
      File(p.join(models.path, 'bad', 'manifest.json')).writeAsStringSync('[');
      Directory(p.join(models.path, 'other')).createSync();
      File(p.join(models.path, 'other', 'manifest.json')).writeAsStringSync(
        jsonEncode({
          'schemaVersion': 1,
          'id': 'tiny',
          'name': 'ggml-tiny.bin',
          'size': 1,
          'sha1': 'a' * 40,
        }),
      );
      File(p.join(models.path, 'stray.txt')).writeAsStringSync('x');

      final fresh = WhisperModelManager(root: root, httpClient: server.client);
      expect((await fresh.installed()).map((m) => m.id), ['tiny']);
    });
  });

  group('delete and cleanUp', () {
    test('delete removes the model and its partial download', () async {
      await manager.install(tiny);
      server.failAfter = 10;
      await expectLater(manager.install(base), throwsA(anything));
      expect(part(base).existsSync(), isTrue);

      await manager.delete('tiny');
      await manager.delete('base');
      expect(await manager.installed(), isEmpty);
      expect(part(base).existsSync(), isFalse);
      // Deleting what is not there is fine.
      await manager.delete('tiny');
    });

    test('cleanUp removes staging and trash but keeps downloads', () async {
      final models = p.join(root.path, 'models');
      Directory(p.join(models, '.staging', 'tiny-1'))
          .createSync(recursive: true);
      Directory(p.join(models, '.trash', '1')).createSync(recursive: true);
      part(tiny)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync([1]);
      await manager.cleanUp();
      expect(Directory(p.join(models, '.staging')).existsSync(), isFalse);
      expect(Directory(p.join(models, '.trash')).existsSync(), isFalse);
      expect(part(tiny).existsSync(), isTrue);
    });

    test('close leaves an injected client open', () async {
      manager.close();
      expect(await manager.install(tiny), isNotNull);
      WhisperModelManager(root: root).close();
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
      final file = write('GGML-Tiny.BIN', tinyBytes);
      final result = await manager.importFiles([file], catalog: catalog);

      expect(result.models.single.status, WhisperImportStatus.installed);
      expect(result.installed, [tiny]);
      expect(result.unmatched, isEmpty);
      expect(await manager.isInstalled(tiny), isTrue);
      expect(file.existsSync(), isTrue, reason: 'imported files are kept');
      expect(server.requests, isEmpty);
      expect(
        result.models.single.toString(),
        'WhisperImportOutcome(tiny, installed)',
      );
    });

    test('recognises a renamed copy by size and SHA-1', () async {
      final result = await manager.importFiles([
        write('ggml-base (1).bin', baseBytes),
      ], catalog: catalog);
      expect(result.installed, [base]);
    });

    test('reports a damaged file named like a model', () async {
      final damaged = Uint8List.fromList(tinyBytes)..[0] ^= 1;
      final file = write('ggml-tiny.bin', damaged);
      final short = write('ggml-tiny.bin.bak', [1, 2]);
      final result = await manager.importFiles([file, short], catalog: catalog);
      final outcome = result.models.single;
      expect(outcome.status, WhisperImportStatus.checksumMismatch);
      expect(outcome.damaged, [file]);
      expect(result.unmatched, [short]);
      expect(await manager.installed(), isEmpty);
    });

    test('reports a named file of the wrong size as damaged', () async {
      final file = write('ggml-tiny.bin', [1, 2, 3]);
      final result = await manager.importFiles([file], catalog: catalog);
      expect(result.models.single.status, WhisperImportStatus.checksumMismatch);
      expect(result.models.single.damaged, [file]);
    });

    test('a same-size file that is something else is unmatched', () async {
      final other = Uint8List.fromList(tinyBytes)..[10] ^= 1;
      final file = write('recording.bin', other);
      final result = await manager.importFiles([file], catalog: catalog);
      expect(result.unmatched, [file]);
      expect(result.models, isEmpty);
    });

    test('uses the first verified candidate', () async {
      final damaged = Uint8List.fromList(tinyBytes)..[0] ^= 1;
      final result = await manager.importFiles([
        write('ggml-tiny.bin', damaged),
        write('copy.bin', tinyBytes),
      ], catalog: catalog);
      expect(result.models.single.status, WhisperImportStatus.installed);
    });

    test('skips models that are installed already', () async {
      await manager.install(tiny);
      final result = await manager.importFiles([
        write('ggml-tiny.bin', tinyBytes),
      ], catalog: catalog);
      expect(result.models.single.status, WhisperImportStatus.alreadyInstalled);
      expect(result.installed, isEmpty);
    });

    test('lists unreadable and unknown files as unmatched', () async {
      final missing = File(p.join(picked.path, 'gone.bin'));
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
      final download = manager.install(tiny);
      final import = manager.importFiles([
        write('ggml-tiny.bin', tinyBytes),
      ], catalog: catalog);
      server.gate!.complete();
      await download;
      final result = await import;
      expect(result.models.single.status, WhisperImportStatus.alreadyInstalled);
    });

    test('installs the file when a running download fails', () async {
      server
        ..gate = Completer()
        ..status = 500;
      final download = manager.install(tiny);
      final import = manager.importFiles([
        write('ggml-tiny.bin', tinyBytes),
      ], catalog: catalog);
      server.gate!.complete();
      await expectLater(download, throwsA(isA<WhisperDownloadException>()));
      expect((await import).installed, [tiny]);
    });

    test('reports a failed install', () async {
      // A file where the models directory should be: staging fails.
      File(p.join(root.path, 'models')).writeAsStringSync('x');
      final result = await manager.importFiles([
        write('ggml-tiny.bin', tinyBytes),
      ], catalog: catalog);
      final outcome = result.models.single;
      expect(outcome.status, WhisperImportStatus.failed);
      expect(outcome.error, isA<FileSystemException>());
    });
  });
  group('free space', () {
    late List<String> asked;
    late int? free;

    WhisperModelManager spaced() => WhisperModelManager(
      root: root,
      httpClient: server.client,
      freeSpace: (path) async {
        asked.add(path);
        return free;
      },
    );

    setUp(() {
      asked = [];
      free = null;
    });

    test('the margin is 5 %, at least 50 MiB', () {
      expect(WhisperModelManager.requiredSpace(0), 50 << 20);
      const large = 2 << 30;
      expect(WhisperModelManager.requiredSpace(large), large + large ~/ 20);
    });

    test('refuses a download without room, before any request', () async {
      free = 1000;
      await expectLater(
        spaced().install(tiny),
        throwsA(
          isA<WhisperInsufficientSpaceException>()
              .having((e) => e.availableBytes, 'availableBytes', 1000)
              .having(
                (e) => e.requiredBytes,
                'requiredBytes',
                WhisperModelManager.requiredSpace(tinyBytes.length),
              )
              .having(
                (e) => e.toString(),
                'toString',
                startsWith('WhisperInsufficientSpaceException(tiny'),
              ),
        ),
      );
      expect(server.requests, isEmpty);
      expect(asked, [p.join(root.path, 'models')]);
    });

    test('downloads with room, or when it is unknown', () async {
      free = WhisperModelManager.requiredSpace(tinyBytes.length);
      expect((await spaced().install(tiny)).id, 'tiny');
      free = null;
      expect((await spaced().install(base)).id, 'base');
    });

    test('a failing answer counts as unknown', () async {
      final failing = WhisperModelManager(
        root: root,
        httpClient: server.client,
        freeSpace: (_) async => throw const FileSystemException('statfs'),
      );
      expect((await failing.install(tiny)).id, 'tiny');
    });

    test('checkSpace asks before anything else', () async {
      free = 10;
      await expectLater(
        spaced().checkSpace(tiny),
        throwsA(isA<WhisperInsufficientSpaceException>()),
      );
      await manager.checkSpace(tiny);
      expect(server.requests, isEmpty);
    });

    test('a resumed download needs room for the rest only', () async {
      server.failAfter = 3000;
      await expectLater(
        manager.install(tiny),
        throwsA(isA<WhisperDownloadException>()),
      );
      server.failAfter = null;
      free = WhisperModelManager.requiredSpace(tinyBytes.length - 3000);
      expect((await spaced().install(tiny)).id, 'tiny');
    });

    test('an import refuses a copy without room', () async {
      free = 1;
      final file = File(p.join(root.path, tiny.name))
        ..writeAsBytesSync(tinyBytes);
      final result = await spaced().importFiles([file], catalog: catalog);
      expect(result.models.single.status, WhisperImportStatus.failed);
      expect(
        result.models.single.error,
        isA<WhisperInsufficientSpaceException>(),
      );
    });
  });

  group('importSources', () {
    test('copies a picked document into staging and installs it', () async {
      final source = _Source('ggml-tiny.bin', tinyBytes);
      final result = await manager.importSources([source], catalog: catalog);
      expect(result.installed, [tiny]);
      expect(source.maxBytes, tiny.size);
      expect(
        p.isWithin(p.join(root.path, 'models', '.staging'), source.target!),
        isTrue,
      );
    });

    test('matches by size or by name alone', () async {
      final result = await manager.importSources([
        _Source('renamed.bin', baseBytes),
        _Source('ggml-tiny.bin', tinyBytes, known: false),
      ], catalog: catalog);
      expect(result.installed, [tiny, base]);
    });

    test('reports damaged, short, unknown and unreadable sources', () async {
      final damaged = Uint8List.fromList(tinyBytes)..[0] ^= 0xff;
      final result = await manager.importSources([
        _Source('ggml-tiny.bin', damaged),
        _Source('ggml-base.bin', baseBytes.sublist(1), known: false),
        _Source('notes.txt', [1, 2]),
      ], catalog: catalog);
      expect(result.installed, isEmpty);
      expect(result.models.first.damaged.single.path, 'ggml-tiny.bin');
      expect(result.unmatched.single.path, 'notes.txt');

      final failed = await manager.importSources([
        _Source(
          'ggml-tiny.bin',
          tinyBytes,
          error: const FileSystemException('denied'),
        ),
      ], catalog: catalog);
      expect(failed.models.single.status, WhisperImportStatus.failed);
    });

    test('a file that cannot be read is not the model', () async {
      final missing = File(p.join(root.path, 'ggml-tiny.bin'));
      final result = await manager.importFiles([missing], catalog: catalog);
      expect(result.models.single.status, WhisperImportStatus.checksumMismatch);
    });
  });

  test('hashes inline as in the background', () async {
    final inline = WhisperModelManager(
      root: root,
      httpClient: server.client,
      hashing: const FileHashing.inline(),
    );
    expect((await inline.install(tiny)).id, 'tiny');
    server.corrupt = true;
    await expectLater(
      inline.install(base),
      throwsA(isA<WhisperChecksumException>()),
    );
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

/// A picked document for [WhisperModelManager.importSources].
class _Source implements WhisperImportSource {
  new(this.name, this.bytes, {this.known = true, this.error});

  @override
  final String name;

  final List<int> bytes;
  final bool known;
  final Exception? error;
  int? maxBytes;
  String? target;

  @override
  int? get length => known ? bytes.length : null;

  @override
  Future<int> copyTo(File destination, {required int maxBytes}) async {
    if (error case final error?) throw error;
    this.maxBytes = maxBytes;
    target = destination.path;
    final written = bytes.length > maxBytes + 1
        ? bytes.sublist(0, maxBytes + 1)
        : bytes;
    await destination.writeAsBytes(written, flush: true);
    return written.length;
  }
}
