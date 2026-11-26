import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:llama_engine/src/catalog.dart';
import 'package:llama_engine/src/file_hashing.dart';
import 'package:llama_engine/src/model_source.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// A download or install of an on-device model failed.
sealed class LlamaModelInstallException implements Exception {
  const new(this.model, this.message, {this.mirror});

  /// The model id, e.g. `hy-mt2-1.8b-q4`.
  final String model;
  final String message;

  /// The mirror ([LlamaModelManager.mirror]) the failed download came
  /// from; null for the catalog's URL (Hugging Face) and for failures that
  /// are not a download's.
  final Uri? mirror;

  String get _name;

  @override
  String toString() => '$_name($model: $message)';
}

/// The file did not match the catalog's size or SHA-256 (corrupt,
/// truncated or tampered download). Nothing was installed.
final class LlamaChecksumException extends LlamaModelInstallException {
  const new(super.model, super.message, {super.mirror});

  @override
  String get _name => 'LlamaChecksumException';
}

/// The server answered with an error or the connection failed.
final class LlamaDownloadException extends LlamaModelInstallException {
  const new(super.model, super.message, {this.statusCode, super.mirror});

  final int? statusCode;

  @override
  String get _name => 'LlamaDownloadException';
}

/// The download was stopped with [LlamaModelManager.cancel]. What was
/// downloaded is kept, so the next [LlamaModelManager.install] resumes it.
final class LlamaDownloadCancelledException extends LlamaModelInstallException {
  const new(super.model, super.message, {super.mirror});

  @override
  String get _name => 'LlamaDownloadCancelledException';
}

/// There is not enough free storage for the model ([requiredBytes]: what
/// is left to download or copy plus a margin, see
/// [LlamaModelManager.requiredSpace]); nothing was downloaded or copied.
final class LlamaInsufficientSpaceException extends LlamaModelInstallException {
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
  String get _name => 'LlamaInsufficientSpaceException';
}

/// A file to import that is read through [copyTo] rather than from a path:
/// a document the user picked (an Android content URI), copied straight
/// into the manager's staging folder ([LlamaModelManager.importSources]),
/// so no other copy of a few GB is made first.
abstract interface class LlamaImportSource {
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

/// Progress of [LlamaModelManager.install].
@immutable
final class LlamaDownloadProgress {
  const new({
    required this.model,
    required this.receivedBytes,
    required this.totalBytes,
  });

  final LlamaCatalogModel model;

  /// Bytes on disk so far (resumed bytes count; includes companion mmproj when
  /// present).
  final int receivedBytes;

  /// [LlamaCatalogModel.totalSize] (main weights plus optional companion
  /// mmproj).
  final int totalBytes;

  double get fraction => totalBytes == 0 ? 1 : receivedBytes / totalBytes;
}

/// A model installed under `<root>/models/<id>/`.
@immutable
final class InstalledLlamaModel {
  const new({
    required this.id,
    required this.path,
    required this.sizeBytes,
    required this.sha256,
    this.projectorPath,
    this.projectorSizeBytes,
    this.projectorSha256,
  });

  /// [LlamaCatalogModel.id].
  final String id;

  /// Absolute path of the `.gguf` file (what the engine loads).
  final String path;

  /// Bytes of the main `.gguf` file on disk.
  final int sizeBytes;

  /// The SHA-256 the main file was verified against when it was installed.
  final String sha256;

  /// Absolute path of the companion multimodal projector (`.gguf` mmproj)
  /// file when installed alongside [path]; null for text-only models.
  final String? projectorPath;

  /// Bytes of the companion projector file on disk, when installed.
  final int? projectorSizeBytes;

  /// The SHA-256 the companion projector file was verified against, when
  /// installed.
  final String? projectorSha256;

  /// Whether a companion multimodal projector is installed for this model.
  bool get hasProjector => projectorPath != null;

  /// Combined installed size in bytes (main weights plus optional projector).
  int get totalSizeBytes => sizeBytes + (projectorSizeBytes ?? 0);

  /// Whether this is exactly [model] (same id, main file, and companion
  /// projector when [model] declares one).
  bool matches(LlamaCatalogModel model) {
    if (model.id != id || model.sha256 != sha256 || model.size != sizeBytes) {
      return false;
    }
    final mmproj = model.mmproj;
    if (mmproj == null) return true;
    return projectorPath != null &&
        projectorSha256 == mmproj.sha256 &&
        projectorSizeBytes == mmproj.size;
  }

  @override
  bool operator ==(Object other) =>
      other is InstalledLlamaModel &&
      other.id == id &&
      other.path == path &&
      other.sizeBytes == sizeBytes &&
      other.sha256 == sha256 &&
      other.projectorPath == projectorPath &&
      other.projectorSizeBytes == projectorSizeBytes &&
      other.projectorSha256 == projectorSha256;

  @override
  int get hashCode => Object.hash(
    id,
    path,
    sizeBytes,
    sha256,
    projectorPath,
    projectorSizeBytes,
    projectorSha256,
  );

  @override
  String toString() => 'InstalledLlamaModel($id)';
}

/// What [LlamaModelManager.importFiles] did with one catalog model.
enum LlamaImportStatus {
  /// The file was there and verified: the model is installed now.
  installed,

  /// This model was installed already (the file was not read).
  alreadyInstalled,

  /// A file named like the model's did not match the catalog's size and
  /// SHA-256 (damaged, truncated or another file); nothing was installed.
  checksumMismatch,

  /// Installing failed, e.g. on a full disk ([LlamaImportOutcome.error]).
  failed,
}

/// The result of [LlamaModelManager.importFiles] for one model.
@immutable
final class LlamaImportOutcome {
  const new({
    required this.model,
    required this.status,
    this.damaged = const [],
    this.error,
  });

  final LlamaCatalogModel model;
  final LlamaImportStatus status;

  /// Imported files named like [model]'s that did not match its checksum
  /// ([LlamaImportStatus.checksumMismatch]).
  final List<File> damaged;

  /// Why installing failed ([LlamaImportStatus.failed]).
  final Object? error;

  @override
  String toString() => 'LlamaImportOutcome(${model.id}, ${status.name})';
}

/// The result of [LlamaModelManager.importFiles].
@immutable
final class LlamaImportResult {
  const new({this.models = const [], this.unmatched = const []});

  /// One outcome per catalog model that an imported file belongs to, in
  /// catalog order.
  final List<LlamaImportOutcome> models;

  /// Imported files that belong to no catalog model.
  final List<File> unmatched;

  /// The models this import installed.
  List<LlamaCatalogModel> get installed => [
    for (final outcome in models)
      if (outcome.status == LlamaImportStatus.installed) outcome.model,
  ];
}

/// Downloads, verifies, installs and deletes on-device AI models (GGUF
/// files of one to a few GB) in an app-private directory ([root], passed
/// in by the app), like `WhisperModelManager` does for speech models.
///
/// Layout:
/// * `<root>/models/<id>/`: an installed model (the `.gguf` file plus
///   `manifest.json`). The directory appears atomically (a rename from
///   staging), so a model is either completely installed or absent.
/// * `<root>/models/.staging/`: models being installed.
/// * `<root>/models/.downloads/<id>/<file>.part`: downloads in progress,
///   with `<file>.part.source` naming where the bytes came from (URL and
///   checksum). Kept when a download is interrupted or [cancel]led and
///   resumed with an HTTP `Range` request next time, from the same URL
///   only (the bytes already on disk are hashed again, so the final
///   checksum covers the whole file); a download from another source (the
///   [mirror] changed, or the catalog's file) starts over.
///
/// Every download is checked against the catalog's size and SHA-256
/// before it is installed. The [http.Client] is injectable (tests use
/// `MockClient`; the app passes one that goes through its network
/// session). Files come from the catalog's URLs (Hugging Face, pinned to a
/// commit) or from a [mirror] of them ([llamaDownloadUrls]), which needs
/// no trust: the same checks apply. Whether a download is allowed (Wi-Fi
/// only, the device's memory, the privacy settings) is the app's decision:
/// this class downloads when asked. [importFiles] installs files copied to
/// the device by hand instead, through the same checks and staging,
/// without any network request ([importSources]: picked documents, copied
/// straight into staging).
///
/// Before a download or an import writes anything, the free space is
/// checked (with `freeSpace`): what is left to write plus a margin
/// ([requiredSpace]); too little fails with a
/// [LlamaInsufficientSpaceException]. A download goes to its `.part` file
/// and is renamed into place, so it needs room for the file once. Hashing
/// (a download's bytes as they arrive, the part of a resumed download, an
/// imported file) runs off the UI isolate ([hashing]).
class LlamaModelManager {
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

  /// App-private directory (e.g. `<support>/llm`).
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
  /// [llamaMirrorUrl]); null downloads from Hugging Face. Read when an
  /// [install] starts. A file that does not match the catalog fails with
  /// a [LlamaChecksumException] naming the mirror.
  Uri? mirror;

  /// Whether a file the [mirror] does not serve (an HTTP error or a failed
  /// connection) is downloaded from the catalog's URL instead. Without it,
  /// the install fails with a [LlamaDownloadException] naming the mirror.
  bool fallbackToDefault = false;

  final http.Client _client;
  final bool _ownsClient;
  final Map<String, Future<InstalledLlamaModel>> _installing = {};
  final Map<String, Completer<void>> _cancels = {};
  List<InstalledLlamaModel>? _installedCache;

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
  Future<List<InstalledLlamaModel>> installed() async =>
      _installedCache ??= List.unmodifiable(await _scan());

  /// The installed model with [id], if any.
  Future<InstalledLlamaModel?> installedModel(String id) async {
    for (final model in await installed()) {
      if (model.id == id) return model;
    }
    return null;
  }

  /// The path of the `.gguf` file of the installed model [id] (what the
  /// engine loads); null when it is not installed.
  Future<String?> pathOf(String id) async => (await installedModel(id))?.path;

  /// The path of the companion multimodal projector (`.gguf` mmproj) file of
  /// the installed model [id]; null when the model is not installed or has no
  /// projector.
  Future<String?> projectorPath(String id) async =>
      (await installedModel(id))?.projectorPath;

  /// Whether the installed model [id] has its companion multimodal projector
  /// installed on disk.
  Future<bool> isProjectorInstalled(String id) async =>
      (await projectorPath(id)) != null;

  /// Whether exactly [model] (same file, and projector when declared) is
  /// installed.
  Future<bool> isInstalled(LlamaCatalogModel model) async =>
      (await installedModel(model.id))?.matches(model) ?? false;

  /// Whether an [install] of the model [id] is running.
  bool isInstalling(String id) => _installing.containsKey(id);

  /// Bytes already downloaded of an interrupted download of [model] (0
  /// when none), including any companion projector partial download, which
  /// [install] resumes when it downloads from the same URL (else it starts
  /// over).
  Future<int> partialBytes(LlamaCatalogModel model) async {
    _checkSafe(model.id);
    var total = await _partialLength(_partFile(model.id, model.name));
    if (model.mmproj case final mmproj?) {
      total += await _partialLength(_partFile(model.id, mmproj.name));
    }
    return total;
  }

  static Future<int> _partialLength(File part) async {
    try {
      return part.existsSync() ? await part.length() : 0;
    } on FileSystemException {
      return 0;
    }
  }

  /// Throws a [LlamaInsufficientSpaceException] when a download of [model]
  /// would not fit now (what is left to download across the main weights and
  /// optional companion projector, plus a margin, see [requiredSpace]): for
  /// asking before anything else (a metered network prompt). [install] checks
  /// again. Passes without a `freeSpace`.
  Future<void> checkSpace(LlamaCatalogModel model) async {
    _checkSafe(model.id);
    final mainPart = _partFile(model.id, model.name);
    var existing = mainPart.existsSync()
        ? (await _lengthOf(mainPart)).clamp(0, model.size)
        : 0;
    if (model.mmproj case final mmproj?) {
      final projPart = _partFile(model.id, mmproj.name);
      existing += projPart.existsSync()
          ? (await _lengthOf(projPart)).clamp(0, mmproj.size)
          : 0;
    }
    await _checkSpace(
      model,
      model.totalSize - existing.clamp(0, model.totalSize),
    );
  }

  /// Downloads and installs [model], replacing another file installed
  /// under the same id. Returns at once when it is already installed.
  /// Concurrent calls for the same model share one download; [cancel]
  /// stops it with a [LlamaDownloadCancelledException].
  Future<InstalledLlamaModel> install(
    LlamaCatalogModel model, {
    void Function(LlamaDownloadProgress progress)? onProgress,
  }) => _exclusive(model, () => _install(model, onProgress));

  /// Stops the running [install] of the model [id], keeping what was
  /// downloaded for the next one to resume. Does nothing when none runs.
  void cancel(String id) {
    final signal = _cancels[id];
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  /// Installs models from files copied to the device by hand (downloaded
  /// elsewhere from [LlamaCatalogModel.url]), without any network request.
  ///
  /// Each of [files] is matched to a model of [catalog] by name (e.g.
  /// `Hy-MT2-1.8B-Q4_K_M.gguf`, ignoring case) or, for a renamed copy (e.g.
  /// `model (1).gguf`), by its exact size; it is then verified against the
  /// catalog's size and SHA-256 and installed through the same atomic
  /// rename as [install].
  ///
  /// [files] are only read and copied, never changed, unless [move]: then
  /// a verified file is moved into place instead of copied when it is on
  /// the same file system (for temporary copies such as a file picker's,
  /// which saves writing a few GB again). A copy needs free space for the
  /// file (else a [LlamaInsufficientSpaceException] for that model).
  /// Problems with a file or a model do not throw: they are reported in
  /// the [LlamaImportResult].
  Future<LlamaImportResult> importFiles(
    Iterable<File> files, {
    required LlamaModelCatalog catalog,
    bool move = false,
  }) => _import([
    for (final file in files) _FileInput(file, move: move),
  ], catalog);

  /// Installs models from [sources] (documents the user picked) like
  /// [importFiles], without any network request: each one is copied
  /// straight into the staging folder ([LlamaImportSource.copyTo], after
  /// the free-space check), verified there and moved into place, so no
  /// other copy of it is made. A source of unknown length is matched by
  /// name only. In the result, [LlamaImportOutcome.damaged] and
  /// [LlamaImportResult.unmatched] hold a [File] named like the source
  /// (not a path on this device).
  Future<LlamaImportResult> importSources(
    Iterable<LlamaImportSource> sources, {
    required LlamaModelCatalog catalog,
  }) => _import([for (final source in sources) _SourceInput(source)], catalog);

  Future<LlamaImportResult> _import(
    List<_ImportInput> inputs,
    LlamaModelCatalog catalog,
  ) async {
    final named = <LlamaCatalogModel, List<_ImportInput>>{};
    final sized = <LlamaCatalogModel, List<_ImportInput>>{};
    final namedProj = <LlamaCatalogModel, List<_ImportInput>>{};
    final sizedProj = <LlamaCatalogModel, List<_ImportInput>>{};
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
      final byProjName = catalog.models
          .where((model) => model.mmproj?.name.toLowerCase() == name)
          .firstOrNull;
      if (byProjName != null) {
        (namedProj[byProjName] ??= []).add(input);
        continue;
      }
      final length = await input.length();
      final bySize = catalog.models
          .where((model) => model.size == length)
          .firstOrNull;
      if (bySize != null) {
        (sized[bySize] ??= []).add(input);
        continue;
      }
      final byProjSize = catalog.models
          .where((model) => model.mmproj?.size == length)
          .firstOrNull;
      if (byProjSize != null) {
        (sizedProj[byProjSize] ??= []).add(input);
      } else {
        unmatched.add(input.file);
      }
    }

    final outcomes = <LlamaImportOutcome>[];
    for (final model in catalog.models) {
      final candidates = [...?named[model], ...?sized[model]];
      final projCandidates = [...?namedProj[model], ...?sizedProj[model]];
      if (candidates.isEmpty && projCandidates.isEmpty) continue;
      if (await isInstalled(model)) {
        outcomes.add(
          LlamaImportOutcome(
            model: model,
            status: LlamaImportStatus.alreadyInstalled,
          ),
        );
        continue;
      }
      final damaged = <File>[];
      LlamaImportOutcome? outcome;
      if (model.mmproj case final mmproj?) {
        if (candidates.isEmpty) {
          // Only a projector file was supplied without the main weights.
          for (final input in projCandidates) {
            if (namedProj[model]?.contains(input) ?? false) {
              damaged.add(input.file);
            } else {
              unmatched.add(input.file);
            }
          }
          if (damaged.isNotEmpty) {
            outcomes.add(
              LlamaImportOutcome(
                model: model,
                status: LlamaImportStatus.failed,
                damaged: List.unmodifiable(damaged),
                error: StateError(
                  'Missing main model file ${model.name} for ${mmproj.name}',
                ),
              ),
            );
          }
          continue;
        }
        outcome = await _importWithProjector(
          model,
          mmproj,
          candidates: candidates,
          namedMain: named[model] ?? const [],
          projCandidates: projCandidates,
          namedProj: namedProj[model] ?? const [],
          damaged: damaged,
          unmatched: unmatched,
        );
      } else {
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
      }
      if (outcome != null) {
        outcomes.add(outcome);
      } else if (damaged.isNotEmpty) {
        outcomes.add(
          LlamaImportOutcome(
            model: model,
            status: LlamaImportStatus.checksumMismatch,
            damaged: List.unmodifiable(damaged),
          ),
        );
      }
    }
    return LlamaImportResult(
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

  /// Deletes every installed model and partial download: the whole
  /// [modelsDirectory] ("Delete all local data"). Running installs are
  /// cancelled first. Throws a [FileSystemException] when something could
  /// not be deleted.
  Future<void> deleteAll() async {
    [..._installing.keys].forEach(cancel);
    for (final running in [..._installing.values]) {
      try {
        await running;
      } on Object {
        // Cancelled or failed: deleted below either way.
      }
    }
    _installedCache = null;
    final directory = modelsDirectory;
    if (directory.existsSync()) await directory.delete(recursive: true);
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

  File _partFile(String modelId, String fileName) =>
      File(p.join(_downloadsDirectory.path, modelId, '$fileName.part'));

  /// Where the bytes of [_partFile] came from (see [_PartSource]).
  File _sourceFile(String modelId, String fileName) =>
      File('${_partFile(modelId, fileName).path}.source');

  Future<void> _deletePart(String modelId, String fileName) async {
    await _deleteQuietly(_partFile(modelId, fileName));
    await _deleteQuietly(_sourceFile(modelId, fileName));
  }

  Future<InstalledLlamaModel> _install(
    LlamaCatalogModel model,
    void Function(LlamaDownloadProgress progress)? onProgress,
  ) async {
    _checkSafe(model.id);
    final current = await installedModel(model.id);
    if (current != null && current.matches(model)) return current;

    final totalBytes = model.totalSize;
    void report(int bytes) => onProgress?.call(
      LlamaDownloadProgress(
        model: model,
        receivedBytes: bytes,
        totalBytes: totalBytes,
      ),
    );

    final cancelled = _cancels[model.id] = Completer<void>();
    try {
      // A resumed download needs room for the rest; one that starts over
      // deletes the part first.
      await checkSpace(model);
      final mainSpec = _FileDownloadSpec.main(model);
      final downloaded = await _downloadFile(
        mainSpec,
        report,
        cancelled.future,
        mirror: mirror,
        fallbackToDefault: fallbackToDefault,
      );
      File? downloadedProjector;
      if (model.mmproj case final mmproj?) {
        final projSpec = _FileDownloadSpec.projector(model.id, mmproj);
        downloadedProjector = await _downloadFile(
          projSpec,
          (projBytes) => report(model.size + projBytes),
          cancelled.future,
          mirror: mirror,
          fallbackToDefault: fallbackToDefault,
        );
      }
      return await _installStaged(model, (staging) async {
        await downloaded.rename(p.join(staging.path, model.name));
        if (downloadedProjector case final proj?) {
          await proj.rename(p.join(staging.path, model.mmproj!.name));
        }
      });
    } finally {
      if (identical(_cancels[model.id], cancelled)) _cancels.remove(model.id);
    }
  }

  /// Runs [run] (installing [model]) unless an install of the same model is
  /// already running, which is then shared.
  Future<InstalledLlamaModel> _exclusive(
    LlamaCatalogModel model,
    Future<InstalledLlamaModel> Function() run,
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
  Future<InstalledLlamaModel> _installStaged(
    LlamaCatalogModel model,
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

  /// Downloads [spec] into its `.part` file (resuming a partial download
  /// from the same URL) from [mirror] or the catalog's URL and verifies its
  /// size and SHA-256. Stops with a [LlamaDownloadCancelledException] when
  /// [cancelled] completes.
  Future<File> _downloadFile(
    _FileDownloadSpec spec,
    void Function(int bytes) report,
    Future<void> cancelled, {
    Uri? mirror,
    bool fallbackToDefault = false,
  }) async {
    final part = _partFile(spec.modelId, spec.name);
    await part.parent.create(recursive: true);
    var existing = part.existsSync() ? part.lengthSync() : 0;
    if (existing > spec.size) {
      await _deletePart(spec.modelId, spec.name);
      existing = 0;
    }
    // Where the bytes on disk came from; null when unknown (then they are
    // only used when complete: the checksum decides).
    final recorded = existing > 0
        ? await _PartSource.read(_sourceFile(spec.modelId, spec.name), spec)
        : null;

    var received = 0;
    // The mirror the bytes come from (null: the catalog's URL).
    var source = recorded?.mirror;
    final FileDigest digest;

    if (existing < spec.size) {
      final (response, from, resumed) = await _request(
        spec,
        existing,
        recorded,
        cancelled,
        mirror: mirror,
        fallbackToDefault: fallbackToDefault,
      );
      source = from.mirror;
      final StreamHasher hasher;
      try {
        hasher = await hashing.stream();
        // An isolate that cannot start: the download fails like an
        // interrupted one.
        // coverage:ignore-start
      } on Object catch (error) {
        unawaited(response.stream.listen(null).cancel());
        throw LlamaDownloadException(
          spec.modelId,
          '${spec.name}${_from(source)}: $error',
          mirror: source,
        );
      }
      // coverage:ignore-end
      try {
        if (resumed) {
          // The same source as the bytes on disk: hash them (in the
          // background), then append.
          received = await hasher.addFile(part.path);
        } else {
          // From the start: no byte of another source is kept.
          try {
            await _deletePart(spec.modelId, spec.name);
            await from.write(_sourceFile(spec.modelId, spec.name), spec);
          } on Object catch (error) {
            unawaited(response.stream.listen(null).cancel());
            throw LlamaDownloadException(
              spec.modelId,
              '${spec.name}${_from(source)}: $error',
              mirror: source,
            );
          }
        }
        report(received);
        final sink = part.openWrite(
          mode: resumed ? FileMode.writeOnlyAppend : FileMode.writeOnly,
        );
        try {
          final chunks = _untilCancelled(
            response.stream.timeout(requestTimeout),
            cancelled,
          );
          await for (final chunk in chunks) {
            received += chunk.length;
            if (received > spec.size) {
              throw LlamaChecksumException(
                spec.modelId,
                '${spec.name}${_from(source)}: more than ${spec.size} bytes',
                mirror: source,
              );
            }
            sink.add(chunk);
            await hasher.add(chunk);
            report(received);
          }
        } on LlamaChecksumException {
          await sink.close();
          await _deletePart(spec.modelId, spec.name);
          rethrow;
        } on _Cancelled {
          // Stopped by the user: keep the part for resuming.
          await sink.close();
          throw LlamaDownloadCancelledException(
            spec.modelId,
            '${spec.name}${_from(source)}: cancelled',
            mirror: source,
          );
        } on Object catch (error) {
          // Interrupted: keep the part for resuming.
          await sink.close();
          throw LlamaDownloadException(
            spec.modelId,
            '${spec.name}${_from(source)}: $error',
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

    if (_mismatchSpec(spec, digest) case final mismatch?) {
      await _deletePart(spec.modelId, spec.name);
      throw LlamaChecksumException(
        spec.modelId,
        '${spec.name}${_from(source)}: $mismatch',
        mirror: source,
      );
    }
    return part;
  }

  /// Null when [digest] matches [expectedSize] and [expectedSha256], else what
  /// differs.
  static String? _mismatchValues(
    int expectedSize,
    String expectedSha256,
    FileDigest digest,
  ) => digest.size == expectedSize && digest.sha256 == expectedSha256
      ? null
      : 'got ${digest.size} bytes with SHA-256 ${digest.sha256}, '
            'expected $expectedSize bytes with SHA-256 $expectedSha256';

  static String? _mismatchSpec(_FileDownloadSpec spec, FileDigest digest) =>
      _mismatchValues(spec.size, spec.sha256, digest);

  /// Sends the request for [spec] to each URL in turn until one answers with
  /// its contents.
  Future<(http.StreamedResponse, _PartSource, bool)> _request(
    _FileDownloadSpec spec,
    int existing,
    _PartSource? recorded,
    Future<void> cancelled, {
    required Uri? mirror,
    required bool fallbackToDefault,
  }) async {
    final urls = spec.downloadUrls(
      mirror: mirror,
      fallbackToDefault: fallbackToDefault,
    );
    var resumeFromStart = false;
    for (var i = 0; ; i++) {
      final url = urls[i];
      final source = i == 0 ? mirror : null;
      final origin = _PartSource(url: url, mirror: source);
      final last = i == urls.length - 1;
      final offset = !resumeFromStart && existing > 0 && origin.sameAs(recorded)
          ? existing
          : 0;
      resumeFromStart = false;
      final request = http.Request('GET', url);
      if (offset > 0) request.headers['Range'] = 'bytes=$offset-';
      final http.StreamedResponse response;
      final sent = _client.send(request).timeout(requestTimeout);
      final stopped = cancelled.then<http.StreamedResponse?>((_) => null);
      try {
        final answer = await Future.any<http.StreamedResponse?>([
          sent,
          stopped,
        ]);
        if (answer == null) {
          // Release the connection once the answer arrives.
          unawaited(
            sent.then(
              (response) => response.stream.listen(null).cancel(),
              onError: (Object _) {},
            ),
          );
          throw LlamaDownloadCancelledException(
            spec.modelId,
            '${spec.name}${_from(source)}: cancelled',
            mirror: source,
          );
        }
        response = answer;
      } on LlamaDownloadCancelledException {
        rethrow;
      } on Object catch (error) {
        if (!last) continue;
        throw LlamaDownloadException(
          spec.modelId,
          '${spec.name}${_from(source)}: $error',
          mirror: source,
        );
      }
      final status = response.statusCode;
      if (status == 200) return (response, origin, false);
      final partial = status == 206 && offset > 0;
      if (partial && _rangeStart(response, spec.size) == offset) {
        return (response, origin, true);
      }
      // Drain so the connection can be reused.
      await response.stream.drain<void>().catchError((_) {});
      if (partial) {
        // Not the bytes that were asked for: the whole file, again.
        resumeFromStart = true;
        i--;
        continue;
      }
      if (last) {
        throw LlamaDownloadException(
          spec.modelId,
          'HTTP $status for $url',
          statusCode: status,
          mirror: source,
        );
      }
    }
  }

  /// The first byte of a 206 [response] (`Content-Range: bytes F-L/T`),
  /// or null when the header is missing, malformed or for a file of
  /// another size than [expectedSize].
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

  /// [source] until [cancelled] completes: then the subscription to
  /// [source] is cancelled (which aborts the download) and the stream ends
  /// with a [_Cancelled] error.
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
          cancelled.then((_) async {
            if (controller.isClosed) return;
            final running = subscription;
            subscription = null;
            // Not awaited: a stalled source may never answer.
            if (running != null) unawaited(running.cancel());
            controller.addError(const _Cancelled());
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

  /// ` from the mirror <mirror>` for a download from [mirror], else empty.
  static String _from(Uri? mirror) =>
      mirror == null ? '' : ' from the mirror $mirror';

  /// Throws a [LlamaInsufficientSpaceException] when the file system of
  /// [modelsDirectory] has less free space than writing [bytes] for
  /// [model] needs ([requiredSpace]). Nothing to write, or an unknown free
  /// space, passes.
  Future<void> _checkSpace(LlamaCatalogModel model, int bytes) async {
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
    throw LlamaInsufficientSpaceException(
      model.id,
      '${model.name}: needs $needed bytes of free space, $available free',
      requiredBytes: needed,
      availableBytes: available,
    );
  }

  /// Installs [model] and its companion [mmproj] when both files are supplied
  /// and match their catalog size and SHA-256.
  Future<LlamaImportOutcome?> _importWithProjector(
    LlamaCatalogModel model,
    LlamaProjectorFile mmproj, {
    required List<_ImportInput> candidates,
    required List<_ImportInput> namedMain,
    required List<_ImportInput> projCandidates,
    required List<_ImportInput> namedProj,
    required List<File> damaged,
    required List<File> unmatched,
  }) async {
    if (projCandidates.isEmpty) {
      return LlamaImportOutcome(
        model: model,
        status: LlamaImportStatus.failed,
        error: StateError(
          'Missing vision projector file ${mmproj.name} for ${model.id}',
        ),
      );
    }
    try {
      _checkSafe(model.id);
      if (_installing[model.id] case final running?) {
        try {
          await running;
        } on Object {
          // Installed from the files below.
        }
      }
      if (await isInstalled(model)) {
        return LlamaImportOutcome(
          model: model,
          status: LlamaImportStatus.alreadyInstalled,
        );
      }
      await _exclusive(
        model,
        () => _installStaged(model, (staging) async {
          var mainOk = false;
          for (final input in candidates) {
            final length = await input.length();
            if (length != null && length != model.size) {
              if (namedMain.contains(input)) {
                damaged.add(input.file);
              } else {
                unmatched.add(input.file);
              }
              continue;
            }
            final target = File(p.join(staging.path, model.name));
            if (await input.stage(
              this,
              model,
              target,
              expectedSize: model.size,
              expectedSha256: model.sha256,
            )) {
              mainOk = true;
              break;
            }
            if (namedMain.contains(input)) {
              damaged.add(input.file);
            } else {
              unmatched.add(input.file);
            }
          }
          if (!mainOk) throw const _NotTheModel();

          var projOk = false;
          for (final input in projCandidates) {
            final length = await input.length();
            if (length != null && length != mmproj.size) {
              if (namedProj.contains(input)) {
                damaged.add(input.file);
              } else {
                unmatched.add(input.file);
              }
              continue;
            }
            final target = File(p.join(staging.path, mmproj.name));
            if (await input.stage(
              this,
              model,
              target,
              expectedSize: mmproj.size,
              expectedSha256: mmproj.sha256,
            )) {
              projOk = true;
              break;
            }
            if (namedProj.contains(input)) {
              damaged.add(input.file);
            } else {
              unmatched.add(input.file);
            }
          }
          if (!projOk) throw const _NotTheModel();
        }),
      );
      return LlamaImportOutcome(
        model: model,
        status: LlamaImportStatus.installed,
      );
    } on _NotTheModel {
      return null;
    } on Object catch (error) {
      return LlamaImportOutcome(
        model: model,
        status: LlamaImportStatus.failed,
        error: error,
      );
    }
  }

  /// Installs [model] from [input] when its size and SHA-256 match; null
  /// when they do not (or it cannot be read).
  Future<LlamaImportOutcome?> _importFile(
    LlamaCatalogModel model,
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
        return LlamaImportOutcome(
          model: model,
          status: LlamaImportStatus.alreadyInstalled,
        );
      }
      await _exclusive(
        model,
        () => _installStaged(model, (staging) async {
          final target = File(p.join(staging.path, model.name));
          if (!await input.stage(
            this,
            model,
            target,
            expectedSize: model.size,
            expectedSha256: model.sha256,
          )) {
            throw const _NotTheModel();
          }
        }),
      );
      return LlamaImportOutcome(
        model: model,
        status: LlamaImportStatus.installed,
      );
    } on _NotTheModel {
      return null;
    } on Object catch (error) {
      return LlamaImportOutcome(
        model: model,
        status: LlamaImportStatus.failed,
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

  Map<String, Object?> _manifest(LlamaCatalogModel model) => {
    'schemaVersion': _manifestSchema,
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
  };

  Future<List<InstalledLlamaModel>> _scan() async {
    final directory = modelsDirectory;
    if (!directory.existsSync()) return const [];
    final models = <InstalledLlamaModel>[];
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
  Future<InstalledLlamaModel?> _readInstalled(Directory directory) async {
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
      final digest = json['sha256']! as String;
      if (p.basename(directory.path) != id || p.basename(name) != name) {
        return null;
      }
      final file = File(p.join(directory.path, name));
      if (await file.length() != size) return null;

      String? projectorPath;
      int? projectorSize;
      String? projectorSha256;
      if (json['mmproj'] case final Map<String, Object?> mmprojJson) {
        final projName = mmprojJson['name']! as String;
        final projSize = mmprojJson['size']! as int;
        final projSha = mmprojJson['sha256']! as String;
        if (p.basename(projName) != projName) return null;
        final projFile = File(p.join(directory.path, projName));
        if (await projFile.length() != projSize) return null;
        projectorPath = projFile.path;
        projectorSize = projSize;
        projectorSha256 = projSha;
      }
      return InstalledLlamaModel(
        id: id,
        path: file.path,
        sizeBytes: size,
        sha256: digest,
        projectorPath: projectorPath,
        projectorSizeBytes: projectorSize,
        projectorSha256: projectorSha256,
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
    if (!LlamaCatalogModel.isSafeId(id)) {
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

/// One file belonging to a catalog model (either the main `.gguf` weights or
/// its companion multimodal projector `.gguf`).
@immutable
final class _FileDownloadSpec {
  const new({
    required this.modelId,
    required this.name,
    required this.size,
    required this.sha256,
    required this.downloadUrls,
  });

  factory main(LlamaCatalogModel model) => _FileDownloadSpec(
    modelId: model.id,
    name: model.name,
    size: model.size,
    sha256: model.sha256,
    downloadUrls: ({mirror, fallbackToDefault = false}) => llamaDownloadUrls(
      model,
      mirror: mirror,
      fallbackToDefault: fallbackToDefault,
    ),
  );

  factory projector(String modelId, LlamaProjectorFile projector) =>
      _FileDownloadSpec(
        modelId: modelId,
        name: projector.name,
        size: projector.size,
        sha256: projector.sha256,
        downloadUrls: ({mirror, fallbackToDefault = false}) =>
            llamaProjectorDownloadUrls(
              projector,
              mirror: mirror,
              fallbackToDefault: fallbackToDefault,
            ),
      );

  final String modelId;
  final String name;
  final int size;
  final String sha256;
  final List<Uri> Function({Uri? mirror, bool fallbackToDefault}) downloadUrls;
}

/// Where the bytes of a partial download came from: the URL, and the
/// mirror it belongs to (null: the catalog's URL). Stored next to the
/// `.part` file with the catalog's size and SHA-256 of the file, so a
/// download is only resumed from the source that sent its first bytes.
@immutable
final class _PartSource {
  const new({required this.url, required this.mirror});

  final Uri url;
  final Uri? mirror;

  /// Whether [other] is this source.
  bool sameAs(_PartSource? other) => other != null && other.url == url;

  Future<void> write(File file, _FileDownloadSpec spec) => file.writeAsString(
    jsonEncode({
      'url': url.toString(),
      'mirror': mirror?.toString(),
      'size': spec.size,
      'sha256': spec.sha256,
    }),
    flush: true,
  );

  /// The source recorded in [file] for [spec]'s file; null when there is
  /// none (or it cannot be read, or it was for another file).
  static Future<_PartSource?> read(File file, _FileDownloadSpec spec) async {
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is! Map<String, Object?> ||
          json['size'] != spec.size ||
          json['sha256'] != spec.sha256) {
        return null;
      }
      final mirror = json['mirror'];
      return _PartSource(
        url: Uri.parse(json['url']! as String),
        mirror: mirror is String ? Uri.parse(mirror) : null,
      );
    } on Object {
      return null;
    }
  }
}

/// An imported file did not match the model it was taken for.
final class _NotTheModel implements Exception {
  const new();
}

/// [LlamaModelManager.cancel] stopped a download.
final class _Cancelled implements Exception {
  const new();
}

/// One file of an import: a local file or an [LlamaImportSource].
sealed class _ImportInput {
  /// The name it is matched by.
  String get name;

  /// The file in the import's result.
  File get file;

  /// Its size; -1 when it cannot be read, null when unknown.
  Future<int?> length();

  /// Writes a model or projector file from this input into [target] (in
  /// staging) and verifies it against [expectedSize] and [expectedSha256].
  Future<bool> stage(
    LlamaModelManager manager,
    LlamaCatalogModel model,
    File target, {
    required int expectedSize,
    required String expectedSha256,
  });
}

final class _FileInput extends _ImportInput {
  new(this.file, {required this.move});

  @override
  final File file;

  /// Whether a verified file is moved instead of copied.
  final bool move;

  @override
  String get name => p.basename(file.path);

  @override
  Future<int?> length() => LlamaModelManager._lengthOf(file);

  @override
  Future<bool> stage(
    LlamaModelManager manager,
    LlamaCatalogModel model,
    File target, {
    required int expectedSize,
    required String expectedSha256,
  }) async {
    final hashing = manager.hashing;
    try {
      if (move) {
        final digest = await hashing.hashFile(
          file.path,
          maxBytes: expectedSize,
        );
        if (LlamaModelManager._mismatchValues(
              expectedSize,
              expectedSha256,
              digest,
            ) !=
            null) {
          return false;
        }
        try {
          await file.rename(target.path);
          return true;
        } on FileSystemException {
          // Another file system: copied (and hashed again) below.
        }
      }
      await manager._checkSpace(model, expectedSize);
      final copied = await hashing.copyFile(
        file.path,
        target.path,
        maxBytes: expectedSize,
      );
      return LlamaModelManager._mismatchValues(
            expectedSize,
            expectedSha256,
            copied,
          ) ==
          null;
    } on FileSystemException catch (error) {
      // The file cannot be read: not the model (a full disk is a failure).
      if (error.path == file.path) return false;
      rethrow;
    }
  }
}

final class _SourceInput extends _ImportInput {
  new(this.source);

  final LlamaImportSource source;

  @override
  String get name => p.basename(source.name);

  @override
  File get file => File(source.name);

  @override
  Future<int?> length() async => source.length;

  @override
  Future<bool> stage(
    LlamaModelManager manager,
    LlamaCatalogModel model,
    File target, {
    required int expectedSize,
    required String expectedSha256,
  }) async {
    await manager._checkSpace(model, expectedSize);
    final written = await source.copyTo(target, maxBytes: expectedSize);
    if (written != expectedSize) return false;
    final digest = await manager.hashing.hashFile(
      target.path,
      maxBytes: expectedSize,
    );
    return LlamaModelManager._mismatchValues(
          expectedSize,
          expectedSha256,
          digest,
        ) ==
        null;
  }
}
