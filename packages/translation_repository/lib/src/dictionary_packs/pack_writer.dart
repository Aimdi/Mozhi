import 'dart:convert';
import 'dart:typed_data';

import 'package:translation_repository/src/dictionary_packs/byte_io.dart';
import 'package:translation_repository/src/dictionary_packs/gzip.dart';
import 'package:translation_repository/src/dictionary_packs/key_folder.dart';
import 'package:translation_repository/src/dictionary_packs/pack_entry.dart';
import 'package:translation_repository/src/dictionary_packs/pack_header.dart';
import 'package:translation_repository/src/dictionary_packs/sha256.dart';

/// Builds a dictionary pack in memory, exactly as the pack builder
/// (`tool/dictionary_packs.py`) lays it out: for tests and small packs.
///
/// 1. Entries are sorted by their key (the folded headword, as UTF-8
///    bytes), then by the order they were added; their place is their id.
/// 2. Every key lists its entries: the entries whose headword it is (ids
///    times two), then the entries it is an inflected form of (ids times
///    two plus one), at most [maxRefs].
/// 3. Entries are written as length-prefixed UTF-8 JSON records into
///    blocks of at most [blockSize] bytes (a larger entry gets a block of
///    its own), each block compressed with `compress` (gzip).
/// 4. Keys are written sorted, front coded within blocks of at most
///    [blockSize] bytes: per key the bytes it shares with the previous key
///    of its block, the rest, its display form when that differs from the
///    key (the headword, or the inflected form, as written), and its
///    entry references.
/// 5. A directory of the key blocks (offset, length, first key) and a
///    table of the entry blocks (offset, length, first entry id) follow.
///
/// Keys are folded with `foldRune` (default [basicFoldRune]); the table of
/// every character used goes into the header.
final class DictionaryPackWriter {
  new({
    required this.language,
    this.glossLanguage = 'en',
    this.name = '',
    this.source = 'Wiktionary',
    this.sourceUrl = '',
    this.extractor = '',
    this.snapshot = '',
    this.license = 'CC BY-SA 4.0',
    this.licenseUrl = '',
    this.attribution = '',
    this.targets = const [],
    this.blockSize = DictionaryPackHeader.defaultBlockSize,
    this._compress = gzipEncodeStored,
    this._foldRune = basicFoldRune,
  });

  /// Most entries a key refers to.
  static const maxRefs = 32;

  final String language;
  final String glossLanguage;
  final String name;
  final String source;
  final String sourceUrl;
  final String extractor;
  final String snapshot;
  final String license;
  final String licenseUrl;
  final String attribution;
  final List<String> targets;
  final int blockSize;
  final Uint8List Function(Uint8List data) _compress;
  final String Function(int rune) _foldRune;

  final List<(DictionaryPackEntry, List<String>)> _entries = [];

  /// Adds [entry], also found under its inflected [forms].
  void add(DictionaryPackEntry entry, {Iterable<String> forms = const []}) {
    _entries.add((entry, List.of(forms)));
  }

  /// The pack's bytes.
  Uint8List build() {
    final fold = _foldTable();
    final folder = DictionaryKeyFolder(fold);
    final entries =
        [
          for (final (index, (entry, forms)) in _entries.indexed)
            (
              index: index,
              entry: entry,
              forms: forms,
              key: utf8.encode(folder.fold(entry.word)),
            ),
        ].where((item) => item.key.isNotEmpty).toList()..sort((a, b) {
          final byKey = compareBytes(a.key, b.key);
          return byKey != 0 ? byKey : a.index - b.index;
        });

    final keys = <String, _Key>{};
    for (final (id, item) in entries.indexed) {
      final key = utf8.decode(item.key);
      (keys[key] ??= _Key()).add(id * 2, item.entry.word, direct: true);
    }
    for (final (id, item) in entries.indexed) {
      final own = utf8.decode(item.key);
      for (final form in item.forms) {
        final key = folder.fold(form);
        if (key.isEmpty || key == own) continue;
        (keys[key] ??= _Key()).add(id * 2 + 1, form, direct: false);
      }
    }

    final data = PackByteWriter();
    final blockTable = PackByteWriter();
    final blocks = <(int, int, int)>[];
    var block = PackByteWriter();
    var first = 0;
    void flushEntries(int next) {
      if (block.length == 0) return;
      final compressed = _compress(block.takeBytes());
      blocks.add((data.length, compressed.length, first));
      data.bytes(compressed);
      block = PackByteWriter();
      first = next;
    }

    for (final (id, item) in entries.indexed) {
      final record = utf8.encode(jsonEncode(item.entry.toJson()));
      final size = _varintLength(record.length) + record.length;
      if (block.length > 0 && block.length + size > blockSize) {
        flushEntries(id);
      }
      block
        ..varint(record.length)
        ..bytes(record);
    }
    flushEntries(entries.length);
    blockTable.varint(blocks.length);
    for (final (offset, length, firstId) in blocks) {
      blockTable
        ..varint(offset)
        ..varint(length)
        ..varint(firstId);
    }

    final sortedKeys = [
      for (final key in keys.keys) (key: key, bytes: utf8.encode(key)),
    ]..sort((a, b) => compareBytes(a.bytes, b.bytes));
    final directory = <(int, int, List<int>)>[];
    var index = PackByteWriter();
    List<int>? firstKey;
    List<int>? previous;
    void flushKeys() {
      if (index.length == 0) return;
      final compressed = _compress(index.takeBytes());
      directory.add((data.length, compressed.length, firstKey!));
      data.bytes(compressed);
      index = PackByteWriter();
      previous = null;
    }

    for (final (:key, :bytes) in sortedKeys) {
      var record = _keyRecord(key, bytes, keys[key]!, previous);
      if (index.length > 0 && index.length + record.length > blockSize) {
        flushKeys();
        // A block starts with a whole key.
        record = _keyRecord(key, bytes, keys[key]!, null);
      }
      if (index.length == 0) firstKey = bytes;
      index.bytes(record);
      previous = bytes;
    }
    flushKeys();

    final directoryBytes = PackByteWriter()..varint(directory.length);
    for (final (offset, length, keyBytes) in directory) {
      directoryBytes
        ..varint(offset)
        ..varint(length)
        ..varint(keyBytes.length)
        ..bytes(keyBytes);
    }
    final directoryOffset = data.length;
    final directoryData = directoryBytes.takeBytes();
    data.bytes(directoryData);
    final blocksOffset = data.length;
    final blockData = blockTable.takeBytes();
    data.bytes(blockData);
    final body = data.takeBytes();

    final header = DictionaryPackHeader(
      language: language,
      glossLanguage: glossLanguage,
      name: name,
      source: source,
      sourceUrl: sourceUrl,
      extractor: extractor,
      snapshot: snapshot,
      license: license,
      licenseUrl: licenseUrl,
      attributionText: attribution,
      targets: targets,
      entryCount: entries.length,
      keyCount: keys.length,
      blockSize: blockSize,
      fold: fold,
      directory: (offset: directoryOffset, length: directoryData.length),
      blocks: (offset: blocksOffset, length: blockData.length),
      dataLength: body.length,
      sha256: Sha256.of(body),
    );
    return (BytesBuilder(copy: false)
          ..add(header.encode())
          ..add(body))
        .takeBytes();
  }

  /// The fold of every character the headwords and forms use and of the
  /// characters they fold to, in either case, plus the combining
  /// diacritics and curly apostrophes, where it changes the character.
  Map<String, String> _foldTable() {
    final runes = <int>{
      for (var rune = 0x300; rune <= 0x36f; rune++) rune,
      0x2018,
      0x2019,
      0x02bc,
    };
    final seen = <int>{
      for (final (entry, forms) in _entries)
        for (final text in [entry.word, ...forms]) ...text.runes,
    };
    // The characters, what they fold to (an accented letter's base letter)
    // and the other cases of both: `CAFE` must find `café`.
    for (final rune in {
      ...seen,
      for (final rune in seen) ..._foldRune(rune).runes,
    }) {
      final char = String.fromCharCode(rune);
      runes
        ..add(rune)
        ..addAll(char.toUpperCase().runes)
        ..addAll(char.toLowerCase().runes);
    }
    final sorted = runes.toList()..sort();
    return {
      for (final rune in sorted)
        if (_foldRune(rune) case final folded
            when folded != String.fromCharCode(rune))
          String.fromCharCode(rune): folded,
    };
  }

  static Uint8List _keyRecord(
    String key,
    List<int> bytes,
    _Key info,
    List<int>? previous,
  ) {
    var shared = 0;
    if (previous != null) {
      final limit = previous.length < bytes.length
          ? previous.length
          : bytes.length;
      while (shared < limit && previous[shared] == bytes[shared]) {
        shared++;
      }
    }
    final display = info.display == key ? '' : info.display;
    final refs = info.refs.take(maxRefs).toList();
    final record = PackByteWriter()
      ..varint(shared)
      ..varint(bytes.length - shared)
      ..bytes(bytes.sublist(shared))
      ..string(display)
      ..varint(refs.length);
    refs.forEach(record.varint);
    return record.takeBytes();
  }

  static int _varintLength(int value) {
    var length = 1;
    var rest = value;
    while (rest >= 0x80) {
      rest >>= 7;
      length++;
    }
    return length;
  }
}

/// What a key refers to while a pack is built.
final class _Key {
  final List<int> _direct = [];
  final List<int> _forms = [];
  String? _directDisplay;
  String? _formDisplay;

  /// The headword, else the first inflected form, as written.
  String get display => _directDisplay ?? _formDisplay ?? '';

  /// Direct references first, each once.
  List<int> get refs => [..._direct, ..._forms];

  void add(int ref, String text, {required bool direct}) {
    if (direct) {
      _directDisplay ??= text;
      _direct.add(ref);
    } else {
      _formDisplay ??= text;
      if (!_forms.contains(ref)) _forms.add(ref);
    }
  }
}
