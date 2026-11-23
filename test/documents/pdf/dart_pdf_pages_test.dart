import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Color, Rect, Size, TextDirection;

import 'package:archive/archive.dart' show ZLibEncoder;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/documents/core/core.dart';
import 'package:mozhi/documents/pdf/dart_pdf_pages.dart';
import 'package:mozhi/documents/pdf/pdf.dart';
import 'package:mozhi/documents/pdf/pdf_scratch_web.dart';
import 'package:mozhi/image_translate/data/text_recognition_plan.dart';
import 'package:mozhi/image_translate/data/text_recognition_service.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:translation_repository/translation_repository.dart';

class _MockTranslationRepository extends Mock implements TranslationRepository;

const _googleEngine = TranslationEngine(
  id: 'mozhi:google',
  kind: EngineKind.mozhi,
  name: 'Google',
  mozhiEngine: 'google',
);
const _english = Language(code: 'en', name: 'English');
const _german = Language(code: 'de', name: 'German');

/// Builds a valid PDF 1.4 from numbered object bodies (1-based).
Uint8List _buildPdf(
  List<Uint8List> objects, {
  String trailerExtra = '',
  int rootObj = 1,
}) {
  final out = BytesBuilder(copy: false)
    ..add(latin1.encode('%PDF-1.4\n%\xE2\xE3\xCF\xD3\n'));
  final offsets = <int>[0];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(out.length);
    out
      ..add(latin1.encode('${i + 1} 0 obj\n'))
      ..add(objects[i])
      ..add(latin1.encode('\nendobj\n'));
  }
  final xrefOffset = out.length;
  out
    ..add(latin1.encode('xref\n0 ${offsets.length}\n'))
    ..add(latin1.encode('0000000000 65535 f \n'));
  for (var i = 1; i < offsets.length; i++) {
    out.add(
      latin1.encode('${offsets[i].toString().padLeft(10, '0')} 00000 n \n'),
    );
  }
  out.add(
    latin1.encode(
      'trailer\n<< /Size ${offsets.length} /Root $rootObj 0 R $trailerExtra>>\n'
      'startxref\n$xrefOffset\n%%EOF\n',
    ),
  );
  return out.takeBytes();
}

Uint8List _streamObj(String dictBody, Uint8List data) {
  final out = BytesBuilder(copy: false)
    ..add(latin1.encode('<< $dictBody /Length ${data.length} >>\nstream\n'))
    ..add(data)
    ..add(latin1.encode('\nendstream'));
  return out.takeBytes();
}

Uint8List _simplePdf({
  required List<String> pageStreams,
  bool compress = false,
  String? mediaBox = '[0 0 612 792]',
  String? fontDict,
  String? extraObjects = '',
  String trailerExtra = '',
}) {
  final objs = <Uint8List>[];
  // 1: Catalog, 2: Pages, 3: Font
  final pageIds = <int>[];
  const firstPage = 4;
  for (var i = 0; i < pageStreams.length; i++) {
    pageIds.add(firstPage + i * 2 + 1);
  }
  objs
    ..add(latin1.encode('<< /Type /Catalog /Pages 2 0 R >>'))
    ..add(
      latin1.encode(
        '<< /Type /Pages /Kids [${pageIds.map((id) => '$id 0 R').join(' ')}] '
        '/Count ${pageIds.length}'
        '${mediaBox != null ? ' /MediaBox $mediaBox' : ''} >>',
      ),
    )
    ..add(
      latin1.encode(
        fontDict ??
            '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica '
                '/Encoding /WinAnsiEncoding >>',
      ),
    );

  for (var i = 0; i < pageStreams.length; i++) {
    final contentId = firstPage + i * 2;
    final raw = latin1.encode(pageStreams[i]);
    final data = compress ? const ZLibEncoder().encodeBytes(raw) : raw;
    objs
      ..add(_streamObj(compress ? '/Filter /FlateDecode' : '', data))
      ..add(
        latin1.encode(
          '<< /Type /Page /Parent 2 0 R '
          '/Resources << /Font << /F1 3 0 R >> >> '
          '/Contents $contentId 0 R >>',
        ),
      );
  }
  if (extraObjects != null && extraObjects.isNotEmpty) {
    objs.add(latin1.encode(extraObjects));
  }
  return _buildPdf(objs, trailerExtra: trailerExtra);
}

class _UnsupportedRecognizer implements TextRecognitionService {
  const new();

  @override
  bool get isSupported => false;

  @override
  Future<String> recognize(PickedImage image, {required Language source}) =>
      throw UnimplementedError();
}

void main() {
  setUpAll(() {
    registerFallbackValue(_googleEngine);
    registerFallbackValue(
      const TranslationRequest(text: '', source: _english, target: _german),
    );
  });

  group('WebPdfScratch', () {
    test('stores, peeks, takes and deletes PDF bytes in memory', () async {
      final scratch = WebPdfScratch();
      final input = Uint8List.fromList([1, 2, 3, 4]);
      final path = await scratch.write(input);
      expect(path, startsWith('/web/pdf_pages/'));
      expect(scratch.peek(path), input);

      final taken = await scratch.take(path);
      expect(taken, input);
      expect(scratch.peek(path), isNull);
      await expectLater(scratch.take(path), throwsStateError);

      final outPath = await scratch.newPath();
      scratch.put(outPath, Uint8List.fromList([9, 8, 7]));
      expect(await scratch.take(outPath), Uint8List.fromList([9, 8, 7]));
      await scratch.delete(outPath);
    });
  });

  group('DartPdfPages.open', () {
    late WebPdfScratch scratch;
    late DartPdfPages pages;

    setUp(() {
      scratch = WebPdfScratch();
      pages = DartPdfPages(readBytes: scratch.peek, writeBytes: scratch.put);
    });

    tearDown(() => pages.close());

    test('opens multi-page PDF with inherited and fallback MediaBox', () async {
      final bytes = _simplePdf(
        pageStreams: [
          'BT /F1 12 Tf 72 720 Td (Hello world on page one!) Tj ET',
          'BT /F1 12 Tf 72 720 Td (Second page text content here) Tj ET',
        ],
        mediaBox: '[0 0 595 842]',
      );
      final path = await scratch.write(bytes);
      final info = await pages.open(path);
      expect(pages.isSupported, isTrue);
      expect(info.pageCount, 2);
      expect(info.pageSizes, const [Size(595, 842), Size(595, 842)]);
    });

    test('falls back to Letter when MediaBox is omitted', () async {
      final bytes = _simplePdf(
        pageStreams: ['BT /F1 12 Tf 72 720 Td (Letter default page) Tj ET'],
        mediaBox: null,
      );
      final path = await scratch.write(bytes);
      final info = await pages.open(path);
      expect(info.pageSizes, const [Size(612, 792)]);
    });

    test('rejects encrypted PDFs', () async {
      final bytes = _simplePdf(
        pageStreams: ['BT /F1 12 Tf (Secret) Tj ET'],
        trailerExtra: '/Encrypt << /Filter /Standard /V 2 >> ',
      );
      final path = await scratch.write(bytes);
      await expectLater(
        pages.open(path),
        throwsA(const PdfOpenException(kind: PdfOpenErrorKind.encrypted)),
      );
    });

    test('rejects non-PDF and damaged bytes', () async {
      final badPath = await scratch.write(utf8.encode('not a pdf'));
      await expectLater(
        pages.open(badPath),
        throwsA(const PdfOpenException(kind: PdfOpenErrorKind.damaged)),
      );

      final corruptPath = await scratch.write(utf8.encode('%PDF-1.4\ngarbage'));
      await expectLater(
        pages.open(corruptPath),
        throwsA(const PdfOpenException(kind: PdfOpenErrorKind.damaged)),
      );
    });

    test('rejects PDFs exceeding PdfLimits.maxPages', () async {
      final streams = List<String>.filled(PdfLimits.maxPages + 1, '');
      final bytes = _simplePdf(pageStreams: streams);
      final path = await scratch.write(bytes);
      await expectLater(
        pages.open(path),
        throwsA(const PdfOpenException(kind: PdfOpenErrorKind.tooLarge)),
      );
    });

    test('parses PDF 1.5 xref stream and compressed object stream', () async {
      // Build a PDF 1.5 file where Catalog (1) and Pages (2) live inside an
      // ObjStm (4), Page (3) and Content (5) are uncompressed, and xref is a
      // FlateDecode xref stream (6) with PNG Up predictor (Predictor 12).
      const obj1 = '<< /Type /Catalog /Pages 2 0 R >> ';
      const obj2 =
          '<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800] >>';
      const objStmHeader = '1 0 2 ${obj1.length} ';
      final objStmBody = latin1.encode('$objStmHeader$obj1$obj2');
      final objStmCompressed = const ZLibEncoder().encodeBytes(objStmBody);
      final contentRaw = latin1.encode(
        'BT /F1 14 Tf 50 700 Td (Compressed xref and object stream text) Tj ET',
      );
      final contentCompressed = const ZLibEncoder().encodeBytes(contentRaw);

      final out = BytesBuilder(copy: false)
        ..add(latin1.encode('%PDF-1.5\n%\xE2\xE3\xCF\xD3\n'));

      final off3 = out.length;
      out.add(
        latin1.encode(
          '3 0 obj\n<< /Type /Page /Parent 2 0 R '
          '/Resources << /Font << /F1 << /Type /Font /Subtype /Type1 '
          '/BaseFont /Helvetica /Encoding /WinAnsiEncoding >> >> >> '
          '/Contents 5 0 R >>\nendobj\n',
        ),
      );
      final off4 = out.length;
      out
        ..add(latin1.encode('4 0 obj\n'))
        ..add(
          _streamObj(
            '/Type /ObjStm /N 2 /First ${objStmHeader.length} '
            '/Filter /FlateDecode',
            objStmCompressed,
          ),
        )
        ..add(latin1.encode('\nendobj\n'));
      final off5 = out.length;
      out
        ..add(latin1.encode('5 0 obj\n'))
        ..add(_streamObj('/Filter /FlateDecode', contentCompressed))
        ..add(latin1.encode('\nendobj\n'));

      final off6 = out.length;
      // XRef stream entries for objs 0..6, /W [1 4 1] => 6 bytes/row + 1 filter
      // byte (PNG None = 0).
      final rows = BytesBuilder(copy: false);
      void addRow(int type, int f1, int f2) {
        rows
          ..addByte(0) // PNG None filter
          ..addByte(type)
          ..addByte((f1 >> 24) & 0xFF)
          ..addByte((f1 >> 16) & 0xFF)
          ..addByte((f1 >> 8) & 0xFF)
          ..addByte(f1 & 0xFF)
          ..addByte(f2);
      }

      addRow(0, 0, 255); // obj 0: free
      addRow(2, 4, 0); // obj 1: in ObjStm 4 index 0
      addRow(2, 4, 1); // obj 2: in ObjStm 4 index 1
      addRow(1, off3, 0); // obj 3: Page
      addRow(1, off4, 0); // obj 4: ObjStm
      addRow(1, off5, 0); // obj 5: Content
      addRow(1, off6, 0); // obj 6: XRef stream

      final xrefCompressed = const ZLibEncoder().encodeBytes(rows.takeBytes());
      out
        ..add(latin1.encode('6 0 obj\n'))
        ..add(
          _streamObj(
            '/Type /XRef /Size 7 /Root 1 0 R /W [1 4 1] /Filter /FlateDecode '
            '/DecodeParms << /Predictor 12 /Columns 6 >>',
            xrefCompressed,
          ),
        )
        ..add(latin1.encode('\nendobj\n'))
        ..add(latin1.encode('startxref\n$off6\n%%EOF\n'));

      final path = await scratch.write(out.takeBytes());
      final info = await pages.open(path);
      expect(info.pageSizes, const [Size(600, 800)]);
      final lines = await pages.readText(0);
      expect(lines, isNotNull);
      expect(lines!.single.text, 'Compressed xref and object stream text');
    });
  });

  group('DartPdfPages.readText & render', () {
    late WebPdfScratch scratch;
    late DartPdfPages pages;

    setUp(() {
      scratch = WebPdfScratch();
      pages = DartPdfPages(readBytes: scratch.peek, writeBytes: scratch.put);
    });

    tearDown(() => pages.close());

    test('extracts uncompressed and FlateDecode text operators', () async {
      const stream =
          'q 1 0 0 1 10 0 cm '
          'BT /F1 12 Tf 14 TL 62 720 Td '
          '(First line of the document) Tj '
          'T* [(Second) -250 (line) -250 (with TJ kerning)] TJ '
          "(Third line with quote operator) ' "
          '0 0 (Fourth line with double quote) " '
          'ET Q';
      for (final compress in [false, true]) {
        final bytes = _simplePdf(pageStreams: [stream], compress: compress);
        final path = await scratch.write(bytes);
        await pages.open(path);
        final lines = await pages.readText(0);
        expect(lines, isNotNull);
        expect(lines!.map((l) => l.text).toList(), [
          'First line of the document',
          'Second line with TJ kerning',
          'Third line with quote operator',
          'Fourth line with double quote',
        ]);
        // Top-down coordinates: each subsequent line has a larger top Y.
        for (var i = 1; i < lines.length; i++) {
          expect(lines[i].rect.top, greaterThan(lines[i - 1].rect.top));
        }
        // Page has a usable text layer: render returns a white image for color
        // sampling.
        final img = await pages.render(0, maxPixels: 500000);
        expect(img.width, greaterThan(0));
        expect(img.height, greaterThan(0));
        final colours = sampleBlockColours(
          img,
          const Rect.fromLTWH(5, 5, 40, 20),
        );
        expect(colours.background, const Color(0xFFFFFFFF));
        expect(colours.foreground, const Color(0xFF000000));
      }
    });

    test('decodes /ToUnicode CMap bfchar and bfrange', () async {
      const cmap = '''
/CIDInit /ProcSet findresource begin
12 dict begin
begincmap
1 begincodespacerange
<0000> <FFFF>
endcodespacerange
2 beginbfchar
<0001> <041F>
<0002> <0440>
endbfchar
2 beginbfrange
<0010> <0012> <0041>
<0020> <0021> [<0068> <0069>]
endbfrange
endcmap
end
end
''';
      final cmapBytes = const ZLibEncoder().encodeBytes(latin1.encode(cmap));
      final contentBytes = latin1.encode(
        'BT /F1 12 Tf 72 720 Td <00010002> Tj 0 -20 Td <00100011001200200021> Tj ET',
      );
      final pdf = _buildPdf([
        latin1.encode('<< /Type /Catalog /Pages 2 0 R >>'),
        latin1.encode(
          '<< /Type /Pages /Kids [5 0 R] /Count 1 /MediaBox [0 0 612 792] >>',
        ),
        latin1.encode(
          '<< /Type /Font /Subtype /Type0 /BaseFont /Custom '
          '/Encoding /Identity-H /ToUnicode 4 0 R >>',
        ),
        _streamObj('/Filter /FlateDecode', cmapBytes),
        latin1.encode(
          '<< /Type /Page /Parent 2 0 R '
          '/Resources << /Font << /F1 3 0 R >> >> /Contents 6 0 R >>',
        ),
        _streamObj('', contentBytes),
      ]);
      final path = await scratch.write(pdf);
      await pages.open(path);
      final lines = await pages.readText(0);
      expect(lines, isNotNull);
      expect(lines!.map((l) => l.text).toList(), ['Пр', 'ABChi']);
    });

    test('decodes WinAnsi and UTF-16BE strings', () async {
      // WinAnsi 0x80 = Euro, 0x96 = en-dash; UTF-16BE <FEFF00480069> = "Hi"
      const stream =
          r'BT /F1 12 Tf 72 720 Td (Price: \200 10 \226 20) Tj '
          '0 -20 Td <FEFF00480065006C006C006F> Tj ET';
      final pdf = _simplePdf(pageStreams: [stream]);
      final path = await scratch.write(pdf);
      await pages.open(path);
      final lines = await pages.readText(0);
      expect(lines, isNotNull);
      expect(lines!.map((l) => l.text).toList(), ['Price: € 10 – 20', 'Hello']);
    });

    test(
      'returns null and refuses render for scanned pages without text',
      () async {
        final pdf = _simplePdf(
          pageStreams: ['q 100 0 0 100 50 50 cm /Im0 Do Q'],
        );
        final path = await scratch.write(pdf);
        await pages.open(path);
        expect(await pages.readText(0), isNull);
        await expectLater(
          pages.render(0, maxPixels: 100000),
          throwsA(isA<PdfRenderException>()),
        );
      },
    );
  });

  group('DartPdfPages.write round-trip', () {
    late WebPdfScratch scratch;
    late DartPdfPages pages;

    setUp(() {
      scratch = WebPdfScratch();
      pages = DartPdfPages(readBytes: scratch.peek, writeBytes: scratch.put);
    });

    tearDown(() => pages.close());

    test(
      'writes multi-page PDF with WinAnsi and Unicode and re-reads it',
      () async {
        final outPath = await scratch.newPath();
        await pages.write(outPath, const [
          PdfOutputPage(
            sourcePage: 0,
            size: Size(612, 792),
            blocks: [
              PdfTextBlock(
                rect: Rect.fromLTRB(72, 72, 400, 140),
                text: 'Café (100% pure) — translated paragraph with wrapping!',
                color: Color(0xFF111111),
                background: Color(0xFFFFFFFF),
                direction: TextDirection.ltr,
                fontSize: 14,
              ),
            ],
          ),
          PdfOutputPage(
            sourcePage: 1,
            size: Size(595, 842),
            blocks: [
              PdfTextBlock(
                rect: Rect.fromLTRB(72, 100, 500, 160),
                text: 'Привет мир на второй странице',
                color: Color(0xFF000000),
                background: Color(0xFFFFFFFF),
                direction: TextDirection.ltr,
                align: PdfTextAlign.center,
                fontSize: 14,
              ),
            ],
          ),
        ]);

        final written = await scratch.take(outPath);
        expect(DocumentFormat.isPdfBytes(written), isTrue);

        final reopenPath = await scratch.write(written);
        final info = await pages.open(reopenPath);
        expect(info.pageCount, 2);
        expect(info.pageSizes, const [Size(612, 792), Size(595, 842)]);

        final page0 = await pages.readText(0);
        expect(page0, isNotNull);
        expect(
          page0!.map((l) => l.text).join(' '),
          'Café (100% pure) — translated paragraph with wrapping!',
        );

        final page1 = await pages.readText(1);
        expect(page1, isNotNull);
        expect(
          page1!.map((l) => l.text).join(' '),
          'Привет мир на второй странице',
        );
      },
    );
  });

  group('PdfTranslator end-to-end with DartPdfPages (web simulation)', () {
    test(
      'translates a text-layer PDF without OCR and writes a valid PDF',
      () async {
        final repository = _MockTranslationRepository();
        when(() => repository.translate(any(), any())).thenAnswer((invocation) {
          final req = invocation.positionalArguments[1] as TranslationRequest;
          return Stream.value(
            TranslationResult(
              engineId: _googleEngine.id,
              engineName: _googleEngine.name,
              text: req.text.toUpperCase(),
            ),
          );
        });
        final scratch = WebPdfScratch();
        final dartPages = DartPdfPages(
          readBytes: scratch.peek,
          writeBytes: scratch.put,
        );
        final translator = PdfTranslator(
          pages: dartPages,
          recognizer: const _UnsupportedRecognizer(),
          translator: DocumentTranslator(
            repository: repository,
            maxAttempts: 1,
            retryDelay: Duration.zero,
          ),
          scratch: scratch,
        );
        addTearDown(translator.close);

        const pageOne =
            'BT /F1 12 Tf 72 720 Td '
            '(Hello world from a real text layer on page one.) Tj ET';
        const pageTwo =
            'BT /F1 12 Tf 72 720 Td '
            '(Second page also carries selectable text content.) Tj ET';
        final inputPdf = _simplePdf(
          pageStreams: [pageOne, pageTwo],
          compress: true,
        );

        final info = await translator.open(inputPdf);
        expect(info.pageCount, 2);
        expect(translator.canRead, isTrue);
        expect(await translator.plan(_english), const TextRecognitionReady([]));

        final progress =
            (await translator
                    .translate(
                      pageSizes: info.pageSizes,
                      codes: const [],
                      engine: _googleEngine,
                      source: _english,
                      target: _german,
                    )
                    .toList())
                .last;
        expect(progress.failures, isEmpty);
        expect(progress.results[0], [
          'HELLO WORLD FROM A REAL TEXT LAYER ON PAGE ONE.',
        ]);
        expect(progress.results[1], [
          'SECOND PAGE ALSO CARRIES SELECTABLE TEXT CONTENT.',
        ]);

        final outputBytes = await translator.write(
          pdfOutputPages(
            PdfSource(pageSizes: info.pageSizes, pages: progress.pages),
            progress.results,
            direction: (_) => TextDirection.ltr,
          ),
        );
        expect(DocumentFormat.isPdfBytes(outputBytes), isTrue);

        // Re-open the output PDF and verify the translated text is selectable.
        final verifyPath = await scratch.write(outputBytes);
        final verifyInfo = await dartPages.open(verifyPath);
        expect(verifyInfo.pageCount, 2);
        expect(
          (await dartPages.readText(0))!.map((l) => l.text).join(' '),
          'HELLO WORLD FROM A REAL TEXT LAYER ON PAGE ONE.',
        );
        expect(
          (await dartPages.readText(1))!.map((l) => l.text).join(' '),
          'SECOND PAGE ALSO CARRIES SELECTABLE TEXT CONTENT.',
        );
      },
    );

    test('reports scanned PDF as unreadable on web without OCR', () async {
      final repository = _MockTranslationRepository();
      final scratch = WebPdfScratch();
      final translator = PdfTranslator(
        pages: DartPdfPages(readBytes: scratch.peek, writeBytes: scratch.put),
        recognizer: const _UnsupportedRecognizer(),
        translator: DocumentTranslator(repository: repository),
        scratch: scratch,
      );
      addTearDown(translator.close);

      final scanned = _simplePdf(pageStreams: ['q 100 0 0 100 0 0 cm Q']);
      await translator.open(scanned);
      expect(translator.canRead, isFalse);
      expect(
        await translator.plan(_english),
        const TextRecognitionUnsupported(),
      );
    });
  });
}
