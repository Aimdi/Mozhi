import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:tesseract_ocr/src/catalog.dart';

/// A download or install of language data failed.
sealed class TessdataInstallException implements Exception {
  const new(this.language, this.message);

  /// The Tesseract code, e.g. `deu`.
  final String language;
  final String message;

  String get _name;

  @override
  String toString() => '$_name($language: $message)';
}

/// A file did not match the catalog's size or SHA-256 (corrupt or tampered
/// download). Nothing was installed.
final class TessdataChecksumException extends TessdataInstallException {
  const new(super.language, super.message);

  @override
  String get _name => 'TessdataChecksumException';
}

/// The server answered with an error or the connection failed.
final class TessdataDownloadException extends TessdataInstallException {
  const new(super.language, super.message, {this.statusCode});

  final int? statusCode;

  @override
  String get _name => 'TessdataDownloadException';
}

/// Progress of [TessdataManager.install].
@immutable
final class TessdataDownloadProgress {
  const new({
    required this.language,
    required this.receivedBytes,
    required this.totalBytes,
  });

  final TessdataLanguage language;

  /// Bytes received so far (resumed bytes count).
  final int receivedBytes;

  /// [TessdataLanguage.size].
  final int totalBytes;

  double get fraction => totalBytes == 0 ? 1 : receivedBytes / totalBytes;
}

/// Language data installed in [TessdataManager.dataDirectory].
@immutable
final class InstalledTessdata {
  const new({
    required this.code,
    required this.path,
    required this.sizeBytes,
    required this.sha256,
  });

  /// Tesseract code, e.g. `deu`.
  final String code;

  /// Absolute path of `<code>.traineddata`.
  final String path;

  /// Bytes on disk.
  final int sizeBytes;

  /// SHA-256 the file was verified with when it was installed (compare
  /// with the catalog's to see whether a newer version exists).
  final String sha256;

  @override
  bool operator ==(Object other) =>
      other is InstalledTessdata &&
      other.code == code &&
      other.path == path &&
      other.sizeBytes == sizeBytes &&
      other.sha256 == sha256;

  @override
  int get hashCode => Object.hash(code, path, sizeBytes, sha256);

  @override
  String toString() => 'InstalledTessdata($code)';
}

/// What [TessdataManager.importFiles] did with one language.
enum TessdataImportStatus {
  /// A file was verified and installed.
  installed,

  /// This version was installed already (the files were not read again).
  alreadyInstalled,

  /// A file named like the language's did not match the catalog's size
  /// and SHA-256 (damaged, truncated or another version:
  /// [TessdataImportOutcome.damaged]); nothing was installed.
  checksumMismatch,

  /// Installing failed, e.g. on a full disk ([TessdataImportOutcome.error]).
  failed,
}

/// The result of [TessdataManager.importFiles] for one language.
@immutable
final class TessdataImportOutcome {
  const new({
    required this.language,
    required this.status,
    this.damaged = const [],
    this.error,
  });

  final TessdataLanguage language;
  final TessdataImportStatus status;

  /// Imported files named like [language]'s that did not match its
  /// checksum ([TessdataImportStatus.checksumMismatch]).
  final List<File> damaged;

  /// Why installing failed ([TessdataImportStatus.failed], or a
  /// [TessdataChecksumException] found while installing).
  final Object? error;

  @override
  String toString() =>
      'TessdataImportOutcome(${language.code}, ${status.name})';
}

/// The result of [TessdataManager.importFiles].
@immutable
final class TessdataImportResult {
  const new({this.languages = const [], this.unmatched = const []});

  /// One outcome per catalog language that an imported file belongs to,
  /// sorted by code.
  final List<TessdataImportOutcome> languages;

  /// Imported files that belong to no catalog language.
  final List<File> unmatched;

  /// The languages this import installed.
  List<TessdataLanguage> get installed => [
    for (final outcome in languages)
      if (outcome.status == TessdataImportStatus.installed) outcome.language,
  ];
}

/// Downloads, verifies, installs and deletes Tesseract language data in an
/// app-private directory ([root], passed in by the app). Mirrors the
/// offline translation models' manager (`bergamot_translator`), with one
/// uncompressed file per language.
///
/// Layout:
/// * `<root>/tessdata/<code>.traineddata`: installed data, the directory
///   Tesseract reads ([dataDirectory]); next to each file
///   `<code>.json` records its size and SHA-256. A file appears with an
///   atomic rename once it is verified, so Tesseract never sees a partial
///   one; a file without its record is not installed (and removed by
///   [cleanUp]).
/// * `<root>/.downloads/<code>.traineddata.part`: downloads in progress.
///   Kept when a download is interrupted and resumed with an HTTP `Range`
///   request next time (the bytes already on disk are hashed again, so
///   the final SHA-256 check covers the whole file).
/// * `<root>/.staging/`: records and imported copies being written.
///
/// Every download is checked against the catalog's size and SHA-256 before
/// it is installed. The [http.Client] is injectable (tests use
/// `MockClient`). [importFiles] installs files copied to the device by
/// hand instead, through the same checks, without any network request.
class TessdataManager {
  new({
    required this.root,
    http.Client? httpClient,
    this.requestTimeout = const Duration(seconds: 60),
  }) : _client = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  /// App-private directory (e.g. `<support>/tesseract`).
  final Directory root;

  /// Maximum wait for response headers and between chunks of a download.
  final Duration requestTimeout;

  final http.Client _client;
  final bool _ownsClient;
  final Map<String, Future<InstalledTessdata>> _installing = {};
  List<InstalledTessdata>? _installedCache;

  static const _recordSchema = 1;
  static const _extension = '.traineddata';

  /// `<root>/tessdata`: the data path Tesseract is given.
  Directory get dataDirectory => Directory(p.join(root.path, 'tessdata'));

  Directory get _downloadsDirectory =>
      Directory(p.join(root.path, '.downloads'));

  Directory get _stagingDirectory => Directory(p.join(root.path, '.staging'));

  /// Every installed language, sorted by code.
  Future<List<InstalledTessdata>> installed() async =>
      _installedCache ??= List.unmodifiable(await _scan());

  /// The installed data for [code], if any (any version).
  Future<InstalledTessdata?> installedLanguage(String code) async {
    for (final language in await installed()) {
      if (language.code == code) return language;
    }
    return null;
  }

  /// Whether exactly [language] (same SHA-256) is installed.
  Future<bool> isInstalled(TessdataLanguage language) async =>
      (await installedLanguage(language.code))?.sha256 == language.sha256;

  /// Bytes used by installed data.
  Future<int> totalSize() async => (await installed()).fold<int>(
    0,
    (sum, language) => sum + language.sizeBytes,
  );

  /// Downloads and installs [language], replacing another version of it.
  /// Returns at once when it is already installed. Concurrent calls for the
  /// same language share one download.
  Future<InstalledTessdata> install(
    TessdataLanguage language, {
    void Function(TessdataDownloadProgress progress)? onProgress,
  }) => _exclusive(language, () => _install(language, onProgress));

  /// Installs language data from files copied to the device by hand
  /// (downloaded elsewhere from [TessdataLanguage.url]), without any
  /// network request.
  ///
  /// Each of [files] is matched to a language of [catalog] by name
  /// (`<code>.traineddata`, ignoring case), a renamed copy (e.g.
  /// `deu (1).traineddata`) by its size and SHA-256. A named file must
  /// match the catalog's size and SHA-256. A verified file is copied into
  /// staging (and checked again while copying) and installed with the same
  /// atomic rename as [install], replacing another version.
  ///
  /// [files] are only read, never moved or deleted. Problems with a file
  /// do not throw: they are reported in the [TessdataImportResult].
  Future<TessdataImportResult> importFiles(
    Iterable<File> files, {
    required TessdataCatalog catalog,
  }) async {
    final bySize = <int, List<TessdataLanguage>>{};
    for (final language in catalog.languages) {
      (bySize[language.size] ??= []).add(language);
    }
    final current = {
      for (final language in await installed()) language.code: language.sha256,
    };
    bool isCurrent(TessdataLanguage language) =>
        current[language.code] == language.sha256;

    final touched = <TessdataLanguage>{};
    final verified = <TessdataLanguage, File>{};
    final damaged = <TessdataLanguage, List<File>>{};
    final unmatched = <File>[];

    for (final input in files) {
      final named = catalog.byCode(_importCode(input.path));
      if (named != null) {
        touched.add(named);
        if (isCurrent(named) || verified.containsKey(named)) continue;
        if (await _matches(input, named)) {
          verified[named] = input;
        } else {
          (damaged[named] ??= []).add(input);
        }
        continue;
      }
      // A renamed copy: a catalog file with its size and SHA-256.
      final candidates = bySize[await _lengthOf(input)];
      final fingerprint = candidates == null ? null : await _sha256Of(input);
      final match = candidates
          ?.where((language) => language.sha256 == fingerprint)
          .firstOrNull;
      if (match == null) {
        unmatched.add(input);
        continue;
      }
      touched.add(match);
      if (!isCurrent(match)) verified.putIfAbsent(match, () => input);
    }

    final outcomes = <TessdataImportOutcome>[];
    for (final language
        in touched.toList()..sort((a, b) => a.code.compareTo(b.code))) {
      if (isCurrent(language)) {
        outcomes.add(
          TessdataImportOutcome(
            language: language,
            status: TessdataImportStatus.alreadyInstalled,
          ),
        );
        continue;
      }
      final file = verified[language];
      if (file == null) {
        outcomes.add(
          TessdataImportOutcome(
            language: language,
            status: TessdataImportStatus.checksumMismatch,
            damaged: List.unmodifiable(damaged[language] ?? const <File>[]),
          ),
        );
        continue;
      }
      outcomes.add(await _importLanguage(language, file));
    }
    return TessdataImportResult(
      languages: List.unmodifiable(outcomes),
      unmatched: List.unmodifiable(unmatched),
    );
  }

  /// Deletes the installed data for [code] and a partial download of it.
  Future<void> delete(String code) async {
    _checkSafe(code);
    _installedCache = null;
    // The record first: without it the file no longer counts as installed.
    await _deleteQuietly(File(_recordPath(code)));
    await _deleteQuietly(File(_dataPath(code)));
    await _deleteQuietly(File(_partPath(code)));
  }

  /// Removes leftovers of interrupted installs (staging, and data files
  /// without a valid record; partial downloads are kept for resuming).
  /// Safe to call at start-up.
  Future<void> cleanUp() async {
    await _deleteQuietly(_stagingDirectory);
    final directory = dataDirectory;
    if (!directory.existsSync()) return;
    final valid = {for (final language in await installed()) language.path};
    try {
      await for (final entry in directory.list()) {
        if (entry is File &&
            entry.path.endsWith(_extension) &&
            !valid.contains(entry.path)) {
          await _deleteQuietly(entry);
        }
      }
    } on FileSystemException {
      // Best effort.
    }
  }

  /// Closes the HTTP client when this manager created it.
  void close() {
    if (_ownsClient) _client.close();
  }

  Future<InstalledTessdata> _install(
    TessdataLanguage language,
    void Function(TessdataDownloadProgress progress)? onProgress,
  ) async {
    _checkSafe(language.code);
    final existing = await installedLanguage(language.code);
    if (existing != null && existing.sha256 == language.sha256) return existing;
    await _downloadsDirectory.create(recursive: true);
    final part = await _download(language, (received) {
      onProgress?.call(
        TessdataDownloadProgress(
          language: language,
          receivedBytes: received,
          totalBytes: language.size,
        ),
      );
    });
    return _installVerified(language, part);
  }

  /// Runs [run] (installing [language]) unless an install of the same
  /// version is already running, which is then shared.
  Future<InstalledTessdata> _exclusive(
    TessdataLanguage language,
    Future<InstalledTessdata> Function() run,
  ) {
    final key = '${language.code}/${language.sha256}';
    // The callback must not return the removed future: whenComplete would
    // then wait for itself.
    return _installing[key] ??= run().whenComplete(() {
      unawaited(_installing.remove(key));
    });
  }

  /// Moves the verified [file] (a finished download or a staged copy) to
  /// `<code>.traineddata` with one rename (atomic on one file system;
  /// replaces another version), then writes its record the same way.
  Future<InstalledTessdata> _installVerified(
    TessdataLanguage language,
    File file,
  ) async {
    await dataDirectory.create(recursive: true);
    await _stagingDirectory.create(recursive: true);
    final record = File(
      p.join(
        _stagingDirectory.path,
        '${language.code}-${_randomSuffix()}.json',
      ),
    );
    try {
      await record.writeAsString(jsonEncode(_record(language)), flush: true);
      _installedCache = null;
      // Another version's record goes first: until the new one is in
      // place, the file counts as not installed.
      await _deleteQuietly(File(_recordPath(language.code)));
      await file.rename(_dataPath(language.code));
      await record.rename(_recordPath(language.code));
    } finally {
      await _deleteQuietly(record);
      _installedCache = null;
    }
    return (await installedLanguage(language.code))!;
  }

  /// Downloads [language] into `<downloads>/<code>.traineddata.part`
  /// (resuming a partial download) and verifies its size and SHA-256.
  Future<File> _download(
    TessdataLanguage language,
    void Function(int received) report,
  ) async {
    final part = File(_partPath(language.code));
    var existing = part.existsSync() ? part.lengthSync() : 0;
    if (existing > language.size) {
      await part.delete();
      existing = 0;
    }

    final digestSink = _DigestSink();
    final hasher = sha256.startChunkedConversion(digestSink);
    var received = 0;

    if (existing < language.size) {
      final request = http.Request('GET', language.url);
      if (existing > 0) request.headers['Range'] = 'bytes=$existing-';
      final http.StreamedResponse response;
      try {
        response = await _client.send(request).timeout(requestTimeout);
      } on Object catch (error) {
        throw TessdataDownloadException(language.code, '$error');
      }
      final resumed = existing > 0 && response.statusCode == 206;
      if (response.statusCode != 200 && !resumed) {
        // Drain so the connection can be reused.
        await response.stream.drain<void>().catchError((_) {});
        throw TessdataDownloadException(
          language.code,
          'HTTP ${response.statusCode} for ${language.url}',
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
      report(received);
      final sink = part.openWrite(
        mode: resumed ? FileMode.writeOnlyAppend : FileMode.writeOnly,
      );
      try {
        await for (final chunk in response.stream.timeout(requestTimeout)) {
          received += chunk.length;
          if (received > language.size) {
            throw TessdataChecksumException(
              language.code,
              '${language.fileName}: more than ${language.size} bytes',
            );
          }
          hasher.add(chunk);
          sink.add(chunk);
          report(received);
        }
      } on TessdataInstallException {
        await sink.close();
        await _deleteQuietly(part);
        rethrow;
      } on Object catch (error) {
        // Interrupted: keep the part for resuming.
        await sink.close();
        throw TessdataDownloadException(
          language.code,
          '${language.fileName}: $error',
        );
      }
      await sink.flush();
      await sink.close();
    } else {
      await for (final chunk in part.openRead()) {
        hasher.add(chunk);
        received += chunk.length;
      }
      report(received);
    }
    hasher.close();

    final digest = digestSink.value.toString();
    if (received != language.size || digest != language.sha256) {
      await _deleteQuietly(part);
      throw TessdataChecksumException(
        language.code,
        '${language.fileName}: got $received bytes with SHA-256 $digest, '
        'expected ${language.size} bytes with SHA-256 ${language.sha256}',
      );
    }
    return part;
  }

  /// Installs [language] from the verified imported [input].
  Future<TessdataImportOutcome> _importLanguage(
    TessdataLanguage language,
    File input,
  ) async {
    try {
      _checkSafe(language.code);
      // A download of the same version that is running finishes first;
      // when it fails, the file is installed instead.
      if (_installing['${language.code}/${language.sha256}']
          case final running?) {
        try {
          await running;
        } on Object {
          // Installed from the file below.
        }
      }
      if (await isInstalled(language)) {
        return TessdataImportOutcome(
          language: language,
          status: TessdataImportStatus.alreadyInstalled,
        );
      }
      await _exclusive(language, () async {
        final copy = await _copyVerified(language, input);
        try {
          return await _installVerified(language, copy);
        } finally {
          await _deleteQuietly(copy);
        }
      });
      return TessdataImportOutcome(
        language: language,
        status: TessdataImportStatus.installed,
      );
    } on TessdataChecksumException catch (error) {
      // Changed since it was verified.
      return TessdataImportOutcome(
        language: language,
        status: TessdataImportStatus.checksumMismatch,
        damaged: [input],
        error: error,
      );
    } on Object catch (error) {
      return TessdataImportOutcome(
        language: language,
        status: TessdataImportStatus.failed,
        error: error,
      );
    }
  }

  /// Copies [input] into staging while hashing it again, so the installed
  /// bytes are the verified ones even if [input] changes meanwhile.
  Future<File> _copyVerified(TessdataLanguage language, File input) async {
    await _stagingDirectory.create(recursive: true);
    final output = File(
      p.join(
        _stagingDirectory.path,
        '${language.code}-${_randomSuffix()}$_extension',
      ),
    );
    final digestSink = _DigestSink();
    final hasher = sha256.startChunkedConversion(digestSink);
    var size = 0;
    final sink = output.openWrite();
    try {
      await for (final chunk in input.openRead()) {
        size += chunk.length;
        if (size > language.size) break;
        hasher.add(chunk);
        sink.add(chunk);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    hasher.close();
    final digest = digestSink.value.toString();
    if (size != language.size || digest != language.sha256) {
      await _deleteQuietly(output);
      throw TessdataChecksumException(
        language.code,
        '${p.basename(input.path)}: $size bytes with SHA-256 $digest, '
        'expected ${language.size} bytes with SHA-256 ${language.sha256}',
      );
    }
    return output;
  }

  Map<String, Object?> _record(TessdataLanguage language) => {
    'schemaVersion': _recordSchema,
    'code': language.code,
    'size': language.size,
    'sha256': language.sha256,
  };

  Future<List<InstalledTessdata>> _scan() async {
    final directory = dataDirectory;
    if (!directory.existsSync()) return const [];
    final languages = <InstalledTessdata>[];
    try {
      await for (final entry in directory.list()) {
        if (entry is! File || !entry.path.endsWith('.json')) continue;
        final language = await _readInstalled(entry);
        if (language != null) languages.add(language);
      }
    } on FileSystemException {
      // Unreadable directory: nothing installed.
    }
    languages.sort((a, b) => a.code.compareTo(b.code));
    return languages;
  }

  /// Null for anything that is not a complete install (ignored).
  Future<InstalledTessdata?> _readInstalled(File record) async {
    try {
      final json = jsonDecode(await record.readAsString());
      if (json is! Map<String, Object?> ||
          json['schemaVersion'] != _recordSchema) {
        return null;
      }
      final code = json['code']! as String;
      final size = json['size']! as int;
      final digest = json['sha256']! as String;
      if (!isTesseractCode(code) || p.basename(record.path) != '$code.json') {
        return null;
      }
      final file = File(_dataPath(code));
      if (await file.length() != size) return null;
      return InstalledTessdata(
        code: code,
        path: file.path,
        sizeBytes: size,
        sha256: digest,
      );
    } on Object {
      return null;
    }
  }

  String _dataPath(String code) =>
      p.join(dataDirectory.path, '$code$_extension');

  String _recordPath(String code) => p.join(dataDirectory.path, '$code.json');

  String _partPath(String code) =>
      p.join(_downloadsDirectory.path, '$code$_extension.part');

  /// Whether [input] has [language]'s size and SHA-256.
  static Future<bool> _matches(File input, TessdataLanguage language) async {
    // Only a file of the right size is worth hashing.
    if (await _lengthOf(input) != language.size) return false;
    return await _sha256Of(input) == language.sha256;
  }

  /// SHA-256 of [file]'s contents; null when it cannot be read.
  static Future<String?> _sha256Of(File file) async {
    final digestSink = _DigestSink();
    final hasher = sha256.startChunkedConversion(digestSink);
    try {
      await for (final chunk in file.openRead()) {
        hasher.add(chunk);
      }
    } on FileSystemException {
      return null;
    }
    hasher.close();
    return digestSink.value.toString();
  }

  /// The length of [file]; -1 when it cannot be read.
  static Future<int> _lengthOf(File file) async {
    try {
      return await file.length();
    } on FileSystemException {
      return -1;
    }
  }

  /// The code an imported file at [path] names: its base name in lower
  /// case without `.traineddata` (empty for other names).
  static String _importCode(String path) {
    final name = p.basename(path).toLowerCase();
    if (!name.endsWith(_extension)) return '';
    return name.substring(0, name.length - _extension.length);
  }

  static void _checkSafe(String code) {
    if (!isTesseractCode(code)) {
      throw ArgumentError.value(code, 'code', 'Invalid Tesseract code');
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

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
