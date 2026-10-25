import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:whisper_speech/src/catalog.dart';
import 'package:whisper_speech/src/file_hashing.dart';

/// A download or install of a Whisper model failed.
sealed class WhisperModelInstallException implements Exception {
  const new(this.model, this.message, {this.mirror});

  /// The model id, e.g. `tiny`.
  final String model;
  final String message;

  /// The mirror ([WhisperModelManager.mirror]) the failed download came
  /// from; null for the catalog's URL (Hugging Face) and for failures that
  /// are not a download's.
  final Uri? mirror;

  String get _name;

  @override
  String toString() => '$_name($model: $message)';
}

/// The file did not match the catalog's size, SHA-1 or SHA-256 (corrupt,
/// truncated or tampered download). Nothing was installed.
final class WhisperChecksumException extends WhisperModelInstallException {
  const new(super.model, super.message, {super.mirror});

  @override
  String get _name => 'WhisperChecksumException';
}

/// The server answered with an error or the connection failed.
final class WhisperDownloadException extends WhisperModelInstallException {
  const new(super.model, super.message, {this.statusCode, super.mirror});

  final int? statusCode;

  @override
  String get _name => 'WhisperDownloadException';
}

/// There is not enough free storage for the model ([requiredBytes]: what
/// is left to download or copy plus a margin, see
/// [WhisperModelManager.requiredSpace]); nothing was downloaded or copied.
final class WhisperInsufficientSpaceException
    extends WhisperModelInstallException {
  const new(
    super.model,
    super.message, {
    required this.requiredBytes,
    required this.availableBytes,
  });

  /// Free bytes the download or import needs.
  final int requiredBytes;

  /// Free bytes there are.
  final int availableBytes;

  @override
  String get _name => 'WhisperInsufficientSpaceException';
}

/// A file to import that is read through [copyTo] rather than from a path:
/// a document the user picked (an Android content URI), copied straight
/// into the manager's staging folder ([WhisperModelManager.importSources]),
/// so no other copy is made first.
abstract interface class WhisperImportSource {
  /// The file's name, matched against the catalog's (ignoring case).
  String get name;

  /// Its size in bytes; null when unknown (it is then matched by [name]
  /// only).
  int? get length;

  /// Writes its bytes to [destination] (a new file), at most
  /// `maxBytes + 1` of them, and returns how many it wrote. Throws when it
  /// cannot be read or written.
  Future<int> copyTo(File destination, {required int maxBytes});
}

/// Progress of [WhisperModelManager.install].
@immutable
final class WhisperDownloadProgress {
  const new({
    required this.model,
    required this.receivedBytes,
    required this.totalBytes,
  });

  final WhisperCatalogModel model;

  /// Bytes on disk so far (resumed bytes count).
  final int receivedBytes;

  /// [WhisperCatalogModel.size].
  final int totalBytes;

  double get fraction => totalBytes == 0 ? 1 : receivedBytes / totalBytes;
}

/// A model installed under `<root>/models/<id>/`.
@immutable
final class InstalledWhisperModel {
  const new({
    required this.id,
    required this.path,
    required this.sizeBytes,
    required this.sha1,
  });

  /// [WhisperCatalogModel.id].
  final String id;

  /// Absolute path of the `ggml-*.bin` file (what the engine loads).
  final String path;

  /// Bytes on disk.
  final int sizeBytes;

  /// The SHA-1 the file was verified against when it was installed.
  final String sha1;

  /// Whether this is exactly [model] (same id and file).
  bool matches(WhisperCatalogModel model) =>
      model.id == id && model.sha1 == sha1;

  @override
  bool operator ==(Object other) =>
      other is InstalledWhisperModel &&
      other.id == id &&
      other.path == path &&
      other.sizeBytes == sizeBytes &&
      other.sha1 == sha1;

  @override
  int get hashCode => Object.hash(id, path, sizeBytes, sha1);

  @override
  String toString() => 'InstalledWhisperModel($id)';
}

/// What [WhisperModelManager.importFiles] did with one catalog model.
enum WhisperImportStatus {
  /// The file was there and verified: the model is installed now.
  installed,

  /// This model was installed already (the file was not read).
  alreadyInstalled,

  /// A file named like the model's did not match the catalog's size and
  /// SHA-1 (damaged, truncated or another file); nothing was installed.
  checksumMismatch,

  /// Installing failed, e.g. on a full disk ([WhisperImportOutcome.error]).
  failed,
}

/// The result of [WhisperModelManager.importFiles] for one model.
@immutable
final class WhisperImportOutcome {
  const new({
    required this.model,
    required this.status,
    this.damaged = const [],
    this.error,
  });

  final WhisperCatalogModel model;
  final WhisperImportStatus status;

  /// Imported files named like [model]'s that did not match its checksum
  /// ([WhisperImportStatus.checksumMismatch]).
  final List<File> damaged;

  /// Why installing failed ([WhisperImportStatus.failed]).
  final Object? error;

  @override
  String toString() => 'WhisperImportOutcome(${model.id}, ${status.name})';
}

/// The result of [WhisperModelManager.importFiles].
@immutable
final class WhisperImportResult {
  const new({this.models = const [], this.unmatched = const []});

  /// One outcome per catalog model that an imported file belongs to, in
  /// catalog order.
  final List<WhisperImportOutcome> models;

  /// Imported files that belong to no catalog model.
  final List<File> unmatched;

  /// The models this import installed.
  List<WhisperCatalogModel> get installed => [
    for (final outcome in models)
      if (outcome.status == WhisperImportStatus.installed) outcome.model,
  ];
}

/// Downloads, verifies, installs and deletes Whisper models in an
/// app-private directory ([root], passed in by the app).
///
/// Layout:
/// * `<root>/models/<id>/`: an installed model (`ggml-*.bin` plus
///   `manifest.json`). The directory appears atomically (a rename from
///   staging), so a model is either completely installed or absent.
/// * `<root>/models/.staging/`: models being installed.
/// * `<root>/models/.downloads/<id>/<file>.part`: downloads in progress.
///   Kept when a download is interrupted and resumed with an HTTP `Range`
///   request next time (the bytes already on disk are hashed again, so the
///   final checksums cover the whole file).
///
/// Every download is checked against the catalog's size and SHA-1 (and
/// SHA-256 when the catalog has it) before it is installed. The
/// [http.Client] is injectable (tests use `MockClient`). Files come from
/// the catalog's URLs (Hugging Face) or from a [mirror] of them
/// ([whisperDownloadUrls]), which needs no trust: the same checks apply.
/// Whether a download is allowed (Wi-Fi only, the privacy settings) is the
/// app's decision: this class downloads when asked.
/// [importFiles] installs files copied to the device by hand instead,
/// through the same checks and staging, without any network request
/// ([importSources]: picked documents, copied straight into staging).
///
/// Before a download or an import writes anything, the free space is
/// checked (with `freeSpace`): what is left to write plus a margin
/// ([requiredSpace]); too little fails with a
/// [WhisperInsufficientSpaceException]. Hashing (a download's bytes as
/// they arrive, the part of a resumed download, an imported file) runs off
/// the UI isolate ([hashing]).
class WhisperModelManager {
  /// `freeSpace` answers the free bytes of the file system of a path (null
  /// when unknown, e.g. the app's `FreeSpace`); without it no download or
  /// import checks for room first. [hashing] decides where files are
  /// hashed (background isolates by default).
  new({
    required this.root,
    http.Client? httpClient,
    this.requestTimeout = const Duration(seconds: 60),
    this._freeSpace,
    this.hashing = const FileHashing.isolate(),
  }) : _client = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  /// App-private directory (e.g. `getApplicationSupportDirectory()`).
  final Directory root;

  /// Where model files are hashed: off the UI isolate unless
  /// [FileHashing.inline].
  final FileHashing hashing;

  final Future<int?> Function(String path)? _freeSpace;

  /// The smallest margin of free space a download or import keeps (on top
  /// of the bytes it writes): 50 MiB.
  static const int spaceMarginBytes = 50 << 20;

  /// The free space writing [bytes] needs: the bytes plus a margin of 5 %,
  /// at least [spaceMarginBytes], so the phone is not left full.
  static int requiredSpace(int bytes) =>
      bytes + max(spaceMarginBytes, bytes ~/ 20);

  /// Maximum wait for response headers and between chunks of a download.
  final Duration requestTimeout;

  /// Base URL of a mirror of the model files to download from instead of
  /// the catalog's URLs, e.g. `https://example.org/models/` (layout: see
  /// [whisperMirrorUrl]); null downloads from Hugging Face. Read when an
  /// [install] starts. A file that does not match the catalog fails with
  /// a [WhisperChecksumException] naming the mirror.
  Uri? mirror;

  /// Whether a file the [mirror] does not serve (an HTTP error or a failed
  /// connection) is downloaded from the catalog's URL instead. Without it,
  /// the install fails with a [WhisperDownloadException] naming the mirror.
  bool fallbackToDefault = false;

  final http.Client _client;
  final bool _ownsClient;
  final Map<String, Future<InstalledWhisperModel>> _installing = {};
  List<InstalledWhisperModel>? _installedCache;

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

  /// Every installed model, sorted by id.
  Future<List<InstalledWhisperModel>> installed() async =>
      _installedCache ??= List.unmodifiable(await _scan());

  /// The installed model with [id], if any.
  Future<InstalledWhisperModel?> installedModel(String id) async {
    for (final model in await installed()) {
      if (model.id == id) return model;
    }
    return null;
  }

  /// Whether exactly [model] (same file) is installed.
  Future<bool> isInstalled(WhisperCatalogModel model) async =>
      (await installedModel(model.id))?.matches(model) ?? false;

  /// Bytes already downloaded of an interrupted download of [model] (0
  /// when none), which [install] resumes.
  Future<int> partialBytes(WhisperCatalogModel model) async {
    _checkSafe(model.id);
    final part = _partFile(model);
    try {
      return part.existsSync() ? await part.length() : 0;
    } on FileSystemException {
      return 0;
    }
  }

  /// Throws a [WhisperInsufficientSpaceException] when a download of
  /// [model] would not fit now (what is left to download plus a margin,
  /// see [requiredSpace]): for asking before anything else (a metered
  /// network prompt). [install] checks again. Passes without a
  /// `freeSpace`.
  Future<void> checkSpace(WhisperCatalogModel model) async {
    _checkSafe(model.id);
    final part = _partFile(model);
    final existing = part.existsSync() ? await _lengthOf(part) : 0;
    await _checkSpace(model, model.size - existing.clamp(0, model.size));
  }

  /// Downloads and installs [model], replacing another file installed
  /// under the same id. Returns at once when it is already installed.
  /// Concurrent calls for the same model share one download.
  Future<InstalledWhisperModel> install(
    WhisperCatalogModel model, {
    void Function(WhisperDownloadProgress progress)? onProgress,
  }) => _exclusive(model, () => _install(model, onProgress));

  /// Installs models from files copied to the device by hand (downloaded
  /// elsewhere from [WhisperCatalogModel.url]), without any network
  /// request.
  ///
  /// Each of [files] is matched to a model of [catalog] by name (e.g.
  /// `ggml-tiny.bin`, ignoring case) or, for a renamed copy (e.g.
  /// `ggml-tiny (1).bin`), by its exact size; it is then copied into
  /// staging while its SHA-1 is computed (in the background) and installed
  /// through the same atomic rename as [install] when size and SHA-1 match
  /// the catalog. A copy needs free space for the file (else a
  /// [WhisperInsufficientSpaceException] for that model).
  ///
  /// [files] are only read, never moved or deleted. Problems with a file
  /// or a model do not throw: they are reported in the
  /// [WhisperImportResult].
  Future<WhisperImportResult> importFiles(
    Iterable<File> files, {
    required WhisperModelCatalog catalog,
  }) => _import([for (final file in files) _FileInput(file)], catalog);

  /// Installs models from [sources] (documents the user picked) like
  /// [importFiles], without any network request: each one is copied
  /// straight into the staging folder ([WhisperImportSource.copyTo], after
  /// the free-space check), verified there and moved into place, so no
  /// other copy of it is made. A source of unknown length is matched by
  /// name only. In the result, [WhisperImportOutcome.damaged] and
  /// [WhisperImportResult.unmatched] hold a [File] named like the source
  /// (not a path on this device).
  Future<WhisperImportResult> importSources(
    Iterable<WhisperImportSource> sources, {
    required WhisperModelCatalog catalog,
  }) => _import([for (final source in sources) _SourceInput(source)], catalog);

  Future<WhisperImportResult> _import(
    List<_ImportInput> inputs,
    WhisperModelCatalog catalog,
  ) async {
    final named = <WhisperCatalogModel, List<_ImportInput>>{};
    final sized = <WhisperCatalogModel, List<_ImportInput>>{};
    final unmatched = <File>[];
    for (final input in inputs) {
      final name = input.name.toLowerCase();
      final byName = catalog.models
          .where((model) => model.name.toLowerCase() == name)
          .firstOrNull;
      if (byName != null) {
        (named[byName] ??= []).add(input);
        continue;
      }
      final length = await input.length();
      final bySize = catalog.models
          .where((model) => model.size == length)
          .firstOrNull;
      if (bySize == null) {
        unmatched.add(input.file);
      } else {
        (sized[bySize] ??= []).add(input);
      }
    }

    final outcomes = <WhisperImportOutcome>[];
    for (final model in catalog.models) {
      final candidates = [...?named[model], ...?sized[model]];
      if (candidates.isEmpty) continue;
      if (await isInstalled(model)) {
        outcomes.add(
          WhisperImportOutcome(
            model: model,
            status: WhisperImportStatus.alreadyInstalled,
          ),
        );
        continue;
      }
      final damaged = <File>[];
      WhisperImportOutcome? outcome;
      for (final input in candidates) {
        final result = await _importFile(model, input);
        if (result == null) {
          // Not the model's file: damaged when it was named like it, a
          // file of the same size that is something else otherwise.
          if (named[model]?.contains(input) ?? false) {
            damaged.add(input.file);
          } else {
            unmatched.add(input.file);
          }
          continue;
        }
        outcome = result;
        break;
      }
      if (outcome != null) {
        outcomes.add(outcome);
      } else if (damaged.isNotEmpty) {
        outcomes.add(
          WhisperImportOutcome(
            model: model,
            status: WhisperImportStatus.checksumMismatch,
            damaged: List.unmodifiable(damaged),
          ),
        );
      }
    }
    return WhisperImportResult(
      models: List.unmodifiable(outcomes),
      unmatched: List.unmodifiable(unmatched),
    );
  }

  /// Deletes the installed model [id], plus a partial download of it.
  Future<void> delete(String id) async {
    _checkSafe(id);
    _installedCache = null;
    await _deleteQuietly(Directory(p.join(modelsDirectory.path, id)));
    await _deleteQuietly(Directory(p.join(_downloadsDirectory.path, id)));
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

  File _partFile(WhisperCatalogModel model) =>
      File(p.join(_downloadsDirectory.path, model.id, '${model.name}.part'));

  Future<InstalledWhisperModel> _install(
    WhisperCatalogModel model,
    void Function(WhisperDownloadProgress progress)? onProgress,
  ) async {
    _checkSafe(model.id);
    final current = await installedModel(model.id);
    if (current != null && current.matches(model)) return current;

    void report(int bytes) => onProgress?.call(
      WhisperDownloadProgress(
        model: model,
        receivedBytes: bytes,
        totalBytes: model.size,
      ),
    );

    await checkSpace(model);
    final part = await _download(
      model,
      report,
      mirror: mirror,
      fallbackToDefault: fallbackToDefault,
    );
    return await _installStaged(model, (staging) async {
      await part.rename(p.join(staging.path, model.name));
    });
  }

  /// Runs [run] (installing [model]) unless an install of the same model is
  /// already running, which is then shared.
  Future<InstalledWhisperModel> _exclusive(
    WhisperCatalogModel model,
    Future<InstalledWhisperModel> Function() run,
  ) {
    final key = model.id;
    // The callback must not return the removed future: whenComplete would
    // then wait for itself.
    return _installing[key] ??= run().whenComplete(() {
      unawaited(_installing.remove(key));
    });
  }

  /// Installs [model] from a fresh staging directory that [fill] puts the
  /// verified model file into: writes `manifest.json`, moves the directory
  /// into place atomically and removes partial downloads of [model]. The
  /// staging directory is removed in any case.
  Future<InstalledWhisperModel> _installStaged(
    WhisperCatalogModel model,
    Future<void> Function(Directory staging) fill,
  ) async {
    final staging = Directory(
      p.join(_stagingDirectory.path, '${model.id}-${_randomSuffix()}'),
    );
    await staging.create(recursive: true);
    try {
      await fill(staging);
      await File(p.join(staging.path, manifestName))
          .writeAsString(jsonEncode(_manifest(model)), flush: true);
      await _replaceAtomically(
        staging,
        Directory(p.join(modelsDirectory.path, model.id)),
      );
      await _deleteQuietly(
        Directory(p.join(_downloadsDirectory.path, model.id)),
      );
      _installedCache = null;
      return (await installedModel(model.id))!;
    } finally {
      await _deleteQuietly(staging);
    }
  }

  /// Downloads [model] into its `.part` file (resuming a partial download)
  /// from [mirror] or the catalog's URL (see [whisperDownloadUrls]) and
  /// verifies its size, SHA-1 and SHA-256 (when the catalog has it).
  Future<File> _download(
    WhisperCatalogModel model,
    void Function(int bytes) report, {
    Uri? mirror,
    bool fallbackToDefault = false,
  }) async {
    final part = _partFile(model);
    await part.parent.create(recursive: true);
    var existing = part.existsSync() ? part.lengthSync() : 0;
    if (existing > model.size) {
      await part.delete();
      existing = 0;
    }

    var received = 0;
    // The mirror the bytes come from (null: the catalog's URL).
    Uri? source;
    final FileDigest digest;

    if (existing < model.size) {
      final (response, from) = await _request(
        model,
        existing,
        mirror: mirror,
        fallbackToDefault: fallbackToDefault,
      );
      source = from;
      final resumed = existing > 0 && response.statusCode == 206;
      final StreamHasher hasher;
      try {
        hasher = await hashing.stream();
      } on Object catch (error) {
        unawaited(response.stream.listen(null).cancel());
        throw WhisperDownloadException(
          model.id,
          '${model.name}${_from(source)}: $error',
          mirror: source,
        );
      }
      try {
        if (resumed) {
          // Hash what is already on disk (in the background), then append.
          received = await hasher.addFile(part.path);
        }
        report(received);
        final sink = part.openWrite(
          mode: resumed ? FileMode.writeOnlyAppend : FileMode.writeOnly,
        );
        try {
          await for (final chunk in response.stream.timeout(requestTimeout)) {
            received += chunk.length;
            if (received > model.size) {
              throw WhisperChecksumException(
                model.id,
                '${model.name}${_from(source)}: more than ${model.size} '
                'bytes',
                mirror: source,
              );
            }
            sink.add(chunk);
            await hasher.add(chunk);
            report(received);
          }
        } on WhisperModelInstallException {
          await sink.close();
          await _deleteQuietly(part);
          rethrow;
        } on Object catch (error) {
          // Interrupted: keep the part for resuming.
          await sink.close();
          throw WhisperDownloadException(
            model.id,
            '${model.name}${_from(source)}: $error',
            mirror: source,
          );
        }
        await sink.flush();
        await sink.close();
        digest = await hasher.close();
      } finally {
        hasher.abort();
      }
    } else {
      digest = await hashing.hashFile(part.path);
      received = digest.size;
      report(received);
    }

    if (_mismatch(model, digest) case final mismatch?) {
      await _deleteQuietly(part);
      throw WhisperChecksumException(
        model.id,
        '${model.name}${_from(source)}: $mismatch',
        mirror: source,
      );
    }
    return part;
  }

  /// Null when [digest] is [model]'s file (size, SHA-1 and, when the
  /// catalog has it, SHA-256), else what differs.
  static String? _mismatch(WhisperCatalogModel model, FileDigest digest) {
    final sha256 = model.sha256;
    if (digest.size == model.size &&
        digest.sha1 == model.sha1 &&
        (sha256 == null || digest.sha256 == sha256)) {
      return null;
    }
    return 'got ${digest.size} bytes with SHA-1 ${digest.sha1}'
        '${sha256 == null ? '' : ' and SHA-256 ${digest.sha256}'}, '
        'expected ${model.size} bytes with SHA-1 ${model.sha1}'
        '${sha256 == null ? '' : ' and SHA-256 $sha256'}';
  }

  /// Sends the request for [model] (from byte [existing] on) to each URL of
  /// [whisperDownloadUrls] in turn until one answers with its contents
  /// (200, or 206 when resuming): the response and the mirror it came from
  /// (null: the catalog's URL). Throws the last URL's
  /// [WhisperDownloadException].
  Future<(http.StreamedResponse, Uri?)> _request(
    WhisperCatalogModel model,
    int existing, {
    required Uri? mirror,
    required bool fallbackToDefault,
  }) async {
    final urls = whisperDownloadUrls(
      model,
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
        response = await _client.send(request).timeout(requestTimeout);
      } on Object catch (error) {
        if (!last) continue;
        throw WhisperDownloadException(
          model.id,
          '${model.name}${_from(source)}: $error',
          mirror: source,
        );
      }
      final status = response.statusCode;
      if (status == 200 || (existing > 0 && status == 206)) {
        return (response, source);
      }
      // Drain so the connection can be reused.
      await response.stream.drain<void>().catchError((_) {});
      if (last) {
        throw WhisperDownloadException(
          model.id,
          'HTTP $status for $url',
          statusCode: status,
          mirror: source,
        );
      }
    }
  }

  /// ` from the mirror <mirror>` for a download from [mirror], else empty.
  static String _from(Uri? mirror) =>
      mirror == null ? '' : ' from the mirror $mirror';

  /// Throws a [WhisperInsufficientSpaceException] when the file system of
  /// [modelsDirectory] has less free space than writing [bytes] for
  /// [model] needs ([requiredSpace]). Nothing to write, or an unknown free
  /// space, passes.
  Future<void> _checkSpace(WhisperCatalogModel model, int bytes) async {
    final freeSpace = _freeSpace;
    if (freeSpace == null || bytes <= 0) return;
    int? available;
    try {
      available = await freeSpace(modelsDirectory.path);
    } on Object {
      // Not known: the write itself fails on a full disk.
    }
    final needed = requiredSpace(bytes);
    if (available == null || available >= needed) return;
    throw WhisperInsufficientSpaceException(
      model.id,
      '${model.name}: needs $needed bytes of free space, $available free',
      requiredBytes: needed,
      availableBytes: available,
    );
  }

  /// Installs [model] from [input] when its size and SHA-1 match; null when
  /// they do not (or it cannot be read).
  Future<WhisperImportOutcome?> _importFile(
    WhisperCatalogModel model,
    _ImportInput input,
  ) async {
    final length = await input.length();
    if (length != null && length != model.size) return null;
    try {
      _checkSafe(model.id);
      // A download of the same model that is running finishes first; when
      // it fails, the file is installed instead.
      if (_installing[model.id] case final running?) {
        try {
          await running;
        } on Object {
          // Installed from the file below.
        }
      }
      if (await isInstalled(model)) {
        return WhisperImportOutcome(
          model: model,
          status: WhisperImportStatus.alreadyInstalled,
        );
      }
      await _exclusive(
        model,
        () => _installStaged(model, (staging) async {
          final target = File(p.join(staging.path, model.name));
          if (!await input.stage(this, model, target)) {
            throw const _NotTheModel();
          }
        }),
      );
      return WhisperImportOutcome(
        model: model,
        status: WhisperImportStatus.installed,
      );
    } on _NotTheModel {
      return null;
    } on Object catch (error) {
      return WhisperImportOutcome(
        model: model,
        status: WhisperImportStatus.failed,
        error: error,
      );
    }
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

  Map<String, Object?> _manifest(WhisperCatalogModel model) => {
    'schemaVersion': _manifestSchema,
    'id': model.id,
    'name': model.name,
    'size': model.size,
    'sha1': model.sha1,
  };

  Future<List<InstalledWhisperModel>> _scan() async {
    final directory = modelsDirectory;
    if (!directory.existsSync()) return const [];
    final models = <InstalledWhisperModel>[];
    await for (final entry in directory.list()) {
      if (entry is! Directory || p.basename(entry.path).startsWith('.')) {
        continue;
      }
      final model = await _readInstalled(entry);
      if (model != null) models.add(model);
    }
    models.sort((a, b) => a.id.compareTo(b.id));
    return models;
  }

  /// Null for anything that is not a complete install (ignored).
  Future<InstalledWhisperModel?> _readInstalled(Directory directory) async {
    final manifest = File(p.join(directory.path, manifestName));
    try {
      final json = jsonDecode(await manifest.readAsString());
      if (json is! Map<String, Object?> ||
          json['schemaVersion'] != _manifestSchema) {
        return null;
      }
      final id = json['id']! as String;
      final name = json['name']! as String;
      final size = json['size']! as int;
      final digest = json['sha1']! as String;
      if (p.basename(directory.path) != id || p.basename(name) != name) {
        return null;
      }
      final file = File(p.join(directory.path, name));
      if (await file.length() != size) return null;
      return InstalledWhisperModel(
        id: id,
        path: file.path,
        sizeBytes: size,
        sha1: digest,
      );
    } on Object {
      return null;
    }
  }

  /// The length of [file]; -1 when it cannot be read.
  static Future<int> _lengthOf(File file) async {
    try {
      return await file.length();
    } on FileSystemException {
      return -1;
    }
  }

  static void _checkSafe(String id) {
    if (!RegExp(r'^[a-z0-9][a-z0-9_.-]{0,31}$').hasMatch(id) ||
        id.contains('..')) {
      throw ArgumentError.value(id, 'id', 'Invalid model id');
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

/// An imported file did not match the model it was taken for.
final class _NotTheModel implements Exception {
  const new();
}

/// One file of an import: a local file or a [WhisperImportSource].
sealed class _ImportInput {
  /// The name it is matched by.
  String get name;

  /// The file in the import's result.
  File get file;

  /// Its size; -1 when it cannot be read, null when unknown.
  Future<int?> length();

  /// Writes [model]'s file from this input into [target] (in staging) and
  /// verifies it: false when it is not [model]'s file.
  Future<bool> stage(
    WhisperModelManager manager,
    WhisperCatalogModel model,
    File target,
  );
}

final class _FileInput extends _ImportInput {
  new(this.file);

  @override
  final File file;

  @override
  String get name => p.basename(file.path);

  @override
  Future<int?> length() => WhisperModelManager._lengthOf(file);

  @override
  Future<bool> stage(
    WhisperModelManager manager,
    WhisperCatalogModel model,
    File target,
  ) async {
    await manager._checkSpace(model, model.size);
    try {
      final copied = await manager.hashing.copyFile(
        file.path,
        target.path,
        maxBytes: model.size,
      );
      return WhisperModelManager._mismatch(model, copied) == null;
    } on FileSystemException catch (error) {
      // The file cannot be read: not the model (a full disk is a failure).
      if (error.path == file.path) return false;
      rethrow;
    }
  }
}

final class _SourceInput extends _ImportInput {
  new(this.source);

  final WhisperImportSource source;

  @override
  String get name => p.basename(source.name);

  @override
  File get file => File(source.name);

  @override
  Future<int?> length() async => source.length;

  @override
  Future<bool> stage(
    WhisperModelManager manager,
    WhisperCatalogModel model,
    File target,
  ) async {
    await manager._checkSpace(model, model.size);
    final written = await source.copyTo(target, maxBytes: model.size);
    if (written != model.size) return false;
    final digest = await manager.hashing.hashFile(
      target.path,
      maxBytes: model.size,
    );
    return WhisperModelManager._mismatch(model, digest) == null;
  }
}
