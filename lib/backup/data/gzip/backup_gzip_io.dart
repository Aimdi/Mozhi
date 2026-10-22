import 'dart:io';
import 'dart:typed_data';

/// [bytes] compressed with gzip.
Future<Uint8List> gzipEncode(Uint8List bytes) async =>
    Uint8List.fromList(gzip.encode(bytes));

/// [bytes] (gzip) decompressed. Throws a [FormatException] when they are
/// not gzip, or decompress to more than [maxLength] bytes (the
/// decompression stops there).
Future<Uint8List> gzipDecode(Uint8List bytes, {required int maxLength}) async {
  final output = _LimitedSink(maxLength);
  // Data that isn't gzip throws a FormatException ("Filter error").
  gzip.decoder.startChunkedConversion(output)
    ..add(bytes)
    ..close();
  return output.builder.takeBytes();
}

/// Collects decompressed chunks up to [maxLength] bytes.
class _LimitedSink implements Sink<List<int>> {
  new(this.maxLength);

  final int maxLength;
  final builder = BytesBuilder(copy: false);

  @override
  void add(List<int> data) {
    if (builder.length + data.length > maxLength) {
      throw const FormatException('Decompressed data too large');
    }
    builder.add(data);
  }

  @override
  void close() {}
}
