import 'dart:typed_data';

/// Random access to the bytes of a dictionary pack, so a reader loads only
/// the parts it needs: a file on Android, a file in the browser's private
/// storage on the web, or memory ([MemoryDictionaryPackSource]).
abstract interface class DictionaryPackSource {
  /// Bytes of the pack.
  int get length;

  /// [length] bytes from [offset] (fewer only past the end).
  Future<Uint8List> read(int offset, int length);

  /// Releases the file; no read follows.
  Future<void> close();
}

/// A pack held in memory (tests, or a pack just built).
final class MemoryDictionaryPackSource implements DictionaryPackSource {
  new(this._bytes);

  final Uint8List _bytes;

  @override
  int get length => _bytes.length;

  @override
  Future<Uint8List> read(int offset, int length) {
    final start = offset.clamp(0, _bytes.length);
    final end = (offset + length).clamp(start, _bytes.length);
    return Future.value(Uint8List.sublistView(_bytes, start, end));
  }

  @override
  Future<void> close() => Future.value();
}
