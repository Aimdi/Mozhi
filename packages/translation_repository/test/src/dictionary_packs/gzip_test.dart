import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:translation_repository/src/dictionary_packs/gzip.dart';

/// gzip members written by Python's zlib (`gzip.compress(..., mtime=0)`).
const _fixed = 'H4sIAAAAAAAC/8tIzcnJV8hAJwHjUT2NFwAAAA==';
const _dynamic =
    'H4sIAAAAAAAC/93MSRLCIBSE4au0eyvlPNzCKnMBMARQwguEIeH0kkO4cd3f360ScFG/PuCe'
    'skVPM95xGCdQEh6hzoaVBR3JBu3P8INVNyzgFWUdFHqdRJ2KsDDaRfK1ldMGu/3heDpfrrf7'
    '3zXPUWk7g3pws+YuMh/KtsJOivUsUW6+Nm8vrLABAAA=';
const _stored = 'H4sIAAAAAAAE/wEMAPP/c3RvcmVkIGJ5dGVzeHemDwwAAAA=';
const _named = 'H4sICAAAAAAC/25hbWUudHh0AMtLzE1NUchNzU1KLQIArLc7QwwAAAA=';

String _decode(String base64Data) =>
    utf8.decode(gzipDecode(base64.decode(base64Data)));

Uint8List _bytes(String base64Data) =>
    Uint8List.fromList(base64.decode(base64Data));

void main() {
  group('gzipDecode', () {
    test('decodes fixed Huffman blocks', () {
      expect(_decode(_fixed), 'hello hello hello hello');
    });

    test('decodes dynamic Huffman blocks', () {
      final text = _decode(_dynamic);
      expect(text, hasLength(432));
      expect(text, startsWith('The quick brown fox jumps over the lazy dog.'));
      expect(text, endsWith('Sphinx of black quartz, judge my vow.'));
    });

    test('decodes stored blocks', () {
      expect(_decode(_stored), 'stored bytes');
    });

    test('skips a file name in the header', () {
      expect(_decode(_named), 'named member');
    });

    test('skips an extra field, a comment and a header CRC', () {
      final member = _bytes(_fixed);
      final withHeader = Uint8List.fromList([
        ...member.sublist(0, 3),
        member[3] | 0x04 | 0x10 | 0x02,
        ...member.sublist(4, 10),
        2, 0, 0xaa, 0xbb, // extra field
        ...ascii.encode('note'), 0, // comment
        0, 0, // header CRC (not checked)
        ...member.sublist(10),
      ]);
      expect(utf8.decode(gzipDecode(withHeader)), 'hello hello hello hello');
    });

    test('decodes what zlib writes for larger data', () {
      final random = Random(7);
      const words = ['house', 'café', 'naïve', 'gato', 'árbol', '家', 'go'];
      final text = List.generate(
        60000,
        (_) => words[random.nextInt(words.length)],
      ).join(' ');
      final data = Uint8List.fromList(utf8.encode(text));
      for (final level in [1, 6, 9]) {
        final compressed = Uint8List.fromList(
          GZipCodec(level: level).encode(data),
        );
        expect(gzipDecode(compressed), data, reason: 'level $level');
      }
      final noise = Uint8List.fromList(
        List.generate(100000, (_) => random.nextInt(256)),
      );
      expect(gzipDecode(Uint8List.fromList(GZipCodec().encode(noise))), noise);
    });

    test('rejects what is not gzip', () {
      expect(
        () => gzipDecode(Uint8List.fromList(List.filled(20, 0))),
        throwsFormatException,
      );
      expect(() => gzipDecode(Uint8List(4)), throwsFormatException);
      final wrongMethod = _bytes(_fixed)..[2] = 7;
      expect(() => gzipDecode(wrongMethod), throwsFormatException);
      final reserved = _bytes(_fixed)..[3] = 0x20;
      expect(() => gzipDecode(reserved), throwsFormatException);
    });

    test('rejects a wrong checksum or length', () {
      final crc = _bytes(_fixed);
      crc[crc.length - 8] ^= 1;
      expect(() => gzipDecode(crc), throwsFormatException);
      final length = _bytes(_fixed);
      length[length.length - 4] ^= 1;
      expect(() => gzipDecode(length), throwsFormatException);
    });

    test('rejects truncated and corrupt data', () {
      final member = _bytes(_dynamic);
      final truncated = Uint8List.fromList([
        ...member.sublist(0, 30),
        ...member.sublist(member.length - 8),
      ]);
      expect(() => gzipDecode(truncated), throwsFormatException);
      final stored = _bytes(_stored)..[12] ^= 0xff;
      expect(() => gzipDecode(stored), throwsFormatException);
      final blockType = _bytes(_fixed)..[10] = 0x07; // reserved type 3
      expect(() => gzipDecode(blockType), throwsFormatException);
      final open = _bytes(_named)..[3] = 0x08;
      expect(
        () => gzipDecode(Uint8List.fromList(open.sublist(0, 20))),
        throwsFormatException,
      );
    });

    test('rejects output larger than the limit', () {
      final big = Uint8List.fromList(GZipCodec().encode(Uint8List(100000)));
      expect(() => gzipDecode(big, maxLength: 1000), throwsFormatException);
      // A lying length field: the data inflates past the limit anyway.
      final lying = Uint8List.fromList(big);
      lying.setRange(lying.length - 4, lying.length, [10, 0, 0, 0]);
      expect(() => gzipDecode(lying, maxLength: 1000), throwsFormatException);
    });

    test('grows the output when the length field is too small', () {
      final data = Uint8List.fromList(utf8.encode('x' * 5000));
      final compressed = Uint8List.fromList(GZipCodec().encode(data));
      compressed.setRange(compressed.length - 4, compressed.length, [
        1,
        0,
        0,
        0,
      ]);
      // Inflates fine, then the length check fails.
      expect(() => gzipDecode(compressed), throwsFormatException);
    });
  });

  group('gzipEncodeStored', () {
    test('round-trips through zlib and gzipDecode', () {
      for (final size in [0, 1, 65535, 65536, 200000]) {
        final data = Uint8List.fromList(
          List.generate(size, (index) => index * 7 & 0xff),
        );
        final encoded = gzipEncodeStored(data);
        expect(gzipDecode(encoded), data, reason: '$size bytes');
        expect(GZipCodec().decode(encoded), data, reason: '$size bytes');
      }
    });
  });

  test('crc32 matches zlib', () {
    expect(crc32(ascii.encode('123456789')), 0xcbf43926);
    expect(crc32(const []), 0);
    expect(
      crc32(ascii.encode('6789'), crc32(ascii.encode('12345'))),
      0xcbf43926,
    );
  });
}
