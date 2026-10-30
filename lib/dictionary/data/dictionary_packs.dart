import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show immutable;

import 'package:http/http.dart' as http;
import 'package:mozhi/dictionary/data/dictionary_pack_storage.dart';
import 'package:mozhi/offline/data/picked_import_file.dart';
import 'package:mozhi/platform/free_space.dart';
import 'package:translation_repository/translation_repository.dart';

export 'dictionary_pack_storage.dart';

/// A dictionary pack download or install failed.
sealed class DictionaryPackException implements Exception {
  const new(this.packId, this.message, {this.url});

  /// The pack's [DictionaryPackInfo.id].
  final String packId;
  final String message;

  /// The URL the failed download came from.
  final Uri? url;

  String get _name;

  @override
  String toString() => '$_name($packId: $message)';
}

/// The file did not match the catalogue's size or SHA-256 (corrupt or
/// tampered); nothing was installed and no other URL is tried.
final class DictionaryPackChecksumException extends DictionaryPackException {
  const new(super.packId, super.message, {super.url});

  @override
  String get _name => 'DictionaryPackChecksumException';
}

/// The server answered with an error ([statusCode]) or the connection
/// failed (null).
final class DictionaryPackDownloadException extends DictionaryPackException {
  const new(super.packId, super.message, {super.url, this.statusCode});

  final int? statusCode;

  @override
  String get _name => 'DictionaryPackDownloadException';
}

/// A Wi-Fi-only download on a metered network: nothing was downloaded.
final class DictionaryPackMeteredException extends DictionaryPackException {
  const new(String packId) : super(packId, 'Metered network');

  @override
  String get _name => 'DictionaryPackMeteredException';
}

/// Packs cannot be stored here (a browser without OPFS).
final class DictionaryPackUnsupportedException extends DictionaryPackException {
  const new(String packId) : super(packId, 'No storage for dictionary packs');

  @override
  String get _name => 'DictionaryPackUnsupportedException';
}

/// The app's offline dictionaries: downloads, checks, installs and deletes
/// the packs of [catalog] in a [DictionaryPackStorage], and looks words up
/// in the installed ones ([OfflineDictionary]) without any network
/// request.
///
/// * Every download is checked against the catalogue's size and SHA-256
///   before it is installed; a pack replaces another version of itself at
///   once (see the storages). [install] tries the URLs of `downloadUrls`
///   (default: the catalogue's) in turn when a server fails, never after a
///   checksum mismatch. Concurrent installs of one pack share a download.
/// * `isMeteredConnection` tells whether a `wifiOnly` install must stop.
/// * An install first checks that the pack fits (`freeSpace`, default
///   [FreeSpace.instance]: the pack's size plus a margin, see
///   [ensureFreeSpace]), else it throws a [NotEnoughSpaceException].
/// * Packs open lazily ([DictionaryPackReader]: a few blocks in memory
///   each) on their first look-up and stay open; installing or deleting a
///   pack closes it. [changes] fires after both.
/// * The first use removes leftovers of interrupted installs
///   ([DictionaryPackStorage.cleanUp]).
class DictionaryPacks implements OfflineDictionary {
  new({
    required this.catalog,
    required this._storage,
    http.Client? httpClient,
    Future<bool> Function()? isMeteredConnection,
    List<Uri> Function(DictionaryPackInfo pack)? downloadUrls,
    this.requestTimeout = const Duration(seconds: 60),
    this.cachedBlocks = 8,
    this._freeSpace,
  }) : _client = httpClient ?? http.Client(),
       _ownsClient = httpClient == null,
       _isMetered = isMeteredConnection ?? _never,
       _downloadUrls = downloadUrls ?? _catalogueUrl;

  /// The packs that can be downloaded.
  final DictionaryPackCatalog catalog;

  /// Maximum wait for response headers and between chunks of a download.
  final Duration requestTimeout;

  /// Decompressed blocks each open pack keeps in memory.
  final int cachedBlocks;

  final DictionaryPackStorage _storage;
  final http.Client _client;
  final bool _ownsClient;
  final Future<bool> Function() _isMetered;
  final List<Uri> Function(DictionaryPackInfo pack) _downloadUrls;
  final FreeSpace? _freeSpace;
  final StreamController<void> _changes = StreamController.broadcast();
  final Map<String, Future<void>> _installing = {};
  final Map<String, Future<DictionaryPackReader>> _readers = {};
  Future<void>? _cleanedUp;
  Future<List<StoredDictionaryPack>>? _installed;

  static Future<bool> _never() async => false;

  static List<Uri> _catalogueUrl(DictionaryPackInfo pack) => [pack.url];

  /// Whether packs can be stored here.
  bool get isSupported => _storage.isSupported;

  @override
  Stream<void> get changes => _changes.stream;

  /// The installed packs, sorted by id (also packs of an older catalogue).
  Future<List<StoredDictionaryPack>> installed() async {
    if (!isSupported) return const [];
    await (_cleanedUp ??= _storage.cleanUp().catchError((Object _) {}));
    final loading = _installed ??= _storage.list().then(List.unmodifiable);
    try {
      return await loading;
    } on Object {
      if (identical(_installed, loading)) _installed = null;
      rethrow;
    }
  }

  /// The installed version of [id], if any.
  Future<StoredDictionaryPack?> installedPack(String id) async {
    for (final pack in await installed()) {
      if (pack.id == id) return pack;
    }
    return null;
  }

  /// Downloads and installs [pack], replacing another version of it.
  /// Returns at once when it is installed already. With [wifiOnly] it
  /// throws [DictionaryPackMeteredException] on a metered network.
  /// [onProgress] gets the fraction received (0 to 1).
  Future<void> install(
    DictionaryPackInfo pack, {
    bool wifiOnly = false,
    void Function(double fraction)? onProgress,
  }) {
    final key = '${pack.id}/${pack.sha256}';
    // The callback must not return the removed future: whenComplete would
    // then wait for itself.
    return _installing[key] ??= _install(pack, wifiOnly, onProgress)
        .whenComplete(() {
          unawaited(_installing.remove(key));
        });
  }

  /// Deletes the installed pack [id] (closing it first).
  Future<void> delete(String id) async {
    await _closeReader(id);
    _installed = null;
    try {
      await _storage.delete(id);
    } finally {
      _installed = null;
      _changes.add(null);
    }
  }

  /// The bytes of the installed pack [id], in chunks of at most
  /// [chunkSize] (for sending it to another phone, `lib/pairing`). Throws
  /// when it is not installed.
  Stream<Uint8List> read(String id, {int chunkSize = 64 * 1024}) async* {
    final source = await _storage.open(id);
    try {
      for (var offset = 0; offset < source.length; offset += chunkSize) {
        final end = offset + chunkSize < source.length
            ? offset + chunkSize
            : source.length;
        yield await source.read(offset, end - offset);
      }
    } finally {
      await source.close();
    }
  }

  /// Installs [pack] from [bytes] (a copy from another phone), with the
  /// checks of a download and without any network request: the size and
  /// SHA-256 must match the catalogue's, else it throws
  /// [DictionaryPackChecksumException] and nothing is installed. Replaces
  /// another version of the pack; [changes] fires. Throws
  /// [DictionaryPackUnsupportedException] where packs cannot be stored,
  /// and what reading [bytes] or the storage throws.
  Future<void> installFrom(
    DictionaryPackInfo pack,
    Stream<List<int>> bytes, {
    void Function(double fraction)? onProgress,
  }) async {
    if (!isSupported) throw DictionaryPackUnsupportedException(pack.id);
    await ensureFreeSpace(pack.size, freeSpace: _freeSpace);
    try {
      await _store(pack, bytes, onProgress: onProgress);
    } finally {
      _installed = null;
    }
    _changes.add(null);
  }

  /// Installs packs of [catalog] from files the user picked (downloaded by
  /// hand from [DictionaryPackInfo.url]), without any network request:
  /// on Android and in the browser alike.
  ///
  /// A file is matched to a pack by its name ([DictionaryPackInfo.fileName],
  /// ignoring case), or, renamed, by its size and then its SHA-256 (the
  /// first pack of that size it is). It is installed like a download, with
  /// the same checks ([installFrom]: the catalogue's size and SHA-256, else
  /// nothing is installed). A pack already installed in that version is not
  /// read again; a file of the wrong size is reported damaged without being
  /// read. Problems with a file never throw: they are in the report.
  Future<DictionaryImportReport> importFiles(
    List<PickedImportFile> files,
  ) async {
    final byName = {
      for (final pack in catalog.packs) pack.fileName.toLowerCase(): pack,
    };
    final bySize = <int, List<DictionaryPackInfo>>{};
    for (final pack in catalog.packs) {
      (bySize[pack.size] ??= []).add(pack);
    }
    final outcomes = <String, DictionaryImportedPack>{};
    final unmatched = <String>[];
    void report(
      DictionaryPackInfo pack,
      DictionaryImportStatus status, [
      Object? error,
    ]) {
      final known = outcomes[pack.id]?.status;
      // A pack installed (or found installed) stays so for this import.
      if (known == DictionaryImportStatus.installed ||
          known == DictionaryImportStatus.alreadyInstalled) {
        return;
      }
      outcomes[pack.id] = DictionaryImportedPack(
        pack: pack,
        status: status,
        error: error,
      );
    }

    Future<DictionaryImportStatus> install(
      DictionaryPackInfo pack,
      PickedImportFile file,
    ) async {
      if ((await installedPack(pack.id))?.sha256 == pack.sha256) {
        return DictionaryImportStatus.alreadyInstalled;
      }
      await installFrom(pack, file.openRead());
      return DictionaryImportStatus.installed;
    }

    for (final file in files) {
      final name = file.name.split(RegExp(r'[/\\]')).last.toLowerCase();
      if (byName[name] case final pack?) {
        final known = outcomes[pack.id]?.status;
        if (known == DictionaryImportStatus.installed ||
            known == DictionaryImportStatus.alreadyInstalled) {
          continue;
        }
        if (file.length case final length? when length != pack.size) {
          if ((await installedPack(pack.id))?.sha256 == pack.sha256) {
            report(pack, DictionaryImportStatus.alreadyInstalled);
          } else {
            report(pack, DictionaryImportStatus.damaged);
          }
          continue;
        }
        try {
          report(pack, await install(pack, file));
        } on DictionaryPackChecksumException catch (error) {
          report(pack, DictionaryImportStatus.damaged, error);
        } on Object catch (error) {
          report(pack, DictionaryImportStatus.failed, error);
        }
        continue;
      }
      // A renamed copy: a pack of its size whose checks it passes.
      var matched = false;
      for (final pack in bySize[file.length] ?? const <DictionaryPackInfo>[]) {
        try {
          report(pack, await install(pack, file));
          matched = true;
          break;
        } on DictionaryPackChecksumException {
          // Not this pack.
        } on Object catch (error) {
          report(pack, DictionaryImportStatus.failed, error);
          matched = true;
          break;
        }
      }
      if (!matched) unmatched.add(file.name);
    }
    final packs = outcomes.values.toList()
      ..sort((a, b) => a.pack.id.compareTo(b.pack.id));
    return DictionaryImportReport(
      packs: List.unmodifiable(packs),
      unmatchedFiles: List.unmodifiable(unmatched),
    );
  }

  @override
  Future<List<String>> installedLanguages() async => [
    for (final pack in await installed()) pack.language,
  ];

  @override
  Future<OfflineDictionaryAnswer?> lookUp(
    String word, {
    String? language,
    String? target,
  }) async {
    final query = word.trim();
    if (query.isEmpty) return null;
    OfflineDictionaryAnswer? best;
    var bestScore = 99;
    for (final pack in await _candidates(language)) {
      final reader = await _reader(pack.id);
      if (reader == null) continue;
      final OfflineDictionaryAnswer? answer;
      try {
        answer = await reader.define(query, target: target);
      } on Object {
        // A damaged pack answers nothing.
        continue;
      }
      if (answer == null) continue;
      if (language != null) return answer;
      final score = _score(answer, query);
      if (score < bestScore) {
        best = answer;
        bestScore = score;
      }
    }
    return best;
  }

  @override
  Future<List<String>> suggest(
    String prefix, {
    String? language,
    int limit = 8,
  }) async {
    if (prefix.trim().isEmpty || limit <= 0) return const [];
    final words = <String>[];
    for (final pack in await _candidates(language)) {
      final reader = await _reader(pack.id);
      if (reader == null) continue;
      try {
        for (final word in await reader.suggest(prefix, limit: limit)) {
          if (words.length < limit && !words.contains(word)) words.add(word);
        }
      } on Object {
        continue;
      }
      if (words.length >= limit) break;
    }
    return words;
  }

  /// Closes the open packs, the change stream and the HTTP client when
  /// this created it.
  Future<void> close() async {
    for (final id in _readers.keys.toList()) {
      await _closeReader(id);
    }
    await _changes.close();
    if (_ownsClient) _client.close();
  }

  /// How well [answer] matches [query] (lower is better): the word itself,
  /// the same but for case, accents, then an inflected form.
  static int _score(OfflineDictionaryAnswer answer, String query) {
    if (answer.inflectedForm != null) return 3;
    final word = answer.entry.word;
    if (word == query) return 0;
    if (word.toLowerCase() == query.toLowerCase()) return 1;
    return 2;
  }

  Future<List<StoredDictionaryPack>> _candidates(String? language) async {
    final List<StoredDictionaryPack> packs;
    try {
      packs = await installed();
    } on Object {
      return const [];
    }
    if (language == null || language.trim().isEmpty) return packs;
    return [
      for (final pack in packs)
        if (dictionaryLanguageMatches(pack.language, language)) pack,
    ];
  }

  Future<DictionaryPackReader?> _reader(String id) async {
    final opening = _readers[id] ??= () async {
      final source = await _storage.open(id);
      return await DictionaryPackReader.open(
        source,
        cachedBlocks: cachedBlocks,
      );
    }();
    try {
      return await opening;
    } on Object {
      if (identical(_readers[id], opening)) unawaited(_readers.remove(id));
      return null;
    }
  }

  Future<void> _closeReader(String id) async {
    final opening = _readers.remove(id);
    if (opening == null) return;
    try {
      await (await opening).close();
    } on Object {
      // It never opened.
    }
  }

  Future<void> _install(
    DictionaryPackInfo pack,
    bool wifiOnly,
    void Function(double fraction)? onProgress,
  ) async {
    if (!isSupported) throw DictionaryPackUnsupportedException(pack.id);
    final existing = await installedPack(pack.id);
    if (existing != null && existing.sha256 == pack.sha256) return;
    if (wifiOnly && await _isMetered()) {
      throw DictionaryPackMeteredException(pack.id);
    }
    await ensureFreeSpace(pack.size, freeSpace: _freeSpace);
    final urls = _downloadUrls(pack);
    for (final (index, url) in urls.indexed) {
      try {
        await _download(pack, url, onProgress);
        break;
      } on DictionaryPackDownloadException {
        if (index == urls.length - 1) rethrow;
      }
    }
    await _closeReader(pack.id);
    _installed = null;
    _changes.add(null);
  }

  Future<void> _download(
    DictionaryPackInfo pack,
    Uri url,
    void Function(double fraction)? onProgress,
  ) async {
    final http.StreamedResponse response;
    try {
      response = await _client
          .send(http.Request('GET', url))
          .timeout(requestTimeout);
    } on Object catch (error) {
      throw DictionaryPackDownloadException(pack.id, '$error', url: url);
    }
    if (response.statusCode != 200) {
      // Drain so the connection can be reused.
      await response.stream.drain<void>().catchError((_) {});
      throw DictionaryPackDownloadException(
        pack.id,
        'HTTP ${response.statusCode} for $url',
        url: url,
        statusCode: response.statusCode,
      );
    }
    await _store(
      pack,
      response.stream.timeout(requestTimeout),
      url: url,
      onProgress: onProgress,
      wrap: (error) => DictionaryPackDownloadException(
        pack.id,
        '${pack.fileName}: $error',
        url: url,
      ),
    );
  }

  /// Writes [bytes] as [pack] into the storage, checking them against the
  /// catalogue's size and SHA-256 (a [DictionaryPackChecksumException]
  /// naming [url] otherwise; nothing is installed). Other errors abort the
  /// write and are rethrown, or replaced by what [wrap] makes of them.
  Future<void> _store(
    DictionaryPackInfo pack,
    Stream<List<int>> bytes, {
    Uri? url,
    void Function(double fraction)? onProgress,
    Exception Function(Object error)? wrap,
  }) async {
    final sink = await _storage.create(pack.id);
    final hash = Sha256();
    var received = 0;
    onProgress?.call(0);
    try {
      await for (final chunk in bytes) {
        received += chunk.length;
        if (received > pack.size) {
          throw DictionaryPackChecksumException(
            pack.id,
            '${pack.fileName}: more than ${pack.size} bytes',
            url: url,
          );
        }
        hash.add(chunk);
        await sink.add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
        onProgress?.call(received / pack.size);
      }
    } on DictionaryPackException {
      await sink.abort();
      rethrow;
    } on Object catch (error) {
      await sink.abort();
      if (wrap == null) rethrow;
      throw wrap(error);
    }
    final digest = hash.close();
    if (received != pack.size || digest != pack.sha256) {
      await sink.abort();
      throw DictionaryPackChecksumException(
        pack.id,
        '${pack.fileName}: got $received bytes with SHA-256 $digest, '
        'expected ${pack.size} bytes with SHA-256 ${pack.sha256}',
        url: url,
      );
    }
    await _closeReader(pack.id);
    await sink.commit(
      StoredDictionaryPack(
        id: pack.id,
        language: pack.language,
        name: pack.name,
        size: pack.size,
        sha256: pack.sha256,
      ),
    );
  }
}

/// What [DictionaryPacks.importFiles] did with a pack.
enum DictionaryImportStatus {
  /// Installed from the file.
  installed,

  /// This version was installed already.
  alreadyInstalled,

  /// The file named like the pack did not match its size or SHA-256
  /// (damaged, incomplete or another version); nothing was installed.
  damaged,

  /// The file was fine but could not be installed (no room, no storage).
  failed,
}

/// One pack an import found a file for.
@immutable
final class DictionaryImportedPack {
  const new({required this.pack, required this.status, this.error});

  final DictionaryPackInfo pack;
  final DictionaryImportStatus status;

  /// Why it was not installed, when known.
  final Object? error;

  @override
  bool operator ==(Object other) =>
      other is DictionaryImportedPack &&
      other.pack.id == pack.id &&
      other.status == status &&
      other.error == error;

  @override
  int get hashCode => Object.hash(pack.id, status, error);

  @override
  String toString() => 'DictionaryImportedPack(${pack.id}, ${status.name})';
}

/// The result of [DictionaryPacks.importFiles].
@immutable
final class DictionaryImportReport {
  const new({this.packs = const [], this.unmatchedFiles = const []});

  /// One entry per pack a file belongs to, sorted by id.
  final List<DictionaryImportedPack> packs;

  /// Names of the files that belong to no pack.
  final List<String> unmatchedFiles;

  /// Whether a pack was installed.
  bool get installedAny =>
      packs.any((pack) => pack.status == DictionaryImportStatus.installed);
}
