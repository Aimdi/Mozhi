import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bergamot_translator/src/catalog.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// A download or install of a model failed.
sealed class ModelInstallException implements Exception {
  const new(this.model, this.message);

  /// The model pair, e.g. `en-de`.
  final String model;
  final String message;

  String get _name;

  @override
  String toString() => '$_name($model: $message)';
}

/// A file did not match the catalog's size or SHA-256 (corrupt or tampered
/// download). Nothing was installed.
final class ModelChecksumException extends ModelInstallException {
  const new(super.model, super.message);

  @override
  String get _name => 'ModelChecksumException';
}

/// The server answered with an error or the connection failed.
final class ModelDownloadException extends ModelInstallException {
  const new(super.model, super.message, {this.statusCode});

  final int? statusCode;

  @override
  String get _name => 'ModelDownloadException';
}

/// Progress of [BergamotModelManager.install].
@immutable
final class ModelDownloadProgress {
  const new({
    required this.model,
    required this.receivedBytes,
    required this.totalBytes,
  });

  final CatalogModel model;

  /// Bytes received so far over all files of [model] (resumed bytes count).
  final int receivedBytes;

  /// [CatalogModel.downloadSize].
  final int totalBytes;

  double get fraction => totalBytes == 0 ? 1 : receivedBytes / totalBytes;
}

/// Paths of an installed model, in the form the native engine takes them.
/// Plain strings, so it can be sent to the translation isolate.
@immutable
final class ModelPaths {
  const new({
    required this.key,
    required this.model,
    required this.shortlist,
    required this.sourceVocab,
    this.targetVocab,
  });

  /// Unique per installed model (`<pair>/<version>`).
  final String key;
  final String model;
  final String shortlist;
  final String sourceVocab;

  /// Null when the vocabulary is shared.
  final String? targetVocab;

  @override
  bool operator ==(Object other) => other is ModelPaths && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => 'ModelPaths($key)';
}

/// A model installed under `<root>/models/<pair>/<version>/`.
@immutable
final class InstalledModel {
  const new({
    required this.source,
    required this.target,
    required this.version,
    required this.directory,
    required this.files,
    required this.sizeBytes,
  });

  final String source;
  final String target;
  final String version;
  final String directory;

  /// Absolute paths of the uncompressed files.
  final Map<ModelFileKind, String> files;

  /// Bytes on disk.
  final int sizeBytes;

  String get pair => '$source-$target';

  ModelPaths get paths => ModelPaths(
    key: '$pair/$version',
    model: files[ModelFileKind.model]!,
    shortlist: files[ModelFileKind.lexicalShortlist]!,
    sourceVocab: files[ModelFileKind.vocab] ?? files[ModelFileKind.srcVocab]!,
    targetVocab: files[ModelFileKind.trgVocab],
  );

  @override
  String toString() => 'InstalledModel($pair, $version)';
}

/// The name of a [CatalogFile] as published, for downloading it by hand
/// (see [BergamotModelManager.importFiles]).
extension CatalogFileDownload on CatalogFile {
  /// The last segment of [CatalogFile.url]: the gzip-compressed file, e.g.
  /// `vocab.ende.spm.gz`.
  String get downloadName => url.pathSegments.last;
}

/// What [BergamotModelManager.importFiles] did with one catalog model.
enum ModelImportStatus {
  /// Every file was there and verified: the model is installed now.
  installed,

  /// This version was installed already (its files were not read again).
  alreadyInstalled,

  /// Some files of the model were not among the imported ones
  /// ([ModelImportOutcome.missing]); nothing was installed.
  incomplete,

  /// A file named like one of the model's did not match the catalog's
  /// size and SHA-256 (damaged, truncated or another model version:
  /// [ModelImportOutcome.damaged]); nothing was installed.
  checksumMismatch,

  /// Installing failed, e.g. on a full disk ([ModelImportOutcome.error]).
  failed,
}

/// The result of [BergamotModelManager.importFiles] for one model.
@immutable
final class ModelImportOutcome {
  const new({
    required this.model,
    required this.status,
    this.missing = const [],
    this.damaged = const [],
    this.error,
  });

  final CatalogModel model;
  final ModelImportStatus status;

  /// Files of [model] without a verified copy among the imported files
  /// ([ModelImportStatus.incomplete], [ModelImportStatus.checksumMismatch]).
  final List<CatalogFile> missing;

  /// Imported files named like a file of [model] that did not match its
  /// checksum ([ModelImportStatus.checksumMismatch]).
  final List<File> damaged;

  /// Why installing failed ([ModelImportStatus.failed], or a
  /// [ModelChecksumException] found while installing).
  final Object? error;

  @override
  String toString() => 'ModelImportOutcome(${model.pair}, ${status.name})';
}

/// The result of [BergamotModelManager.importFiles].
@immutable
final class ModelImportResult {
  const new({this.models = const [], this.unmatched = const []});

  /// One outcome per catalog model that an imported file belongs to,
  /// sorted by pair.
  final List<ModelImportOutcome> models;

  /// Imported files that belong to no catalog model.
  final List<File> unmatched;

  /// The models this import installed.
  List<CatalogModel> get installed => [
    for (final outcome in models)
      if (outcome.status == ModelImportStatus.installed) outcome.model,
  ];
}

/// Downloads, verifies, installs and deletes models in an app-private
/// directory ([root], passed in by the app).
///
/// Layout:
/// * `<root>/models/<pair>/<version>/`: an installed model (uncompressed
///   files plus `manifest.json`). The directory appears atomically (a
///   rename from staging), so a model is either completely installed or
///   absent.
/// * `<root>/models/.staging/`: models being decompressed.
/// * `<root>/models/.downloads/<pair>/<version>/<file>.gz.part`: downloads
///   in progress. Kept when a download is interrupted and resumed with an
///   HTTP `Range` request next time (the bytes already on disk are hashed
///   again, so the final SHA-256 check covers the whole file).
///
/// Every download is checked against the catalog's size and SHA-256 before
/// it is decompressed, and the decompressed file against its own size and
/// SHA-256. The [http.Client] is injectable (tests use `MockClient`).
/// [importFiles] installs files copied to the device by hand instead,
/// through the same checks and staging, without any network request.
class BergamotModelManager {
  new({
    required this.root,
    http.Client? httpClient,
    this.requestTimeout = const Duration(seconds: 60),
  }) : _client = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  /// App-private directory (e.g. `getApplicationSupportDirectory()`).
  final Directory root;

  /// Maximum wait for response headers and between chunks of a download.
  final Duration requestTimeout;

  final http.Client _client;
  final bool _ownsClient;
  final Map<String, Future<InstalledModel>> _installing = {};
  List<InstalledModel>? _installedCache;

  static const manifestName = 'manifest.json';
  static const _manifestSchema = 1;

  /// `<root>/models`.
  Directory get modelsDirectory => Directory(p.join(root.path, 'models'));

  Directory get _stagingDirectory =>
      Directory(p.join(modelsDirectory.path, '.staging'));

  Directory get _downloadsDirectory =>
      Directory(p.join(modelsDirectory.path, '.downloads'));

  Directory get _trashDirectory =>
      Directory(p.join(modelsDirectory.path, '.trash'));

  /// Every installed model (one version per pair).
  Future<List<InstalledModel>> installed() async =>
      _installedCache ??= List.unmodifiable(await _scan());

  /// The installed model for `source -> target` (Mozilla codes), if any.
  Future<InstalledModel?> installedModel(String source, String target) async {
    for (final model in await installed()) {
      if (model.source == source && model.target == target) return model;
    }
    return null;
  }

  /// Whether exactly [model] (same version) is installed.
  Future<bool> isInstalled(CatalogModel model) async {
    final installed = await installedModel(model.source, model.target);
    return installed?.version == model.version;
  }

  /// Bytes used by installed models.
  Future<int> totalSize() async =>
      (await installed()).fold<int>(0, (sum, model) => sum + model.sizeBytes);

  /// Downloads and installs [model], replacing any other version of the
  /// same pair. Returns at once when it is already installed. Concurrent
  /// calls for the same model share one download.
  Future<InstalledModel> install(
    CatalogModel model, {
    void Function(ModelDownloadProgress progress)? onProgress,
  }) {
    return _exclusive(model, () => _install(model, onProgress));
  }

  /// Installs models from files copied to the device by hand (downloaded
  /// elsewhere from [CatalogFile.url]), without any network request.
  ///
  /// Each of [files] is matched to a file of [catalog] by name, as
  /// published (`<name>.gz`, see [CatalogFileDownload.downloadName]) or
  /// decompressed (`<name>`), ignoring case; a renamed copy (e.g.
  /// `vocab.ende (1).spm.gz`) by its size and SHA-256. A named file is
  /// verified like a download: the size and SHA-256 of the gzip file or of
  /// the decompressed file must match the catalog. A model whose files are
  /// all there and verified is installed through the same staging,
  /// decompression checks and atomic rename as [install] (replacing another
  /// version of the pair); other models are left alone. A language pair
  /// that pivots through English (de -> fr) needs both of its models
  /// (de -> en, en -> fr); each is imported on its own.
  ///
  /// [files] are only read, never moved or deleted. Problems with a file or
  /// a model do not throw: they are reported in the [ModelImportResult].
  Future<ModelImportResult> importFiles(
    Iterable<File> files, {
    required ModelCatalog catalog,
  }) async {
    final byName = <String, (CatalogModel, CatalogFile)>{};
    final bySize = <int, List<(CatalogModel, CatalogFile)>>{};
    for (final model in catalog.models) {
      for (final file in model.files.values) {
        byName[file.name.toLowerCase()] = (model, file);
        for (final size in {file.size, file.uncompressedSize}) {
          (bySize[size] ??= []).add((model, file));
        }
      }
    }
    final versions = {
      for (final model in await installed()) model.pair: model.version,
    };
    bool isCurrent(CatalogModel model) => versions[model.pair] == model.version;

    final touched = <CatalogModel>{};
    final verified = <CatalogModel, Map<ModelFileKind, _ImportedFile>>{};
    final damaged = <CatalogModel, Map<ModelFileKind, List<File>>>{};
    final unmatched = <File>[];

    for (final input in files) {
      if (byName[_importName(input.path)] case (final model, final file)) {
        touched.add(model);
        if (isCurrent(model) ||
            (verified[model]?.containsKey(file.kind) ?? false)) {
          continue;
        }
        final compressed = await _identify(input, file);
        if (compressed == null) {
          ((damaged[model] ??= {})[file.kind] ??= []).add(input);
        } else {
          (verified[model] ??= {})[file.kind] = (
            file: input,
            compressed: compressed,
          );
        }
        continue;
      }
      // A renamed copy: the catalog file with its size and SHA-256.
      final candidates = bySize[await _lengthOf(input)];
      final fingerprint = candidates == null ? null : await _fingerprint(input);
      (CatalogModel, CatalogFile, bool)? match;
      for (final (model, file) in candidates ?? const <Never>[]) {
        if (_formOf(file, fingerprint) case final compressed?) {
          match = (model, file, compressed);
          break;
        }
      }
      if (match == null) {
        unmatched.add(input);
        continue;
      }
      final (model, file, compressed) = match;
      touched.add(model);
      if (!isCurrent(model)) {
        (verified[model] ??= {}).putIfAbsent(
          file.kind,
          () => (file: input, compressed: compressed),
        );
      }
    }

    final outcomes = <ModelImportOutcome>[];
    for (final model
        in touched.toList()..sort((a, b) => a.pair.compareTo(b.pair))) {
      if (isCurrent(model)) {
        outcomes.add(
          ModelImportOutcome(
            model: model,
            status: ModelImportStatus.alreadyInstalled,
          ),
        );
        continue;
      }
      final found = verified[model] ?? const {};
      final missing = [
        for (final file in model.files.values)
          if (!found.containsKey(file.kind)) file,
      ];
      if (missing.isEmpty) {
        outcomes.add(await _importModel(model, found));
        continue;
      }
      final bad = [
        for (final MapEntry(:key, :value) in (damaged[model] ?? {}).entries)
          if (!found.containsKey(key)) ...value,
      ];
      outcomes.add(
        ModelImportOutcome(
          model: model,
          status: bad.isEmpty
              ? ModelImportStatus.incomplete
              : ModelImportStatus.checksumMismatch,
          missing: List.unmodifiable(missing),
          damaged: List.unmodifiable(bad),
        ),
      );
    }
    return ModelImportResult(
      models: List.unmodifiable(outcomes),
      unmatched: List.unmodifiable(unmatched),
    );
  }

  /// Deletes every installed version of `source -> target`, plus partial
  /// downloads of it.
  Future<void> delete(String source, String target) async {
    final pair = '$source-$target';
    _checkSafe(pair);
    _installedCache = null;
    await _deleteQuietly(Directory(p.join(modelsDirectory.path, pair)));
    await _deleteQuietly(Directory(p.join(_downloadsDirectory.path, pair)));
  }

  /// Removes leftovers of interrupted installs (staging and trash; partial
  /// downloads are kept for resuming). Safe to call at start-up.
  Future<void> cleanUp() async {
    await _deleteQuietly(_stagingDirectory);
    await _deleteQuietly(_trashDirectory);
  }

  /// Closes the HTTP client when this manager created it.
  void close() {
    if (_ownsClient) _client.close();
  }

  Future<InstalledModel> _install(
    CatalogModel model,
    void Function(ModelDownloadProgress progress)? onProgress,
  ) async {
    _checkSafe(model.pair);
    final current = await installedModel(model.source, model.target);
    if (current != null && current.version == model.version) return current;

    final downloads = Directory(
      p.join(_downloadsDirectory.path, model.pair, model.version),
    );
    await downloads.create(recursive: true);

    final received = <ModelFileKind, int>{};
    void report(ModelFileKind kind, int bytes) {
      received[kind] = bytes;
      onProgress?.call(
        ModelDownloadProgress(
          model: model,
          receivedBytes: received.values.fold(0, (a, b) => a + b),
          totalBytes: model.downloadSize,
        ),
      );
    }

    return await _installStaged(model, (staging) async {
      for (final file in model.files.values) {
        final gz = await _download(model, file, downloads, report);
        try {
          await _writeVerified(
            model,
            file,
            gz.openRead().transform(gzip.decoder),
            staging,
          );
        } on ModelChecksumException {
          // A verified download that does not decompress to the catalog's
          // file: download it again next time.
          await _deleteQuietly(gz);
          rethrow;
        }
      }
    });
  }

  /// Runs [run] (installing [model]) unless an install of the same model is
  /// already running, which is then shared.
  Future<InstalledModel> _exclusive(
    CatalogModel model,
    Future<InstalledModel> Function() run,
  ) {
    final key = '${model.pair}/${model.version}';
    // The callback must not return the removed future: whenComplete would
    // then wait for itself.
    return _installing[key] ??= run().whenComplete(() {
      unawaited(_installing.remove(key));
    });
  }

  /// Installs [model] from a fresh staging directory that [fill] writes
  /// every verified file of [model] into (see [_writeVerified]): writes
  /// `manifest.json`, moves the directory into place atomically, removes
  /// other versions of the pair and partial downloads of [model]. The
  /// staging directory is removed in any case.
  Future<InstalledModel> _installStaged(
    CatalogModel model,
    Future<void> Function(Directory staging) fill,
  ) async {
    final staging = Directory(
      p.join(
        _stagingDirectory.path,
        '${model.pair}-${model.version}-${_randomSuffix()}',
      ),
    );
    await staging.create(recursive: true);
    try {
      await fill(staging);
      await File(p.join(staging.path, manifestName))
          .writeAsString(jsonEncode(_manifest(model)), flush: true);

      final destination = Directory(
        p.join(modelsDirectory.path, model.pair, model.version),
      );
      await _replaceAtomically(staging, destination);
      // Other versions of the pair are obsolete now.
      await for (final entry in destination.parent.list()) {
        if (entry is Directory && p.basename(entry.path) != model.version) {
          await _deleteQuietly(entry);
        }
      }
      await _deleteQuietly(
        Directory(p.join(_downloadsDirectory.path, model.pair, model.version)),
      );
      _installedCache = null;
      return (await installedModel(model.source, model.target))!;
    } finally {
      await _deleteQuietly(staging);
    }
  }

  /// Downloads [file] into `<downloads>/<name>.gz.part` (resuming a partial
  /// download) and verifies its size and SHA-256.
  Future<File> _download(
    CatalogModel model,
    CatalogFile file,
    Directory downloads,
    void Function(ModelFileKind kind, int bytes) report,
  ) async {
    final part = File(p.join(downloads.path, '${file.name}.gz.part'));
    var existing = part.existsSync() ? part.lengthSync() : 0;
    if (existing > file.size) {
      await part.delete();
      existing = 0;
    }

    final digestSink = _DigestSink();
    final hasher = sha256.startChunkedConversion(digestSink);
    var received = 0;

    if (existing < file.size) {
      final request = http.Request('GET', file.url);
      if (existing > 0) request.headers['Range'] = 'bytes=$existing-';
      final http.StreamedResponse response;
      try {
        response = await _client.send(request).timeout(requestTimeout);
      } on Object catch (error) {
        throw ModelDownloadException(model.pair, '$error');
      }
      final resumed = existing > 0 && response.statusCode == 206;
      if (response.statusCode != 200 && !resumed) {
        // Drain so the connection can be reused.
        await response.stream.drain<void>().catchError((_) {});
        throw ModelDownloadException(
          model.pair,
          'HTTP ${response.statusCode} for ${file.url}',
          statusCode: response.statusCode,
        );
      }
      if (resumed) {
        // Hash what is already on disk, then append.
        await for (final chunk in part.openRead()) {
          hasher.add(chunk);
          received += chunk.length;
        }
      }
      report(file.kind, received);
      final sink = part.openWrite(
        mode: resumed ? FileMode.writeOnlyAppend : FileMode.writeOnly,
      );
      try {
        await for (final chunk in response.stream.timeout(requestTimeout)) {
          received += chunk.length;
          if (received > file.size) {
            throw ModelChecksumException(
              model.pair,
              '${file.name}: more than ${file.size} bytes',
            );
          }
          hasher.add(chunk);
          sink.add(chunk);
          report(file.kind, received);
        }
      } on ModelInstallException {
        await sink.close();
        await _deleteQuietly(part);
        rethrow;
      } on Object catch (error) {
        // Interrupted: keep the part for resuming.
        await sink.close();
        throw ModelDownloadException(model.pair, '${file.name}: $error');
      }
      await sink.flush();
      await sink.close();
    } else {
      await for (final chunk in part.openRead()) {
        hasher.add(chunk);
        received += chunk.length;
      }
      report(file.kind, received);
    }
    hasher.close();

    final digest = digestSink.value.toString();
    if (received != file.size || digest != file.sha256) {
      await _deleteQuietly(part);
      throw ModelChecksumException(
        model.pair,
        '${file.name}: got $received bytes with SHA-256 $digest, expected '
        '${file.size} bytes with SHA-256 ${file.sha256}',
      );
    }
    return part;
  }

  /// Writes [contents] (the decompressed bytes of [file]: a verified
  /// download through `gzip.decoder`, or an imported decompressed file)
  /// into [staging] and verifies their size and SHA-256.
  Future<File> _writeVerified(
    CatalogModel model,
    CatalogFile file,
    Stream<List<int>> contents,
    Directory staging,
  ) async {
    final output = File(p.join(staging.path, file.name));
    final digestSink = _DigestSink();
    final hasher = sha256.startChunkedConversion(digestSink);
    var size = 0;
    final sink = output.openWrite();
    try {
      await for (final chunk in contents) {
        size += chunk.length;
        if (size > file.uncompressedSize) break;
        hasher.add(chunk);
        sink.add(chunk);
      }
    } on FormatException catch (error) {
      throw ModelChecksumException(model.pair, '${file.name}: $error');
    } finally {
      await sink.close();
    }
    hasher.close();
    final digest = digestSink.value.toString();
    if (size != file.uncompressedSize || digest != file.uncompressedSha256) {
      throw ModelChecksumException(
        model.pair,
        '${file.name}: decompressed to $size bytes with SHA-256 $digest, '
        'expected ${file.uncompressedSize} bytes with SHA-256 '
        '${file.uncompressedSha256}',
      );
    }
    return output;
  }

  /// Moves [staging] to [destination] with a rename (atomic on one file
  /// system); an existing [destination] is moved to the trash first.
  Future<void> _replaceAtomically(
    Directory staging,
    Directory destination,
  ) async {
    await destination.parent.create(recursive: true);
    Directory? old;
    if (destination.existsSync()) {
      await _trashDirectory.create(recursive: true);
      old = await destination.rename(
        p.join(_trashDirectory.path, _randomSuffix()),
      );
    }
    await staging.rename(destination.path);
    if (old != null) await _deleteQuietly(old);
  }

  Map<String, Object?> _manifest(CatalogModel model) => {
    'schemaVersion': _manifestSchema,
    'source': model.source,
    'target': model.target,
    'version': model.version,
    'files': {
      for (final file in model.files.values)
        file.kind.key: {
          'name': file.name,
          'size': file.uncompressedSize,
          'sha256': file.uncompressedSha256,
        },
    },
  };

  Future<List<InstalledModel>> _scan() async {
    final directory = modelsDirectory;
    if (!directory.existsSync()) return const [];
    final models = <InstalledModel>[];
    await for (final pairDir in directory.list()) {
      if (pairDir is! Directory || p.basename(pairDir.path).startsWith('.')) {
        continue;
      }
      await for (final versionDir in pairDir.list()) {
        if (versionDir is! Directory) continue;
        final model = await _readInstalled(versionDir);
        if (model != null) models.add(model);
      }
    }
    models.sort((a, b) => a.pair.compareTo(b.pair));
    return models;
  }

  /// Null for anything that is not a complete install (ignored).
  Future<InstalledModel?> _readInstalled(Directory directory) async {
    final manifest = File(p.join(directory.path, manifestName));
    try {
      final json = jsonDecode(await manifest.readAsString());
      if (json is! Map<String, Object?> ||
          json['schemaVersion'] != _manifestSchema) {
        return null;
      }
      final source = json['source']! as String;
      final target = json['target']! as String;
      final version = json['version']! as String;
      if (p.basename(directory.path) != version ||
          p.basename(directory.parent.path) != '$source-$target') {
        return null;
      }
      final files = <ModelFileKind, String>{};
      var size = 0;
      for (final MapEntry(:key, :value)
          in (json['files']! as Map<String, Object?>).entries) {
        final kind = ModelFileKind.fromKey(key);
        final entry = value! as Map<String, Object?>;
        final name = entry['name']! as String;
        if (kind == null || p.basename(name) != name) return null;
        final file = File(p.join(directory.path, name));
        final length = await file.length();
        if (length != entry['size']) return null;
        files[kind] = file.path;
        size += length;
      }
      if (!files.containsKey(ModelFileKind.model) ||
          !files.containsKey(ModelFileKind.lexicalShortlist) ||
          !(files.containsKey(ModelFileKind.vocab) ||
              files.containsKey(ModelFileKind.srcVocab))) {
        return null;
      }
      return InstalledModel(
        source: source,
        target: target,
        version: version,
        directory: directory.path,
        files: Map.unmodifiable(files),
        sizeBytes: size,
      );
    } on Object {
      return null;
    }
  }

  /// Installs [model] from its verified imported [files].
  Future<ModelImportOutcome> _importModel(
    CatalogModel model,
    Map<ModelFileKind, _ImportedFile> files,
  ) async {
    CatalogFile? writing;
    try {
      _checkSafe(model.pair);
      await _exclusive(
        model,
        () => _installStaged(model, (staging) async {
          for (final file in model.files.values) {
            writing = file;
            final source = files[file.kind]!;
            final contents = source.file.openRead();
            await _writeVerified(
              model,
              file,
              source.compressed ? contents.transform(gzip.decoder) : contents,
              staging,
            );
          }
        }),
      );
      return ModelImportOutcome(
        model: model,
        status: ModelImportStatus.installed,
      );
    } on ModelChecksumException catch (error) {
      // Changed since it was verified, or a gzip file that does not
      // decompress to the catalog's file.
      final file = writing;
      return ModelImportOutcome(
        model: model,
        status: ModelImportStatus.checksumMismatch,
        missing: [?file],
        damaged: [?files[file?.kind]?.file],
        error: error,
      );
    } on Object catch (error) {
      return ModelImportOutcome(
        model: model,
        status: ModelImportStatus.failed,
        error: error,
      );
    }
  }

  /// Whether [input] is [file] as published (true: gzip) or decompressed
  /// (false); null when it is neither or cannot be read.
  static Future<bool?> _identify(File input, CatalogFile file) async {
    final length = await _lengthOf(input);
    // Only a file of the right size is worth hashing.
    if (length != file.size && length != file.uncompressedSize) return null;
    return _formOf(file, await _fingerprint(input));
  }

  /// Whether [fingerprint] is that of [file] as published (true: gzip) or
  /// decompressed (false); null when it is neither.
  static bool? _formOf(
    CatalogFile file,
    ({int size, String sha256})? fingerprint,
  ) => switch (fingerprint) {
    (:final size, :final sha256)
        when size == file.size && sha256 == file.sha256 =>
      true,
    (:final size, :final sha256)
        when size == file.uncompressedSize &&
            sha256 == file.uncompressedSha256 =>
      false,
    _ => null,
  };

  /// Size and SHA-256 of [file]'s contents; null when it cannot be read.
  static Future<({int size, String sha256})?> _fingerprint(File file) async {
    final digestSink = _DigestSink();
    final hasher = sha256.startChunkedConversion(digestSink);
    var size = 0;
    try {
      await for (final chunk in file.openRead()) {
        size += chunk.length;
        hasher.add(chunk);
      }
    } on FileSystemException {
      return null;
    }
    hasher.close();
    return (size: size, sha256: digestSink.value.toString());
  }

  /// The length of [file]; -1 when it cannot be read.
  static Future<int> _lengthOf(File file) async {
    try {
      return await file.length();
    } on FileSystemException {
      return -1;
    }
  }

  /// The catalog name an imported file at [path] stands for: its base
  /// name in lower case, without a `.gz` extension.
  static String _importName(String path) {
    final name = p.basename(path).toLowerCase();
    return name.endsWith('.gz') ? name.substring(0, name.length - 3) : name;
  }

  static void _checkSafe(String pair) {
    if (!RegExp(r'^[a-z_]+-[a-z_]+$').hasMatch(pair)) {
      throw ArgumentError.value(pair, 'pair', 'Invalid language pair');
    }
  }

  static final _random = Random();

  static String _randomSuffix() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(1 << 32)}';

  static Future<void> _deleteQuietly(FileSystemEntity entity) async {
    try {
      if (entity.existsSync()) await entity.delete(recursive: true);
    } on FileSystemException {
      // Best effort: leftovers are removed by the next cleanUp().
    }
  }
}

/// A verified imported file: gzip-compressed as published, or decompressed.
typedef _ImportedFile = ({File file, bool compressed});

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
