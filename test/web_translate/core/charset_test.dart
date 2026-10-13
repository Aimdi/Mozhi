import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/web_translate/core/charset.dart';

void main() {
  group('decodeHtmlBytes', () {
    test('decodes UTF-8 by default', () {
      final decoded = decodeHtmlBytes(utf8.encode('<p>Grüße 😀</p>'));
      expect(decoded.text, '<p>Grüße 😀</p>');
      expect(decoded.charset, 'utf-8');
      expect(decoded.unsupportedCharset, isNull);
    });

    test('falls back to windows-1252 for invalid UTF-8', () {
      final decoded = decodeHtmlBytes([0x63, 0x61, 0x66, 0xE9, 0x80]);
      expect(decoded.text, 'café€');
      expect(decoded.charset, 'windows-1252');
    });

    test('honours byte order marks', () {
      expect(
        decodeHtmlBytes([0xEF, 0xBB, 0xBF, ...utf8.encode('ü')]).text,
        'ü',
      );
      final be = decodeHtmlBytes([0xFE, 0xFF, 0x00, 0x41, 0x04, 0x10]);
      expect(be.text, 'AА');
      expect(be.charset, 'utf-16be');
      final le = decodeHtmlBytes([0xFF, 0xFE, 0x41, 0x00, 0x10, 0x04]);
      expect(le.text, 'AА');
      expect(le.charset, 'utf-16le');
    });

    test('prefers the Content-Type charset over the meta tag', () {
      final bytes = latin1.encode('<meta charset="utf-8"><p>né</p>');
      final decoded = decodeHtmlBytes(
        bytes,
        contentType: 'text/html; charset="ISO-8859-1"',
      );
      expect(decoded.text, contains('né'));
      expect(decoded.charset, 'windows-1252');
    });

    test('sniffs <meta charset> and http-equiv declarations', () {
      expect(
        decodeHtmlBytes(latin1.encode("<meta charset='latin1'><p>Ça</p>")).text,
        contains('Ça'),
      );
      expect(
        decodeHtmlBytes(
          latin1.encode(
            '<meta http-equiv="content-type" '
            'content="text/html; charset=iso-8859-15"><p>¤</p>',
          ),
        ).text,
        contains('€'),
      );
    });

    test('reads the XML declaration encoding', () {
      final decoded = decodeHtmlBytes(
        latin1.encode('<?xml version="1.0" encoding="windows-1252"?><p>é</p>'),
      );
      expect(decoded.charset, 'windows-1252');
      expect(decoded.text, contains('é'));
    });

    test('decodes windows-1251', () {
      final decoded = decodeHtmlBytes([
        0xCF,
        0xF0,
        0xE8,
        0xE2,
        0xE5,
        0xF2,
        0x20,
        0xA8,
        0xB8,
        0xB9,
        0x88,
      ], contentType: 'text/html;charset=cp1251');
      expect(decoded.text, 'Привет Ёё№€');
      expect(decoded.charset, 'windows-1251');
    });

    test('decodes declared UTF-16 without a BOM', () {
      expect(
        decodeHtmlBytes([
          0x00,
          0x41,
        ], contentType: 'text/html; charset=utf-16be').text,
        'A',
      );
      expect(
        decodeHtmlBytes([
          0x41,
          0x00,
        ], contentType: 'text/html; charset=utf-16').text,
        'A',
      );
    });

    test('decodes declared UTF-8 leniently', () {
      final decoded = decodeHtmlBytes([
        0x61,
        0xFF,
        0x62,
      ], contentType: 'text/html; charset=UTF8');
      expect(decoded.text, 'a�b');
      expect(decoded.charset, 'utf-8');
    });

    test('reports unsupported encodings and falls back to UTF-8', () {
      final decoded = decodeHtmlBytes(
        utf8.encode('<p>x</p>'),
        contentType: 'text/html; charset=Shift_JIS',
      );
      expect(decoded.text, '<p>x</p>');
      expect(decoded.charset, 'utf-8');
      expect(decoded.unsupportedCharset, 'shift_jis');
    });
  });

  group('charsetFromContentType', () {
    test('extracts the charset parameter', () {
      expect(charsetFromContentType(null), isNull);
      expect(charsetFromContentType('text/html'), isNull);
      expect(charsetFromContentType('text/html; Charset=UTF-8'), 'utf-8');
      expect(charsetFromContentType("text/html;charset='koi8-r'"), 'koi8-r');
    });
  });

  group('sniffCharset', () {
    test('only looks at the first 4 KiB', () {
      final late = '${' ' * 5000}<meta charset="latin1">';
      expect(sniffCharset(latin1.encode(late)), isNull);
      expect(sniffCharset(latin1.encode('<META CHARSET=UTF-8>')), 'utf-8');
    });
  });

  test('decodeWindows1252 maps the C1 range', () {
    expect(decodeWindows1252([0x93, 0x94, 0x96, 0x81]), '“”–\u0081');
  });
}
