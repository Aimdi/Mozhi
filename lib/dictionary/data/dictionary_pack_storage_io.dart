import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mozhi/dictionary/data/dictionary_pack_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:translation_repository/translation_repository.dart';

/// Folder of the app's support directory that holds the dictionary packs.
const dictionaryPacksFolder = 'dictionary';

/// The app's pack storage: [FileDictionaryPackStorage] in
/// `<support>/dictionary` (not backed up, removed with the app).
DictionaryPackStorage createDictionaryPackStorage() =>
    FileDictionaryPackStorage(root: _supportFolder);

// coverage:ignore-start
// A platform call: only in the app.
Future<Directory> _supportFolder() async => Directory(
  '${(await getApplicationSupportDirectory()).path}'
  '${Platform.pathSeparator}$dictionaryPacksFolder',
);
// coverage:ignore-end

/// Dictionary packs as files in an app-private directory:
///
/// * `<root>/<id>.mzd`: an installed pack, opened for random access;
///   next to it `<id>.json` records its language, size and SHA-256. A
///   pack file without a valid record (or of another size) is not
///   installed.
/// * `<root>/.downloads/<id>-<random>.part`: a pack being written. It is
///   moved into place with one rename once it is checked, so a reader
///   never sees a partial pack.
class FileDictionaryPackStorage implements DictionaryPackStorage {
  /// [_root] is resolved on first use (the app's support directory needs a
  /// platform call).
  new({required this._root});

  final Future<Directory> Function() _root;
  Future<Directory>? _resolved;

  static const _extension = '.mzd';

  @override
  bool get isSupported => true;

  Future<Directory> get _directory => _resolved ??= _root();

  @override
  Future<List<StoredDictionaryPack>> list() async {
    final directory = await _directory;
    if (!directory.existsSync()) return const [];
    final packs = <StoredDictionaryPack>[];
    try {
      await for (final entry in directory.list()) {
        if (entry is! File || !entry.path.endsWith('.json')) continue;
        final pack = await _readRecord(entry);
        if (pack != null) packs.add(pack);
      }
      // coverage:ignore-start
    } on FileSystemException {
      // Unreadable directory: nothing installed.
    }
    // coverage:ignore-end
    return packs..sort((a, b) => a.id.compareTo(b.id));
  }

  @override
  Future<DictionaryPackSink> create(String id) async {
    _check(id);
    final downloads = Directory(_join((await _directory).path, '.downloads'));
    await downloads.create(recursive: true);
    final part = File(_join(downloads.path, '$id-${_randomSuffix()}.part'));
    return _FileSink(this, part, part.openWrite());
  }

  @override
  Future<DictionaryPackSource> open(String id) async {
    _check(id);
    final file = File(await _packPath(id));
    final handle = await file.open();
    return _FileSource(handle, await handle.length());
  }

  @override
  Future<void> delete(String id) async {
    _check(id);
    // The record first: without it the file no longer counts as installed.
    await _deleteQuietly(File(await _recordPath(id)));
    await _deleteQuietly(File(await _packPath(id)));
  }

  /// Removes partial downloads and pack files without a record.
  @override
  Future<void> cleanUp() async {
    final directory = await _directory;
    if (!directory.existsSync()) return;
    await _deleteQuietly(Directory(_join(directory.path, '.downloads')));
    final installed = {
      for (final pack in await list())
        _join(directory.path, '${pack.id}$_extension'),
    };
    try {
      await for (final entry in directory.list()) {
        if (entry is File &&
            entry.path.endsWith(_extension) &&
            !installed.contains(entry.path)) {
          await _deleteQuietly(entry);
        }
      }
      // coverage:ignore-start
    } on FileSystemException {
      // Best effort.
    }
    // coverage:ignore-end
  }

  Future<void> _install(File part, StoredDictionaryPack pack) async {
    _check(pack.id);
    final directory = await _directory;
    await directory.create(recursive: true);
    final record = File(
      _join(directory.path, '.${pack.id}-${_randomSuffix()}.json'),
    );
    try {
      await record.writeAsString(jsonEncode(_record(pack)), flush: true);
      // Another version's record goes first: until the new one is in
      // place, the file counts as not installed.
      await _deleteQuietly(File(await _recordPath(pack.id)));
      await part.rename(await _packPath(pack.id));
      await record.rename(await _recordPath(pack.id));
    } finally {
      await _deleteQuietly(record);
      await _deleteQuietly(part);
    }
  }

  Map<String, Object?> _record(StoredDictionaryPack pack) => {
    'schemaVersion': 1,
    ...pack.toJson(),
  };

  Future<StoredDictionaryPack?> _readRecord(File record) async {
    try {
      final json = jsonDecode(await record.readAsString());
      if (json is! Map<String, Object?> || json['schemaVersion'] != 1) {
        return null;
      }
      final pack = StoredDictionaryPack.fromJson(json);
      if (pack == null || _basename(record.path) != '${pack.id}.json') {
        return null;
      }
      final file = File(await _packPath(pack.id));
      if (await file.length() != pack.size) return null;
      return pack;
    } on Object {
      return null;
    }
  }

  Future<String> _packPath(String id) async =>
      _join((await _directory).path, '$id$_extension');

  Future<String> _recordPath(String id) async =>
      _join((await _directory).path, '$id.json');

  static String _join(String directory, String name) =>
      '$directory${Platform.pathSeparator}$name';

  static String _basename(String path) =>
      path.substring(path.lastIndexOf(Platform.pathSeparator) + 1);

  static void _check(String id) {
    if (!isDictionaryPackId(id)) {
      throw ArgumentError.value(id, 'id', 'Invalid dictionary pack id');
    }
  }

  static final _random = Random();

  static String _randomSuffix() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(1 << 32)}';

  static Future<void> _deleteQuietly(FileSystemEntity entity) async {
    try {
      if (entity.existsSync()) await entity.delete(recursive: true);
      // coverage:ignore-start
    } on FileSystemException {
      // Best effort: leftovers are removed by the next cleanUp().
    }
    // coverage:ignore-end
  }
}

class _FileSink implements DictionaryPackSink {
  new(this._storage, this._part, this._sink);

  final FileDictionaryPackStorage _storage;
  final File _part;
  final IOSink _sink;
  bool _closed = false;

  @override
  Future<void> add(Uint8List chunk) async => _sink.add(chunk);

  @override
  Future<void> commit(StoredDictionaryPack pack) async {
    await _close();
    if (await _part.length() != pack.size) {
      await FileDictionaryPackStorage._deleteQuietly(_part);
      throw FileSystemException('Pack size changed while writing', _part.path);
    }
    await _storage._install(_part, pack);
  }

  @override
  Future<void> abort() async {
    try {
      await _close();
    } finally {
      await FileDictionaryPackStorage._deleteQuietly(_part);
    }
  }

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    await _sink.flush();
    await _sink.close();
  }
}

/// A pack file opened for reading; reads run one after the other (a
/// [RandomAccessFile] allows one operation at a time).
class _FileSource implements DictionaryPackSource {
  new(this._file, this.length);

  final RandomAccessFile _file;

  @override
  final int length;

  Future<void> _last = Future.value();
  bool _closed = false;

  @override
  Future<Uint8List> read(int offset, int length) {
    final result = _last.then((_) async {
      if (_closed) throw StateError('The dictionary pack is closed');
      await _file.setPosition(offset);
      return await _file.read(length);
    });
    _last = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  @override
  Future<void> close() {
    final done = _last.then((_) async {
      if (_closed) return;
      _closed = true;
      await _file.close();
    });
    _last = done;
    return done;
  }
}
