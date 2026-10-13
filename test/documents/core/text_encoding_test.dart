import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/core/core.dart';

void main() {
  group('decodeText / encodeText', () {
    test('plain UTF-8 round-trips', () {
      final bytes = utf8.encode('Grüße 👋');
      final decoded = decodeText(bytes);
      expect(decoded.text, 'Grüße 👋');
      expect(decoded.encoding, TextEncoding.utf8);
      expect(encodeText(decoded.text, decoded.encoding), bytes);
    });

    test('UTF-8 with BOM keeps the BOM', () {
      final bytes = [0xEF, 0xBB, 0xBF, ...utf8.encode('Hi')];
      final decoded = decodeText(bytes);
      expect(decoded.text, 'Hi');
      expect(decoded.encoding, TextEncoding.utf8Bom);
      expect(encodeText('Hi', TextEncoding.utf8Bom), bytes);
    });

    test('UTF-16 little and big endian', () {
      const text = 'Añ😀';
      for (final encoding in [TextEncoding.utf16le, TextEncoding.utf16be]) {
        final bytes = encodeText(text, encoding);
        expect(bytes.length, 2 + text.codeUnits.length * 2);
        final decoded = decodeText(bytes);
        expect(decoded.text, text);
        expect(decoded.encoding, encoding);
      }
      expect(encodeText('A', TextEncoding.utf16le), [0xFF, 0xFE, 0x41, 0]);
      expect(encodeText('A', TextEncoding.utf16be), [0xFE, 0xFF, 0, 0x41]);
    });

    test('invalid UTF-8 falls back to Latin-1 and is written as UTF-8', () {
      final bytes = [0x43, 0x61, 0x66, 0xE9]; // "Café" in Latin-1.
      final decoded = decodeText(bytes);
      expect(decoded.text, 'Café');
      expect(decoded.encoding, TextEncoding.latin1);
      expect(encodeText('Café', TextEncoding.latin1), utf8.encode('Café'));
    });

    test('rejects binary data', () {
      expect(
        () => decodeText([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]),
        throwsA(isA<BinaryContentException>()),
      );
      expect(
        const BinaryContentException().toString(),
        contains('not a text file'),
      );
    });

    test('empty input', () {
      expect(decodeText(const []).text, '');
      expect(decodeText(const [0xEF]).encoding, TextEncoding.latin1);
    });
  });

  group('splitLines', () {
    test('keeps every terminator', () {
      const text = 'a\nb\r\nc\rd';
      final lines = splitLines(text);
      expect(lines.map((l) => l.content), ['a', 'b', 'c', 'd']);
      expect(lines.map((l) => l.ending), ['\n', '\r\n', '\r', '']);
      expect(joinLines(lines, 0, lines.length), text);
      expect(lines.first.toString(), r'SourceLine(a\n)');
    });

    test('a trailing newline adds no empty line; blank detection', () {
      final lines = splitLines('x\n \t\n');
      expect(lines.length, 2);
      expect(lines[1].isBlank, isTrue);
      expect(lines[0].isBlank, isFalse);
      expect(splitLines(''), isEmpty);
    });

    test('dominant line break', () {
      expect(dominantLineBreak(splitLines('a\r\nb\r\nc\n')), '\r\n');
      expect(dominantLineBreak(splitLines('a\rb\rc')), '\r');
      expect(dominantLineBreak(splitLines('a\nb')), '\n');
      expect(dominantLineBreak(splitLines('a')), '\n');
    });
  });
}
