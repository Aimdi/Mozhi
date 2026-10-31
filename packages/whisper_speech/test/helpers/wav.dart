import 'dart:typed_data';

/// The 16-bit PCM of a WAV file ([bytes]): its `data` chunk, after checking
/// that the `fmt ` chunk says 16 kHz mono 16-bit PCM (what Whisper reads
/// and the app records). Throws [FormatException] otherwise.
Uint8List wavPcm16(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  String tag(int offset) => String.fromCharCodes(bytes, offset, offset + 4);
  if (bytes.length < 12 || tag(0) != 'RIFF' || tag(8) != 'WAVE') {
    throw const FormatException('Not a WAV file');
  }
  var offset = 12;
  var format = false;
  while (offset + 8 <= bytes.length) {
    final id = tag(offset);
    final size = data.getUint32(offset + 4, Endian.little);
    final body = offset + 8;
    if (id == 'fmt ') {
      final encoding = data.getUint16(body, Endian.little);
      final channels = data.getUint16(body + 2, Endian.little);
      final rate = data.getUint32(body + 4, Endian.little);
      final bits = data.getUint16(body + 14, Endian.little);
      if (encoding != 1 || channels != 1 || rate != 16000 || bits != 16) {
        throw FormatException(
          'Not 16 kHz mono 16-bit PCM: $encoding, $channels, $rate, $bits',
        );
      }
      format = true;
    } else if (id == 'data') {
      if (!format) throw const FormatException('data before fmt');
      final end = body + size > bytes.length ? bytes.length : body + size;
      return Uint8List.sublistView(bytes, body, end);
    }
    offset = body + size + (size.isOdd ? 1 : 0);
  }
  throw const FormatException('No data chunk');
}
