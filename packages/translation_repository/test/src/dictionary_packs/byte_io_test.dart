import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:translation_repository/src/dictionary_packs/byte_io.dart';

void main() {
  test('writes and reads bytes, varints and strings', () {
    final writer = PackByteWriter()
      ..byte(7)
      ..varint(0)
      ..varint(127)
      ..varint(128)
      ..varint(0xffffffff)
      ..string('café')
      ..bytes(const [1, 2]);
    expect(writer.length, 1 + 1 + 1 + 2 + 5 + 6 + 2);
    final reader = PackByteReader(writer.takeBytes());
    expect(reader.byte(), 7);
    expect(reader.varint(), 0);
    expect(reader.varint(), 127);
    expect(reader.varint(), 128);
    expect(reader.varint(), 0xffffffff);
    expect(reader.string(), 'café');
    expect(reader.take(2), [1, 2]);
    expect(reader.isAtEnd, isTrue);
    expect(reader.byte, throwsFormatException);
  });

  test('rejects values it cannot write or read', () {
    expect(() => PackByteWriter().varint(-1), throwsArgumentError);
    expect(() => PackByteWriter().varint(1 << 32), throwsArgumentError);
    final long = PackByteReader(Uint8List.fromList(List.filled(6, 0x80)));
    expect(long.varint, throwsFormatException);
    final short = PackByteReader(Uint8List.fromList(const [3, 1]));
    expect(short.string, throwsFormatException);
    expect(() => PackByteReader(Uint8List(2)).take(-1), throwsFormatException);
  });

  test('compares bytes like sorted keys', () {
    expect(compareBytes([1, 2], [1, 2]), 0);
    expect(compareBytes([1, 2], [1, 3]), lessThan(0));
    expect(compareBytes([1, 2, 0], [1, 2]), greaterThan(0));
    expect(startsWithBytes([1, 2, 3], [1, 2]), isTrue);
    expect(startsWithBytes([1, 2], [1, 2, 3]), isFalse);
    expect(startsWithBytes([1, 3], [1, 2]), isFalse);
  });
}
