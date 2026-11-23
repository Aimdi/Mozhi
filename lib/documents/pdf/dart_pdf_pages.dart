import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color, Rect, Size, TextDirection;

import 'package:archive/archive.dart' show Inflate, ZLibDecoder;
import 'package:flutter/foundation.dart' show immutable;
import 'package:mozhi/documents/core/document_format.dart';
import 'package:mozhi/documents/pdf/pdf_pages.dart';
import 'package:mozhi/documents/pdf/pdf_scratch_web.dart';
import 'package:mozhi/documents/pdf/pdf_text_layer.dart';

/// Pure-Dart [PdfPages] implementation for the web app: reads PDF structure
/// and text layers (uncompressed and `/FlateDecode` content streams,
/// `/ToUnicode` CMaps, WinAnsi/MacRoman/UTF-16BE encodings, xref tables and
/// xref/object streams) and writes valid multi-page PDF 1.4 documents with
/// real selectable translated text.
///
/// Scanned PDFs (pages without a usable text layer) return `null` from
/// [readText] and fail [render] so the UI explains that OCR is unavailable on
/// the web.
class DartPdfPages implements PdfPages {
  new({
    Uint8List? Function(String path)? readBytes,
    void Function(String path, Uint8List bytes)? writeBytes,
  }) : _readBytes = readBytes ?? WebPdfScratch.shared.peek,
       _writeBytes = writeBytes ?? WebPdfScratch.shared.put;

  final Uint8List? Function(String path) _readBytes;
  final void Function(String path, Uint8List bytes) _writeBytes;

  _PdfDoc? _doc;
  final Map<int, List<PdfTextLine>?> _textCache = {};

  /// Safety cap on any single decompressed PDF stream (16 MB).
  static const int _maxStreamBytes = 16 * 1024 * 1024;

  /// Maximum object reference recursion depth.
  static const int _maxRecursionDepth = 48;

  /// Maximum Form XObject nesting depth.
  static const int _maxFormDepth = 8;

  @override
  bool get isSupported => true;

  @override
  Future<PdfInfo> open(String path) async {
    await close();
    final bytes = _readBytes(path);
    if (bytes == null || bytes.isEmpty) {
      throw const PdfOpenException(kind: PdfOpenErrorKind.damaged);
    }
    if (bytes.length > PdfLimits.maxBytes) {
      throw const PdfOpenException(kind: PdfOpenErrorKind.tooLarge);
    }
    if (!DocumentFormat.isPdfBytes(bytes)) {
      throw const PdfOpenException(kind: PdfOpenErrorKind.damaged);
    }
    final doc = _PdfDoc.parse(bytes);
    _doc = doc;
    return PdfInfo(pageSizes: doc.pageSizes);
  }

  @override
  Future<List<PdfTextLine>?> readText(int page) async {
    final doc = _doc;
    if (doc == null || page < 0 || page >= doc.pages.length) return null;
    if (_textCache.containsKey(page)) return _textCache[page];
    try {
      final lines = doc.extractTextLines(page);
      return _textCache[page] = (lines == null || lines.isEmpty) ? null : lines;
    } on Object {
      return _textCache[page] = null;
    }
  }

  @override
  Future<PdfPageImage> render(int page, {required int maxPixels}) async {
    final doc = _doc;
    if (doc == null || page < 0 || page >= doc.pages.length) {
      throw PdfRenderException(page: page, cause: 'no open page');
    }
    final lines = await readText(page);
    if (!PdfTextLayer.isUsable(lines)) {
      throw PdfRenderException(page: page, cause: 'no text layer');
    }
    final size = doc.pageSizes[page];
    final safeMax = math.max(1, maxPixels);
    var width = math.max(1, size.width.round());
    var height = math.max(1, size.height.round());
    final pixelsCount = width * height;
    if (pixelsCount > safeMax) {
      final scale = math.sqrt(safeMax / pixelsCount);
      width = math.max(1, (width * scale).floor());
      height = math.max(1, (height * scale).floor());
    }
    final pixels = Uint8List(width * height)..fillRange(0, width * height, 255);
    return PdfPageImage(
      pixels: pixels,
      width: width,
      height: height,
      bytesPerPixel: 1,
    );
  }

  @override
  Future<void> write(String outputPath, List<PdfOutputPage> pages) async {
    try {
      final bytes = _PdfWriter.build(pages);
      _writeBytes(outputPath, bytes);
    } on PdfWriteException {
      rethrow;
    } on Object catch (error) {
      throw PdfWriteException(cause: error);
    }
  }

  @override
  Future<void> close() async {
    _doc = null;
    _textCache.clear();
  }
}

// ============================================================================
// PDF Object Model
// ============================================================================

@immutable
class _PdfName {
  const new(this.value);
  final String value;

  @override
  bool operator ==(Object other) => other is _PdfName && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => '/$value';
}

@immutable
class _PdfRef {
  const new(this.obj, this.gen);
  final int obj;
  final int gen;

  @override
  bool operator ==(Object other) =>
      other is _PdfRef && other.obj == obj && other.gen == gen;

  @override
  int get hashCode => Object.hash(obj, gen);

  @override
  String toString() => '$obj $gen R';
}

class _PdfStream {
  const new(this.dict, this.rawBytes);
  final Map<String, Object?> dict;
  final Uint8List rawBytes;
}

class _XrefEntry {
  const new uncompressed(this.offset) : inStream = null, index = 0;
  const new compressed(int streamObj, this.index)
    : offset = -1,
      inStream = streamObj;

  final int offset;
  final int? inStream;
  final int index;
}

class _PdfPageInfo {
  const new({
    required this.dict,
    required this.mediaBox,
    required this.size,
    required this.rotate,
    required this.inheritedResources,
  });

  final Map<String, Object?> dict;
  final Rect mediaBox;
  final Size size;
  final int rotate;
  final Map<String, Object?>? inheritedResources;
}

// ============================================================================
// PDF Document Parser
// ============================================================================

class _PdfDoc {
  new _(this.bytes, this._xref, this.pages)
    : pageSizes = [for (final p in pages) p.size];

  factory parse(Uint8List bytes) {
    final xref = <int, _XrefEntry>{};
    Object? rootRef;
    var encrypted = false;

    final startXref = _findStartXref(bytes);
    final visitedOffsets = <int>{};

    void parseXrefAt(int offset) {
      var current = offset;
      for (var hops = 0; hops < 32; hops++) {
        if (current < 0 ||
            current >= bytes.length ||
            !visitedOffsets.add(current)) {
          break;
        }
        final reader = _PdfReader(bytes, current)..skipWhitespace();
        if (reader.matchesKeyword('xref')) {
          final trailer = _parseXrefTable(reader, xref);
          if (trailer != null) {
            if (trailer.containsKey('Encrypt') && trailer['Encrypt'] != null) {
              encrypted = true;
            }
            rootRef ??= trailer['Root'];
            final xrefStm = _asInt(trailer['XRefStm']);
            if (xrefStm != null && !visitedOffsets.contains(xrefStm)) {
              parseXrefAt(xrefStm);
            }
            final prev = _asInt(trailer['Prev']);
            if (prev != null) {
              current = prev;
              continue;
            }
          }
          break;
        } else {
          // Possible PDF 1.5+ cross-reference stream.
          final stream = _parseIndirectObjectAt(bytes, current);
          if (stream is _PdfStream && _asName(stream.dict['Type']) == 'XRef') {
            if (stream.dict.containsKey('Encrypt') &&
                stream.dict['Encrypt'] != null) {
              encrypted = true;
            }
            rootRef ??= stream.dict['Root'];
            _parseXrefStream(stream, xref);
            final prev = _asInt(stream.dict['Prev']);
            if (prev != null) {
              current = prev;
              continue;
            }
          }
          break;
        }
      }
    }

    if (startXref != null) {
      parseXrefAt(startXref);
    }

    // Fallback scan if xref table was missing or incomplete.
    if (xref.isEmpty || rootRef == null) {
      final scanned = _scanFallback(bytes, xref);
      if (scanned.encrypted) encrypted = true;
      rootRef ??= scanned.rootRef;
    }

    if (encrypted) {
      throw const PdfOpenException(kind: PdfOpenErrorKind.encrypted);
    }
    if (rootRef == null) {
      throw const PdfOpenException(kind: PdfOpenErrorKind.damaged);
    }

    final doc = _PdfDoc._(bytes, xref, const []);
    final catalog = doc.resolveDict(rootRef);
    if (catalog == null) {
      throw const PdfOpenException(kind: PdfOpenErrorKind.damaged);
    }
    final pagesRef = catalog['Pages'];
    if (pagesRef == null) {
      throw const PdfOpenException(kind: PdfOpenErrorKind.damaged);
    }

    final pages = <_PdfPageInfo>[];
    final visitedNodes = <int>{};
    doc._collectPages(
      pagesRef,
      inheritedMediaBox: null,
      inheritedCropBox: null,
      inheritedRotate: 0,
      inheritedResources: null,
      out: pages,
      visited: visitedNodes,
      depth: 0,
    );
    if (pages.isEmpty) {
      throw const PdfOpenException(kind: PdfOpenErrorKind.damaged);
    }
    return _PdfDoc._(bytes, xref, pages);
  }

  final Uint8List bytes;
  final Map<int, _XrefEntry> _xref;
  final List<_PdfPageInfo> pages;
  final List<Size> pageSizes;

  final Map<int, Object?> _cache = {};
  final Map<int, Map<int, Object?>> _objStmCache = {};
  final Map<Object, _PdfFont> _fontCache = {};

  void _collectPages(
    Object? refOrDict, {
    required Rect? inheritedMediaBox,
    required Rect? inheritedCropBox,
    required int inheritedRotate,
    required Map<String, Object?>? inheritedResources,
    required List<_PdfPageInfo> out,
    required Set<int> visited,
    required int depth,
  }) {
    if (depth > DartPdfPages._maxRecursionDepth) {
      throw const PdfOpenException(kind: PdfOpenErrorKind.damaged);
    }
    if (refOrDict is _PdfRef && !visited.add(refOrDict.obj)) return;
    final dict = resolveDict(refOrDict);
    if (dict == null) return;

    final mediaBox = _parseRect(resolve(dict['MediaBox'])) ?? inheritedMediaBox;
    final cropBox = _parseRect(resolve(dict['CropBox'])) ?? inheritedCropBox;
    final rotate = _asInt(resolve(dict['Rotate'])) ?? inheritedRotate;
    final resources = resolveDict(dict['Resources']) ?? inheritedResources;

    final type = _asName(resolve(dict['Type']));
    final kids = resolveList(dict['Kids']);
    if (type == 'Pages' || (type == null && kids != null)) {
      if (kids == null) return;
      for (final kid in kids) {
        _collectPages(
          kid,
          inheritedMediaBox: mediaBox,
          inheritedCropBox: cropBox,
          inheritedRotate: rotate,
          inheritedResources: resources,
          out: out,
          visited: visited,
          depth: depth + 1,
        );
      }
      return;
    }

    if (type == 'Page' || kids == null) {
      if (out.length >= PdfLimits.maxPages) {
        throw const PdfOpenException(kind: PdfOpenErrorKind.tooLarge);
      }
      final box = cropBox ?? mediaBox ?? const Rect.fromLTRB(0, 0, 612, 792);
      final normalizedRotate = ((rotate % 360) + 360) % 360;
      final swap = normalizedRotate == 90 || normalizedRotate == 270;
      final width = box.width > 0 ? box.width : 612.0;
      final height = box.height > 0 ? box.height : 792.0;
      out.add(
        _PdfPageInfo(
          dict: dict,
          mediaBox: Rect.fromLTRB(
            box.left,
            box.top,
            box.left + width,
            box.top + height,
          ),
          size: swap ? Size(height, width) : Size(width, height),
          rotate: normalizedRotate,
          inheritedResources: resources,
        ),
      );
    }
  }

  Object? resolve(Object? value, {int depth = 0}) {
    if (value is! _PdfRef) return value;
    if (depth > DartPdfPages._maxRecursionDepth) return null;
    if (_cache.containsKey(value.obj)) return _cache[value.obj];
    final entry = _xref[value.obj];
    if (entry == null) return null;
    Object? parsed;
    if (entry.inStream case final stmObj?) {
      parsed = _readFromObjStm(stmObj, value.obj, depth: depth + 1);
    } else {
      parsed = _parseIndirectObjectAt(bytes, entry.offset, resolver: this);
    }
    _cache[value.obj] = parsed;
    return parsed is _PdfRef ? resolve(parsed, depth: depth + 1) : parsed;
  }

  Object? _readFromObjStm(int stmObj, int targetObj, {required int depth}) {
    var objects = _objStmCache[stmObj];
    if (objects == null) {
      objects = <int, Object?>{};
      _objStmCache[stmObj] = objects;
      final stm = resolve(_PdfRef(stmObj, 0), depth: depth);
      if (stm is! _PdfStream) return null;
      final decoded = decodeStream(stm);
      if (decoded == null) return null;
      final n = _asInt(resolve(stm.dict['N'], depth: depth)) ?? 0;
      final first = _asInt(resolve(stm.dict['First'], depth: depth)) ?? 0;
      if (n <= 0 || first < 0 || first > decoded.length) return null;
      final headerReader = _PdfReader(decoded, 0);
      final offsets = <(int, int)>[];
      for (var i = 0; i < n; i++) {
        final objNum = _asInt(headerReader.readObject());
        final relOffset = _asInt(headerReader.readObject());
        if (objNum == null || relOffset == null) break;
        offsets.add((objNum, first + relOffset));
      }
      for (final (objNum, absOffset) in offsets) {
        if (absOffset < 0 || absOffset >= decoded.length) continue;
        final objReader = _PdfReader(decoded, absOffset);
        objects[objNum] = objReader.readObject();
      }
    }
    return objects[targetObj];
  }

  Map<String, Object?>? resolveDict(Object? value) {
    final resolved = resolve(value);
    if (resolved is Map<String, Object?>) return resolved;
    if (resolved is _PdfStream) return resolved.dict;
    return null;
  }

  List<Object?>? resolveList(Object? value) {
    final resolved = resolve(value);
    return resolved is List<Object?> ? resolved : null;
  }

  Uint8List? decodeStream(_PdfStream stream) {
    var data = stream.rawBytes;
    if (data.length > DartPdfPages._maxStreamBytes) return null;
    final filterObj = resolve(stream.dict['Filter']);
    final filters = <String>[];
    if (filterObj is _PdfName) {
      filters.add(filterObj.value);
    } else if (filterObj is List<Object?>) {
      for (final item in filterObj) {
        final name = _asName(resolve(item));
        if (name != null) filters.add(name);
      }
    }
    final parmsObj = resolve(stream.dict['DecodeParms']);
    final parmsList = <Map<String, Object?>?>[];
    if (parmsObj is Map<String, Object?>) {
      parmsList.add(parmsObj);
    } else if (parmsObj is List<Object?>) {
      for (final item in parmsObj) {
        parmsList.add(resolveDict(item));
      }
    }

    for (var i = 0; i < filters.length; i++) {
      final filter = filters[i];
      final parms = i < parmsList.length ? parmsList[i] : null;
      final next = _applyFilter(filter, data, parms);
      if (next == null || next.length > DartPdfPages._maxStreamBytes) {
        return null;
      }
      data = next;
    }
    return data;
  }

  Uint8List? _applyFilter(
    String filter,
    Uint8List data,
    Map<String, Object?>? parms,
  ) {
    switch (filter) {
      case 'FlateDecode' || 'Fl':
        Uint8List decoded;
        try {
          decoded = const ZLibDecoder().decodeBytes(data);
        } on Object {
          try {
            decoded = Inflate(data).getBytes();
          } on Object {
            return null;
          }
        }
        if (decoded.length > DartPdfPages._maxStreamBytes) return null;
        if (parms != null) {
          final predictor = _asInt(resolve(parms['Predictor'])) ?? 1;
          if (predictor >= 10) {
            final columns = _asInt(resolve(parms['Columns'])) ?? 1;
            final colors = _asInt(resolve(parms['Colors'])) ?? 1;
            final bpc = _asInt(resolve(parms['BitsPerComponent'])) ?? 8;
            return _unpredictPng(decoded, columns, colors, bpc);
          } else if (predictor == 2) {
            final columns = _asInt(resolve(parms['Columns'])) ?? 1;
            final colors = _asInt(resolve(parms['Colors'])) ?? 1;
            final bpc = _asInt(resolve(parms['BitsPerComponent'])) ?? 8;
            return _unpredictTiff(decoded, columns, colors, bpc);
          }
        }
        return decoded;
      case 'ASCIIHexDecode' || 'AHx':
        return _decodeAsciiHex(data);
      case 'ASCII85Decode' || 'A85':
        return _decodeAscii85(data);
      default:
        return null;
    }
  }

  List<PdfTextLine>? extractTextLines(int pageIndex) {
    final page = pages[pageIndex];
    final contentsObj = resolve(page.dict['Contents']);
    if (contentsObj == null) return null;
    final builder = BytesBuilder(copy: false);
    if (contentsObj is _PdfStream) {
      final decoded = decodeStream(contentsObj);
      if (decoded != null) builder.add(decoded);
    } else if (contentsObj is List<Object?>) {
      for (final item in contentsObj) {
        final stm = resolve(item);
        if (stm is _PdfStream) {
          final decoded = decodeStream(stm);
          if (decoded != null) {
            if (builder.isNotEmpty) builder.addByte(0x0A);
            builder.add(decoded);
          }
        }
      }
    }
    final streamBytes = builder.takeBytes();
    if (streamBytes.isEmpty) return null;

    final extractor = _TextExtractor(
      this,
      page,
    )..interpret(streamBytes, resources: page.inheritedResources, formDepth: 0);
    return extractor.buildLines();
  }

  _PdfFont resolveFont(Object? fontRefOrDict) {
    final key = fontRefOrDict is _PdfRef
        ? fontRefOrDict
        : fontRefOrDict ?? Object();
    final cached = _fontCache[key];
    if (cached != null) return cached;
    final dict = resolveDict(fontRefOrDict);
    final font = dict == null ? _PdfFont.fallback : _PdfFont.parse(this, dict);
    _fontCache[key] = font;
    return font;
  }
}

// ============================================================================
// Xref Parsing Helpers
// ============================================================================

int? _findStartXref(Uint8List bytes) {
  final start = math.max(0, bytes.length - 4096);
  const needle = 'startxref';
  for (var i = bytes.length - needle.length; i >= start; i--) {
    var matched = true;
    for (var k = 0; k < needle.length; k++) {
      if (bytes[i + k] != needle.codeUnitAt(k)) {
        matched = false;
        break;
      }
    }
    if (matched) {
      final reader = _PdfReader(bytes, i + needle.length)..skipWhitespace();
      final offset = _asInt(reader.readObject());
      if (offset != null && offset >= 0 && offset < bytes.length) {
        return offset;
      }
    }
  }
  return null;
}

Map<String, Object?>? _parseXrefTable(
  _PdfReader reader,
  Map<int, _XrefEntry> xref,
) {
  reader.readKeyword(); // consume 'xref'
  while (true) {
    reader.skipWhitespace();
    if (reader.isEof) return null;
    if (reader.matchesKeyword('trailer')) {
      reader.readKeyword();
      final trailer = reader.readObject();
      return trailer is Map<String, Object?> ? trailer : null;
    }
    final firstObj = _asInt(reader.readObject());
    final count = _asInt(reader.readObject());
    if (firstObj == null || count == null || count < 0 || count > 2000000) {
      return null;
    }
    for (var i = 0; i < count; i++) {
      final offset = _asInt(reader.readObject());
      final gen = _asInt(reader.readObject());
      final status = reader.readKeyword();
      if (offset == null || gen == null || status == null) return null;
      if (status == 'n') {
        xref.putIfAbsent(firstObj + i, () => _XrefEntry.uncompressed(offset));
      }
    }
  }
}

void _parseXrefStream(_PdfStream stream, Map<int, _XrefEntry> xref) {
  final doc = _PdfDoc._(Uint8List(0), const {}, const []);
  final data = doc.decodeStream(stream);
  if (data == null) return;
  final wList = stream.dict['W'];
  if (wList is! List<Object?> || wList.length < 3) return;
  final w0 = _asInt(wList[0]) ?? 0;
  final w1 = _asInt(wList[1]) ?? 0;
  final w2 = _asInt(wList[2]) ?? 0;
  final entrySize = w0 + w1 + w2;
  if (entrySize <= 0 || w0 > 8 || w1 > 8 || w2 > 8) return;

  final size = _asInt(stream.dict['Size']) ?? 0;
  final indexObj = stream.dict['Index'];
  final ranges = <(int, int)>[];
  if (indexObj is List<Object?> && indexObj.length >= 2) {
    for (var i = 0; i + 1 < indexObj.length; i += 2) {
      final start = _asInt(indexObj[i]);
      final count = _asInt(indexObj[i + 1]);
      if (start != null && count != null && count >= 0) {
        ranges.add((start, count));
      }
    }
  } else if (size > 0) {
    ranges.add((0, size));
  }

  int readField(int pos, int width) {
    var value = 0;
    for (var i = 0; i < width; i++) {
      value = (value << 8) | data[pos + i];
    }
    return value;
  }

  var pos = 0;
  for (final (startObj, count) in ranges) {
    for (var i = 0; i < count; i++) {
      if (pos + entrySize > data.length) return;
      final type = w0 == 0 ? 1 : readField(pos, w0);
      final f1 = w1 == 0 ? 0 : readField(pos + w0, w1);
      final f2 = w2 == 0 ? 0 : readField(pos + w0 + w1, w2);
      pos += entrySize;
      final objNum = startObj + i;
      if (type == 1) {
        xref.putIfAbsent(objNum, () => _XrefEntry.uncompressed(f1));
      } else if (type == 2) {
        xref.putIfAbsent(objNum, () => _XrefEntry.compressed(f1, f2));
      }
    }
  }
}

({Object? rootRef, bool encrypted}) _scanFallback(
  Uint8List bytes,
  Map<int, _XrefEntry> xref,
) {
  Object? rootRef;
  var encrypted = false;
  final reader = _PdfReader(bytes, 0);
  while (!reader.isEof) {
    reader.skipWhitespace();
    if (reader.isEof) break;
    final pos = reader.pos;
    if (reader.matchesKeyword('trailer')) {
      reader.readKeyword();
      final dict = reader.readObject();
      if (dict is Map<String, Object?>) {
        if (dict.containsKey('Encrypt') && dict['Encrypt'] != null) {
          encrypted = true;
        }
        if (dict['Root'] != null) rootRef = dict['Root'];
      }
      continue;
    }
    final b = bytes[pos];
    if (b >= 0x30 && b <= 0x39) {
      final first = _asInt(reader.readObject());
      final second = _asInt(reader.readObject());
      if (first != null && second != null && reader.matchesKeyword('obj')) {
        xref.putIfAbsent(first, () => _XrefEntry.uncompressed(pos));
        reader.readKeyword();
        final obj = reader.readObject();
        if (obj is Map<String, Object?>) {
          if (_asName(obj['Type']) == 'Catalog') {
            rootRef ??= _PdfRef(first, second);
          }
          if (obj.containsKey('Encrypt') && obj['Encrypt'] != null) {
            encrypted = true;
          }
        }
        continue;
      }
    }
    reader.skipLine();
  }
  return (rootRef: rootRef, encrypted: encrypted);
}

Object? _parseIndirectObjectAt(
  Uint8List bytes,
  int offset, {
  _PdfDoc? resolver,
}) {
  if (offset < 0 || offset >= bytes.length) return null;
  final reader = _PdfReader(bytes, offset)..skipWhitespace();
  final objNum = _asInt(reader.readObject());
  final gen = _asInt(reader.readObject());
  if (objNum == null || gen == null || !reader.matchesKeyword('obj')) {
    return null;
  }
  reader.readKeyword(); // consume 'obj'
  final value = reader.readObject();
  reader.skipWhitespace();
  if (value is Map<String, Object?> && reader.matchesKeyword('stream')) {
    reader.readKeyword(); // consume 'stream'
    if (!reader.isEof && bytes[reader.pos] == 0x0D) reader.pos++;
    if (!reader.isEof && bytes[reader.pos] == 0x0A) reader.pos++;
    final streamStart = reader.pos;
    int? length;
    final lenVal = value['Length'];
    if (lenVal is int) {
      length = lenVal;
    } else if (lenVal is _PdfRef && resolver != null) {
      length = _asInt(resolver.resolve(lenVal, depth: 1));
    }
    Uint8List raw;
    if (length != null && length >= 0 && streamStart + length <= bytes.length) {
      raw = Uint8List.sublistView(bytes, streamStart, streamStart + length);
    } else {
      final end = _findEndstream(bytes, streamStart);
      if (end < streamStart) return null;
      raw = Uint8List.sublistView(bytes, streamStart, end);
    }
    return _PdfStream(value, raw);
  }
  return value;
}

int _findEndstream(Uint8List bytes, int start) {
  const needle = 'endstream';
  for (var i = start; i <= bytes.length - needle.length; i++) {
    var matched = true;
    for (var k = 0; k < needle.length; k++) {
      if (bytes[i + k] != needle.codeUnitAt(k)) {
        matched = false;
        break;
      }
    }
    if (matched) {
      var end = i;
      if (end > start && bytes[end - 1] == 0x0A) end--;
      if (end > start && bytes[end - 1] == 0x0D) end--;
      return end;
    }
  }
  return -1;
}

// ============================================================================
// PDF Stream Filters & Predictors
// ============================================================================

Uint8List? _unpredictPng(Uint8List data, int columns, int colors, int bpc) {
  if (columns <= 0 || colors <= 0 || bpc <= 0) return data;
  final bpp = math.max(1, (colors * bpc + 7) ~/ 8);
  final rowBytes = (columns * colors * bpc + 7) ~/ 8;
  final stride = rowBytes + 1;
  if (stride <= 1) return data;
  final rows = data.length ~/ stride;
  final out = Uint8List(rows * rowBytes);
  for (var r = 0; r < rows; r++) {
    final filter = data[r * stride];
    final srcOff = r * stride + 1;
    final dstOff = r * rowBytes;
    final prevOff = (r - 1) * rowBytes;
    for (var x = 0; x < rowBytes; x++) {
      final raw = data[srcOff + x];
      final a = x >= bpp ? out[dstOff + x - bpp] : 0;
      final b = r > 0 ? out[prevOff + x] : 0;
      final c = (r > 0 && x >= bpp) ? out[prevOff + x - bpp] : 0;
      final int value;
      switch (filter) {
        case 0:
          value = raw;
        case 1:
          value = (raw + a) & 0xFF;
        case 2:
          value = (raw + b) & 0xFF;
        case 3:
          value = (raw + ((a + b) >> 1)) & 0xFF;
        case 4:
          final p = a + b - c;
          final pa = (p - a).abs();
          final pb = (p - b).abs();
          final pc = (p - c).abs();
          final pr = (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c);
          value = (raw + pr) & 0xFF;
        default:
          value = raw;
      }
      out[dstOff + x] = value;
    }
  }
  return out;
}

Uint8List _unpredictTiff(Uint8List data, int columns, int colors, int bpc) {
  if (bpc != 8 || columns <= 0 || colors <= 0) return data;
  final rowBytes = columns * colors;
  final out = Uint8List.fromList(data);
  for (var row = 0; row + rowBytes <= out.length; row += rowBytes) {
    for (var x = colors; x < rowBytes; x++) {
      out[row + x] = (out[row + x] + out[row + x - colors]) & 0xFF;
    }
  }
  return out;
}

Uint8List _decodeAsciiHex(Uint8List data) {
  final out = BytesBuilder(copy: false);
  var high = -1;
  for (final byte in data) {
    if (byte == 0x3E) break; // '>'
    final nib = _hexDigit(byte);
    if (nib < 0) continue;
    if (high < 0) {
      high = nib;
    } else {
      out.addByte((high << 4) | nib);
      high = -1;
    }
  }
  if (high >= 0) out.addByte(high << 4);
  return out.takeBytes();
}

Uint8List? _decodeAscii85(Uint8List data) {
  final out = BytesBuilder(copy: false);
  var tuple = 0;
  var count = 0;
  for (var i = 0; i < data.length; i++) {
    final b = data[i];
    if (_isWhitespace(b)) continue;
    if (b == 0x7E) break; // '~>'
    if (b == 0x7A && count == 0) {
      // 'z' shorthand for four zero bytes.
      out.add(const [0, 0, 0, 0]);
      continue;
    }
    if (b < 0x21 || b > 0x75) return null;
    tuple = tuple * 85 + (b - 0x21);
    count++;
    if (count == 5) {
      out
        ..addByte((tuple >> 24) & 0xFF)
        ..addByte((tuple >> 16) & 0xFF)
        ..addByte((tuple >> 8) & 0xFF)
        ..addByte(tuple & 0xFF);
      tuple = 0;
      count = 0;
    }
  }
  if (count > 1) {
    for (var i = count; i < 5; i++) {
      tuple = tuple * 85 + 84;
    }
    for (var i = 0; i < count - 1; i++) {
      out.addByte((tuple >> (24 - 8 * i)) & 0xFF);
    }
  }
  return out.takeBytes();
}

// ============================================================================
// PDF Lexer / Object Reader
// ============================================================================

class _PdfReader {
  new(this.bytes, this.pos);

  final Uint8List bytes;
  int pos;

  bool get isEof => pos >= bytes.length;

  void skipWhitespace() {
    while (pos < bytes.length) {
      final b = bytes[pos];
      if (_isWhitespace(b)) {
        pos++;
      } else if (b == 0x25) {
        // '%' comment until end of line.
        pos++;
        while (pos < bytes.length && bytes[pos] != 0x0A && bytes[pos] != 0x0D) {
          pos++;
        }
      } else {
        break;
      }
    }
  }

  void skipLine() {
    while (pos < bytes.length && bytes[pos] != 0x0A && bytes[pos] != 0x0D) {
      pos++;
    }
    if (pos < bytes.length && bytes[pos] == 0x0D) pos++;
    if (pos < bytes.length && bytes[pos] == 0x0A) pos++;
  }

  bool matchesKeyword(String kw) {
    skipWhitespace();
    if (pos + kw.length > bytes.length) return false;
    for (var i = 0; i < kw.length; i++) {
      if (bytes[pos + i] != kw.codeUnitAt(i)) return false;
    }
    final after = pos + kw.length;
    return after == bytes.length ||
        _isWhitespace(bytes[after]) ||
        _isDelimiter(bytes[after]);
  }

  String? readKeyword() {
    skipWhitespace();
    if (isEof) return null;
    final start = pos;
    while (pos < bytes.length &&
        !_isWhitespace(bytes[pos]) &&
        !_isDelimiter(bytes[pos])) {
      pos++;
    }
    if (pos == start) return null;
    return latin1.decode(Uint8List.sublistView(bytes, start, pos));
  }

  Object? readObject({bool allowRef = true, int depth = 0}) {
    if (depth > DartPdfPages._maxRecursionDepth) return null;
    skipWhitespace();
    if (isEof) return null;
    final b = bytes[pos];
    if (b == 0x2F) return _PdfName(_readName()); // '/'
    if (b == 0x28) return _readLiteralString(); // '('
    if (b == 0x3C) {
      if (pos + 1 < bytes.length && bytes[pos + 1] == 0x3C) {
        return _readDict(allowRef: allowRef, depth: depth + 1);
      }
      return _readHexString();
    }
    if (b == 0x5B) {
      return _readArray(allowRef: allowRef, depth: depth + 1); // '['
    }
    if (b == 0x2B || b == 0x2D || b == 0x2E || (b >= 0x30 && b <= 0x39)) {
      final numValue = _readNumber();
      if (allowRef && numValue is int && numValue >= 0) {
        final saved = pos;
        final gen = _tryReadNonNegInt();
        if (gen != null && matchesKeyword('R')) {
          readKeyword();
          return _PdfRef(numValue, gen);
        }
        pos = saved;
      }
      return numValue;
    }
    final kw = readKeyword();
    return switch (kw) {
      'true' => true,
      'false' => false,
      'null' => null,
      _ => kw,
    };
  }

  int? _tryReadNonNegInt() {
    skipWhitespace();
    if (isEof) return null;
    final start = pos;
    while (pos < bytes.length && bytes[pos] >= 0x30 && bytes[pos] <= 0x39) {
      pos++;
    }
    if (pos == start) return null;
    if (pos < bytes.length &&
        !_isWhitespace(bytes[pos]) &&
        !_isDelimiter(bytes[pos])) {
      return null;
    }
    return int.tryParse(
      latin1.decode(Uint8List.sublistView(bytes, start, pos)),
    );
  }

  num? _readNumber() {
    final start = pos;
    var isFloat = false;
    if (pos < bytes.length && (bytes[pos] == 0x2B || bytes[pos] == 0x2D)) {
      pos++;
    }
    while (pos < bytes.length) {
      final b = bytes[pos];
      if (b >= 0x30 && b <= 0x39) {
        pos++;
      } else if (b == 0x2E && !isFloat) {
        isFloat = true;
        pos++;
      } else {
        break;
      }
    }
    final text = latin1.decode(Uint8List.sublistView(bytes, start, pos));
    return isFloat ? double.tryParse(text) : int.tryParse(text);
  }

  String _readName() {
    pos++; // skip '/'
    final out = BytesBuilder(copy: false);
    while (pos < bytes.length) {
      final b = bytes[pos];
      if (_isWhitespace(b) || _isDelimiter(b)) break;
      if (b == 0x23 && pos + 2 < bytes.length) {
        final hi = _hexDigit(bytes[pos + 1]);
        final lo = _hexDigit(bytes[pos + 2]);
        if (hi >= 0 && lo >= 0) {
          out.addByte((hi << 4) | lo);
          pos += 3;
          continue;
        }
      }
      out.addByte(b);
      pos++;
    }
    final raw = out.takeBytes();
    try {
      return utf8.decode(raw);
    } on FormatException {
      return latin1.decode(raw);
    }
  }

  Uint8List _readLiteralString() {
    pos++; // skip '('
    final out = BytesBuilder(copy: false);
    var parenDepth = 1;
    while (pos < bytes.length && parenDepth > 0) {
      final b = bytes[pos++];
      if (b == 0x5C) {
        // '\' escape
        if (pos >= bytes.length) break;
        final next = bytes[pos++];
        switch (next) {
          case 0x6E:
            out.addByte(0x0A); // \n
          case 0x72:
            out.addByte(0x0D); // \r
          case 0x74:
            out.addByte(0x09); // \t
          case 0x62:
            out.addByte(0x08); // \b
          case 0x66:
            out.addByte(0x0C); // \f
          case 0x28 || 0x29 || 0x5C:
            out.addByte(next);
          case 0x0D:
            if (pos < bytes.length && bytes[pos] == 0x0A) pos++;
          case 0x0A:
            break;
          default:
            if (next >= 0x30 && next <= 0x37) {
              var oct = next - 0x30;
              for (var k = 0; k < 2 && pos < bytes.length; k++) {
                final d = bytes[pos];
                if (d >= 0x30 && d <= 0x37) {
                  oct = (oct << 3) | (d - 0x30);
                  pos++;
                } else {
                  break;
                }
              }
              out.addByte(oct & 0xFF);
            } else {
              out.addByte(next);
            }
        }
      } else if (b == 0x28) {
        parenDepth++;
        out.addByte(b);
      } else if (b == 0x29) {
        parenDepth--;
        if (parenDepth > 0) out.addByte(b);
      } else if (b == 0x0D) {
        if (pos < bytes.length && bytes[pos] == 0x0A) pos++;
        out.addByte(0x0A);
      } else {
        out.addByte(b);
      }
    }
    return out.takeBytes();
  }

  Uint8List _readHexString() {
    pos++; // skip '<'
    final out = BytesBuilder(copy: false);
    var high = -1;
    while (pos < bytes.length) {
      final b = bytes[pos++];
      if (b == 0x3E) break; // '>'
      final nib = _hexDigit(b);
      if (nib < 0) continue;
      if (high < 0) {
        high = nib;
      } else {
        out.addByte((high << 4) | nib);
        high = -1;
      }
    }
    if (high >= 0) out.addByte(high << 4);
    return out.takeBytes();
  }

  List<Object?> _readArray({required bool allowRef, required int depth}) {
    pos++; // skip '['
    final list = <Object?>[];
    while (true) {
      skipWhitespace();
      if (isEof) break;
      if (bytes[pos] == 0x5D) {
        pos++;
        break;
      }
      final before = pos;
      final item = readObject(allowRef: allowRef, depth: depth);
      if (pos == before) {
        pos++;
        break;
      }
      list.add(item);
    }
    return list;
  }

  Map<String, Object?> _readDict({required bool allowRef, required int depth}) {
    pos += 2; // skip '<<'
    final map = <String, Object?>{};
    while (true) {
      skipWhitespace();
      if (isEof) break;
      if (bytes[pos] == 0x3E &&
          pos + 1 < bytes.length &&
          bytes[pos + 1] == 0x3E) {
        pos += 2;
        break;
      }
      final before = pos;
      final key = readObject(allowRef: false, depth: depth);
      if (key is! _PdfName) {
        if (pos == before) pos++;
        continue;
      }
      final value = readObject(allowRef: allowRef, depth: depth);
      map[key.value] = value;
    }
    return map;
  }
}

bool _isWhitespace(int b) =>
    b == 0x00 || b == 0x09 || b == 0x0A || b == 0x0C || b == 0x0D || b == 0x20;

bool _isDelimiter(int b) =>
    b == 0x28 ||
    b == 0x29 ||
    b == 0x3C ||
    b == 0x3E ||
    b == 0x5B ||
    b == 0x5D ||
    b == 0x7B ||
    b == 0x7D ||
    b == 0x2F ||
    b == 0x25;

int _hexDigit(int b) {
  if (b >= 0x30 && b <= 0x39) return b - 0x30;
  if (b >= 0x41 && b <= 0x46) return b - 0x41 + 10;
  if (b >= 0x61 && b <= 0x66) return b - 0x61 + 10;
  return -1;
}

int? _asInt(Object? value) => value is num ? value.toInt() : null;
double? _asDouble(Object? value) => value is num ? value.toDouble() : null;
String? _asName(Object? value) => value is _PdfName ? value.value : null;

Rect? _parseRect(Object? value) {
  if (value is! List<Object?> || value.length < 4) return null;
  final x1 = _asDouble(value[0]);
  final y1 = _asDouble(value[1]);
  final x2 = _asDouble(value[2]);
  final y2 = _asDouble(value[3]);
  if (x1 == null || y1 == null || x2 == null || y2 == null) return null;
  return Rect.fromLTRB(
    math.min(x1, x2),
    math.min(y1, y2),
    math.max(x1, x2),
    math.max(y1, y2),
  );
}

// ============================================================================
// Font Decoding (/ToUnicode CMap, /Encoding, /Differences, WinAnsi, UTF-16BE)
// ============================================================================

class _PdfFont {
  const new({
    required this.toUnicode,
    required this.codeLengths,
    required this.differences,
    required this.baseEncoding,
    required this.isIdentityTwoByte,
    required this.firstChar,
    required this.widths,
  });

  factory parse(_PdfDoc doc, Map<String, Object?> dict) {
    final toUnicode = <(int, int), String>{};
    final lengths = <int>{};
    final toUnicodeObj = doc.resolve(dict['ToUnicode']);
    if (toUnicodeObj is _PdfStream) {
      final cmapBytes = doc.decodeStream(toUnicodeObj);
      if (cmapBytes != null) {
        _parseCMap(cmapBytes, toUnicode, lengths);
      }
    }

    var baseEncoding = 'WinAnsiEncoding';
    var isIdentityTwoByte = false;
    final differences = <int, String>{};
    final encObj = doc.resolve(dict['Encoding']);
    if (encObj is _PdfName) {
      baseEncoding = encObj.value;
      if (baseEncoding == 'Identity-H' || baseEncoding == 'Identity-V') {
        isIdentityTwoByte = true;
      }
    } else if (encObj is Map<String, Object?>) {
      final base = _asName(doc.resolve(encObj['BaseEncoding']));
      if (base != null) baseEncoding = base;
      final diffList = doc.resolveList(encObj['Differences']);
      if (diffList != null) {
        var code = 0;
        for (final item in diffList) {
          if (item is int) {
            code = item;
          } else if (item is _PdfName) {
            final ch = _glyphToUnicode(item.value);
            if (ch != null) differences[code] = ch;
            code++;
          }
        }
      }
    }
    if (_asName(doc.resolve(dict['Subtype'])) == 'Type0' &&
        lengths.contains(2)) {
      isIdentityTwoByte = true;
    }

    final firstChar = _asInt(doc.resolve(dict['FirstChar'])) ?? 0;
    final widthsList = doc.resolveList(dict['Widths']);
    final widths = <double>[
      if (widthsList != null)
        for (final w in widthsList) _asDouble(doc.resolve(w)) ?? 500.0,
    ];

    final sortedLengths = lengths.toList()..sort((a, b) => b.compareTo(a));
    return _PdfFont(
      toUnicode: toUnicode,
      codeLengths: sortedLengths,
      differences: differences,
      baseEncoding: baseEncoding,
      isIdentityTwoByte: isIdentityTwoByte,
      firstChar: firstChar,
      widths: widths,
    );
  }

  static const fallback = _PdfFont(
    toUnicode: {},
    codeLengths: [],
    differences: {},
    baseEncoding: 'WinAnsiEncoding',
    isIdentityTwoByte: false,
    firstChar: 0,
    widths: [],
  );

  /// `(byteLength, code)` -> Unicode string.
  final Map<(int, int), String> toUnicode;

  /// Distinct byte lengths present in [toUnicode] (descending order).
  final List<int> codeLengths;
  final Map<int, String> differences;
  final String baseEncoding;
  final bool isIdentityTwoByte;
  final int firstChar;
  final List<double> widths;

  /// Decodes raw PDF string [bytes] into a Unicode string.
  String decode(Uint8List bytes) {
    if (bytes.isEmpty) return '';
    // UTF-16BE BOM inside a literal or hex string.
    if (toUnicode.isEmpty &&
        bytes.length >= 2 &&
        bytes[0] == 0xFE &&
        bytes[1] == 0xFF) {
      return _decodeUtf16Be(Uint8List.sublistView(bytes, 2));
    }
    if (toUnicode.isNotEmpty) {
      final out = StringBuffer();
      var i = 0;
      while (i < bytes.length) {
        var matched = false;
        for (final len in codeLengths) {
          if (i + len > bytes.length) continue;
          var code = 0;
          for (var k = 0; k < len; k++) {
            code = (code << 8) | bytes[i + k];
          }
          final mapped = toUnicode[(len, code)];
          if (mapped != null) {
            out.write(mapped);
            i += len;
            matched = true;
            break;
          }
        }
        if (!matched) {
          final step = isIdentityTwoByte && i + 2 <= bytes.length ? 2 : 1;
          if (step == 2) {
            final unit = (bytes[i] << 8) | bytes[i + 1];
            if (unit >= 0x20 && unit != 0xFFFF) out.writeCharCode(unit);
          } else {
            out.write(_decodeSingleByte(bytes[i]));
          }
          i += step;
        }
      }
      return out.toString();
    }
    if (isIdentityTwoByte && bytes.length.isEven) {
      return _decodeUtf16Be(bytes);
    }
    final out = StringBuffer();
    for (final byte in bytes) {
      out.write(_decodeSingleByte(byte));
    }
    return out.toString();
  }

  String _decodeSingleByte(int byte) {
    final diff = differences[byte];
    if (diff != null) return diff;
    if (baseEncoding == 'MacRomanEncoding') return _macRoman(byte);
    return _winAnsi(byte);
  }

  /// Estimated width of [rawBytes] (and [decoded] text) in units of 1/1000 em.
  double widthThousandths(Uint8List rawBytes, String decoded) {
    if (widths.isNotEmpty && !isIdentityTwoByte) {
      var total = 0.0;
      for (final b in rawBytes) {
        final idx = b - firstChar;
        if (idx >= 0 && idx < widths.length) {
          total += widths[idx];
        } else {
          total += 520.0;
        }
      }
      return total;
    }
    var total = 0.0;
    for (final rune in decoded.runes) {
      total += _approxGlyphWidth(rune);
    }
    return total;
  }
}

void _parseCMap(
  Uint8List bytes,
  Map<(int, int), String> map,
  Set<int> lengths,
) {
  final reader = _PdfReader(bytes, 0);
  final tokens = <Object?>[];
  while (!reader.isEof) {
    reader.skipWhitespace();
    if (reader.isEof) break;
    final before = reader.pos;
    final tok = reader.readObject(allowRef: false);
    if (reader.pos == before) {
      reader.pos++;
      continue;
    }
    if (tok == 'beginbfchar') {
      final count = tokens.isNotEmpty ? (_asInt(tokens.last) ?? 0) : 0;
      for (var i = 0; i < count; i++) {
        final src = reader.readObject(allowRef: false);
        final dst = reader.readObject(allowRef: false);
        if (src == 'endbfchar' || dst == 'endbfchar') break;
        if (src is Uint8List && dst is Uint8List && src.isNotEmpty) {
          final code = _bytesToInt(src);
          lengths.add(src.length);
          map[(src.length, code)] = _decodeUtf16Be(dst);
        }
      }
      tokens.clear();
    } else if (tok == 'beginbfrange') {
      final count = tokens.isNotEmpty ? (_asInt(tokens.last) ?? 0) : 0;
      for (var i = 0; i < count; i++) {
        final startObj = reader.readObject(allowRef: false);
        if (startObj == 'endbfrange') break;
        final endObj = reader.readObject(allowRef: false);
        final dstObj = reader.readObject(allowRef: false);
        if (startObj is! Uint8List ||
            endObj is! Uint8List ||
            startObj.isEmpty) {
          continue;
        }
        final len = startObj.length;
        final start = _bytesToInt(startObj);
        final end = _bytesToInt(endObj);
        if (end < start || end - start > 65536) continue;
        lengths.add(len);
        if (dstObj is Uint8List) {
          final base = _decodeUtf16Be(dstObj);
          if (base.isEmpty) continue;
          final units = base.codeUnits.toList();
          for (var c = start; c <= end; c++) {
            final last = units.last + (c - start);
            if (last <= 0xFFFF) {
              final copy = [...units.sublist(0, units.length - 1), last];
              map[(len, c)] = String.fromCharCodes(copy);
            }
          }
        } else if (dstObj is List<Object?>) {
          for (var idx = 0; idx < dstObj.length && start + idx <= end; idx++) {
            final elem = dstObj[idx];
            if (elem is Uint8List) {
              map[(len, start + idx)] = _decodeUtf16Be(elem);
            }
          }
        }
      }
      tokens.clear();
    } else {
      if (tokens.length > 8) tokens.removeAt(0);
      tokens.add(tok);
    }
  }
}

int _bytesToInt(Uint8List bytes) {
  var value = 0;
  for (final b in bytes) {
    value = (value << 8) | b;
  }
  return value;
}

String _decodeUtf16Be(Uint8List bytes) {
  if (bytes.isEmpty) return '';
  if (bytes.length == 1) return String.fromCharCode(bytes[0]);
  final units = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    units.add((bytes[i] << 8) | bytes[i + 1]);
  }
  return String.fromCharCodes(units);
}

String _winAnsi(int b) {
  if (b < 0x80 || b >= 0xA0) return String.fromCharCode(b);
  return _cp1252[b - 0x80];
}

const List<String> _cp1252 = [
  '\u20AC',
  '\u0081',
  '\u201A',
  '\u0192',
  '\u201E',
  '\u2026',
  '\u2020',
  '\u2021',
  '\u02C6',
  '\u2030',
  '\u0160',
  '\u2039',
  '\u0152',
  '\u008D',
  '\u017D',
  '\u008F',
  '\u0090',
  '\u2018',
  '\u2019',
  '\u201C',
  '\u201D',
  '\u2022',
  '\u2013',
  '\u2014',
  '\u02DC',
  '\u2122',
  '\u0161',
  '\u203A',
  '\u0153',
  '\u009D',
  '\u017E',
  '\u0178',
];

String _macRoman(int b) {
  if (b < 0x80) return String.fromCharCode(b);
  return _macRomanHigh[b - 0x80];
}

const List<String> _macRomanHigh = [
  'Ä',
  'Å',
  'Ç',
  'É',
  'Ñ',
  'Ö',
  'Ü',
  'á',
  'à',
  'â',
  'ä',
  'ã',
  'å',
  'ç',
  'é',
  'è',
  'ê',
  'ë',
  'í',
  'ì',
  'î',
  'ï',
  'ñ',
  'ó',
  'ò',
  'ô',
  'ö',
  'õ',
  'ú',
  'ù',
  'û',
  'ü',
  '†',
  '°',
  '¢',
  '£',
  '§',
  '•',
  '¶',
  'ß',
  '®',
  '©',
  '™',
  '´',
  '¨',
  '≠',
  'Æ',
  'Ø',
  '∞',
  '±',
  '≤',
  '≥',
  '¥',
  'µ',
  '∂',
  '∑',
  '∏',
  'π',
  '∫',
  'ª',
  'º',
  'Ω',
  'æ',
  'ø',
  '¿',
  '¡',
  '¬',
  '√',
  'ƒ',
  '≈',
  '∆',
  '«',
  '»',
  '…',
  '\u00A0',
  'À',
  'Ã',
  'Õ',
  'Œ',
  'œ',
  '–',
  '—',
  '“',
  '”',
  '‘',
  '’',
  '÷',
  '◊',
  'ÿ',
  'Ÿ',
  '⁄',
  '€',
  '‹',
  '›',
  'ﬁ',
  'ﬂ',
  '‡',
  '·',
  '‚',
  '„',
  '‰',
  'Â',
  'Ê',
  'Á',
  'Ë',
  'È',
  'Í',
  'Î',
  'Ï',
  'Ì',
  'Ó',
  'Ô',
  '\uF8FF',
  'Ò',
  'Ú',
  'Û',
  'Ù',
  'ı',
  'ˆ',
  '˜',
  '¯',
  '˘',
  '˙',
  '˚',
  '¸',
  '˝',
  '˛',
  'ˇ',
];

String? _glyphToUnicode(String name) {
  if (name.length == 1) return name;
  final known = _glyphNames[name];
  if (known != null) return known;
  if (name.startsWith('uni') &&
      name.length >= 7 &&
      (name.length - 3) % 4 == 0) {
    final units = <int>[];
    for (var i = 3; i < name.length; i += 4) {
      final code = int.tryParse(name.substring(i, i + 4), radix: 16);
      if (code == null) return null;
      units.add(code);
    }
    return String.fromCharCodes(units);
  }
  if (name.startsWith('u') && name.length >= 5 && name.length <= 7) {
    final code = int.tryParse(name.substring(1), radix: 16);
    if (code != null && code <= 0x10FFFF) return String.fromCharCode(code);
  }
  return null;
}

const Map<String, String> _glyphNames = {
  'space': ' ',
  'nbspace': ' ',
  'exclam': '!',
  'quotedbl': '"',
  'numbersign': '#',
  'dollar': r'$',
  'percent': '%',
  'ampersand': '&',
  'quotesingle': "'",
  'parenleft': '(',
  'parenright': ')',
  'asterisk': '*',
  'plus': '+',
  'comma': ',',
  'hyphen': '-',
  'minus': '-',
  'period': '.',
  'slash': '/',
  'zero': '0',
  'one': '1',
  'two': '2',
  'three': '3',
  'four': '4',
  'five': '5',
  'six': '6',
  'seven': '7',
  'eight': '8',
  'nine': '9',
  'colon': ':',
  'semicolon': ';',
  'less': '<',
  'equal': '=',
  'greater': '>',
  'question': '?',
  'at': '@',
  'bracketleft': '[',
  'backslash': r'\',
  'bracketright': ']',
  'asciicircum': '^',
  'underscore': '_',
  'grave': '`',
  'braceleft': '{',
  'bar': '|',
  'braceright': '}',
  'asciitilde': '~',
  'endash': '–',
  'emdash': '—',
  'quoteleft': '‘',
  'quoteright': '’',
  'quotedblleft': '“',
  'quotedblright': '”',
  'bullet': '•',
  'ellipsis': '…',
  'Euro': '€',
  'fi': 'fi',
  'fl': 'fl',
  'ff': 'ff',
  'ffi': 'ffi',
  'ffl': 'ffl',
  'germandbls': 'ß',
  'udieresis': 'ü',
  'adieresis': 'ä',
  'odieresis': 'ö',
  'Udieresis': 'Ü',
  'Adieresis': 'Ä',
  'Odieresis': 'Ö',
  'eacute': 'é',
  'egrave': 'è',
  'ecircumflex': 'ê',
  'aacute': 'á',
  'agrave': 'à',
  'acircumflex': 'â',
  'ccedilla': 'ç',
  'ntilde': 'ñ',
  'oacute': 'ó',
  'uacute': 'ú',
  'iacute': 'í',
  'Eacute': 'É',
  'AE': 'Æ',
  'ae': 'æ',
  'OE': 'Œ',
  'oe': 'œ',
};

// ============================================================================
// Content Stream Interpreter
// ============================================================================

class _GraphicsState {
  new({
    List<double>? ctm,
    this.font = _PdfFont.fallback,
    this.fontSize = 12,
    this.charSpace = 0,
    this.wordSpace = 0,
    this.hScale = 1,
    this.leading = 0,
    this.rise = 0,
  }) : ctm = ctm ?? [1, 0, 0, 1, 0, 0];

  List<double> ctm;
  _PdfFont font;
  double fontSize;
  double charSpace;
  double wordSpace;
  double hScale;
  double leading;
  double rise;

  _GraphicsState clone() => _GraphicsState(
    ctm: [...ctm],
    font: font,
    fontSize: fontSize,
    charSpace: charSpace,
    wordSpace: wordSpace,
    hScale: hScale,
    leading: leading,
    rise: rise,
  );
}

class _TextSpan {
  const new({
    required this.text,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.baselineY,
    required this.fontSize,
  });

  final String text;
  final double left;
  final double top;
  final double right;
  final double bottom;
  final double baselineY;
  final double fontSize;
}

class _TextExtractor {
  new(this.doc, this.page);

  final _PdfDoc doc;
  final _PdfPageInfo page;
  final List<_TextSpan> _spans = [];

  _GraphicsState _gs = _GraphicsState();
  final List<_GraphicsState> _stack = [];
  List<double> _tm = [1, 0, 0, 1, 0, 0];
  List<double> _tlm = [1, 0, 0, 1, 0, 0];

  void interpret(
    Uint8List streamBytes, {
    required Map<String, Object?>? resources,
    required int formDepth,
  }) {
    final fonts = doc.resolveDict(resources?['Font']);
    final xObjects = doc.resolveDict(resources?['XObject']);
    final reader = _PdfReader(streamBytes, 0);
    final operands = <Object?>[];

    while (!reader.isEof) {
      reader.skipWhitespace();
      if (reader.isEof) break;
      final before = reader.pos;
      final token = reader.readObject(allowRef: false);
      if (reader.pos == before) {
        reader.pos++;
        continue;
      }
      if (token is String) {
        _handleOperator(
          token,
          operands,
          fonts: fonts,
          xObjects: xObjects,
          parentResources: resources,
          formDepth: formDepth,
        );
        operands.clear();
        if (_spans.length >= PdfLimits.maxTextLines * 8) break;
      } else {
        operands.add(token);
      }
    }
  }

  void _handleOperator(
    String op,
    List<Object?> args, {
    required Map<String, Object?>? fonts,
    required Map<String, Object?>? xObjects,
    required Map<String, Object?>? parentResources,
    required int formDepth,
  }) {
    switch (op) {
      case 'q':
        if (_stack.length < 64) _stack.add(_gs.clone());
      case 'Q':
        if (_stack.isNotEmpty) _gs = _stack.removeLast();
      case 'cm':
        if (args.length >= 6) {
          final m = _matrixFromArgs(args);
          if (m != null) _gs.ctm = _multiplyMatrix(m, _gs.ctm);
        }
      case 'BT':
        _tm = [1, 0, 0, 1, 0, 0];
        _tlm = [1, 0, 0, 1, 0, 0];
      case 'ET':
        break;
      case 'Tf':
        if (args.length >= 2) {
          final name = _asName(args[args.length - 2]);
          final size = _asDouble(args.last);
          if (name != null) {
            final fontObj = fonts?[name];
            _gs.font = fontObj != null
                ? doc.resolveFont(fontObj)
                : _PdfFont.fallback;
          }
          if (size != null && size.isFinite) _gs.fontSize = size.abs();
        }
      case 'Tc':
        if (args.isNotEmpty) _gs.charSpace = _asDouble(args.last) ?? 0;
      case 'Tw':
        if (args.isNotEmpty) _gs.wordSpace = _asDouble(args.last) ?? 0;
      case 'Tz':
        if (args.isNotEmpty) {
          final scale = _asDouble(args.last);
          if (scale != null && scale > 0) _gs.hScale = scale / 100.0;
        }
      case 'TL':
        if (args.isNotEmpty) _gs.leading = _asDouble(args.last) ?? 0;
      case 'Ts':
        if (args.isNotEmpty) _gs.rise = _asDouble(args.last) ?? 0;
      case 'Tm':
        if (args.length >= 6) {
          final m = _matrixFromArgs(args);
          if (m != null) {
            _tm = [...m];
            _tlm = [...m];
          }
        }
      case 'Td':
        if (args.length >= 2) {
          final tx = _asDouble(args[args.length - 2]) ?? 0;
          final ty = _asDouble(args.last) ?? 0;
          _tlm = _multiplyMatrix([1, 0, 0, 1, tx, ty], _tlm);
          _tm = [..._tlm];
        }
      case 'TD':
        if (args.length >= 2) {
          final tx = _asDouble(args[args.length - 2]) ?? 0;
          final ty = _asDouble(args.last) ?? 0;
          _gs.leading = -ty;
          _tlm = _multiplyMatrix([1, 0, 0, 1, tx, ty], _tlm);
          _tm = [..._tlm];
        }
      case 'T*':
        _tlm = _multiplyMatrix([1, 0, 0, 1, 0, -_gs.leading], _tlm);
        _tm = [..._tlm];
      case 'Tj':
        if (args.isNotEmpty && args.last is Uint8List) {
          _showBytes(args.last! as Uint8List);
        }
      case 'TJ':
        if (args.isNotEmpty && args.last is List<Object?>) {
          for (final item in args.last! as List<Object?>) {
            if (item is Uint8List) {
              _showBytes(item);
            } else if (item is num) {
              final dx = -item.toDouble() / 1000.0 * _gs.fontSize * _gs.hScale;
              _tm = _multiplyMatrix([1, 0, 0, 1, dx, 0], _tm);
            }
          }
        }
      case "'":
        _tlm = _multiplyMatrix([1, 0, 0, 1, 0, -_gs.leading], _tlm);
        _tm = [..._tlm];
        if (args.isNotEmpty && args.last is Uint8List) {
          _showBytes(args.last! as Uint8List);
        }
      case '"':
        if (args.length >= 3 && args.last is Uint8List) {
          _gs.wordSpace = _asDouble(args[args.length - 3]) ?? 0;
          _gs.charSpace = _asDouble(args[args.length - 2]) ?? 0;
          _tlm = _multiplyMatrix([1, 0, 0, 1, 0, -_gs.leading], _tlm);
          _tm = [..._tlm];
          _showBytes(args.last! as Uint8List);
        }
      case 'Do':
        if (formDepth < DartPdfPages._maxFormDepth &&
            args.isNotEmpty &&
            xObjects != null) {
          final name = _asName(args.last);
          if (name != null) {
            final obj = doc.resolve(xObjects[name]);
            if (obj is _PdfStream &&
                _asName(doc.resolve(obj.dict['Subtype'])) == 'Form') {
              final formBytes = doc.decodeStream(obj);
              if (formBytes != null && formBytes.isNotEmpty) {
                final saved = _gs.clone();
                final mList = doc.resolveList(obj.dict['Matrix']);
                if (mList != null && mList.length >= 6) {
                  final m = _matrixFromArgs(mList);
                  if (m != null) _gs.ctm = _multiplyMatrix(m, _gs.ctm);
                }
                final formRes =
                    doc.resolveDict(obj.dict['Resources']) ?? parentResources;
                interpret(
                  formBytes,
                  resources: formRes,
                  formDepth: formDepth + 1,
                );
                _gs = saved;
              }
            }
          }
        }
    }
  }

  void _showBytes(Uint8List raw) {
    if (raw.isEmpty) return;
    final text = _gs.font.decode(raw);
    final widthEm = _gs.font.widthThousandths(raw, text);
    final spaces = ' '.allMatches(text).length;
    final advanceLocal =
        (widthEm / 1000.0 * _gs.fontSize +
            _gs.charSpace * text.length +
            _gs.wordSpace * spaces) *
        _gs.hScale;

    if (text.trim().isNotEmpty) {
      final combined = _multiplyMatrix(_tm, _gs.ctm);
      final scaleY = math.sqrt(
        combined[2] * combined[2] + combined[3] * combined[3],
      );
      final scaleX = math.sqrt(
        combined[0] * combined[0] + combined[1] * combined[1],
      );
      final effectiveSize = math.max<double>(
        1,
        (_gs.fontSize > 0 ? _gs.fontSize : 12.0) * (scaleY > 0 ? scaleY : 1.0),
      );
      final widthPt = math.max(
        effectiveSize * 0.3,
        advanceLocal * (scaleX > 0 ? scaleX : 1.0),
      );
      final x = combined[4] - page.mediaBox.left;
      final yFromBottom = combined[5] - page.mediaBox.top + _gs.rise * scaleY;
      final baselineY = page.mediaBox.height - yFromBottom;
      final top = baselineY - effectiveSize * 0.85;
      final bottom = baselineY + effectiveSize * 0.25;
      _spans.add(
        _TextSpan(
          text: text,
          left: x,
          top: top,
          right: x + widthPt,
          bottom: bottom,
          baselineY: baselineY,
          fontSize: effectiveSize,
        ),
      );
    }

    _tm = _multiplyMatrix([1, 0, 0, 1, advanceLocal, 0], _tm);
  }

  List<PdfTextLine> buildLines() {
    if (_spans.isEmpty) return const [];
    final lines = <PdfTextLine>[];
    final current = <_TextSpan>[];

    void flush() {
      if (current.isEmpty || lines.length >= PdfLimits.maxTextLines) {
        current.clear();
        return;
      }
      current.sort((a, b) => a.left.compareTo(b.left));
      final buffer = StringBuffer();
      var left = current.first.left;
      var top = current.first.top;
      var right = current.first.right;
      var bottom = current.first.bottom;
      _TextSpan? prev;
      for (final span in current) {
        if (prev != null) {
          final gap = span.left - prev.right;
          final threshold = math.min(prev.fontSize, span.fontSize) * 0.22;
          final needsSpace =
              gap > threshold &&
              !buffer.toString().endsWith(' ') &&
              !span.text.startsWith(' ');
          if (needsSpace) buffer.write(' ');
        }
        buffer.write(span.text);
        left = math.min(left, span.left);
        top = math.min(top, span.top);
        right = math.max(right, span.right);
        bottom = math.max(bottom, span.bottom);
        prev = span;
      }
      var text = buffer.toString().trim();
      if (text.length > PdfLimits.maxTextLineLength) {
        text = text.substring(0, PdfLimits.maxTextLineLength);
      }
      if (text.isNotEmpty) {
        final w = page.size.width;
        final h = page.size.height;
        final rect = Rect.fromLTRB(
          left.clamp(0.0, w),
          top.clamp(0.0, h),
          right.clamp(0.0, w),
          bottom.clamp(0.0, h),
        );
        if (rect.width > 0 && rect.height > 0) {
          lines.add(PdfTextLine(text: text, rect: rect));
        }
      }
      current.clear();
    }

    for (final span in _spans) {
      if (current.isEmpty) {
        current.add(span);
        continue;
      }
      final ref = current.last;
      final sameLine =
          (span.baselineY - ref.baselineY).abs() <=
          math.max(ref.fontSize, span.fontSize) * 0.4;
      if (sameLine) {
        current.add(span);
      } else {
        flush();
        current.add(span);
      }
    }
    flush();
    return lines;
  }
}

List<double>? _matrixFromArgs(List<Object?> args) {
  final start = args.length - 6;
  final out = <double>[];
  for (var i = 0; i < 6; i++) {
    final v = _asDouble(args[start + i]);
    if (v == null || !v.isFinite) return null;
    out.add(v);
  }
  return out;
}

List<double> _multiplyMatrix(List<double> m1, List<double> m2) => [
  m1[0] * m2[0] + m1[1] * m2[2],
  m1[0] * m2[1] + m1[1] * m2[3],
  m1[2] * m2[0] + m1[3] * m2[2],
  m1[2] * m2[1] + m1[3] * m2[3],
  m1[4] * m2[0] + m1[5] * m2[2] + m2[4],
  m1[4] * m2[1] + m1[5] * m2[3] + m2[5],
];

// ============================================================================
// PDF 1.4 Writer
// ============================================================================

abstract final class _PdfWriter {
  static Uint8List build(List<PdfOutputPage> pages) {
    // Collect any non-WinAnsi runes across all blocks so we can emit an exact
    // /ToUnicode CMap on /F2 when needed.
    final unicodeRunes = <int>{};
    for (final page in pages) {
      for (final block in page.blocks) {
        for (final rune in block.text.runes) {
          if (_toWinAnsiByte(rune) == null && rune != 0x0A && rune != 0x0D) {
            unicodeRunes.add(rune);
          }
        }
      }
    }
    final needsUnicodeFont = unicodeRunes.isNotEmpty;

    final objects = <Uint8List>[];
    // Reserve indices:
    // 1: Catalog
    // 2: Pages
    // 3: /F1 Helvetica (WinAnsiEncoding)
    // Optional 4, 5, 6: /F2 Type0, CIDFont, ToUnicode CMap
    const catalogId = 1;
    const pagesId = 2;
    const f1Id = 3;
    final f2Id = needsUnicodeFont ? 4 : null;
    final cidId = needsUnicodeFont ? 5 : null;
    final cmapId = needsUnicodeFont ? 6 : null;

    final firstPageObjId = needsUnicodeFont ? 7 : 4;
    final pageObjIds = <int>[];
    final pageContentObjects = <Uint8List>[];
    final pageDictObjects = <Uint8List>[];

    for (var i = 0; i < pages.length; i++) {
      final page = pages[i];
      final contentId = firstPageObjId + i * 2;
      final pageId = contentId + 1;
      pageObjIds.add(pageId);

      final stream = _buildPageStream(page);
      final streamBytes = latin1.encode(stream);
      pageContentObjects.add(
        _streamObject('<< /Length ${streamBytes.length} >>', streamBytes),
      );
      final w = _fmt(page.size.width > 0 ? page.size.width : 612);
      final h = _fmt(page.size.height > 0 ? page.size.height : 792);
      final fontDict = needsUnicodeFont
          ? '/F1 $f1Id 0 R /F2 $f2Id 0 R'
          : '/F1 $f1Id 0 R';
      pageDictObjects.add(
        latin1.encode(
          '<< /Type /Page /Parent $pagesId 0 R /MediaBox [0 0 $w $h] '
          '/Resources << /Font << $fontDict >> >> '
          '/Contents $contentId 0 R >>',
        ),
      );
    }

    objects
      ..add(latin1.encode('<< /Type /Catalog /Pages $pagesId 0 R >>'))
      ..add(
        latin1.encode(
          '<< /Type /Pages /Kids [${pageObjIds.map((id) => '$id 0 R').join(' ')}] '
          '/Count ${pageObjIds.length} >>',
        ),
      )
      ..add(
        latin1.encode(
          '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica '
          '/Encoding /WinAnsiEncoding >>',
        ),
      );

    if (needsUnicodeFont) {
      final cmapBytes = latin1.encode(_buildToUnicodeCMap(unicodeRunes));
      objects
        ..add(
          latin1.encode(
            '<< /Type /Font /Subtype /Type0 /BaseFont /Helvetica '
            '/Encoding /Identity-H /DescendantFonts [$cidId 0 R] '
            '/ToUnicode $cmapId 0 R >>',
          ),
        )
        ..add(
          latin1.encode(
            '<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Helvetica '
            '/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) '
            '/Supplement 0 >> /DW 600 >>',
          ),
        )
        ..add(_streamObject('<< /Length ${cmapBytes.length} >>', cmapBytes));
    }

    for (var i = 0; i < pages.length; i++) {
      objects
        ..add(pageContentObjects[i])
        ..add(pageDictObjects[i]);
    }

    final out = BytesBuilder(copy: false)
      ..add(const [0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34, 0x0A])
      ..add(const [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]);

    final offsets = <int>[0]; // object 0 is always free
    for (var i = 0; i < objects.length; i++) {
      offsets.add(out.length);
      out
        ..add(latin1.encode('${i + 1} 0 obj\n'))
        ..add(objects[i])
        ..add(latin1.encode('\nendobj\n'));
    }

    final xrefOffset = out.length;
    out
      ..add(latin1.encode('xref\n0 ${offsets.length}\n'))
      ..add(latin1.encode('0000000000 65535 f \n'));
    for (var i = 1; i < offsets.length; i++) {
      final off = offsets[i].toString().padLeft(10, '0');
      out.add(latin1.encode('$off 00000 n \n'));
    }
    out.add(
      latin1.encode(
        'trailer\n<< /Size ${offsets.length} /Root $catalogId 0 R >>\n'
        'startxref\n$xrefOffset\n%%EOF\n',
      ),
    );
    return out.takeBytes();
  }

  static Uint8List _streamObject(String dict, Uint8List bytes) {
    final builder = BytesBuilder(copy: false)
      ..add(latin1.encode('$dict\nstream\n'))
      ..add(bytes)
      ..add(latin1.encode('\nendstream'));
    return builder.takeBytes();
  }

  static String _buildToUnicodeCMap(Set<int> runes) {
    final sorted = runes.toList()..sort();
    final buffer = StringBuffer()
      ..writeln('/CIDInit /ProcSet findresource begin')
      ..writeln('12 dict begin')
      ..writeln('begincmap')
      ..writeln(
        '/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def',
      )
      ..writeln('/CMapName /Adobe-Identity-UCS def')
      ..writeln('/CMapType 2 def')
      ..writeln('1 begincodespacerange')
      ..writeln('<0000> <FFFF>')
      ..writeln('endcodespacerange');

    // Emit in chunks of at most 100 entries per beginbfchar..endbfchar block.
    final entries = <String>[];
    for (final rune in sorted) {
      if (rune <= 0xFFFF) {
        final hex = rune.toRadixString(16).toUpperCase().padLeft(4, '0');
        entries.add('<$hex> <$hex>');
      } else {
        // Surrogate pair encoded as two UTF-16 code units.
        final v = rune - 0x10000;
        final hi = (0xD800 + (v >> 10))
            .toRadixString(16)
            .toUpperCase()
            .padLeft(4, '0');
        final lo = (0xDC00 + (v & 0x3FF))
            .toRadixString(16)
            .toUpperCase()
            .padLeft(4, '0');
        entries
          ..add('<$hi> <$hi>')
          ..add('<$lo> <$lo>');
      }
    }
    for (var i = 0; i < entries.length; i += 100) {
      final end = math.min(entries.length, i + 100);
      buffer.writeln('${end - i} beginbfchar');
      for (var k = i; k < end; k++) {
        buffer.writeln(entries[k]);
      }
      buffer.writeln('endbfchar');
    }
    buffer
      ..writeln('endcmap')
      ..writeln('CMapName currentdict /CMap defineresource pop')
      ..writeln('end')
      ..writeln('end');
    return buffer.toString();
  }

  static String _buildPageStream(PdfOutputPage page) {
    final pageW = page.size.width > 0 ? page.size.width : 612.0;
    final pageH = page.size.height > 0 ? page.size.height : 792.0;
    final out = StringBuffer()
      ..writeln('1 1 1 rg')
      ..writeln('0 0 ${_fmt(pageW)} ${_fmt(pageH)} re f');

    for (final block in page.blocks) {
      final text = block.text.trim();
      if (text.isEmpty || block.rect.width <= 0 || block.rect.height <= 0) {
        continue;
      }
      final rect = block.rect;
      final bgY = pageH - rect.bottom;
      out
        ..writeln('${_rgb(block.background)} rg')
        ..writeln(
          '${_fmt(rect.left)} ${_fmt(bgY)} '
          '${_fmt(rect.width)} ${_fmt(rect.height)} re f',
        );

      // Fit font size and word-wrap text into rect.
      var fontSize = block.fontSize.isFinite
          ? block.fontSize.clamp(5.0, 72.0)
          : 12.0;
      var lines = _wrapText(text, rect.width, fontSize);
      while (lines.length * fontSize * 1.2 > rect.height && fontSize > 4.5) {
        fontSize *= 0.9;
        lines = _wrapText(text, rect.width, fontSize);
      }

      final lineHeight = fontSize * 1.2;
      out.writeln('${_rgb(block.color)} rg');

      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.isEmpty) continue;
        final lineW = _measureText(line, fontSize);
        final x = _alignedX(rect, lineW, block.align, block.direction);
        final baselineY = pageH - (rect.top + fontSize * 0.85 + i * lineHeight);
        if (_isAllWinAnsi(line)) {
          out.writeln(
            'BT /F1 ${_fmt(fontSize)} Tf '
            '1 0 0 1 ${_fmt(x)} ${_fmt(baselineY)} Tm '
            '(${_escapePdfWinAnsi(line)}) Tj ET',
          );
        } else {
          out.writeln(
            'BT /F2 ${_fmt(fontSize)} Tf '
            '1 0 0 1 ${_fmt(x)} ${_fmt(baselineY)} Tm '
            '<${_encodeUtf16BeHex(line)}> Tj ET',
          );
        }
      }
    }
    return out.toString();
  }

  static double _alignedX(
    Rect rect,
    double lineWidth,
    PdfTextAlign align,
    TextDirection direction,
  ) {
    final effective = switch (align) {
      PdfTextAlign.center => PdfTextAlign.center,
      PdfTextAlign.start =>
        direction == TextDirection.rtl ? PdfTextAlign.end : PdfTextAlign.start,
      PdfTextAlign.end =>
        direction == TextDirection.rtl ? PdfTextAlign.start : PdfTextAlign.end,
    };
    return switch (effective) {
      PdfTextAlign.start => rect.left,
      PdfTextAlign.center =>
        rect.left + math.max(0.0, (rect.width - lineWidth) / 2),
      PdfTextAlign.end => math.max(rect.left, rect.right - lineWidth),
    };
  }

  static List<String> _wrapText(String text, double maxWidth, double fontSize) {
    final out = <String>[];
    for (final rawLine in text.replaceAll('\r\n', '\n').split('\n')) {
      final words = rawLine.split(RegExp(r'\s+'));
      final current = StringBuffer();
      for (final word in words) {
        if (word.isEmpty) continue;
        if (current.isEmpty) {
          current.write(word);
          continue;
        }
        final candidate = '$current $word';
        if (_measureText(candidate, fontSize) <= maxWidth) {
          current
            ..write(' ')
            ..write(word);
        } else {
          out.add(current.toString());
          current
            ..clear()
            ..write(word);
        }
      }
      if (current.isNotEmpty) out.add(current.toString());
    }
    return out;
  }

  static double _measureText(String text, double fontSize) {
    var units = 0.0;
    for (final rune in text.runes) {
      units += _approxGlyphWidth(rune);
    }
    return units / 1000.0 * fontSize;
  }

  static bool _isAllWinAnsi(String text) {
    for (final rune in text.runes) {
      if (_toWinAnsiByte(rune) == null) return false;
    }
    return true;
  }

  static String _escapePdfWinAnsi(String text) {
    final out = StringBuffer();
    for (final rune in text.runes) {
      final byte = _toWinAnsiByte(rune) ?? 0x3F;
      switch (byte) {
        case 0x28:
          out.write(r'\(');
        case 0x29:
          out.write(r'\)');
        case 0x5C:
          out.write(r'\\');
        default:
          if (byte >= 0x20 && byte <= 0x7E) {
            out.writeCharCode(byte);
          } else {
            out.write('\\${byte.toRadixString(8).padLeft(3, '0')}');
          }
      }
    }
    return out.toString();
  }

  static String _encodeUtf16BeHex(String text) {
    final out = StringBuffer();
    for (final unit in text.codeUnits) {
      out.write(unit.toRadixString(16).toUpperCase().padLeft(4, '0'));
    }
    return out.toString();
  }

  static String _rgb(Color color) {
    final argb = color.toARGB32();
    final r = ((argb >> 16) & 0xFF) / 255.0;
    final g = ((argb >> 8) & 0xFF) / 255.0;
    final b = (argb & 0xFF) / 255.0;
    return '${_fmt(r)} ${_fmt(g)} ${_fmt(b)}';
  }

  static String _fmt(double value) {
    if (!value.isFinite) return '0';
    final s = value.toStringAsFixed(3);
    if (!s.contains('.')) return s;
    return s.replaceFirst(RegExp(r'\.?0+$'), '');
  }
}

int? _toWinAnsiByte(int rune) {
  if ((rune >= 0x20 && rune <= 0x7E) || (rune >= 0xA0 && rune <= 0xFF)) {
    return rune;
  }
  return _unicodeToCp1252[rune];
}

const Map<int, int> _unicodeToCp1252 = {
  0x20AC: 0x80,
  0x201A: 0x82,
  0x0192: 0x83,
  0x201E: 0x84,
  0x2026: 0x85,
  0x2020: 0x86,
  0x2021: 0x87,
  0x02C6: 0x88,
  0x2030: 0x89,
  0x0160: 0x8A,
  0x2039: 0x8B,
  0x0152: 0x8C,
  0x017D: 0x8E,
  0x2018: 0x91,
  0x2019: 0x92,
  0x201C: 0x93,
  0x201D: 0x94,
  0x2022: 0x95,
  0x2013: 0x96,
  0x2014: 0x97,
  0x02DC: 0x98,
  0x2122: 0x99,
  0x0161: 0x9A,
  0x203A: 0x9B,
  0x0153: 0x9C,
  0x017E: 0x9E,
  0x0178: 0x9F,
};

double _approxGlyphWidth(int rune) {
  if (rune == 0x20) return 278;
  if (rune == 0x69 ||
      rune == 0x6C ||
      rune == 0x49 ||
      rune == 0x21 ||
      rune == 0x2E ||
      rune == 0x2C ||
      rune == 0x3A ||
      rune == 0x3B ||
      rune == 0x27) {
    return 278;
  }
  if (rune == 0x6D || rune == 0x77 || rune == 0x4D || rune == 0x57) return 833;
  if (rune >= 0x41 && rune <= 0x5A) return 667;
  if (rune >= 0x2E80 && rune <= 0x9FFF || rune >= 0xAC00 && rune <= 0xD7AF) {
    return 950;
  }
  return 540;
}
