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
///   checksum mismatch. Concurrent installs of one pack share a download
///   (each caller gets its progress), which [cancelInstall] stops; the
///   running ones are in [installing].
/// * With a [ResumableDictionaryPackStorage] (the app's files on Android),
///   a download that stops (no connection, a cancel) is kept, and the next
///   one of that version from the same URL resumes it (`Range`; the whole
///   file again when the server does not answer with the rest). The whole
///   file is checked at the end as always; resumed bytes that do not match
///   are downloaded again from the start.
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
  final Map<String, _PackInstall> _installing = {};
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

  /// The packs [install] is downloading now, by id, with the fraction
  /// received so far (0 to 1; null until the download starts).
  Map<String, double?> get installing => {
    for (final install in _installing.values)
      if (!install.cancel.isCancelled) install.packId: install.fraction,
  };

  /// Downloads and installs [pack], replacing another version of it.
  /// Returns at once when it is installed already. With [wifiOnly] it
  /// throws [DictionaryPackMeteredException] on a metered network.
  /// [onProgress] gets the fraction received (0 to 1), also when this call
  /// joins a running install of the pack. [cancelInstall] stops it with an
  /// [OfflineDownloadCancelledException].
  Future<void> install(
    DictionaryPackInfo pack, {
    bool wifiOnly = false,
    void Function(double fraction)? onProgress,
  }) {
    final key = '${pack.id}/${pack.sha256}';
    final running = _installing[key];
    if (running != null && !running.cancel.isCancelled) {
      if (onProgress != null) running.listen(onProgress);
      return running.result;
    }
    // A cancelled install winds down first (it may still be aborting its
    // write).
    final install = _PackInstall(
      pack.id,
      (install) => _install(pack, wifiOnly, install.report, install.cancel),
      onProgress: onProgress,
      after: running?.settled,
    );
    _installing[key] = install;
    unawaited(
      install.settled.then((_) {
        if (identical(_installing[key], install)) _installing.remove(key);
      }),
    );
    return install.result;
  }

  /// Stops every running [install] of the pack [id]: the request is
  /// closed, what was received is kept for resuming where the storage
  /// can ([ResumableDictionaryPackStorage]) and nothing is installed;
  /// those calls fail with an [OfflineDownloadCancelledException].
  /// Completes once they have stopped; does nothing when none runs. Never
  /// throws.
  Future<void> cancelInstall(String id) async {
    final stopping = [
      for (final MapEntry(:key, value: install) in _installing.entries)
        if (key.startsWith('$id/')) install..cancel.cancel(),
    ];
    for (final install in stopping) {
      await install.settled;
    }
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
    _DownloadCancel cancel,
  ) async {
    if (!isSupported) throw DictionaryPackUnsupportedException(pack.id);
    final existing = await installedPack(pack.id);
    if (existing != null && existing.sha256 == pack.sha256) return;
    if (wifiOnly && await _isMetered()) {
      throw DictionaryPackMeteredException(pack.id);
    }
    final urls = _downloadUrls(pack);
    final kept = await _kept(pack);
    // Only the rest of a download that resumes needs room.
    final reused =
        kept != null &&
            urls.any((url) => kept.continues(pack.sha256, pack.size, url))
        ? kept.received
        : 0;
    await ensureFreeSpace(pack.size - reused, freeSpace: _freeSpace);
    for (final (index, url) in urls.indexed) {
      cancel.check();
      try {
        final resume =
            kept != null && kept.continues(pack.sha256, pack.size, url)
            ? kept.received
            : 0;
        await _download(pack, url, resume, onProgress, cancel);
        break;
      } on DictionaryPackDownloadException {
        cancel.check();
        if (index == urls.length - 1) rethrow;
      }
    }
    await _closeReader(pack.id);
    _installed = null;
    _changes.add(null);
  }

  /// The kept download of [pack] (any version, see
  /// [ResumableDictionaryPackStorage.partial]), if the storage keeps them.
  Future<DictionaryPartialDownload?> _kept(DictionaryPackInfo pack) async {
    final storage = _storage;
    if (storage is! ResumableDictionaryPackStorage) return null;
    try {
      return await storage.partial(pack.id);
    } on Object {
      return null;
    }
  }

  /// Downloads [pack] from [url] and installs it, resuming the kept bytes
  /// from byte [resume] on when the server answers with the rest (`206`
  /// from there; else the whole file); once [cancel] is cancelled the
  /// request is aborted and this fails with an
  /// [OfflineDownloadCancelledException] (what came is kept for resuming).
  Future<void> _download(
    DictionaryPackInfo pack,
    Uri url,
    int resume,
    void Function(double fraction)? onProgress,
    _DownloadCancel cancel,
  ) async {
    var from = resume;
    while (true) {
      final request = http.AbortableRequest(
        'GET',
        url,
        abortTrigger: cancel.future,
      );
      if (from > 0) request.headers['Range'] = 'bytes=$from-';
      final http.StreamedResponse response;
      try {
        response = await cancel.race(
          _client.send(request).timeout(requestTimeout),
          onLate: _discard,
        );
      } on OfflineDownloadCancelledException {
        rethrow;
      } on Object catch (error) {
        cancel.check();
        throw DictionaryPackDownloadException(pack.id, '$error', url: url);
      }
      final status = response.statusCode;
      final continues =
          from > 0 && status == 206 && _rangeStart(response, pack) == from;
      if (status != 200 && !continues) {
        // Drain so the connection can be reused.
        await response.stream.drain<void>().catchError((_) {});
        if (from > 0 && (status == 206 || status == 416)) {
          // Not the rest that was asked for: the whole file.
          from = 0;
          continue;
        }
        throw DictionaryPackDownloadException(
          pack.id,
          'HTTP $status for $url',
          url: url,
          statusCode: status,
        );
      }
      try {
        await _store(
          pack,
          cancel.guard(response.stream).timeout(requestTimeout),
          url: url,
          resumeFrom: continues ? from : 0,
          onProgress: onProgress,
          cancel: cancel,
          wrap: (error) => DictionaryPackDownloadException(
            pack.id,
            '${pack.fileName}: $error',
            url: url,
          ),
        );
        return;
      } on DictionaryPackChecksumException {
        // Kept bytes that do not fit: the whole file once more.
        if (!continues) rethrow;
        from = 0;
      }
    }
  }

  /// The first byte of a `206` [response] (`Content-Range: bytes F-L/T`),
  /// or null when the header is missing, malformed or for a file of
  /// another size than [pack]'s.
  static int? _rangeStart(
    http.StreamedResponse response,
    DictionaryPackInfo pack,
  ) {
    final header = response.headers.entries
        .where((entry) => entry.key.toLowerCase() == 'content-range')
        .firstOrNull
        ?.value;
    if (header == null) return null;
    final match = RegExp(r'^\s*bytes\s+(\d+)-(\d+)/(\d+|\*)\s*$')
        .firstMatch(header);
    if (match == null) return null;
    final first = int.tryParse(match[1]!);
    final last = int.tryParse(match[2]!);
    final total = match[3] == '*' ? null : int.tryParse(match[3]!);
    if (first == null ||
        last == null ||
        last < first ||
        last >= pack.size ||
        (total != null && total != pack.size)) {
      return null;
    }
    return first;
  }

  /// Stops reading [response] (closing its connection).
  static void _discard(http.StreamedResponse response) {
    unawaited(
      response.stream
          .listen(null, onError: (Object _) {})
          .cancel()
          .catchError((Object _) {}),
    );
  }

  /// Writes [bytes] as [pack] into the storage, checking them against the
  /// catalogue's size and SHA-256 (a [DictionaryPackChecksumException]
  /// naming [url] otherwise; nothing is installed). Other errors stop the
  /// write and are rethrown, or replaced by what [wrap] makes of them;
  /// once [cancel] is cancelled, the write stops (also when every byte
  /// came) with an [OfflineDownloadCancelledException].
  ///
  /// A download (with its [url]) into a [ResumableDictionaryPackStorage]
  /// is kept when it stops so (not after a checksum mismatch); with
  /// [resumeFrom] its kept bytes come first ([bytes] are the rest).
  Future<void> _store(
    DictionaryPackInfo pack,
    Stream<List<int>> bytes, {
    Uri? url,
    int resumeFrom = 0,
    void Function(double fraction)? onProgress,
    Exception Function(Object error)? wrap,
    _DownloadCancel? cancel,
  }) async {
    final storage = _storage;
    final hash = Sha256();
    var received = 0;
    final DictionaryPackSink sink;
    if (url != null && storage is ResumableDictionaryPackStorage) {
      if (resumeFrom > 0) {
        try {
          await for (final chunk in storage.readPartial(pack.id)) {
            received += chunk.length;
            hash.add(chunk);
          }
        } on Object catch (error) {
          throw DictionaryPackChecksumException(pack.id, '$error', url: url);
        }
        if (received != resumeFrom) {
          throw DictionaryPackChecksumException(
            pack.id,
            '${pack.fileName}: kept $received bytes, not $resumeFrom',
            url: url,
          );
        }
      }
      sink = await storage.createPartial(
        pack.id,
        DictionaryPartialDownload(
          url: url,
          size: pack.size,
          sha256: pack.sha256,
        ),
        append: resumeFrom > 0,
      );
    } else {
      sink = await storage.create(pack.id);
    }
    onProgress?.call(received / pack.size);
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
      await _stop(sink);
      cancel?.check();
      if (wrap == null) rethrow;
      throw wrap(error);
    }
    if (cancel?.isCancelled ?? false) {
      await _stop(sink);
      cancel?.check();
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

/// Stops writing [sink], keeping what was written for resuming when it
/// can be.
Future<void> _stop(DictionaryPackSink sink) =>
    sink is ResumableDictionaryPackSink ? sink.keep() : sink.abort();

/// An install of [DictionaryPacks] that callers share, with its [cancel]
/// and the progress callbacks of every caller.
final class _PackInstall {
  new(
    this.packId,
    Future<void> Function(_PackInstall install) run, {
    void Function(double fraction)? onProgress,
    Future<void>? after,
  }) : cancel = _DownloadCancel(packId) {
    if (onProgress != null) _listeners.add(onProgress);
    result = after == null
        ? Future.sync(() => run(this))
        : after.then((_) => run(this));
    settled = result.then<void>((_) {}, onError: (Object _) {});
  }

  final String packId;
  final _DownloadCancel cancel;
  final _listeners = <void Function(double fraction)>[];

  /// The fraction received so far (null until the download starts).
  double? fraction;

  /// Adds a caller's progress callback (told the progress so far at once).
  void listen(void Function(double fraction) onProgress) {
    _listeners.add(onProgress);
    if (fraction case final fraction?) onProgress(fraction);
  }

  void report(double fraction) {
    this.fraction = fraction;
    for (final listener in [..._listeners]) {
      listener(fraction);
    }
  }

  late final Future<void> result;

  /// Completes (never with an error) when [result] does.
  late final Future<void> settled;
}

/// Stops a pack download once [cancel] is called: requests sent with
/// [future] as their abort trigger are aborted, [guard]ed response streams
/// end with an [OfflineDownloadCancelledException], [race]d futures fail
/// with it and [check] throws it.
final class _DownloadCancel {
  new(this.packId);

  final String packId;
  final _stopped = Completer<void>();

  bool get isCancelled => _stopped.isCompleted;

  /// Completes when [cancel] is called (never with an error).
  Future<void> get future => _stopped.future;

  void cancel() {
    if (!_stopped.isCompleted) _stopped.complete();
  }

  OfflineDownloadCancelledException get _error =>
      OfflineDownloadCancelledException(packId);

  void check() {
    if (isCancelled) throw _error;
  }

  /// [work], or an [OfflineDownloadCancelledException] as soon as [cancel]
  /// is called (`MockClient` and some platform clients do not abort a
  /// request by its trigger); a later result goes to [onLate].
  Future<T> race<T>(Future<T> work, {void Function(T value)? onLate}) {
    final result = Completer<T>();
    unawaited(
      work.then(
        (value) {
          if (result.isCompleted) {
            onLate?.call(value);
          } else {
            result.complete(value);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!result.isCompleted) result.completeError(error, stackTrace);
        },
      ),
    );
    unawaited(
      future.then((_) {
        if (!result.isCompleted) result.completeError(_error);
      }),
    );
    return result.future;
  }

  /// [stream] until [cancel] is called: then its subscription is cancelled
  /// (closing the response) and the stream ends with an
  /// [OfflineDownloadCancelledException] at once.
  Stream<T> guard<T>(Stream<T> stream) {
    final controller = StreamController<T>();
    // Cancelled by stop() or onCancel.
    // ignore: cancel_subscriptions
    StreamSubscription<T>? subscription;
    void stop() {
      if (controller.isClosed) return;
      final source = subscription;
      subscription = null;
      if (source != null) unawaited(source.cancel());
      controller.addError(_error);
      unawaited(controller.close());
    }

    controller
      ..onListen = () {
        if (isCancelled) {
          unawaited(stream.listen(null, onError: (Object _) {}).cancel());
          return stop();
        }
        subscription = stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: () {
            subscription = null;
            unawaited(controller.close());
          },
        );
        unawaited(future.then((_) => stop()));
      }
      ..onPause = (() => subscription?.pause())
      ..onResume = (() => subscription?.resume())
      ..onCancel = () {
        final source = subscription;
        subscription = null;
        return source?.cancel();
      };
    return controller.stream;
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
