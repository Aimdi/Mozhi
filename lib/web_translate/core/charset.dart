/// Decoding of fetched HTML bytes: byte order marks, the HTTP
/// `Content-Type` charset, `<meta charset>` / `http-equiv` sniffing and a
/// UTF-8 -> windows-1252 fallback.
library;

import 'dart:convert';

/// The decoded document and the encoding that was used.
typedef DecodedHtml = ({
  String text,

  /// Canonical name of the encoding used (`utf-8`, `windows-1252`, ...).
  String charset,

  /// The charset the page declared but that is not supported (the text was
  /// then decoded as UTF-8 and may contain replacement characters).
  String? unsupportedCharset,
});

/// Decodes [bytes] of an HTML document.
///
/// Order: byte order mark, then the `charset` parameter of [contentType],
/// then a `<meta charset>` / `<meta http-equiv="Content-Type">` / XML
/// declaration within the first 4 KiB, else UTF-8 when the bytes are valid
/// UTF-8 and windows-1252 otherwise (the browsers' Western default).
///
/// Supported encodings: UTF-8, UTF-16 (LE/BE), windows-1252 (and every label
/// browsers treat as it: `iso-8859-1`, `latin1`, `us-ascii`, ...),
/// ISO-8859-15 and windows-1251. Other declared encodings fall back to
/// UTF-8 and are reported in `unsupportedCharset`.
DecodedHtml decodeHtmlBytes(List<int> bytes, {String? contentType}) {
  // Byte order marks win over everything else.
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return _decoded(_utf8(bytes.sublist(3)), 'utf-8');
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return _decoded(_utf16(bytes, 2, bigEndian: true), 'utf-16be');
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return _decoded(_utf16(bytes, 2, bigEndian: false), 'utf-16le');
  }

  final declared = charsetFromContentType(contentType) ?? sniffCharset(bytes);
  if (declared != null) {
    final encoding = _canonical(declared);
    if (encoding != null) {
      return _decoded(_decodeWith(encoding, bytes), encoding);
    }
    return (text: _utf8(bytes), charset: 'utf-8', unsupportedCharset: declared);
  }
  try {
    return _decoded(utf8.decode(bytes), 'utf-8');
  } on FormatException {
    return _decoded(decodeWindows1252(bytes), 'windows-1252');
  }
}

DecodedHtml _decoded(String text, String charset) =>
    (text: text, charset: charset, unsupportedCharset: null);

/// The `charset` parameter of a `Content-Type` header value, lower-cased.
String? charsetFromContentType(String? contentType) {
  if (contentType == null) return null;
  final match = RegExp(
    r'''charset\s*=\s*["']?\s*([^"';\s]+)''',
    caseSensitive: false,
  ).firstMatch(contentType);
  return match?.group(1)?.toLowerCase();
}

/// Looks for a declared charset in the first 4 KiB of [bytes]: `<meta
/// charset>`, `<meta http-equiv="Content-Type" content="...charset=...">`
/// or an XML declaration's `encoding`.
String? sniffCharset(List<int> bytes) {
  final head = latin1.decode(
    bytes.length > 4096 ? bytes.sublist(0, 4096) : bytes,
  );
  final meta = RegExp(
    r'''<meta\b[^>]*?charset\s*=\s*["']?\s*([a-zA-Z0-9_.:\-]+)''',
    caseSensitive: false,
  ).firstMatch(head);
  if (meta != null) return meta.group(1)!.toLowerCase();
  final xml = RegExp(
    r'''^\s*<\?xml\b[^>]*encoding\s*=\s*["']([a-zA-Z0-9_.:\-]+)''',
    caseSensitive: false,
  ).firstMatch(head);
  return xml?.group(1)?.toLowerCase();
}

/// Maps a charset label to the name of a supported decoder, else null.
String? _canonical(String label) {
  final name = label.trim().toLowerCase();
  if (_utf8Labels.contains(name)) return 'utf-8';
  if (_windows1252Labels.contains(name)) return 'windows-1252';
  if (_iso885915Labels.contains(name)) return 'iso-8859-15';
  if (_windows1251Labels.contains(name)) return 'windows-1251';
  if (name == 'utf-16be' || name == 'unicodefffe') return 'utf-16be';
  if (name == 'utf-16' || name == 'utf-16le' || name == 'unicode') {
    return 'utf-16le';
  }
  return null;
}

String _decodeWith(String encoding, List<int> bytes) => switch (encoding) {
  'windows-1252' => decodeWindows1252(bytes),
  'iso-8859-15' => _decodeIso885915(bytes),
  'windows-1251' => _decodeWindows1251(bytes),
  'utf-16be' => _utf16(bytes, 0, bigEndian: true),
  'utf-16le' => _utf16(bytes, 0, bigEndian: false),
  _ => _utf8(bytes),
};

String _utf8(List<int> bytes) => utf8.decode(bytes, allowMalformed: true);

String _utf16(List<int> bytes, int offset, {required bool bigEndian}) {
  final units = <int>[];
  for (var i = offset; i + 1 < bytes.length; i += 2) {
    units.add(
      bigEndian
          ? (bytes[i] << 8) | bytes[i + 1]
          : bytes[i] | (bytes[i + 1] << 8),
    );
  }
  return String.fromCharCodes(units);
}

/// Decodes windows-1252 (a superset of ISO-8859-1 for printable text).
String decodeWindows1252(List<int> bytes) {
  final codes = List<int>.filled(bytes.length, 0);
  for (var i = 0; i < bytes.length; i++) {
    final b = bytes[i] & 0xFF;
    codes[i] = b >= 0x80 && b <= 0x9F ? windows1252HighCodes[b - 0x80] : b;
  }
  return String.fromCharCodes(codes);
}

String _decodeIso885915(List<int> bytes) {
  final codes = List<int>.filled(bytes.length, 0);
  for (var i = 0; i < bytes.length; i++) {
    final b = bytes[i] & 0xFF;
    codes[i] = _iso885915Overrides[b] ?? b;
  }
  return String.fromCharCodes(codes);
}

String _decodeWindows1251(List<int> bytes) {
  final codes = List<int>.filled(bytes.length, 0);
  for (var i = 0; i < bytes.length; i++) {
    final b = bytes[i] & 0xFF;
    codes[i] = switch (b) {
      < 0x80 => b,
      >= 0xC0 => 0x0410 + (b - 0xC0),
      _ => _windows1251High[b - 0x80],
    };
  }
  return String.fromCharCodes(codes);
}

/// Code points of the windows-1252 bytes 0x80-0x9F (unassigned bytes map to
/// themselves, as in browsers).
const List<int> windows1252HighCodes = [
  0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, //
  0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F, //
  0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, //
  0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178, //
];

/// Code points of the windows-1251 bytes 0x80-0xBF (0xC0-0xFF are
/// U+0410-U+044F).
const List<int> _windows1251High = [
  0x0402, 0x0403, 0x201A, 0x0453, 0x201E, 0x2026, 0x2020, 0x2021, //
  0x20AC, 0x2030, 0x0409, 0x2039, 0x040A, 0x040C, 0x040B, 0x040F, //
  0x0452, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, //
  0x0098, 0x2122, 0x0459, 0x203A, 0x045A, 0x045C, 0x045B, 0x045F, //
  0x00A0, 0x040E, 0x045E, 0x0408, 0x00A4, 0x0490, 0x00A6, 0x00A7, //
  0x0401, 0x00A9, 0x0404, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x0407, //
  0x00B0, 0x00B1, 0x0406, 0x0456, 0x0491, 0x00B5, 0x00B6, 0x00B7, //
  0x0451, 0x2116, 0x0454, 0x00BB, 0x0458, 0x0405, 0x0455, 0x0457, //
];

const Map<int, int> _iso885915Overrides = {
  0xA4: 0x20AC,
  0xA6: 0x0160,
  0xA8: 0x0161,
  0xB4: 0x017D,
  0xB8: 0x017E,
  0xBC: 0x0152,
  0xBD: 0x0153,
  0xBE: 0x0178,
};

const _utf8Labels = {'utf-8', 'utf8', 'unicode-1-1-utf-8', 'x-unicode20utf8'};

/// Every label the WHATWG Encoding standard maps to windows-1252.
const _windows1252Labels = {
  'windows-1252',
  'cp1252',
  'x-cp1252',
  'iso-8859-1',
  'iso8859-1',
  'iso88591',
  'iso_8859-1',
  'iso_8859-1:1987',
  'iso-ir-100',
  'l1',
  'latin1',
  'ibm819',
  'cp819',
  'csisolatin1',
  'us-ascii',
  'ascii',
  'ansi_x3.4-1968',
  'iso-ir-6',
  'us',
};

const _iso885915Labels = {
  'iso-8859-15',
  'iso8859-15',
  'iso885915',
  'iso_8859-15',
  'l9',
  'latin9',
  'csisolatin9',
};

const _windows1251Labels = {'windows-1251', 'cp1251', 'x-cp1251'};
