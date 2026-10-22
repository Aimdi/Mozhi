import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:translation_repository/src/dictionary_packs/byte_io.dart';
import 'package:translation_repository/src/dictionary_packs/gzip.dart';
import 'package:translation_repository/src/dictionary_packs/key_folder.dart';
import 'package:translation_repository/src/dictionary_packs/pack_entry.dart';
import 'package:translation_repository/src/dictionary_packs/pack_header.dart';
import 'package:translation_repository/src/dictionary_packs/pack_source.dart';
import 'package:translation_repository/src/dictionary_packs/sha256.dart';

/// An entry found for a key.
@immutable
final class DictionaryPackHit {
  const new({required this.id, required this.entry, this.viaForm = false});

  /// The entry's place in the pack.
  final int id;
  final DictionaryPackEntry entry;

  /// The key is an inflected form of the entry's headword (`went` for
  /// `go`), not the headword itself.
  final bool viaForm;

  @override
  bool operator ==(Object other) =>
      other is DictionaryPackHit &&
      other.id == id &&
      other.entry == entry &&
      other.viaForm == viaForm;

  @override
  int get hashCode => Object.hash(id, entry, viaForm);

  @override
  String toString() => 'DictionaryPackHit($id, ${entry.word}, $viaForm)';
}

/// Reads a dictionary pack ([DictionaryPackHeader] describes the format)
/// without loading it: [open] reads the header, the key directory and the
/// entry block table; look-ups then read and decompress only the blocks
/// they need, keeping the last [cachedBlocks] (each at most the pack's
/// block size, 64 KB) in memory.
///
/// ```dart
/// final reader = await DictionaryPackReader.open(source);
/// final hits = await reader.lookUp('Café'); // café
/// final words = await reader.suggest('caf'); // [café, cafeteria, …]
/// ```
final class DictionaryPackReader {
  new _(
    this._source,
    this.header,
    this._dataStart,
    this._directory,
    this._blocks,
    this.cachedBlocks,
  ) : folder = DictionaryKeyFolder(header.fold);

  /// Opens the pack in [source]. Throws [FormatException] when it is not a
  /// valid pack of a supported format (the source is then closed).
  static Future<DictionaryPackReader> open(
    DictionaryPackSource source, {
    int cachedBlocks = 8,
  }) async {
    try {
      final prefix = await source.read(0, DictionaryPackHeader.prefixLength);
      final metadataLength = DictionaryPackHeader.metadataLength(prefix);
      final metadata = await source.read(
        DictionaryPackHeader.prefixLength,
        metadataLength,
      );
      if (metadata.length != metadataLength) {
        throw const FormatException('Truncated pack metadata');
      }
      final header = DictionaryPackHeader.fromJson(
        jsonDecode(utf8.decode(metadata)),
      );
      final dataStart = DictionaryPackHeader.prefixLength + metadataLength;
      if (dataStart + header.dataLength != source.length) {
        throw const FormatException('The pack has the wrong length');
      }
      final directory = _parseDirectory(
        await _section(source, dataStart, header, header.directory),
        header.dataLength,
      );
      final blocks = _parseBlocks(
        await _section(source, dataStart, header, header.blocks),
        header,
      );
      return DictionaryPackReader._(
        source,
        header,
        dataStart,
        directory,
        blocks,
        math.max(1, cachedBlocks),
      );
    } on Object {
      await source.close();
      rethrow;
    }
  }

  final DictionaryPackSource _source;
  final DictionaryPackHeader header;
  final DictionaryKeyFolder folder;

  /// Decompressed blocks kept in memory.
  final int cachedBlocks;

  final int _dataStart;
  final List<_IndexBlock> _directory;
  final List<_EntryBlock> _blocks;

  /// Decompressed blocks by number (key blocks from 0, entry blocks
  /// negative), least recently used first.
  final Map<int, Completer<Uint8List>> _cache = {};
  bool _closed = false;

  /// Longest decompressed block accepted (a corrupt or hostile size).
  static const int _maxBlock = 1 << 22;

  /// The entries [word] finds (folded like the pack's keys: `Café`, `cafe`
  /// and `CAFÉ` find `café`): those it is the headword of, then those it
  /// is an inflected form of ([DictionaryPackHit.viaForm]). Empty when
  /// the pack does not have it.
  Future<List<DictionaryPackHit>> lookUp(String word) async {
    final key = utf8.encode(folder.fold(word));
    if (key.isEmpty) return const [];
    final start = _blockFor(key);
    if (start < 0) return const [];
    List<int>? refs;
    _scan(await _indexBlock(start), (bytes, display, keyRefs) {
      final order = compareBytes(bytes, key);
      if (order == 0) refs = keyRefs;
      return order < 0;
    });
    final found = refs;
    if (found == null) return const [];
    return [
      for (final ref in found)
        DictionaryPackHit(
          id: ref >> 1,
          entry: await entry(ref >> 1),
          viaForm: ref & 1 == 1,
        ),
    ];
  }

  /// Up to [limit] words starting with [prefix] (folded), in key order, as
  /// written (headwords, else inflected forms): suggestions while typing.
  Future<List<String>> suggest(String prefix, {int limit = 8}) async {
    final key = utf8.encode(folder.fold(prefix));
    if (key.isEmpty || limit <= 0 || _directory.isEmpty) return const [];
    final words = <String>[];
    final seen = <String>{};
    var done = false;
    for (
      var block = math.max(0, _blockFor(key));
      block < _directory.length && !done;
      block++
    ) {
      _scan(await _indexBlock(block), (bytes, display, _) {
        if (compareBytes(bytes, key) < 0) return true;
        if (!startsWithBytes(bytes, key)) {
          done = true;
          return false;
        }
        final word = display.isEmpty ? utf8.decode(bytes) : display;
        if (seen.add(word)) words.add(word);
        done = words.length >= limit;
        return !done;
      });
    }
    return words;
  }

  /// The entry with [id] (0 to the entry count). Throws [RangeError] for
  /// another id and [FormatException] for corrupt data.
  Future<DictionaryPackEntry> entry(int id) async {
    RangeError.checkValueInInterval(id, 0, header.entryCount - 1, 'id');
    var low = 0;
    var high = _blocks.length - 1;
    while (low < high) {
      final middle = (low + high + 1) >> 1;
      if (_blocks[middle].firstId <= id) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    final block = _blocks[low];
    final reader = PackByteReader(await _entryBlock(low));
    for (var skip = id - block.firstId; skip > 0; skip--) {
      reader.skip(reader.varint());
    }
    return DictionaryPackEntry.fromJson(
      jsonDecode(utf8.decode(reader.take(reader.varint()))),
    );
  }

  /// Whether the data section matches the header's SHA-256 (reads the whole
  /// pack, a chunk at a time).
  Future<bool> verify({int chunkSize = 1 << 20}) async {
    final hash = Sha256();
    for (var offset = 0; offset < header.dataLength; offset += chunkSize) {
      final length = math.min(chunkSize, header.dataLength - offset);
      final chunk = await _source.read(_dataStart + offset, length);
      if (chunk.length != length) return false;
      hash.add(chunk);
    }
    return hash.close() == header.sha256;
  }

  /// Closes the source. Look-ups fail afterwards.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _cache.clear();
    await _source.close();
  }

  /// The last key block whose first key is not after [key], or -1.
  int _blockFor(List<int> key) {
    var low = 0;
    var high = _directory.length - 1;
    var found = -1;
    while (low <= high) {
      final middle = (low + high) >> 1;
      if (compareBytes(_directory[middle].firstKey, key) <= 0) {
        found = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return found;
  }

  Future<Uint8List> _indexBlock(int number) {
    final block = _directory[number];
    return _cached(number, block.offset, block.length);
  }

  Future<Uint8List> _entryBlock(int number) {
    final block = _blocks[number];
    return _cached(-1 - number, block.offset, block.length);
  }

  Future<Uint8List> _cached(int number, int offset, int length) async {
    if (_closed) throw StateError('The dictionary pack is closed');
    final cached = _cache.remove(number);
    if (cached != null) {
      _cache[number] = cached;
      return await cached.future;
    }
    final loading = Completer<Uint8List>();
    _cache[number] = loading;
    while (_cache.length > cachedBlocks) {
      _cache.remove(_cache.keys.first);
    }
    try {
      final block = await _load(offset, length);
      loading.complete(block);
      return block;
    } on Object catch (error, stackTrace) {
      // A failed read is not kept; concurrent readers get the error too.
      if (identical(_cache[number], loading)) _cache.remove(number);
      loading
        ..future.ignore()
        ..completeError(error, stackTrace);
      rethrow;
    }
  }

  Future<Uint8List> _load(int offset, int length) async {
    final compressed = await _source.read(_dataStart + offset, length);
    if (compressed.length != length) {
      throw const FormatException('Truncated pack block');
    }
    return gzipDecode(compressed, maxLength: _maxBlock);
  }

  /// Calls [visit] with each key of [block] (its UTF-8 bytes, its display
  /// form or an empty string, its references) while it returns true.
  static void _scan(
    Uint8List block,
    bool Function(Uint8List key, String display, List<int> refs) visit,
  ) {
    final reader = PackByteReader(block);
    var previous = Uint8List(0);
    while (!reader.isAtEnd) {
      final shared = reader.varint();
      final suffix = reader.take(reader.varint());
      if (shared > previous.length) {
        throw const FormatException('Invalid key prefix');
      }
      final key = Uint8List(shared + suffix.length)
        ..setRange(0, shared, previous)
        ..setRange(shared, shared + suffix.length, suffix);
      final display = reader.string();
      final refs = [
        for (var count = reader.varint(); count > 0; count--) reader.varint(),
      ];
      if (!visit(key, display, refs)) return;
      previous = key;
    }
  }

  static Future<Uint8List> _section(
    DictionaryPackSource source,
    int dataStart,
    DictionaryPackHeader header,
    ({int offset, int length}) range,
  ) async {
    if (range.offset + range.length > header.dataLength) {
      throw const FormatException('Pack section out of range');
    }
    final bytes = await source.read(dataStart + range.offset, range.length);
    if (bytes.length != range.length) {
      throw const FormatException('Truncated pack section');
    }
    return bytes;
  }

  static List<_IndexBlock> _parseDirectory(Uint8List bytes, int dataLength) {
    final reader = PackByteReader(bytes);
    final blocks = [
      for (var count = reader.varint(); count > 0; count--)
        _IndexBlock(
          offset: reader.varint(),
          length: reader.varint(),
          firstKey: Uint8List.fromList(reader.take(reader.varint())),
        ),
    ];
    for (final block in blocks) {
      if (block.offset + block.length > dataLength) {
        throw const FormatException('Key block out of range');
      }
    }
    return blocks;
  }

  static List<_EntryBlock> _parseBlocks(
    Uint8List bytes,
    DictionaryPackHeader header,
  ) {
    final reader = PackByteReader(bytes);
    final blocks = [
      for (var count = reader.varint(); count > 0; count--)
        _EntryBlock(
          offset: reader.varint(),
          length: reader.varint(),
          firstId: reader.varint(),
        ),
    ];
    var previous = -1;
    for (final block in blocks) {
      if (block.offset + block.length > header.dataLength ||
          block.firstId <= previous ||
          block.firstId >= header.entryCount) {
        throw const FormatException('Invalid entry block table');
      }
      previous = block.firstId;
    }
    if (header.entryCount > 0 &&
        (blocks.isEmpty || blocks.first.firstId != 0)) {
      throw const FormatException('Invalid entry block table');
    }
    return blocks;
  }
}

final class _IndexBlock {
  const new({
    required this.offset,
    required this.length,
    required this.firstKey,
  });

  final int offset;
  final int length;
  final Uint8List firstKey;
}

final class _EntryBlock {
  const new({
    required this.offset,
    required this.length,
    required this.firstId,
  });

  final int offset;
  final int length;
  final int firstId;
}
