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

    test('decodes windows-1250 (Central European)', () {
      // "Příliš žluťoučký €" in windows-1250
      final decoded = decodeHtmlBytes([
        0x50,
        0xF8,
        0xED,
        0x6C,
        0x69,
        0x9A,
        0x20,
        0x9E,
        0x6C,
        0x75,
        0x9D,
        0x6F,
        0x75,
        0xE8,
        0x6B,
        0xFD,
        0x20,
        0x80,
      ], contentType: 'text/html; charset=windows-1250');
      expect(decoded.text, 'Příliš žluťoučký €');
      expect(decoded.charset, 'windows-1250');
      expect(decoded.unsupportedCharset, isNull);
    });

    test('decodes windows-1253 (Greek)', () {
      // "Ελλάδα €" in windows-1253
      final decoded = decodeHtmlBytes([
        0xC5,
        0xEB,
        0xEB,
        0xDC,
        0xE4,
        0xE1,
        0x20,
        0x80,
      ], contentType: 'text/html; charset=cp1253');
      expect(decoded.text, 'Ελλάδα €');
      expect(decoded.charset, 'windows-1253');
      expect(decoded.unsupportedCharset, isNull);
    });

    test('decodes windows-1254 (Turkish)', () {
      // "İstanbul ğşçı €" in windows-1254
      final decoded = decodeHtmlBytes([
        0xDD,
        0x73,
        0x74,
        0x61,
        0x6E,
        0x62,
        0x75,
        0x6C,
        0x20,
        0xF0,
        0xFE,
        0xE7,
        0xFD,
        0x20,
        0x80,
      ], contentType: 'text/html; charset=windows-1254');
      expect(decoded.text, 'İstanbul ğşçı €');
      expect(decoded.charset, 'windows-1254');
      expect(decoded.unsupportedCharset, isNull);
    });

    test('decodes windows-1256 (Arabic)', () {
      // "مرحبا؟" in windows-1256
      final decoded = decodeHtmlBytes([
        0xE3,
        0xD1,
        0xCD,
        0xC8,
        0xC7,
        0xBF,
      ], contentType: 'text/html; charset=windows-1256');
      expect(decoded.text, 'مرحبا؟');
      expect(decoded.charset, 'windows-1256');
      expect(decoded.unsupportedCharset, isNull);
    });

    test('decodes iso-8859-2 (Central European)', () {
      // "Zażółć gęślą jaźń" in iso-8859-2
      final decoded = decodeHtmlBytes([
        0x5A,
        0x61,
        0xBF,
        0xF3,
        0xB3,
        0xE6,
        0x20,
        0x67,
        0xEA,
        0xB6,
        0x6C,
        0xB1,
        0x20,
        0x6A,
        0x61,
        0xBC,
        0xF1,
      ], contentType: 'text/html; charset=latin2');
      expect(decoded.text, 'Zażółć gęślą jaźń');
      expect(decoded.charset, 'iso-8859-2');
      expect(decoded.unsupportedCharset, isNull);
    });

    test('decodes iso-8859-5 (Cyrillic)', () {
      // "Привет ё№" in iso-8859-5
      final decoded = decodeHtmlBytes([
        0xBF,
        0xE0,
        0xD8,
        0xD2,
        0xD5,
        0xE2,
        0x20,
        0xF1,
        0xF0,
      ], contentType: 'text/html; charset=iso-8859-5');
      expect(decoded.text, 'Привет ё№');
      expect(decoded.charset, 'iso-8859-5');
      expect(decoded.unsupportedCharset, isNull);
    });

    test('decodes iso-8859-7 (Greek)', () {
      // "Καλημέρα €" in iso-8859-7
      final decoded = decodeHtmlBytes([
        0xCA,
        0xE1,
        0xEB,
        0xE7,
        0xEC,
        0xDD,
        0xF1,
        0xE1,
        0x20,
        0xA4,
      ], contentType: 'text/html; charset=greek');
      expect(decoded.text, 'Καλημέρα €');
      expect(decoded.charset, 'iso-8859-7');
      expect(decoded.unsupportedCharset, isNull);
    });

    test('decodes iso-8859-9 (Turkish)', () {
      // "Şeker Ğı" in iso-8859-9
      final decoded = decodeHtmlBytes([
        0xDE,
        0x65,
        0x6B,
        0x65,
        0x72,
        0x20,
        0xD0,
        0xFD,
      ], contentType: 'text/html; charset=iso-8859-9');
      expect(decoded.text, 'Şeker Ğı');
      expect(decoded.charset, 'iso-8859-9');
      expect(decoded.unsupportedCharset, isNull);
    });

    test('decodes koi8-r (Russian)', () {
      // "Привет Ёё" in koi8-r
      final decoded = decodeHtmlBytes([
        0xF0,
        0xD2,
        0xC9,
        0xD7,
        0xC5,
        0xD4,
        0x20,
        0xB3,
        0xA3,
      ], contentType: 'text/html; charset=koi8-r');
      expect(decoded.text, 'Привет Ёё');
      expect(decoded.charset, 'koi8-r');
      expect(decoded.unsupportedCharset, isNull);
    });

    test('decodes koi8-u (Ukrainian)', () {
      // "Київ єґЄҐ" in koi8-u
      final decoded = decodeHtmlBytes([
        0xEB,
        0xC9,
        0xA7,
        0xD7,
        0x20,
        0xA4,
        0xAD,
        0xB4,
        0xBD,
      ], contentType: 'text/html; charset=koi8-u');
      expect(decoded.text, 'Київ єґЄҐ');
      expect(decoded.charset, 'koi8-u');
      expect(decoded.unsupportedCharset, isNull);
    });

    test('decodes windows-1255 and iso-8859-8 (Hebrew)', () {
      // "שלום ₪" in windows-1255
      final win = decodeHtmlBytes([
        0xF9,
        0xEC,
        0xE5,
        0xED,
        0x20,
        0xA4,
      ], contentType: 'text/html; charset=windows-1255');
      expect(win.text, 'שלום ₪');
      expect(win.charset, 'windows-1255');

      // "שלום" in iso-8859-8-i
      final iso = decodeHtmlBytes([
        0xF9,
        0xEC,
        0xE5,
        0xED,
      ], contentType: 'text/html; charset=iso-8859-8-i');
      expect(iso.text, 'שלום');
      expect(iso.charset, 'iso-8859-8');
    });

    test('decodes windows-1257, iso-8859-13, and iso-8859-4 (Baltic)', () {
      // "Rīga €" in windows-1257
      final win = decodeHtmlBytes([
        0x52,
        0xEE,
        0x67,
        0x61,
        0x20,
        0x80,
      ], contentType: 'text/html; charset=windows-1257');
      expect(win.text, 'Rīga €');
      expect(win.charset, 'windows-1257');

      // "Rīga" in iso-8859-13 and iso-8859-4
      expect(
        decodeHtmlBytes([
          0x52,
          0xEE,
          0x67,
          0x61,
        ], contentType: 'text/html; charset=iso-8859-13').text,
        'Rīga',
      );
      expect(
        decodeHtmlBytes([
          0x52,
          0xEF,
          0x67,
          0x61,
        ], contentType: 'text/html; charset=latin4').text,
        'Rīga',
      );
    });

    test('decodes windows-1258 (Vietnamese), windows-874 (Thai), and '
        'iso-8859-6 (Arabic)', () {
      // "Hà Nội ₫" (combining marks in cp1258)
      final vi = decodeHtmlBytes([
        0x48,
        0x61,
        0xCC,
        0x20,
        0x4E,
        0xF4,
        0xF2,
        0x69,
        0x20,
        0xFE,
      ], contentType: 'text/html; charset=cp1258');
      expect(vi.text, 'Ha\u0300 Nô\u0323i ₫');
      expect(vi.charset, 'windows-1258');

      // "ไทย ฿" in tis-620 / windows-874
      final th = decodeHtmlBytes([
        0xE4,
        0xB7,
        0xC2,
        0x20,
        0xDF,
      ], contentType: 'text/html; charset=tis-620');
      expect(th.text, 'ไทย ฿');
      expect(th.charset, 'windows-874');

      // "مرحبا؟" in iso-8859-6
      final ar = decodeHtmlBytes([
        0xE5,
        0xD1,
        0xCD,
        0xC8,
        0xC7,
        0xBF,
      ], contentType: 'text/html; charset=iso-8859-6');
      expect(ar.text, 'مرحبا؟');
      expect(ar.charset, 'iso-8859-6');
    });

    test('sniffs legacy charset from <meta> tag', () {
      final bytes = [
        ...latin1.encode('<meta charset="koi8-r"><p>'),
        0xF0,
        0xD2,
        0xC9,
        0xD7,
        0xC5,
        0xD4,
        ...latin1.encode('</p>'),
      ];
      final decoded = decodeHtmlBytes(bytes);
      expect(decoded.charset, 'koi8-r');
      expect(decoded.text, contains('Привет'));
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
