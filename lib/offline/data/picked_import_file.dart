import 'package:bergamot_translator/bergamot_translator.dart'
    show ModelImportSource;
import 'package:flutter/foundation.dart';

/// A file the user picked to import (language packs, dictionary packs),
/// read by its contents: the web app's picks have no path. Its bytes are
/// read in chunks, as often as needed ([openRead]).
@immutable
class PickedImportFile implements ModelImportSource {
  const new({required this.name, required this.length, required this._read});

  /// A picked file held in memory.
  factory bytes(String name, Uint8List bytes, {int chunkSize = 1 << 20}) =>
      PickedImportFile(
        name: name,
        length: bytes.length,
        read: () async* {
          for (var start = 0; start < bytes.length; start += chunkSize) {
            final end = start + chunkSize < bytes.length
                ? start + chunkSize
                : bytes.length;
            yield Uint8List.sublistView(bytes, start, end);
          }
        },
      );

  /// The file's name as picked (no folders).
  @override
  final String name;

  /// Its size in bytes; null when the platform could not tell.
  @override
  final int? length;

  final Stream<List<int>> Function() _read;

  @override
  Stream<List<int>> openRead() => _read();

  @override
  String toString() => 'PickedImportFile($name, $length)';
}
