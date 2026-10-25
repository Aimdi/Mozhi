// XML fixtures are written as adjacent string literals.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/core/core.dart';
import 'package:mozhi/documents/core/office/office.dart';

import 'office_fixtures.dart';

Matcher throwsProblem(PackageProblem problem, [Object? message]) => throwsA(
  isA<PackageParseException>()
      .having((e) => e.problem, 'problem', problem)
      .having((e) => e.message, 'message', message ?? anything),
);

void main() {
  PackagedDocument parse(
    Uint8List bytes, {
    DocumentFormat format = DocumentFormat.docx,
    PackageLimits limits = const PackageLimits(),
  }) => OfficePackage.parse(bytes, format, limits: limits);

  group('ZIP safety', () {
    test('files that are not ZIP packages', () {
      expect(
        () => parse(utf8.encode('Just some text')),
        throwsProblem(PackageProblem.damaged, contains('not a ZIP')),
      );
      expect(() => parse(Uint8List(0)), throwsProblem(PackageProblem.damaged));
      // A local header but no directory.
      expect(
        () => parse(Uint8List.fromList([0x50, 0x4B, 0x03, 0x04, 1, 2, 3])),
        throwsProblem(PackageProblem.damaged),
      );
      // Truncated in the middle.
      final bytes = docx('<w:p><w:r><w:t>Hello</w:t></w:r></w:p>');
      expect(
        () => parse(bytes.sublist(0, bytes.length ~/ 2)),
        throwsProblem(PackageProblem.damaged),
      );
    });

    test('encrypted and old binary Office files', () {
      const header = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
      final encrypted = Uint8List.fromList([
        ...header,
        ...List.filled(64, 0),
        for (final unit in 'EncryptionInfo'.codeUnits) ...[unit, 0],
        ...List.filled(64, 0),
      ]);
      expect(() => parse(encrypted), throwsProblem(PackageProblem.encrypted));
      final legacy = Uint8List.fromList([...header, ...List.filled(512, 0)]);
      expect(
        () => parse(legacy),
        throwsProblem(PackageProblem.damaged, contains('old binary')),
      );
    });

    test('password-protected ZIP entries', () {
      final archive = Archive()
        ..add(ArchiveFile.string('[Content_Types].xml', '<Types/>'));
      final bytes = ZipEncoder(password: 'secret').encodeBytes(archive);
      expect(() => parse(bytes), throwsProblem(PackageProblem.encrypted));
    });

    test('entry names that leave the package', () {
      for (final name in [
        '../evil.xml',
        'word/../../evil.xml',
        '/etc/passwd',
        'C:/windows.xml',
        r'word\document.xml',
        'word/./document.xml',
        'word//document.xml',
        'bad\u0001name.xml',
      ]) {
        final bytes = docx(
          '<w:p><w:r><w:t>Hello</w:t></w:r></w:p>',
          extra: {name: 'x'},
        );
        expect(
          () => parse(bytes),
          throwsProblem(PackageProblem.unsafe, contains('entry name')),
          reason: name,
        );
      }
      expect(ZipPackage.isSafeEntryName('word/media/'), isTrue);
      expect(ZipPackage.isSafeEntryName(''), isFalse);
      expect(ZipPackage.isSafeEntryName('a' * 1025), isFalse);
    });

    test('duplicate entry names', () {
      final bytes = zipOf({'a.xml': '<a/>', 'b.xml': '<b/>'});
      final patched = latin1.encode(
        latin1.decode(bytes).replaceAll('b.xml', 'a.xml'),
      );
      expect(
        () => parse(patched),
        throwsProblem(PackageProblem.unsafe, contains('duplicate')),
      );
    });

    test('too many entries', () {
      final bytes = docx(
        '<w:p><w:r><w:t>Hello</w:t></w:r></w:p>',
        extra: {for (var i = 0; i < 20; i++) 'extra/$i.bin': 'x'},
      );
      expect(
        () => parse(bytes, limits: const PackageLimits(maxEntries: 10)),
        throwsProblem(PackageProblem.unsafe, contains('too many')),
      );
      expect(textsOf(parse(bytes)), ['Hello']);
    });

    test('decompression bombs', () {
      // 4 MB of spaces deflates to a few KB.
      final bytes = zipOf({
        '[Content_Types].xml': bytesTypes,
        'word/document.xml':
            '<w:document xmlns:w="$wNs"><w:body>${' ' * (4 * 1024 * 1024)}'
            '</w:body></w:document>',
      }, level: DeflateLevel.bestCompression);
      expect(
        () => parse(bytes),
        throwsProblem(PackageProblem.unsafe, contains('compressed')),
      );
    });

    test('size limits for parts, all parts and declared sizes', () {
      final bytes = docx('<w:p><w:r><w:t>Hello</w:t></w:r></w:p>');
      expect(
        () => parse(bytes, limits: const PackageLimits(maxPartBytes: 100)),
        throwsProblem(PackageProblem.unsafe, contains('too large')),
      );
      expect(
        () => parse(bytes, limits: const PackageLimits(maxParsedBytes: 600)),
        throwsProblem(PackageProblem.unsafe, contains('too much text')),
      );
      expect(
        () => parse(bytes, limits: const PackageLimits(maxTotalBytes: 100)),
        throwsProblem(PackageProblem.unsafe, contains('too much data')),
      );
      expect(
        () => parse(
          bytes,
          limits: const PackageLimits(ratioFloorBytes: 10, maxRatio: 1),
        ),
        throwsProblem(PackageProblem.unsafe),
      );
    });

    test('ZIP64 directories are checked before decoding', () {
      final normal = zipOf({'a.xml': '<a/>'});
      // Drop the end record and append a ZIP64 record, its locator and an
      // end record that points to them.
      final body = normal.sublist(0, normal.length - 22);
      Uint8List zip64({required int count, required int recordOffset}) {
        final data = ByteData(56 + 20 + 22)
          ..setUint32(0, 0x06064b50, Endian.little)
          ..setUint32(32, count, Endian.little)
          ..setUint32(56, 0x07064b50, Endian.little)
          ..setUint32(56 + 8, recordOffset, Endian.little)
          ..setUint32(76, 0x06054b50, Endian.little)
          ..setUint16(76 + 10, 0xFFFF, Endian.little);
        return Uint8List.fromList([...body, ...data.buffer.asUint8List()]);
      }

      expect(
        () => parse(zip64(count: 50000, recordOffset: body.length)),
        throwsProblem(PackageProblem.unsafe, contains('too many')),
      );
      expect(
        () => parse(zip64(count: 1, recordOffset: 0x7FFFFFFF)),
        throwsProblem(PackageProblem.damaged, contains('ZIP64')),
      );
    });

    test('document type declarations and entities', () {
      const laughs =
          '<!DOCTYPE lolz [<!ENTITY lol "lol"><!ENTITY lol2 '
          '"&lol;&lol;&lol;&lol;">]>';
      final bomb = zipOf({
        '[Content_Types].xml':
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/'
            'content-types"><Override PartName="/word/document.xml" '
            'ContentType="application/vnd.openxmlformats-officedocument.'
            'wordprocessingml.document.main+xml"/></Types>',
        'word/document.xml':
            '$laughs<w:document xmlns:w="$wNs"><w:body><w:p><w:r>'
            '<w:t>&lol2;</w:t></w:r></w:p></w:body></w:document>',
      });
      expect(
        () => parse(bomb),
        throwsProblem(PackageProblem.unsafe, contains('document type')),
      );
      // Office parts never have a doctype.
      final external = zipOf({
        '[Content_Types].xml':
            '<!DOCTYPE Types SYSTEM "http://evil.example/x.dtd"><Types/>',
      });
      expect(() => parse(external), throwsProblem(PackageProblem.unsafe));
      // E-books may, but never with an internal subset.
      expect(
        () => parse(
          epub({'c.xhtml': '<p>x</p>'}, doctype: '$laughs\n'),
          format: DocumentFormat.epub,
        ),
        throwsProblem(PackageProblem.unsafe),
      );
    });

    test('elements nested too deeply', () {
      final bytes = docx(
        '${'<w:tbl>' * 20}<w:p><w:r><w:t>Deep</w:t></w:r></w:p>'
        '${'</w:tbl>' * 20}',
      );
      expect(
        () => parse(bytes, limits: const PackageLimits(maxDepth: 10)),
        throwsProblem(PackageProblem.unsafe, contains('nested')),
      );
      expect(textsOf(parse(bytes)), ['Deep']);
    });

    test('malformed XML', () {
      for (final body in ['<w:p><w:r></w:p>', '<w:p>']) {
        expect(
          () => parse(docx(body)),
          throwsProblem(PackageProblem.damaged),
          reason: body,
        );
      }
      for (final document in [
        '<a/><b/>',
        'text<a/>',
        '<a/>text',
        '<a/><![CDATA[x]]>',
        '<a/><?xml version="1.0"?>',
        '<a/><!DOCTYPE a>',
        '',
      ]) {
        final bytes = zipOf({'[Content_Types].xml': document});
        expect(
          () => parse(bytes),
          throwsA(isA<PackageParseException>()),
          reason: document,
        );
      }
    });

    test('text encodings of parts', () {
      final document = parse(docx('<w:p><w:r><w:t>Hello</w:t></w:r></w:p>'));
      expect(textsOf(document), ['Hello']);

      // UTF-16 with a byte order mark is read and written back as UTF-16.
      const xml =
          '<?xml version="1.0" encoding="UTF-16"?>'
          '<w:document xmlns:w="$wNs"><w:body><w:p><w:r><w:t>Grüße</w:t>'
          '</w:r></w:p></w:body></w:document>';
      final utf16 = encodeText(xml, TextEncoding.utf16le);
      final bytes = zipOf({
        '[Content_Types].xml':
            '\uFEFF<Types xmlns="http://schemas.openxmlformats.org/package/'
            '2006/content-types"><Override PartName="/word/document.xml" '
            'ContentType="application/vnd.openxmlformats-officedocument.'
            'wordprocessingml.document.main+xml"/></Types>',
        'word/document.xml': utf16,
      });
      final wide = parse(bytes);
      expect(textsOf(wide), ['Grüße']);
      final output = wide.render(['Grüße!']);
      final entry = ZipDecoder()
          .decodeBytes(output)
          .findFile('word/document.xml')!;
      final decoded = decodeText(entry.readBytes()!);
      expect(decoded.encoding, TextEncoding.utf16le);
      expect(decoded.text, contains('Grüße!'));

      // Big-endian too.
      final big = zipOf({
        '[Content_Types].xml': bytesTypes,
        'word/document.xml': encodeText(xml, TextEncoding.utf16be),
      });
      expect(textsOf(parse(big)), ['Grüße']);

      // Invalid UTF-8 without a legacy declaration is damaged.
      final invalid = zipOf({
        '[Content_Types].xml': bytesTypes,
        'word/document.xml': [0x3C, 0x61, 0xFF, 0x2F, 0x3E],
      });
      expect(() => parse(invalid), throwsProblem(PackageProblem.damaged));
    });

    test('legacy single-byte e-book documents get character references', () {
      final chapter = latin1.encode(
        '<?xml version="1.0" encoding="ISO-8859-1"?>'
        '<html xmlns="$xhtmlNs"><body><p>Café crème</p></body></html>',
      );
      final bytes = zipOf(
        {
          'mimetype': 'application/epub+zip',
          'META-INF/container.xml':
              '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:'
              'container"><rootfiles><rootfile full-path="b.opf"/></rootfiles>'
              '</container>',
          'b.opf':
              '<package xmlns="http://www.idpf.org/2007/opf"><manifest>'
              '<item id="a" href="a%20b.xhtml" '
              'media-type="application/xhtml+xml"/>'
              '</manifest><spine><itemref idref="a"/></spine></package>',
          'a b.xhtml': chapter,
        },
        stored: {'mimetype'},
      );
      final document = parse(bytes, format: DocumentFormat.epub);
      expect(textsOf(document), ['Café crème']);
      final output = document.render(['Кофе à la crème']);
      final entry = ZipDecoder().decodeBytes(output).findFile('a b.xhtml')!;
      final text = latin1.decode(entry.readBytes()!);
      expect(text, contains('&#x41A;&#x43E;&#x444;&#x435; à la crème'));
    });

    test('only packaged formats are parsed', () {
      expect(
        () => OfficePackage.parse(Uint8List(0), DocumentFormat.plainText),
        throwsArgumentError,
      );
      expect(
        const PackageParseException(PackageProblem.unsafe, 'x').toString(),
        contains('unsafe'),
      );
    });
  });
}

const bytesTypes =
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/'
    'content-types"><Override PartName="/word/document.xml" '
    'ContentType="application/vnd.openxmlformats-officedocument.'
    'wordprocessingml.document.main+xml"/></Types>';
