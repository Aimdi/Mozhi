import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:translation_repository/translation_repository.dart';

/// A dictionary pack on the device, as its storage recorded it when it was
/// installed (after its size and SHA-256 were checked).
@immutable
class StoredDictionaryPack {
  const new({
    required this.id,
    required this.language,
    required this.size,
    required this.sha256,
    this.name = '',
  });

  /// Tolerant counterpart of [toJson]: null for anything invalid.
  static StoredDictionaryPack? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final id = json['id'];
    final language = json['language'];
    final size = json['size'];
    final sha256 = json['sha256'];
    final name = json['name'];
    if (id is! String ||
        !isDictionaryPackId(id) ||
        language is! String ||
        language.isEmpty ||
        size is! int ||
        size <= 0 ||
        sha256 is! String ||
        !_hexSha256.hasMatch(sha256)) {
      return null;
    }
    return StoredDictionaryPack(
      id: id,
      language: language,
      size: size,
      sha256: sha256,
      name: name is String ? name : '',
    );
  }

  /// The catalogue's [DictionaryPackInfo.id].
  final String id;

  /// Language of the words.
  final String language;

  /// English name of [language].
  final String name;

  /// Bytes of the file.
  final int size;

  /// SHA-256 the file was checked with (compare with the catalogue's to see
  /// whether a newer version exists).
  final String sha256;

  Map<String, Object?> toJson() => {
    'id': id,
    'language': language,
    'name': name,
    'size': size,
    'sha256': sha256,
  };

  @override
  bool operator ==(Object other) =>
      other is StoredDictionaryPack &&
      other.id == id &&
      other.language == language &&
      other.name == name &&
      other.size == size &&
      other.sha256 == sha256;

  @override
  int get hashCode => Object.hash(id, language, name, size, sha256);

  @override
  String toString() => 'StoredDictionaryPack($id)';
}

/// A pack being written to a [DictionaryPackStorage]: [add] its bytes,
/// then [commit] once they are checked (the pack then replaces another
/// version at once), or [abort].
abstract interface class DictionaryPackSink {
  Future<void> add(Uint8List chunk);

  /// Installs the written bytes as [pack].
  Future<void> commit(StoredDictionaryPack pack);

  /// Discards the written bytes; an installed version stays.
  Future<void> abort();
}

/// Where the app keeps its dictionary packs: app files on Android, the
/// origin private file system (OPFS) in a browser, memory in tests.
abstract interface class DictionaryPackStorage {
  /// Whether packs can be kept here (a browser without OPFS cannot).
  bool get isSupported;

  /// Every installed pack, sorted by id.
  Future<List<StoredDictionaryPack>> list();

  /// Starts writing the pack [id].
  Future<DictionaryPackSink> create(String id);

  /// Random access to the installed pack [id]. Throws when it is not
  /// installed.
  Future<DictionaryPackSource> open(String id);

  /// Removes the pack [id] (nothing when it is not installed).
  Future<void> delete(String id);

  /// Removes leftovers of interrupted installs. Safe at start-up.
  Future<void> cleanUp();
}

/// Whether [id] is a valid pack id ([DictionaryPackInfo.id]): it names a
/// file directly in the storage.
bool isDictionaryPackId(String id) => _id.hasMatch(id);

final _id = RegExp(r'^[a-z]{2,3}(-[a-z0-9]{2,8})*$');
final _hexSha256 = RegExp(r'^[0-9a-f]{64}$');

/// Packs in memory (tests, and a browser without OPFS: nothing is kept).
class MemoryDictionaryPackStorage implements DictionaryPackStorage {
  new({this.isSupported = true});

  @override
  final bool isSupported;

  final Map<String, (StoredDictionaryPack, Uint8List)> _packs = {};

  /// Adds [bytes] as the installed pack [pack] (tests).
  void put(StoredDictionaryPack pack, Uint8List bytes) =>
      _packs[pack.id] = (pack, bytes);

  @override
  Future<List<StoredDictionaryPack>> list() async => [
    for (final id in _packs.keys.toList()..sort()) _packs[id]!.$1,
  ];

  @override
  Future<DictionaryPackSink> create(String id) async {
    _check(id);
    return _MemorySink(this);
  }

  @override
  Future<DictionaryPackSource> open(String id) async {
    final stored = _packs[id];
    if (stored == null) throw StateError('Dictionary pack $id not installed');
    return MemoryDictionaryPackSource(stored.$2);
  }

  @override
  Future<void> delete(String id) async => _packs.remove(id);

  @override
  Future<void> cleanUp() async {}

  static void _check(String id) {
    if (!isDictionaryPackId(id)) {
      throw ArgumentError.value(id, 'id', 'Invalid dictionary pack id');
    }
  }
}

class _MemorySink implements DictionaryPackSink {
  new(this._storage);

  final MemoryDictionaryPackStorage _storage;
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  @override
  Future<void> add(Uint8List chunk) async => _bytes.add(chunk);

  @override
  Future<void> commit(StoredDictionaryPack pack) async {
    MemoryDictionaryPackStorage._check(pack.id);
    _storage.put(pack, _bytes.takeBytes());
  }

  @override
  Future<void> abort() async => _bytes.clear();
}
