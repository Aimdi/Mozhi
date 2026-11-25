import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, FileSystemException;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:llama_engine/src/catalog.dart';
import 'package:llama_engine/src/engine/web/llama_worker.dart';
import 'package:llama_engine/src/model_manager.dart';
import 'package:llama_engine/src/model_source.dart';
import 'package:meta/meta.dart';

/// Capabilities reported by `web/llama/worker.js`'s `probe` operation.
@immutable
final class LlamaWebSupport {
  const new({
    required this.supported,
    this.wasm = false,
    this.opfs = false,
    this.syncAccess = false,
    this.digest = false,
    this.engineAvailable = false,
    this.abiVersion = 0,
  });

  factory fromWorker(Object? raw) {
    if (raw is! Map) return const LlamaWebSupport(supported: false);
    return LlamaWebSupport(
      supported: raw['supported'] == true,
      wasm: raw['wasm'] == true,
      opfs: raw['opfs'] == true,
      syncAccess: raw['syncAccess'] == true,
      digest: raw['digest'] == true,
      engineAvailable: raw['engineAvailable'] == true,
      abiVersion: (raw['abiVersion'] as num?)?.toInt() ?? 0,
    );
  }

  /// Whether WASM, OPFS, and the `llama-engine.wasm` binary are all available.
  final bool supported;
  final bool wasm;
  final bool opfs;
  final bool syncAccess;
  final bool digest;
  final bool engineAvailable;
  final int abiVersion;

  @override
  bool operator ==(Object other) =>
      other is LlamaWebSupport &&
      other.supported == supported &&
      other.wasm == wasm &&
      other.opfs == opfs &&
      other.syncAccess == syncAccess &&
      other.digest == digest &&
      other.engineAvailable == engineAvailable &&
      other.abiVersion == abiVersion;

  @override
  int get hashCode => Object.hash(
    supported,
    wasm,
    opfs,
    syncAccess,
    digest,
    engineAvailable,
    abiVersion,
  );

  @override
  String toString() =>
      'LlamaWebSupport(supported: $supported, wasm: $wasm, opfs: $opfs, '
      'engineAvailable: $engineAvailable)';
}

/// Probes [channel] (`web/llama/worker.js`) for browser and WASM runtime
/// capabilities. Never throws; returns unsupported on error.
Future<LlamaWebSupport> probeLlamaWorker(
  LlamaWorkerChannel channel, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  try {
    final raw = await channel.request('probe').timeout(timeout);
    return LlamaWebSupport.fromWorker(raw);
  } on Object {
    return const LlamaWebSupport(supported: false);
  }
}

/// Result of probing `<host>/models/llm/index.json` on a web deployment.
@immutable
final class LlamaHostMirrorProbe {
  const new({required this.available, this.modelIds = const []});

  /// Whether the host serves a valid `models/llm/index.json` listing at least
  /// one model.
  final bool available;

  /// Model ids listed in the mirror's `items` array.
  final List<String> modelIds;

  @override
  bool operator ==(Object other) =>
      other is LlamaHostMirrorProbe &&
      other.available == available &&
      _sameStrings(other.modelIds, modelIds);

  @override
  int get hashCode => Object.hash(available, Object.hashAll(modelIds));

  static bool _sameStrings(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Probes `<baseUrl>/models/llm/index.json` (or `<baseUrl>/llm/index.json` if
/// [baseUrl] already ends in `/models/`) to see whether the web host mirrors
/// on-device LLM files. Never throws.
Future<LlamaHostMirrorProbe> probeLlamaHostMirror(
  http.Client client,
  Uri baseUrl, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final normalized = baseUrl.path.endsWith('/')
      ? baseUrl
      : baseUrl.replace(path: '${baseUrl.path}/');
  final indexPath = normalized.path.endsWith('/models/')
      ? '$llamaMirrorFolder/index.json'
      : 'models/$llamaMirrorFolder/index.json';
  final url = normalized.resolve(indexPath);
  try {
    final response = await client.get(url).timeout(timeout);
    if (response.statusCode != 200) {
      return const LlamaHostMirrorProbe(available: false);
    }
    final decoded = jsonDecode(
      utf8.decode(response.bodyBytes, allowMalformed: true),
    );
    if (decoded is! Map<String, Object?>) {
      return const LlamaHostMirrorProbe(available: false);
    }
    final items = decoded['items'];
    if (items is! List<Object?> || items.isEmpty) {
      return const LlamaHostMirrorProbe(available: false);
    }
    final ids = [
      for (final item in items)
        if (item is String && item.isNotEmpty) item,
    ];
    return LlamaHostMirrorProbe(
      available: ids.isNotEmpty,
      modelIds: List.unmodifiable(ids),
    );
  } on Object {
    return const LlamaHostMirrorProbe(available: false);
  }
}

/// [LlamaModelManager] for web builds: stores, SHA-256 verifies, lists, and
/// deletes GGUF models (and optional `mmproj` vision projectors) in the
/// browser's Origin Private File System (OPFS) via `web/llama/worker.js`
/// ([channel]), while downloading bytes through the app's [http.Client].
///
/// Pure Dart (no `dart:js_interop`), so it can be unit-tested on any platform
/// against a fake [LlamaWorkerChannel] and `MockClient`.
class WebLlamaModelManager extends LlamaModelManager {
  new({
    required this.channel,
    required http.Client httpClient,
    this.requestPersistence,
    this.writeChunkSize = 1 << 20,
    this.freeSpace,
    super.requestTimeout,
  }) : _http = httpClient,
       super(root: Directory(rootFolder), httpClient: httpClient);

  /// The worker's root folder in OPFS.
  static const rootFolder = 'llama';

  final LlamaWorkerChannel channel;
  final Future<bool> Function()? requestPersistence;
  final int writeChunkSize;
  final Future<int?> Function()? freeSpace;

  final http.Client _http;
  final Map<String, Future<InstalledLlamaModel>> _installing = {};
  final Map<String, Completer<void>> _cancels = {};
  List<InstalledLlamaModel>? _cache;
  bool _persistent = false;
  Future<void>? _persisting;

  @override
  Future<List<InstalledLlamaModel>> installed() async =>
      _cache ??= List.unmodifiable(await _list());

  @override
  bool isInstalling(String id) => _installing.containsKey(id);

  @override
  void cancel(String id) {
    final signal = _cancels[id];
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  @override
  Future<int> partialBytes(LlamaCatalogModel model) async {
    _checkSafeId(model.id);
    final paths = [
      '.downloads/${model.id}/${model.name}.part',
      if (model.mmproj case final mmproj?)
        '.downloads/${model.id}/${mmproj.name}.part',
    ];
    try {
      final result = await channel.request('partialSize', {'paths': paths});
      if (result is num) return result.toInt();
      if (result is Map && result['size'] is num) {
        return (result['size']! as num).toInt();
      }
      return 0;
    } on Object {
      return 0;
    }
  }

  @override
  Future<void> checkSpace(LlamaCatalogModel model) async {
    _checkSafeId(model.id);
    final existing = (await partialBytes(model)).clamp(0, model.totalSize);
    await _checkQuota(model, model.totalSize - existing);
  }

  @override
  Future<InstalledLlamaModel> install(
    LlamaCatalogModel model, {
    void Function(LlamaDownloadProgress progress)? onProgress,
  }) {
    final key = model.id;
    return _installing[key] ??= _install(model, onProgress).whenComplete(() {
      unawaited(_installing.remove(key));
    });
  }

  @override
  Future<LlamaImportResult> importFiles(
    Iterable<File> files, {
    required LlamaModelCatalog catalog,
    bool move = false,
  }) => Future.error(
    UnsupportedError('Importing model files is not available in a browser'),
  );

  @override
  Future<LlamaImportResult> importSources(
    Iterable<LlamaImportSource> sources, {
    required LlamaModelCatalog catalog,
  }) => Future.error(
    UnsupportedError('Importing model files is not available in a browser'),
  );

  @override
  Future<void> delete(String id) async {
    _checkSafeId(id);
    _cache = null;
    try {
      await channel.request('remove', {'path': 'models/$id'});
      await channel.request('remove', {'path': '.downloads/$id'});
    } finally {
      _cache = null;
    }
  }

  @override
  Future<void> deleteAll() async {
    [..._installing.keys].forEach(cancel);
    for (final running in [..._installing.values]) {
      try {
        await running;
      } on Object {
        // Cancelled or failed: deleted below either way.
      }
    }
    _cache = null;
    await channel.request('remove', {'path': 'models'});
    await channel.request('remove', {'path': '.downloads'});
  }

  @override
  Future<void> cleanUp() async {
    try {
      await channel.request('cleanUp');
    } on Object {
      // Best effort.
    }
  }

  /// Probes [baseUrl] for `models/llm/index.json` using this manager's HTTP
  /// client.
  Future<LlamaHostMirrorProbe> probeHostMirror(Uri baseUrl) =>
      probeLlamaHostMirror(_http, baseUrl, timeout: requestTimeout);

  @override
  void close() {}

  Future<List<InstalledLlamaModel>> _list() async {
    final raw = await _call('list', const {}, '');
    final models = <InstalledLlamaModel>[];
    if (raw is List) {
      for (final item in raw) {
        final model = _parseInstalled(item);
        if (model != null) models.add(model);
      }
    }
    models.sort((a, b) => a.id.compareTo(b.id));
    return models;
  }

  static InstalledLlamaModel? _parseInstalled(Object? raw) {
    if (raw is! Map) return null;
    final directory = raw['directory'];
    final manifest = raw['manifest'];
    if (directory is! String || manifest is! Map) return null;
    final id = manifest['id'];
    final name = manifest['name'];
    final size = manifest['size'];
    final sha256 = manifest['sha256'];
    if (id is! String ||
        name is! String ||
        size is! num ||
        sha256 is! String ||
        directory != 'models/$id') {
      return null;
    }
    String? projectorPath;
    int? projectorSize;
    String? projectorSha256;
    if (manifest['mmproj'] case final Map<Object?, Object?> proj) {
      final projName = proj['name'];
      final projSize = proj['size'];
      final projSha = proj['sha256'];
      if (projName is String && projSize is num && projSha is String) {
        projectorPath = '$directory/$projName';
        projectorSize = projSize.toInt();
        projectorSha256 = projSha;
      }
    }
    return InstalledLlamaModel(
      id: id,
      path: '$directory/$name',
      sizeBytes: size.toInt(),
      sha256: sha256,
      projectorPath: projectorPath,
      projectorSizeBytes: projectorSize,
      projectorSha256: projectorSha256,
    );
  }

  Future<InstalledLlamaModel> _install(
    LlamaCatalogModel model,
    void Function(LlamaDownloadProgress progress)? onProgress,
  ) async {
    _checkSafeId(model.id);
    final current = await installedModel(model.id);
    if (current != null && current.matches(model)) return current;

    await checkSpace(model);
    _askToPersist();

    final cancelled = _cancels[model.id] = Completer<void>();
    final activeMirror = mirror;
    final activeFallback = fallbackToDefault;
    final totalBytes = model.totalSize;
    void report(int bytes) => onProgress?.call(
      LlamaDownloadProgress(
        model: model,
        receivedBytes: bytes,
        totalBytes: totalBytes,
      ),
    );

    final directory = 'models/${model.id}';
    final downloads = '.downloads/${model.id}';
    try {
      await _downloadAndVerify(
        modelId: model.id,
        fileName: model.name,
        expectedSize: model.size,
        expectedSha256: model.sha256,
        urls: llamaDownloadUrls(
          model,
          mirror: activeMirror,
          fallbackToDefault: activeFallback,
        ),
        part: '$downloads/${model.name}.part',
        target: '$directory/${model.name}',
        mirror: activeMirror,
        cancelled: cancelled.future,
        report: report,
      );
      if (model.mmproj case final mmproj?) {
        await _downloadAndVerify(
          modelId: model.id,
          fileName: mmproj.name,
          expectedSize: mmproj.size,
          expectedSha256: mmproj.sha256,
          urls: llamaProjectorDownloadUrls(
            mmproj,
            mirror: activeMirror,
            fallbackToDefault: activeFallback,
          ),
          part: '$downloads/${mmproj.name}.part',
          target: '$directory/${mmproj.name}',
          mirror: activeMirror,
          cancelled: cancelled.future,
          report: (projBytes) => report(model.size + projBytes),
        );
      }
      _checkCancelled(cancelled, model.id, model.name);
      await _call('commit', {
        'directory': directory,
        'downloads': downloads,
        'manifest': {
          'schemaVersion': 1,
          'id': model.id,
          'name': model.name,
          'size': model.size,
          'sha256': model.sha256,
          if (model.mmproj case final mmproj?)
            'mmproj': {
              'name': mmproj.name,
              'size': mmproj.size,
              'sha256': mmproj.sha256,
            },
        },
      }, model.id);
      _cache = null;
      final installed = await installedModel(model.id);
      if (installed == null || !installed.matches(model)) {
        throw FileSystemException(
          'The browser did not keep ${model.id} (storage cleared?)',
          directory,
        );
      }
      return installed;
    } finally {
      _cache = null;
      if (identical(_cancels[model.id], cancelled)) _cancels.remove(model.id);
    }
  }

  Future<void> _downloadAndVerify({
    required String modelId,
    required String fileName,
    required int expectedSize,
    required String expectedSha256,
    required List<Uri> urls,
    required String part,
    required String target,
    required Uri? mirror,
    required Future<void> cancelled,
    required void Function(int bytes) report,
  }) async {
    Future<int> open({required bool restart}) async {
      final res = await _call('downloadOpen', {
        'path': part,
        'restart': restart,
      }, modelId);
      if (res is Map && res['size'] is num) {
        return (res['size']! as num).toInt();
      }
      return 0;
    }

    for (var restarted = false; ; restarted = true) {
      var offset = await open(restart: false);
      if (offset > expectedSize) offset = await open(restart: true);
      report(offset);

      Uri? usedMirror;
      var resumed = false;
      if (offset < expectedSize) {
        final (response, source, didResume) = await _request(
          modelId: modelId,
          fileName: fileName,
          expectedSize: expectedSize,
          urls: urls,
          existing: offset,
          mirror: mirror,
          cancelled: cancelled,
        );
        usedMirror = source;
        resumed = didResume;
        if (offset > 0 && !resumed) {
          offset = await open(restart: true);
          report(0);
        }

        final pending = BytesBuilder(copy: false);
        Future<void> flush() async {
          if (pending.isEmpty) return;
          final bytes = pending.takeBytes();
          await _call(
            'downloadWrite',
            {'path': part, 'at': offset, 'bytes': bytes},
            modelId,
            mirror: usedMirror,
          );
          offset += bytes.length;
        }

        try {
          await for (final chunk in _untilCancelled(
            response.stream.timeout(requestTimeout),
            cancelled,
          )) {
            if (offset + pending.length + chunk.length > expectedSize) {
              await _closeQuietly(part);
              await _removeQuietly(part);
              throw LlamaChecksumException(
                modelId,
                '$fileName: more than $expectedSize bytes',
                mirror: usedMirror,
              );
            }
            pending.add(chunk);
            if (pending.length >= writeChunkSize) await flush();
            report(offset + pending.length);
          }
          await flush();
        } on LlamaModelInstallException {
          await _closeQuietly(part);
          rethrow;
        } on _WebCancelled {
          try {
            await flush();
          } on Object {
            // Keep what already reached the worker.
          }
          await _closeQuietly(part);
          throw LlamaDownloadCancelledException(
            modelId,
            '$fileName: cancelled',
            mirror: usedMirror,
          );
        } on Object catch (error) {
          try {
            await flush();
          } on Object {
            // Keep what already reached the worker.
          }
          await _closeQuietly(part);
          throw LlamaDownloadException(
            modelId,
            '$fileName: $error',
            mirror: usedMirror,
          );
        }
        await _call(
          'downloadClose',
          {'path': part},
          modelId,
          mirror: usedMirror,
        );
      } else {
        resumed = true;
        await _closeQuietly(part);
      }

      try {
        await _call(
          'install',
          {
            'part': part,
            'target': target,
            'size': expectedSize,
            'sha256': expectedSha256,
          },
          modelId,
          mirror: usedMirror,
        );
        return;
      } on LlamaChecksumException {
        if (!resumed || restarted) rethrow;
        report(0);
      }
    }
  }

  Future<(http.StreamedResponse, Uri?, bool)> _request({
    required String modelId,
    required String fileName,
    required int expectedSize,
    required List<Uri> urls,
    required int existing,
    required Uri? mirror,
    required Future<void> cancelled,
  }) async {
    var resumeFromStart = false;
    for (var i = 0; ; i++) {
      final url = urls[i];
      final source = i == 0 ? mirror : null;
      final last = i == urls.length - 1;
      final offset = resumeFromStart ? 0 : existing;
      resumeFromStart = false;
      final request = http.Request('GET', url);
      if (offset > 0) request.headers['Range'] = 'bytes=$offset-';
      final http.StreamedResponse response;
      final sent = _http.send(request).timeout(requestTimeout);
      final stopped = cancelled.then<http.StreamedResponse?>((_) => null);
      try {
        final answer = await Future.any<http.StreamedResponse?>([
          sent,
          stopped,
        ]);
        if (answer == null) {
          unawaited(
            sent.then(
              (r) => r.stream.listen(null).cancel(),
              onError: (Object _) {},
            ),
          );
          throw LlamaDownloadCancelledException(
            modelId,
            '$fileName: cancelled',
            mirror: source,
          );
        }
        response = answer;
      } on LlamaDownloadCancelledException {
        rethrow;
      } on Object catch (error) {
        if (!last) continue;
        throw LlamaDownloadException(
          modelId,
          '$fileName: $error',
          mirror: source,
        );
      }
      final status = response.statusCode;
      if (status == 200) return (response, source, false);
      final partial = status == 206 && offset > 0;
      if (partial && _rangeStart(response, expectedSize) == offset) {
        return (response, source, true);
      }
      await response.stream.drain<void>().catchError((_) {});
      if (partial) {
        resumeFromStart = true;
        i--;
        continue;
      }
      if (last) {
        throw LlamaDownloadException(
          modelId,
          'HTTP $status for $url',
          statusCode: status,
          mirror: source,
        );
      }
    }
  }

  static int? _rangeStart(http.StreamedResponse response, int expectedSize) {
    final header = response.headers.entries
        .where((entry) => entry.key.toLowerCase() == 'content-range')
        .firstOrNull
        ?.value;
    if (header == null) return null;
    final match = RegExp(r'^\s*bytes\s+(\d+)-(\d+)/(\d+|\*)\s*$')
        .firstMatch(header);
    if (match == null) return null;
    final first = int.parse(match[1]!);
    final lastByte = int.parse(match[2]!);
    final total = int.tryParse(match[3]!);
    if (lastByte < first || (total != null && total != expectedSize)) {
      return null;
    }
    return first;
  }

  Future<Object?> _call(
    String op,
    Map<String, Object?> args,
    String modelId, {
    Uri? mirror,
  }) async {
    try {
      return await channel.request(op, args);
    } on LlamaWorkerException catch (error) {
      switch (error.kind) {
        case LlamaWorkerErrorKind.checksum:
          throw LlamaChecksumException(modelId, error.message, mirror: mirror);
        case LlamaWorkerErrorKind.unsupported:
          throw UnsupportedError(error.message);
        case LlamaWorkerErrorKind.storage || LlamaWorkerErrorKind.missing:
          throw FileSystemException(error.message);
        case _:
          throw LlamaDownloadException(modelId, error.message, mirror: mirror);
      }
    }
  }

  Future<void> _checkQuota(LlamaCatalogModel model, int bytes) async {
    final query = freeSpace;
    if (query == null || bytes <= 0) return;
    int? available;
    try {
      available = await query();
    } on Object {
      // Unknown quota: browser refuses write if full.
    }
    final needed = LlamaModelManager.requiredSpace(bytes);
    if (available == null || available >= needed) return;
    throw LlamaInsufficientSpaceException(
      model.id,
      '${model.name}: needs $needed bytes of storage, $available left',
      requiredBytes: needed,
      availableBytes: available,
    );
  }

  void _askToPersist() {
    final request = requestPersistence;
    if (_persistent || request == null || _persisting != null) return;
    _persisting = Future<bool>.sync(request)
        .then<void>((granted) => _persistent = granted, onError: (Object _) {})
        .whenComplete(() => _persisting = null);
  }

  Future<void> _closeQuietly(String path) async {
    try {
      await channel.request('downloadClose', {'path': path});
    } on Object {
      // Already closed.
    }
  }

  Future<void> _removeQuietly(String path) async {
    try {
      await channel.request('remove', {'path': path});
    } on Object {
      // Best effort.
    }
  }

  static void _checkCancelled(
    Completer<void> signal,
    String modelId,
    String name,
  ) {
    if (signal.isCompleted) {
      throw LlamaDownloadCancelledException(modelId, '$name: cancelled');
    }
  }

  static void _checkSafeId(String id) {
    if (!LlamaCatalogModel.isSafeId(id)) {
      throw ArgumentError.value(id, 'id', 'Invalid model id');
    }
  }

  static Stream<List<int>> _untilCancelled(
    Stream<List<int>> source,
    Future<void> cancelled,
  ) {
    late final StreamController<List<int>> controller;
    StreamSubscription<List<int>>? subscription;
    controller = StreamController<List<int>>(
      onListen: () {
        subscription = source.listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
        unawaited(
          cancelled.then((_) {
            if (controller.isClosed) return;
            final running = subscription;
            subscription = null;
            if (running != null) unawaited(running.cancel());
            controller.addError(const _WebCancelled());
            unawaited(controller.close());
          }),
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () => subscription?.cancel(),
    );
    return controller.stream;
  }
}

final class _WebCancelled implements Exception {
  const new();
}
