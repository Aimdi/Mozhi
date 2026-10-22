import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/phrasebook/models/starter_phrasebook.dart';
import 'package:translation_repository/translation_repository.dart'
    show Sha256, gzipDecode;

/// A starter phrasebook download or install failed.
sealed class StarterPhrasebookException implements Exception {
  const new(this.packId, this.message);

  /// The pack's [StarterPhrasebookInfo.id].
  final String packId;
  final String message;

  String get _name;

  @override
  String toString() => '$_name($packId: $message)';
}

/// The file did not match the catalogue's size or SHA-256 (corrupt or
/// tampered), or is not a phrasebook pack: nothing was installed, and no
/// other URL is tried.
final class StarterPhrasebookChecksumException
    extends StarterPhrasebookException {
  const new(super.packId, super.message);

  @override
  String get _name => 'StarterPhrasebookChecksumException';
}

/// The server answered with an error ([statusCode]) or could not be
/// reached (null).
final class StarterPhrasebookDownloadException
    extends StarterPhrasebookException {
  const new(super.packId, super.message, {this.statusCode});

  final int? statusCode;

  @override
  String get _name => 'StarterPhrasebookDownloadException';
}

/// The starter phrasebooks: downloads the packs of [catalog] (once, on
/// request), checks each against the catalogue's size and SHA-256, keeps
/// them in [store] and reads them back without any network request.
///
/// * Downloads go to `httpClient`, which the app sets to the model client
///   of `NetworkSession.current` (its proxy, network rules and request
///   log), from the URLs of `downloadUrls` in turn (default: the
///   catalogue's; the app adds the model source's mirror first). A
///   server error tries the next URL; a checksum mismatch never does.
/// * A pack is stored as downloaded (base64 of the gzip'd JSON, a few tens
///   of KB) under [packKeyPrefix]`<id>`, with the list of installed packs
///   under [indexKey]. Reading one checks its SHA-256 again and parses it
///   once; it stays in memory until it is deleted.
/// * The data is public (Wikivoyage) and not encrypted. It is not part of
///   backups: it can be downloaded again.
class StarterPhrasebooks {
  new({
    required this.catalog,
    KeyValueStore? store,
    http.Client? httpClient,
    List<Uri> Function(StarterPhrasebookInfo pack)? downloadUrls,
    this.requestTimeout = const Duration(seconds: 60),
    DateTime Function()? clock,
  }) : store = store ?? PreferencesStore(),
       _client = httpClient,
       _downloadUrls = downloadUrls ?? _catalogueUrl,
       _clock = clock ?? DateTime.now;

  /// Key of the list of installed packs in [store].
  static const indexKey = 'phrasebook.starter.index';

  /// Prefix of the stored packs' keys in [store].
  static const packKeyPrefix = 'phrasebook.starter.pack.';

  /// The packs that can be downloaded.
  final StarterPhrasebookCatalog catalog;
  final KeyValueStore store;

  /// Maximum wait for the response and between its chunks.
  final Duration requestTimeout;

  final http.Client? _client;
  final List<Uri> Function(StarterPhrasebookInfo pack) _downloadUrls;
  final DateTime Function() _clock;
  final StreamController<void> _changes = StreamController.broadcast();
  final Map<String, Future<void>> _installing = {};
  final Map<String, StarterPhrasebook> _loaded = {};
  List<InstalledStarterPhrasebook>? _installed;

  static List<Uri> _catalogueUrl(StarterPhrasebookInfo pack) => [pack.url];

  /// Fires after a pack was installed or deleted.
  Stream<void> get changes => _changes.stream;

  /// The installed packs, sorted by name (also packs that an older
  /// catalogue listed). An unreadable list reads as empty.
  Future<List<InstalledStarterPhrasebook>> installed() async {
    if (_installed case final installed?) return installed;
    final raw = await store.read(indexKey);
    final packs = <InstalledStarterPhrasebook>[];
    if (raw != null) {
      try {
        final json = jsonDecode(raw);
        if (json is List<Object?>) {
          for (final item in json) {
            if (item is! Map<String, Object?>) continue;
            try {
              packs.add(InstalledStarterPhrasebook.fromJson(item));
            } on FormatException {
              continue;
            }
          }
        }
      } on FormatException {
        // Nothing usable: no packs.
      }
    }
    packs.sort((a, b) => a.name.compareTo(b.name));
    return _installed = List.unmodifiable(packs);
  }

  /// The installed pack [id], parsed; null when it is not installed or
  /// its stored copy is damaged (it no longer matches its SHA-256).
  Future<StarterPhrasebook?> load(String id) async {
    if (_loaded[id] case final pack?) return pack;
    final info = (await installed()).where((p) => p.id == id).firstOrNull;
    if (info == null) return null;
    final raw = await store.read('$packKeyPrefix$id');
    if (raw == null) return null;
    try {
      final bytes = base64Decode(raw);
      if (Sha256.of(bytes) != info.sha256) return null;
      return _loaded[id] = _parse(id, bytes, installedAt: info.installedAt);
    } on FormatException {
      return null;
    }
  }

  /// Downloads and installs [pack], replacing another version of it.
  /// Returns at once when this version is installed. Concurrent calls for
  /// one pack share the download. [onProgress] gets the fraction received
  /// (0 to 1).
  Future<void> install(
    StarterPhrasebookInfo pack, {
    void Function(double fraction)? onProgress,
  }) {
    final key = '${pack.id}/${pack.sha256}';
    // The callback must not return the removed future: whenComplete would
    // then wait for itself.
    return _installing[key] ??= _install(pack, onProgress).whenComplete(() {
      unawaited(_installing.remove(key));
    });
  }

  /// Deletes the installed pack [id].
  Future<void> delete(String id) async {
    final packs = await installed();
    _loaded.remove(id);
    await store.delete('$packKeyPrefix$id');
    await _writeIndex([
      for (final pack in packs)
        if (pack.id != id) pack,
    ]);
    _changes.add(null);
  }

  /// Deletes every installed pack (also ones the index lost track of
  /// that the catalogue lists).
  Future<void> deleteAll() async {
    final ids = {
      for (final pack in await installed()) pack.id,
      for (final pack in catalog.packs) pack.id,
    };
    _loaded.clear();
    for (final id in ids) {
      await store.delete('$packKeyPrefix$id');
    }
    await store.delete(indexKey);
    _installed = const [];
    _changes.add(null);
  }

  /// Closes the change stream.
  Future<void> close() => _changes.close();

  Future<void> _install(
    StarterPhrasebookInfo pack,
    void Function(double fraction)? onProgress,
  ) async {
    final existing = (await installed())
        .where((p) => p.id == pack.id)
        .firstOrNull;
    if (existing != null && existing.sha256 == pack.sha256) return;
    final bytes = await _downloadFromAny(pack, onProgress);
    final installedAt = _clock();
    final StarterPhrasebook parsed;
    try {
      parsed = _parse(pack.id, bytes, installedAt: installedAt);
    } on FormatException catch (error) {
      throw StarterPhrasebookChecksumException(pack.id, '$error');
    }
    await store.write('$packKeyPrefix${pack.id}', base64Encode(bytes));
    final others = [
      for (final other in await installed())
        if (other.id != pack.id) other,
    ];
    await _writeIndex([
      ...others,
      InstalledStarterPhrasebook(
        id: pack.id,
        language: parsed.language,
        baseLanguage: parsed.baseLanguage,
        name: pack.name,
        sha256: pack.sha256,
        size: pack.size,
        phrases: parsed.phrases.length,
        installedAt: installedAt,
      ),
    ]);
    _loaded[pack.id] = parsed;
    _changes.add(null);
  }

  Future<void> _writeIndex(List<InstalledStarterPhrasebook> packs) async {
    final sorted = [...packs]..sort((a, b) => a.name.compareTo(b.name));
    await store.write(
      indexKey,
      jsonEncode([for (final pack in sorted) pack.toJson()]),
    );
    _installed = List.unmodifiable(sorted);
  }

  /// The file of [pack] from the first of its URLs that answers.
  Future<Uint8List> _downloadFromAny(
    StarterPhrasebookInfo pack,
    void Function(double fraction)? onProgress,
  ) async {
    final urls = _downloadUrls(pack);
    if (urls.isEmpty) {
      throw StarterPhrasebookDownloadException(pack.id, 'No download URL');
    }
    for (var index = 0; ; index++) {
      try {
        return await _download(pack, urls[index], onProgress);
      } on StarterPhrasebookDownloadException {
        if (index >= urls.length - 1) rethrow;
      }
    }
  }

  Future<Uint8List> _download(
    StarterPhrasebookInfo pack,
    Uri url,
    void Function(double fraction)? onProgress,
  ) async {
    final client = _client;
    if (client == null) {
      throw StarterPhrasebookDownloadException(pack.id, 'No network client');
    }
    final http.StreamedResponse response;
    try {
      response = await client
          .send(http.Request('GET', url))
          .timeout(requestTimeout);
    } on Object catch (error) {
      throw StarterPhrasebookDownloadException(pack.id, '$error');
    }
    if (response.statusCode != 200) {
      await response.stream.drain<void>().catchError((_) {});
      throw StarterPhrasebookDownloadException(
        pack.id,
        'HTTP ${response.statusCode} for $url',
        statusCode: response.statusCode,
      );
    }
    final builder = BytesBuilder(copy: false);
    onProgress?.call(0);
    try {
      await for (final chunk in response.stream.timeout(requestTimeout)) {
        builder.add(chunk);
        if (builder.length > pack.size) {
          throw StarterPhrasebookChecksumException(
            pack.id,
            '${pack.fileName}: more than ${pack.size} bytes',
          );
        }
        onProgress?.call(builder.length / pack.size);
      }
    } on StarterPhrasebookException {
      rethrow;
    } on Object catch (error) {
      throw StarterPhrasebookDownloadException(pack.id, '$error');
    }
    final bytes = builder.takeBytes();
    final digest = Sha256.of(bytes);
    if (bytes.length != pack.size || digest != pack.sha256) {
      throw StarterPhrasebookChecksumException(
        pack.id,
        '${pack.fileName}: got ${bytes.length} bytes with SHA-256 $digest, '
        'expected ${pack.size} bytes with SHA-256 ${pack.sha256}',
      );
    }
    return bytes;
  }

  /// The pack in [bytes] (gzip'd JSON). Throws [FormatException] when it
  /// is not a phrasebook pack, or one of another pack than [id].
  static StarterPhrasebook _parse(
    String id,
    Uint8List bytes, {
    required DateTime installedAt,
  }) {
    final text = utf8.decode(gzipDecode(bytes, maxLength: _maxUnpacked));
    final json = jsonDecode(text);
    if (json is! Map<String, Object?>) {
      throw const FormatException('Not a phrasebook');
    }
    final pack = StarterPhrasebook.fromJson(json, installedAt: installedAt);
    if (pack.id != id) throw FormatException('Not the pack $id', pack.id);
    return pack;
  }

  /// The largest unpacked pack (bytes of JSON).
  static const int _maxUnpacked = 8 * 1024 * 1024;
}
