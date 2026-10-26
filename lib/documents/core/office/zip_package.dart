import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:mozhi/documents/core/office/package_errors.dart';
import 'package:mozhi/documents/core/text_encoding.dart';

/// Limits for untrusted ZIP packages.
final class PackageLimits {
  const new({
    this.maxEntries = 10000,
    this.maxPartBytes = 32 * 1024 * 1024,
    this.maxParsedBytes = 128 * 1024 * 1024,
    this.maxTotalBytes = 2 * 1024 * 1024 * 1024,
    this.maxRatio = 500,
    this.ratioFloorBytes = 1024 * 1024,
    this.maxDepth = 256,
  });

  /// Most entries a package may have.
  final int maxEntries;

  /// Largest XML part that is read (uncompressed).
  final int maxPartBytes;

  /// Most bytes read from all parts together (uncompressed).
  final int maxParsedBytes;

  /// Most bytes all entries may claim together (uncompressed): a sanity
  /// bound; entries that are not read are copied without unpacking them.
  final int maxTotalBytes;

  /// Highest compression ratio of a part that is read and larger than
  /// [ratioFloorBytes], and of the whole package when its entries claim
  /// more than [ratioFloorBytes] together (decompression bombs).
  final int maxRatio;
  final int ratioFloorBytes;

  /// Deepest element nesting in a part.
  final int maxDepth;
}

/// How an XML part's text is encoded.
enum PartEncoding { utf8, utf8Bom, utf16le, utf16be, latin1 }

/// A ZIP package read defensively: refuses encrypted, damaged and unsafe
/// archives (see [PackageLimits]) and entry names that could leave the
/// package (absolute paths, `..`, drive letters, backslashes, control
/// characters).
///
/// The directory is checked before the archive library decodes it (which
/// unpacks symbolic links right away): symbolic links, entries that lie
/// outside the file or overlap each other, and declared sizes over the
/// limits are refused without unpacking anything.
final class ZipPackage {
  new _(this.bytes, this.entries, this.limits)
    : _byName = {for (final entry in entries) entry.name: entry},
      _byLowerName = {
        for (final entry in entries) entry.name.toLowerCase(): entry,
      };

  /// Reads [bytes]. Throws [PackageParseException].
  factory read(
    Uint8List bytes, {
    PackageLimits limits = const PackageLimits(),
  }) {
    if (_startsWith(bytes, _compoundFile)) {
      // Encrypted Office files (and old .doc/.xls/.ppt files) are OLE
      // compound files, not ZIP packages.
      throw _containsUtf16(bytes, 'EncryptionInfo')
          ? const PackageParseException(
              PackageProblem.encrypted,
              'an encrypted Office document',
            )
          : const PackageParseException(
              PackageProblem.damaged,
              'an old binary Office document',
            );
    }
    if (!_startsWith(bytes, _localHeader)) {
      throw const PackageParseException(
        PackageProblem.damaged,
        'not a ZIP package',
      );
    }
    _checkDirectory(bytes, limits);

    final decoder = ZipDecoder();
    final Archive archive;
    try {
      archive = decoder.decodeBytes(bytes);
      // Bad data inside an archive surfaces as any kind of error. After
      // _checkDirectory, nothing is left for the decoder to fail on; kept
      // in case a later version of it reads more while decoding.
    } catch (error) {
      // coverage:ignore-start
      throw PackageParseException(
        PackageProblem.damaged,
        'damaged ZIP package ($error)',
      );
      // coverage:ignore-end
    }
    // Entry count and sizes were checked by _checkDirectory.
    final headers = decoder.directory.fileHeaders;
    if (headers.length != archive.length) {
      throw const PackageParseException(
        PackageProblem.unsafe,
        'duplicate entry names',
      );
    }
    for (final header in headers) {
      final file = header.file;
      if (file != null && file.flags & 0x1 != 0) {
        throw const PackageParseException(
          PackageProblem.encrypted,
          'password-protected ZIP entries',
        );
      }
    }
    for (final entry in archive) {
      if (!isSafeEntryName(entry.name)) {
        throw PackageParseException(
          PackageProblem.unsafe,
          'unsafe entry name ${jsonEncode(entry.name)}',
        );
      }
    }
    return ZipPackage._(bytes, archive.files.toList(), limits);
  }

  /// The package as read.
  final Uint8List bytes;
  final List<ArchiveFile> entries;
  final PackageLimits limits;
  final Map<String, ArchiveFile> _byName;
  final Map<String, ArchiveFile> _byLowerName;
  int _parsedBytes = 0;

  /// The file [name] (exact), or null.
  ArchiveFile? file(String name) {
    final entry = _byName[name];
    return entry != null && entry.isFile ? entry : null;
  }

  /// The file [name] compared without case (OPC part names), or null.
  ArchiveFile? fileIgnoringCase(String name) {
    final entry = _byName[name] ?? _byLowerName[name.toLowerCase()];
    return entry != null && entry.isFile ? entry : null;
  }

  /// Whether [entry] can be read within the limits.
  bool canRead(ArchiveFile entry) {
    final size = entry.size;
    final content = entry.rawContent;
    final compressed = content is ZipFile ? content.compressedSize : size;
    return size <= limits.maxPartBytes &&
        (size <= limits.ratioFloorBytes ||
            (compressed > 0 && size / compressed <= limits.maxRatio)) &&
        _parsedBytes + size <= limits.maxParsedBytes;
  }

  /// The unpacked bytes of [entry], within the limits.
  Uint8List readBytes(ArchiveFile entry) {
    final size = entry.size;
    final content = entry.rawContent;
    // Files of a decoded package always have content.
    if (content == null) return Uint8List(0); // coverage:ignore-line
    final compressed = content is ZipFile ? content.compressedSize : size;
    if (size > limits.maxPartBytes) {
      throw PackageParseException(
        PackageProblem.unsafe,
        '${entry.name} is too large',
      );
    }
    if (size > limits.ratioFloorBytes &&
        (compressed <= 0 || size / compressed > limits.maxRatio)) {
      throw PackageParseException(
        PackageProblem.unsafe,
        '${entry.name} is compressed suspiciously well',
      );
    }
    _parsedBytes += size;
    if (_parsedBytes > limits.maxParsedBytes) {
      throw const PackageParseException(
        PackageProblem.unsafe,
        'the document unpacks to too much text',
      );
    }
    try {
      final output = OutputMemoryStream(size: size > 0 ? size : null);
      content.decompress(output);
      return output.getBytes();
      // Bad data inside an archive surfaces as any kind of error.
    } catch (error) {
      throw PackageParseException(
        PackageProblem.damaged,
        '${entry.name} is damaged ($error)',
      );
    }
  }

  /// The text of the XML part [entry] and its encoding.
  (String, PartEncoding) readText(ArchiveFile entry) =>
      decodePart(readBytes(entry), entry.name);

  /// Writes the package again: entries in their original order (with
  /// `mimetype` first and stored when [mimetypeFirst]), [replaced] entries
  /// deflated, every other entry copied as it was stored. A compressed
  /// `mimetype` is unpacked within the limits of [readBytes].
  Uint8List write(
    Map<String, Uint8List> replaced, {
    required bool mimetypeFirst,
  }) {
    final ordered = [...entries];
    if (mimetypeFirst) {
      final index = ordered.indexWhere((entry) => entry.name == 'mimetype');
      if (index > 0) ordered.insert(0, ordered.removeAt(index));
    }
    final archive = Archive();
    for (final entry in ordered) {
      final ArchiveFile copy;
      final content = replaced[entry.name];
      if (!entry.isFile) {
        copy = ArchiveFile.directory(entry.name);
      } else if (content != null) {
        copy = ArchiveFile.bytes(entry.name, content)
          ..compression = CompressionType.deflate;
      } else if ((mimetypeFirst && entry.name == 'mimetype') ||
          entry.compression == CompressionType.none) {
        // Stored entries are written with their sizes up front (no data
        // descriptor), as ODF and EPUB require for `mimetype`.
        final data = entry.compression == CompressionType.none
            ? _stored(entry)
            : readBytes(entry);
        copy = ArchiveFile.noCompress(entry.name, data.length, data);
      } else {
        copy = entry;
      }
      copy
        ..lastModTime = _epochSeconds(entry)
        ..mode = entry.mode;
      archive.add(copy);
    }
    return ZipEncoder().encodeBytes(archive, level: 6);
  }

  static Uint8List _stored(ArchiveFile entry) {
    final content = entry.rawContent;
    // Files of a decoded package always have content.
    if (content == null) return Uint8List(0); // coverage:ignore-line
    final output = OutputMemoryStream();
    content.decompress(output);
    return output.getBytes();
  }

  /// The archive library reads entry times in MS-DOS format but writes
  /// them from seconds since the epoch; this converts, so that copied
  /// entries keep their times.
  static int _epochSeconds(ArchiveFile entry) {
    final dos = entry.lastModDateTime;
    final valid = dos.year >= 1980 && dos.month >= 1 && dos.day >= 1;
    final local = valid
        ? DateTime(
            dos.year,
            dos.month,
            dos.day,
            dos.hour,
            dos.minute,
            dos.second,
          )
        : DateTime(1980);
    return local.millisecondsSinceEpoch ~/ 1000;
  }

  /// Whether [name] stays inside the package when extracted.
  static bool isSafeEntryName(String name) {
    if (name.isEmpty || name.length > 1024) return false;
    if (name.startsWith('/') || name.contains(r'\')) return false;
    if (RegExp('^[A-Za-z]:').hasMatch(name)) return false;
    for (final unit in name.codeUnits) {
      if (unit < 0x20 || unit == 0x7F) return false;
    }
    final segments = name.split('/');
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      if (segment == '..' || segment == '.') return false;
      // Only a directory entry may end with a slash.
      if (segment.isEmpty && i != segments.length - 1) return false;
    }
    return true;
  }

  static const _eocdSignature = 0x06054b50;
  static const _zip64LocatorSignature = 0x07064b50;
  static const _zip64RecordSignature = 0x06064b50;
  static const _centralSignature = 0x02014b50;
  static const _localSignature = 0x04034b50;

  /// Stands for 64-bit sizes and offsets from 2^53 on (far beyond any
  /// limit), which are not exact integers on the web.
  static const _huge = 0x20000000000000;

  /// Checks the directory before the archive is decoded, reading it the way
  /// the decoder of package:archive will (its `ZipDirectory` and
  /// `ZipFileHeader`): the end of central directory record (and a ZIP64
  /// record its locator points to), then every central directory header
  /// and the local header it points to. Refuses, without unpacking
  /// anything:
  /// * too many entries (also as announced) or too large a directory;
  /// * symbolic links (Unix mode `0xA000`), which the decoder would unpack
  ///   while decoding, before any limit applies;
  /// * declared sizes over [PackageLimits.maxTotalBytes] together, or more
  ///   than [PackageLimits.maxRatio] times the size of the file;
  /// * a directory, local header or entry data that lies outside the file
  ///   (damaged), and entries that overlap each other or the directory
  ///   (unsafe: copied entries would repeat the same bytes).
  static void _checkDirectory(Uint8List bytes, PackageLimits limits) {
    final data = ByteData.sublistView(bytes);
    int u16(int at) => data.getUint16(at, Endian.little);
    int u32(int at) => data.getUint32(at, Endian.little);
    // 64-bit fields, read as two halves (the web has no getUint64).
    int u64(int at) {
      final high = u32(at + 4);
      return high >= _huge ~/ 0x100000000
          ? _huge
          : high * 0x100000000 + u32(at);
    }

    Never damaged(String what) => throw PackageParseException(
      PackageProblem.damaged,
      'damaged ZIP package ($what)',
    );
    Never unsafe(String what) =>
        throw PackageParseException(PackageProblem.unsafe, what);

    // The decoder takes the last end of central directory record.
    const eocdSize = 22;
    final lowest = bytes.length - eocdSize - 0xFFFF;
    var position = bytes.length - eocdSize;
    while (position >= 0 &&
        position >= lowest &&
        u32(position) != _eocdSignature) {
      position--;
    }
    if (position < 0 || position < lowest) {
      throw const PackageParseException(
        PackageProblem.damaged,
        'no ZIP directory',
      );
    }
    var count = u16(position + 10);
    var directorySize = u32(position + 12);
    var directoryOffset = u32(position + 16);
    // Like the decoder, follow a ZIP64 locator whatever the record says.
    final locator = position - 20;
    if (locator >= 0 && u32(locator) == _zip64LocatorSignature) {
      final record = u64(locator + 8);
      if (record > locator - 56) {
        throw const PackageParseException(
          PackageProblem.damaged,
          'damaged ZIP64 directory',
        );
      }
      if (u32(record) == _zip64RecordSignature) {
        count = u64(record + 32);
        directorySize = u64(record + 40);
        directoryOffset = u64(record + 48);
      }
    }
    if (count > limits.maxEntries || directorySize > limits.maxEntries * 1024) {
      unsafe('too many entries');
    }
    final directoryEnd = directoryOffset + directorySize;
    if (directoryEnd > bytes.length) damaged('directory outside the file');

    // Byte ranges taken by the directory and each entry.
    final ranges = <(int, int)>[
      if (directorySize > 0) (directoryOffset, directoryEnd),
    ];
    var entries = 0;
    var total = 0;
    var at = directoryOffset;
    while (at < directoryEnd) {
      if (at + 4 > directoryEnd) damaged('cut-off directory');
      // The decoder stops at anything that is not a header.
      if (u32(at) != _centralSignature) break;
      if (at + 46 > directoryEnd) damaged('cut-off directory');
      if (++entries > limits.maxEntries) unsafe('too many entries');
      final madeBy = u16(at + 4);
      var compressed = u32(at + 20);
      var size = u32(at + 24);
      final extraStart = at + 46 + u16(at + 28);
      final extraEnd = extraStart + u16(at + 30);
      final next = extraEnd + u16(at + 32);
      final attributes = u32(at + 38);
      var offset = u32(at + 42);
      if (next > directoryEnd) damaged('cut-off directory');
      // ZIP64 sizes and offset, read in the decoder's order.
      var field = extraStart;
      while (extraEnd - field >= 4) {
        final id = u16(field);
        var length = u16(field + 2);
        var value = field + 4;
        final valueEnd = math.min(value + length, extraEnd);
        field = valueEnd;
        if (id != 1) continue;
        int read64() {
          if (value + 8 > valueEnd) damaged('cut-off ZIP64 field');
          length -= 8;
          value += 8;
          return u64(value - 8);
        }

        if (length >= 8 && size == 0xFFFFFFFF) size = read64();
        if (length >= 8 && compressed == 0xFFFFFFFF) compressed = read64();
        if (length >= 8 && offset == 0xFFFFFFFF) offset = read64();
      }
      if (madeBy >> 8 == 3 && (attributes >> 16) & 0xF000 == 0xA000) {
        unsafe('symbolic link entries');
      }
      total += size;
      if (total > limits.maxTotalBytes) unsafe('unpacks to too much data');
      if (offset + 30 > bytes.length || u32(offset) != _localSignature) {
        damaged('entry outside the file');
      }
      final end =
          offset + 30 + u16(offset + 26) + u16(offset + 28) + compressed;
      if (end > bytes.length) damaged('entry outside the file');
      ranges.add((offset, end));
      at = next;
    }
    if (total > limits.ratioFloorBytes &&
        total > bytes.length * limits.maxRatio) {
      unsafe('the package is compressed suspiciously well');
    }
    ranges.sort((a, b) => a.$1.compareTo(b.$1));
    for (var i = 1; i < ranges.length; i++) {
      if (ranges[i].$1 < ranges[i - 1].$2) unsafe('overlapping entries');
    }
  }

  static const _compoundFile = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
  static const _localHeader = [0x50, 0x4B, 0x03, 0x04];

  static bool _startsWith(Uint8List bytes, List<int> prefix) {
    if (bytes.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix[i]) return false;
    }
    return true;
  }

  static bool _containsUtf16(Uint8List bytes, String text) {
    final pattern = [
      for (final unit in text.codeUnits) ...[unit & 0xFF, unit >> 8],
    ];
    outer:
    for (var i = 0; i + pattern.length <= bytes.length; i++) {
      for (var k = 0; k < pattern.length; k++) {
        if (bytes[i + k] != pattern[k]) continue outer;
      }
      return true;
    }
    return false;
  }
}

/// Decodes an XML part: UTF-8 (with or without a byte order mark), UTF-16
/// with a byte order mark, or Latin-1 when the declaration names a legacy
/// single-byte encoding. Throws [PackageParseException].
(String, PartEncoding) decodePart(Uint8List bytes, String name) {
  try {
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return (utf8.decode(bytes.sublist(3)), PartEncoding.utf8Bom);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return (decodeText(bytes).text, PartEncoding.utf16le);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return (decodeText(bytes).text, PartEncoding.utf16be);
    }
    return (utf8.decode(bytes), PartEncoding.utf8);
  } on FormatException {
    final head = latin1.decode(bytes.sublist(0, bytes.length.clamp(0, 200)));
    final declared = _declaredEncoding
        .firstMatch(head)
        ?.group(1)
        ?.toLowerCase();
    if (declared != null && _singleByte.contains(declared)) {
      return (latin1.decode(bytes), PartEncoding.latin1);
    }
    throw PackageParseException(
      PackageProblem.damaged,
      '$name is not valid UTF-8',
    );
  }
}

/// Encodes a part's text as [encoding]. Latin-1 parts get character
/// references for characters Latin-1 cannot hold (they can only come from
/// translations, which are element content).
Uint8List encodePart(String text, PartEncoding encoding) => switch (encoding) {
  PartEncoding.utf8 => utf8.encode(text),
  PartEncoding.utf8Bom => encodeText(text, TextEncoding.utf8Bom),
  PartEncoding.utf16le => encodeText(text, TextEncoding.utf16le),
  PartEncoding.utf16be => encodeText(text, TextEncoding.utf16be),
  PartEncoding.latin1 => _latin1(text),
};

Uint8List _latin1(String text) {
  final out = BytesBuilder(copy: false);
  for (final rune in text.runes) {
    if (rune <= 0xFF) {
      out.addByte(rune);
    } else {
      out.add(ascii.encode('&#x${rune.toRadixString(16).toUpperCase()};'));
    }
  }
  return out.takeBytes();
}

final _declaredEncoding = RegExp(r'''encoding\s*=\s*["']([A-Za-z0-9._-]+)''');
const _singleByte = {
  'iso-8859-1',
  'iso8859-1',
  'latin1',
  'latin-1',
  'us-ascii',
  'ascii',
  'windows-1252',
  'cp1252',
};
