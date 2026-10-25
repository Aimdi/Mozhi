import 'dart:convert';
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
  /// [ratioFloorBytes] (decompression bombs).
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
final class ZipPackage {
  ZipPackage._(this.bytes, this.entries, this.limits)
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
      // Bad data inside an archive surfaces as any kind of error.
    } catch (error) {
      throw PackageParseException(
        PackageProblem.damaged,
        'damaged ZIP package ($error)',
      );
    }
    final headers = decoder.directory.fileHeaders;
    if (headers.length > limits.maxEntries) {
      throw const PackageParseException(
        PackageProblem.unsafe,
        'too many entries',
      );
    }
    if (headers.length != archive.length) {
      throw const PackageParseException(
        PackageProblem.unsafe,
        'duplicate entry names',
      );
    }
    var total = 0;
    for (final header in headers) {
      final file = header.file;
      if (file != null && file.flags & 0x1 != 0) {
        throw const PackageParseException(
          PackageProblem.encrypted,
          'password-protected ZIP entries',
        );
      }
      total += header.uncompressedSize;
    }
    if (total > limits.maxTotalBytes) {
      throw const PackageParseException(
        PackageProblem.unsafe,
        'unpacks to too much data',
      );
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
  /// deflated, every other entry copied as it was stored.
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
        final data = _stored(entry);
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

  /// Checks the end of central directory record before the archive is
  /// decoded: it must exist and announce a sane number of entries.
  static void _checkDirectory(Uint8List bytes, PackageLimits limits) {
    final data = ByteData.sublistView(bytes);
    const eocdSize = 22;
    final lowest = bytes.length - eocdSize - 0xFFFF;
    var position = bytes.length - eocdSize;
    while (position >= 0 &&
        position >= lowest &&
        data.getUint32(position, Endian.little) != 0x06054b50) {
      position--;
    }
    if (position < 0 || position < lowest) {
      throw const PackageParseException(
        PackageProblem.damaged,
        'no ZIP directory',
      );
    }
    var count = data.getUint16(position + 10, Endian.little);
    var directorySize = data.getUint32(position + 12, Endian.little);
    final locator = position - 20;
    if ((count == 0xFFFF || directorySize == 0xFFFFFFFF) &&
        locator >= 0 &&
        data.getUint32(locator, Endian.little) == 0x07064b50) {
      // 64-bit fields, read as two halves (the web has no getUint64).
      int uint64(int at) =>
          data.getUint32(at, Endian.little) +
          data.getUint32(at + 4, Endian.little) * 0x100000000;
      final record = uint64(locator + 8);
      if (record + 56 > bytes.length) {
        throw const PackageParseException(
          PackageProblem.damaged,
          'damaged ZIP64 directory',
        );
      }
      count = uint64(record + 32);
      directorySize = uint64(record + 40);
    }
    if (count > limits.maxEntries ||
        directorySize > limits.maxEntries * 1024) {
      throw const PackageParseException(
        PackageProblem.unsafe,
        'too many entries',
      );
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
