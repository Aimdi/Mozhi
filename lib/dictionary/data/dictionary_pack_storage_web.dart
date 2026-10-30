// coverage:ignore-file
// Browser-only (dart:js_interop): exercised in the web build, not by the
// VM tests (the storage contract is tested with the file and memory
// storages).

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:mozhi/dictionary/data/dictionary_pack_storage.dart';
import 'package:translation_repository/translation_repository.dart';

/// The browser's pack storage: [OpfsDictionaryPackStorage] when the
/// browser has the origin private file system with writable files, else
/// memory that keeps nothing ([DictionaryPackStorage.isSupported] false).
DictionaryPackStorage createDictionaryPackStorage() =>
    OpfsDictionaryPackStorage.isAvailable
    ? OpfsDictionaryPackStorage()
    : MemoryDictionaryPackStorage(isSupported: false);

/// Dictionary packs in the origin private file system (OPFS), in the
/// folder `dictionary`: `<id>.mzd` per pack, and `packs.json` with the
/// record of every installed pack. A pack file is written through a
/// writable stream, which the browser applies in one step when it is
/// closed, so a reader never sees a partial pack; the record is updated
/// after that. Reads slice the file (`Blob.slice`), so a pack is never
/// loaded whole.
class OpfsDictionaryPackStorage implements DictionaryPackStorage {
  /// Whether this browser has OPFS with writable files (Chrome, Edge,
  /// Firefox, Safari 26).
  static bool get isAvailable {
    final navigator = globalContext.getProperty<JSObject?>('navigator'.toJS);
    final storage = navigator?.getProperty<JSObject?>('storage'.toJS);
    if (storage == null || !storage.has('getDirectory')) return false;
    final handle = globalContext.getProperty<JSObject?>(
      'FileSystemFileHandle'.toJS,
    );
    final prototype = handle?.getProperty<JSObject?>('prototype'.toJS);
    return prototype != null && prototype.has('createWritable');
  }

  static const _folder = 'dictionary';
  static const _index = 'packs.json';

  Future<_DirectoryHandle>? _directory;

  /// Whether the browser refused its private storage although it has the
  /// API (Firefox's private windows, site data blocked): from then on this
  /// storage is not supported, nothing is installed.
  bool _refused = false;

  /// Index writes run one after the other.
  Future<void> _lastIndexWrite = Future.value();

  @override
  bool get isSupported => !_refused;

  Future<_DirectoryHandle> get _folderHandle => _directory ??= () async {
    final _DirectoryHandle root;
    try {
      root = await _storageManager().getDirectory().toDart;
    } on Object {
      _refused = true;
      rethrow;
    }
    _refused = false;
    return await root.getDirectoryHandle(_folder, _create).toDart;
  }();

  Future<_DirectoryHandle> get _openFolder async {
    final opening = _folderHandle;
    try {
      return await opening;
    } on Object {
      // Asked again next time (unless the browser refused the storage).
      if (identical(_directory, opening)) _directory = null;
      rethrow;
    }
  }

  @override
  Future<List<StoredDictionaryPack>> list() async {
    final _DirectoryHandle directory;
    try {
      directory = await _openFolder;
    } on Object {
      if (_refused) return const [];
      rethrow;
    }
    final packs = <StoredDictionaryPack>[];
    for (final pack in await _readIndex(directory)) {
      try {
        final file =
            await (await directory.getFileHandle('${pack.id}.mzd').toDart)
                .getFile()
                .toDart;
        if (file.size == pack.size) packs.add(pack);
      } on Object {
        // Missing file: not installed.
      }
    }
    return packs..sort((a, b) => a.id.compareTo(b.id));
  }

  @override
  Future<DictionaryPackSink> create(String id) async {
    _check(id);
    final directory = await _openFolder;
    final handle = await directory.getFileHandle('$id.mzd', _create).toDart;
    final stream = await handle.createWritable().toDart;
    return _OpfsSink(this, stream);
  }

  @override
  Future<DictionaryPackSource> open(String id) async {
    _check(id);
    final directory = await _openFolder;
    final file = await (await directory.getFileHandle('$id.mzd').toDart)
        .getFile()
        .toDart;
    return _BlobSource(file);
  }

  @override
  Future<void> delete(String id) async {
    _check(id);
    final directory = await _openFolder;
    await _updateIndex((packs) => packs..removeWhere((pack) => pack.id == id));
    try {
      await directory.removeEntry('$id.mzd').toDart;
    } on Object {
      // Not there.
    }
  }

  /// Nothing to remove: an interrupted write never replaces a file.
  @override
  Future<void> cleanUp() async {}

  Future<void> _record(StoredDictionaryPack pack) => _updateIndex(
    (packs) => packs
      ..removeWhere((other) => other.id == pack.id)
      ..add(pack),
  );

  Future<void> _updateIndex(
    List<StoredDictionaryPack> Function(List<StoredDictionaryPack>) change,
  ) {
    final next = _lastIndexWrite.then((_) async {
      final directory = await _openFolder;
      final packs = change(await _readIndex(directory));
      final handle = await directory.getFileHandle(_index, _create).toDart;
      final stream = await handle.createWritable().toDart;
      final bytes = utf8.encode(
        jsonEncode({
          'schemaVersion': 1,
          'packs': [for (final pack in packs) pack.toJson()],
        }),
      );
      await stream.write(bytes.toJS).toDart;
      await stream.close().toDart;
    });
    _lastIndexWrite = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  Future<List<StoredDictionaryPack>> _readIndex(
    _DirectoryHandle directory,
  ) async {
    try {
      final file = await (await directory.getFileHandle(_index).toDart)
          .getFile()
          .toDart;
      final buffer = await file.slice(0, file.size).arrayBuffer().toDart;
      final json = jsonDecode(utf8.decode(buffer.toDart.asUint8List()));
      if (json is! Map<String, Object?> || json['schemaVersion'] != 1) {
        return [];
      }
      return [
        for (final item in json['packs'] as List<Object?>? ?? const [])
          ?StoredDictionaryPack.fromJson(item),
      ];
    } on Object {
      return [];
    }
  }

  static void _check(String id) {
    if (!isDictionaryPackId(id)) {
      throw ArgumentError.value(id, 'id', 'Invalid dictionary pack id');
    }
  }
}

class _OpfsSink implements DictionaryPackSink {
  new(this._storage, this._stream);

  final OpfsDictionaryPackStorage _storage;
  final _WritableStream _stream;
  int _written = 0;

  @override
  Future<void> add(Uint8List chunk) async {
    _written += chunk.length;
    await _stream.write(chunk.toJS).toDart;
  }

  @override
  Future<void> commit(StoredDictionaryPack pack) async {
    if (_written != pack.size) {
      await abort();
      throw StateError('Pack size changed while writing');
    }
    await _stream.close().toDart;
    await _storage._record(pack);
  }

  @override
  Future<void> abort() async {
    try {
      await _stream.abort().toDart;
    } on Object {
      // Already closed.
    }
  }
}

/// Reads slices of a pack file (a `File` snapshot from OPFS).
class _BlobSource implements DictionaryPackSource {
  new(this._file);

  final _File _file;

  @override
  int get length => _file.size;

  @override
  Future<Uint8List> read(int offset, int length) async {
    final end = offset + length > _file.size ? _file.size : offset + length;
    final buffer = await _file.slice(offset, end).arrayBuffer().toDart;
    return buffer.toDart.asUint8List();
  }

  @override
  Future<void> close() async {}
}

_StorageManager _storageManager() => globalContext
    .getProperty<JSObject>('navigator'.toJS)
    .getProperty<_StorageManager>('storage'.toJS);

final _create = _GetHandleOptions(create: true);

extension type _GetHandleOptions._(JSObject _) implements JSObject {
  external factory({bool create});
}

extension type _StorageManager._(JSObject _) implements JSObject {
  external JSPromise<_DirectoryHandle> getDirectory();
}

extension type _DirectoryHandle._(JSObject _) implements JSObject {
  external JSPromise<_DirectoryHandle> getDirectoryHandle(
    String name, [
    _GetHandleOptions options,
  ]);

  external JSPromise<_FileHandle> getFileHandle(
    String name, [
    _GetHandleOptions options,
  ]);

  external JSPromise<JSAny?> removeEntry(String name);
}

extension type _FileHandle._(JSObject _) implements JSObject {
  external JSPromise<_File> getFile();

  external JSPromise<_WritableStream> createWritable();
}

extension type _WritableStream._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> write(JSUint8Array data);

  external JSPromise<JSAny?> close();

  external JSPromise<JSAny?> abort();
}

extension type _File._(JSObject _) implements JSObject {
  external int get size;

  external _Blob slice(int start, int end);
}

extension type _Blob._(JSObject _) implements JSObject {
  external JSPromise<JSArrayBuffer> arrayBuffer();
}
