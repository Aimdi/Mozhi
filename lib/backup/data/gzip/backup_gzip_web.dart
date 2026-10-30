// coverage:ignore-file
// The browser's CompressionStream / DecompressionStream; covered by the
// web e2e test (e2e/tests/backup.spec.js), not by the VM tests. Browsers
// without them (Firefox before 113, Safari before 16.4) use the pure Dart
// gzip of backup_gzip_dart.dart (tested in the VM).
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:mozhi/backup/data/gzip/backup_gzip_dart.dart';

@JS('CompressionStream')
extension type _CompressionStream._(JSObject _) implements JSObject {
  external factory(JSString format);
}

@JS('DecompressionStream')
extension type _DecompressionStream._(JSObject _) implements JSObject {
  external factory(JSString format);
}

@JS('Blob')
extension type _Blob._(JSObject _) implements JSObject {
  external factory(JSArray<JSAny> parts);

  external _ReadableStream stream();
}

@JS('Response')
extension type _Response._(JSObject _) implements JSObject {
  external factory(_ReadableStream body);

  external JSPromise<JSArrayBuffer> arrayBuffer();
}

extension type _ReadableStream._(JSObject _) implements JSObject {
  external _ReadableStream pipeThrough(JSObject transform);

  external _Reader getReader();
}

extension type _Reader._(JSObject _) implements JSObject {
  external JSPromise<_ReadResult> read();

  external JSPromise<JSAny?> cancel();
}

extension type _ReadResult._(JSObject _) implements JSObject {
  external bool get done;

  external JSUint8Array? get value;
}

/// Whether the browser has the global constructor [name].
bool _has(String name) =>
    globalContext.getProperty<JSAny?>(name.toJS).isA<JSFunction>();

/// [bytes] compressed with gzip (stored, not compressed, where the browser
/// has no `CompressionStream`).
Future<Uint8List> gzipEncode(Uint8List bytes) async {
  if (!_has('CompressionStream')) return await dartGzipEncode(bytes);
  final stream = _Blob([bytes.toJS].toJS)
      .stream()
      .pipeThrough(_CompressionStream('gzip'.toJS));
  final buffer = await _Response(stream).arrayBuffer().toDart;
  return buffer.toDart.asUint8List();
}

/// [bytes] (gzip) decompressed. Throws a [FormatException] when they are
/// not gzip, or decompress to more than [maxLength] bytes (the
/// decompression stops there).
Future<Uint8List> gzipDecode(Uint8List bytes, {required int maxLength}) async {
  if (!_has('DecompressionStream')) {
    return await dartGzipDecode(bytes, maxLength: maxLength);
  }
  final reader = _Blob([bytes.toJS].toJS)
      .stream()
      .pipeThrough(_DecompressionStream('gzip'.toJS))
      .getReader();
  final builder = BytesBuilder(copy: false);
  while (true) {
    final _ReadResult chunk;
    try {
      chunk = await reader.read().toDart;
    } on Object {
      throw const FormatException('Not gzip data');
    }
    if (chunk.done) break;
    final value = chunk.value?.toDart;
    if (value == null) continue;
    if (builder.length + value.length > maxLength) {
      await reader.cancel().toDart;
      throw const FormatException('Decompressed data too large');
    }
    builder.add(value);
  }
  return builder.takeBytes();
}
