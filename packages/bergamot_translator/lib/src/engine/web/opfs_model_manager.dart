import 'dart:async';
import 'dart:io' show Directory, File, FileSystemException;
import 'dart:typed_data';

import 'package:bergamot_translator/src/catalog.dart';
import 'package:bergamot_translator/src/engine/bergamot_engine.dart';
import 'package:bergamot_translator/src/engine/web/bergamot_worker.dart';
import 'package:bergamot_translator/src/engine/web/worker_engine.dart';
import 'package:bergamot_translator/src/engine/web/worker_values.dart';
import 'package:bergamot_translator/src/model_manager.dart';
import 'package:http/http.dart' as http;

/// The [BergamotModelManager] of the web app: models in the browser's
/// Origin Private File System, which the worker behind [channel]
/// (`web/bergamot/worker.js`) reads, writes and verifies; downloads
/// through the app's [http.Client] (so its network rules and request log
/// apply, as on Android).
///
/// Layout (in the worker's `bergamot/` folder of the origin's storage):
/// * `models/<pair>/<version>/`: an installed model (decompressed files and
///   `manifest.json`, written last: a model without one is not installed
///   and [cleanUp] removes it);
/// * `.downloads/<pair>/<version>/<file>.gz.part`: downloads in progress,
///   resumed with an HTTP `Range` request next time.
///
/// Every download is checked by the worker against the catalog's size and
/// SHA-256 (`crypto.subtle`) before it is decompressed
/// (`DecompressionStream`), and the decompressed file against its own;
/// files come from the catalog's URLs or the [mirror]
/// ([bergamotDownloadUrls]), like on Android. [ModelPaths] of installed
/// models are paths in that folder (e.g.
/// `models/en-de/<version>/model.ende.intgemm.alphas.bin`), which only the
/// worker's engine ([WorkerBergamotEngine]) understands.
///
/// Before each download it asks for persistent storage
/// ([requestPersistence]: `navigator.storage.persist()`), so the browser
/// does not evict the models under storage pressure.
///
/// [importFiles] is not available: a browser has no file paths.
///
/// With [freeSpace] (what the browser's storage quota leaves, e.g. from
/// `navigator.storage.estimate()`; null when it cannot tell), a download
/// that would not fit (the compressed files, the decompressed ones and a
/// margin, see [BergamotModelManager.requiredSpace]) fails at once with a
/// [ModelInsufficientSpaceException].
class OpfsModelManager extends BergamotModelManager {
  new({
    required this.channel,
    required http.Client httpClient,
    this.requestPersistence,
    this.writeChunkSize = 1 << 20,
    this.freeSpace,
    super.requestTimeout,
  }) : _http = httpClient,
       super(root: Directory(rootFolder), httpClient: httpClient);

  /// The bytes the browser still lets this origin store; null when
  /// unknown.
  final Future<int?> Function()? freeSpace;

  /// The worker's folder in the origin's storage.
  static const rootFolder = 'bergamot';

  final BergamotWorkerChannel channel;

  /// Asks the browser to keep the models (true when it will); null for
  /// none.
  final Future<bool> Function()? requestPersistence;

  /// Bytes of a download sent to the worker at a time.
  final int writeChunkSize;

  final http.Client _http;
  final Map<String, Future<InstalledModel>> _installs = {};
  List<InstalledModel>? _cache;
  var _persistent = false;

  @override
  Future<List<InstalledModel>> installed() async =>
      _cache ??= List.unmodifiable(await _list());

  @override
  Future<InstalledModel> install(
    CatalogModel model, {
    void Function(ModelDownloadProgress progress)? onProgress,
  }) {
    final key = '${model.pair}/${model.version}';
    final running = _installs[key];
    if (running != null) return running;
    final started = _install(model, onProgress);
    _installs[key] = started;
    return started.whenComplete(() => _installs.remove(key));
  }

  @override
  Future<ModelImportResult> importFiles(
    Iterable<File> files, {
    required ModelCatalog catalog,
  }) => Future.error(
    UnsupportedError('Importing model files is not available in a browser'),
  );

  @override
  Future<void> delete(String source, String target) async {
    final pair = '$source-$target';
    try {
      await _call('remove', {'path': 'models/$pair'}, pair);
      await _call('remove', {'path': '.downloads/$pair'}, pair);
    } finally {
      _cache = null;
    }
  }

  /// Removes installs that never completed (without a manifest). Partial
  /// downloads are kept for resuming. Never throws.
  @override
  Future<void> cleanUp() async {
    try {
      await channel.request('cleanUp');
    } on Object {
      // A chore: the next start tries again.
    }
  }

  /// Nothing to release: the app owns the HTTP client and the worker.
  @override
  void close() {}

  Future<List<InstalledModel>> _list() async {
    final listed = await _call('list', const {}, '');
    final byPair = <String, InstalledModel>{};
    for (final entry in listed.asList) {
      final model = _installedOf(entry.asMap);
      if (model != null) byPair.putIfAbsent(model.pair, () => model);
    }
    return [for (final pair in byPair.keys.toList()..sort()) byPair[pair]!];
  }

  /// The [InstalledModel] of one `list` entry (`{directory, manifest,
  /// sizeBytes}`), or null when its manifest is not one this manager wrote.
  static InstalledModel? _installedOf(Map<String, Object?> entry) {
    final directory = entry['directory'].asString();
    final manifest = entry['manifest'].asMap;
    final source = manifest['source'].asString();
    final target = manifest['target'].asString();
    final version = manifest['version'].asString();
    if (source.isEmpty ||
        target.isEmpty ||
        version.isEmpty ||
        directory != 'models/$source-$target/$version') {
      return null;
    }
    final files = <ModelFileKind, String>{};
    for (final MapEntry(:key, :value) in manifest['files'].asMap.entries) {
      final kind = ModelFileKind.fromKey(key);
      final name = value.asMap['name'].asString();
      if (kind == null || name.isEmpty || name.contains('/')) return null;
      files[kind] = '$directory/$name';
    }
    final complete =
        files.containsKey(ModelFileKind.model) &&
        files.containsKey(ModelFileKind.lexicalShortlist) &&
        (files.containsKey(ModelFileKind.vocab) ||
            files.containsKey(ModelFileKind.srcVocab));
    if (!complete) return null;
    return InstalledModel(
      source: source,
      target: target,
      version: version,
      directory: directory,
      files: files,
      sizeBytes: entry['sizeBytes'].asInt(),
    );
  }

  /// Throws a [ModelInsufficientSpaceException] when the storage quota
  /// left ([freeSpace]) is below what [model] needs: its downloads (a
  /// partial one counts whole) and its decompressed files, plus a margin.
  Future<void> _checkQuota(CatalogModel model) async {
    final query = freeSpace;
    if (query == null) return;
    int? available;
    try {
      available = await query();
    } on Object {
      // Not known: the browser refuses a write that does not fit.
    }
    final needed = BergamotModelManager.requiredSpace(
      model.downloadSize + model.installedSize,
    );
    if (available == null || available >= needed) return;
    throw ModelInsufficientSpaceException(
      model.pair,
      '${model.pair}: needs $needed bytes of storage, $available left',
      requiredBytes: needed,
      availableBytes: available,
    );
  }

  Future<InstalledModel> _install(
    CatalogModel model,
    void Function(ModelDownloadProgress progress)? onProgress,
  ) async {
    final current = await installedModel(model.source, model.target);
    if (current != null && current.version == model.version) return current;
    await _checkQuota(model);
    await _askToPersist();

    // Every file of the model comes from the source chosen at the start.
    final mirror = this.mirror;
    final fallbackToDefault = this.fallbackToDefault;
    final directory = 'models/${model.pair}/${model.version}';
    final downloads = '.downloads/${model.pair}/${model.version}';
    final received = <ModelFileKind, int>{};
    void report(ModelFileKind kind, int bytes) {
      received[kind] = bytes;
      onProgress?.call(
        ModelDownloadProgress(
          model: model,
          receivedBytes: received.values.fold(0, (sum, value) => sum + value),
          totalBytes: model.downloadSize,
        ),
      );
    }

    try {
      for (final file in model.files.values) {
        final part = '$downloads/${file.name}.gz.part';
        final source = await _download(
          model,
          file,
          part,
          report,
          mirror: mirror,
          fallbackToDefault: fallbackToDefault,
        );
        await _call(
          'install',
          {
            'part': part,
            'target': '$directory/${file.name}',
            'size': file.size,
            'sha256': file.sha256,
            'uncompressedSize': file.uncompressedSize,
            'uncompressedSha256': file.uncompressedSha256,
          },
          model.pair,
          mirror: source,
        );
      }
      await _call('commit', {
        'directory': directory,
        'downloads': downloads,
        'manifest': {
          'schema': 1,
          'source': model.source,
          'target': model.target,
          'version': model.version,
          'files': {
            for (final file in model.files.values)
              file.kind.key: {'name': file.name, 'size': file.uncompressedSize},
          },
        },
      }, model.pair);
    } finally {
      _cache = null;
    }
    final installed = await installedModel(model.source, model.target);
    if (installed == null || installed.version != model.version) {
      throw FileSystemException(
        'The browser did not keep ${model.pair} (storage cleared?)',
        directory,
      );
    }
    return installed;
  }

  Future<void> _askToPersist() async {
    final request = requestPersistence;
    if (_persistent || request == null) return;
    try {
      _persistent = await request();
    } on Object {
      // Best effort: the models still work while the browser keeps them.
    }
  }

  /// Downloads [file] into [part] (resuming a partial download) from the
  /// [mirror] or the catalog's URL; returns the mirror the bytes came from
  /// (null: the catalog's URL). The worker verifies it afterwards
  /// (`install`).
  Future<Uri?> _download(
    CatalogModel model,
    CatalogFile file,
    String part,
    void Function(ModelFileKind kind, int bytes) report, {
    required Uri? mirror,
    required bool fallbackToDefault,
  }) async {
    Future<int> open({required bool restart}) async => (await _call(
      'downloadOpen',
      {'path': part, 'restart': restart},
      model.pair,
    )).asMap['size'].asInt();

    var offset = await open(restart: false);
    if (offset > file.size) offset = await open(restart: true);
    report(file.kind, offset);
    if (offset == file.size) {
      // Complete already (the checksum decides whether it is right).
      await _call('downloadClose', {'path': part}, model.pair);
      return null;
    }

    final (http.StreamedResponse, Uri?) answer;
    try {
      answer = await _request(
        model,
        file,
        offset,
        mirror: mirror,
        fallbackToDefault: fallbackToDefault,
      );
    } on Object {
      await _closeQuietly(part);
      rethrow;
    }
    final (response, source) = answer;
    if (offset > 0 && response.statusCode != 206) {
      // The server sent the whole file: start over.
      offset = await open(restart: true);
    }

    final pending = BytesBuilder(copy: false);
    Future<void> flush() async {
      if (pending.isEmpty) return;
      final bytes = pending.takeBytes();
      await _call(
        'downloadWrite',
        {'path': part, 'at': offset, 'bytes': bytes},
        model.pair,
        mirror: source,
      );
      offset += bytes.length;
    }

    try {
      await for (final chunk in response.stream.timeout(requestTimeout)) {
        if (offset + pending.length + chunk.length > file.size) {
          await _call('remove', {'path': part}, model.pair);
          throw ModelChecksumException(
            model.pair,
            '${file.name}${_from(source)}: more than ${file.size} bytes',
            mirror: source,
          );
        }
        pending.add(chunk);
        if (pending.length >= writeChunkSize) await flush();
        report(file.kind, offset + pending.length);
      }
      await flush();
    } on ModelInstallException {
      await _closeQuietly(part);
      rethrow;
    } on Object catch (error) {
      if (error is FileSystemException ||
          error is UnsupportedError ||
          error is BergamotEngineException) {
        await _closeQuietly(part);
        rethrow;
      }
      // Interrupted: keep what arrived for resuming.
      try {
        await flush();
      } on Object {
        // Resumes from what the worker has.
      }
      await _closeQuietly(part);
      throw ModelDownloadException(
        model.pair,
        '${file.name}${_from(source)}: $error',
        mirror: source,
      );
    }
    await _call('downloadClose', {'path': part}, model.pair, mirror: source);
    return source;
  }

  /// Sends the request for [file] (from byte [existing] on) to each URL of
  /// [bergamotDownloadUrls] in turn until one answers with its contents
  /// (200, or 206 when resuming): the response and the mirror it came from
  /// (null: the catalog's URL). Throws the last URL's
  /// [ModelDownloadException].
  Future<(http.StreamedResponse, Uri?)> _request(
    CatalogModel model,
    CatalogFile file,
    int existing, {
    required Uri? mirror,
    required bool fallbackToDefault,
  }) async {
    final urls = bergamotDownloadUrls(
      model,
      file,
      mirror: mirror,
      fallbackToDefault: fallbackToDefault,
    );
    for (var i = 0; ; i++) {
      final url = urls[i];
      final source = i == 0 ? mirror : null;
      final last = i == urls.length - 1;
      final request = http.Request('GET', url);
      if (existing > 0) request.headers['Range'] = 'bytes=$existing-';
      final http.StreamedResponse response;
      try {
        response = await _http.send(request).timeout(requestTimeout);
      } on Object catch (error) {
        if (!last) continue;
        throw ModelDownloadException(
          model.pair,
          '${file.name}${_from(source)}: $error',
          mirror: source,
        );
      }
      final status = response.statusCode;
      if (status == 200 || (existing > 0 && status == 206)) {
        return (response, source);
      }
      await response.stream.drain<void>().catchError((_) {});
      if (last) {
        throw ModelDownloadException(
          model.pair,
          'HTTP $status for $url',
          statusCode: status,
          mirror: source,
        );
      }
    }
  }

  Future<void> _closeQuietly(String part) async {
    try {
      await channel.request('downloadClose', {'path': part});
    } on Object {
      // The worker closes it with the next open.
    }
  }

  /// [op] on the worker; its errors as the exceptions the app classifies
  /// (`OfflineModelError.of`): a checksum mismatch, storage, the engine.
  Future<Object?> _call(
    String op,
    Map<String, Object?> arguments,
    String pair, {
    Uri? mirror,
  }) async {
    try {
      return await channel.request(op, arguments);
    } on BergamotWorkerException catch (error) {
      switch (error.kind) {
        case BergamotWorkerErrorKind.checksum:
          throw ModelChecksumException(pair, error.message, mirror: mirror);
        case BergamotWorkerErrorKind.storage || BergamotWorkerErrorKind.missing:
          throw FileSystemException(error.message);
        case BergamotWorkerErrorKind.unsupported:
          throw UnsupportedError(error.message);
        case BergamotWorkerErrorKind.engine || BergamotWorkerErrorKind.protocol:
          throw error.toEngineException();
      }
    }
  }

  /// ` from the mirror <mirror>` for a download from [mirror], else empty.
  static String _from(Uri? mirror) =>
      mirror == null ? '' : ' from the mirror $mirror';
}
