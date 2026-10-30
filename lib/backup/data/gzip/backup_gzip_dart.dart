import 'dart:typed_data';

import 'package:translation_repository/translation_repository.dart'
    as packs
    show gzipDecode, gzipEncodeStored;

// gzip in pure Dart, for browsers without `CompressionStream` /
// `DecompressionStream` (Firefox before 113, Safari before 16.4): the web
// app uses it there instead of failing (backup_gzip_web.dart).
//
// [dartGzipEncode] stores the data without compressing it (stored DEFLATE
// blocks): a larger file, but standard gzip that every backup reader opens
// (the Android app, the web app, `gunzip`). [dartGzipDecode] reads any
// gzip.

/// [bytes] as gzip (not compressed).
Future<Uint8List> dartGzipEncode(Uint8List bytes) async =>
    packs.gzipEncodeStored(bytes);

/// [bytes] (gzip) decompressed. Throws a [FormatException] when they are
/// not gzip (or damaged), or decompress to more than [maxLength] bytes.
Future<Uint8List> dartGzipDecode(
  Uint8List bytes, {
  required int maxLength,
}) async => packs.gzipDecode(bytes, maxLength: maxLength);
