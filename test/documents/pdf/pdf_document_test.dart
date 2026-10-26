import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/core/core.dart';
import 'package:mozhi/documents/pdf/pdf.dart';
import 'package:mozhi/documents/pdf/pdf_scratch_io.dart' show FolderPdfScratch;
import 'package:mozhi/image_translate/models/models.dart';
import 'package:translation_repository/translation_repository.dart';

import 'pdf_fakes.dart';

const _white = Color(0xFFFFFFFF);
const _black = Color(0xFF000000);

PdfParagraph _paragraph(
  String text, [
  Rect rect = const Rect.fromLTRB(1, 2, 3, 4),
]) => PdfParagraph(
  text: text,
  rect: rect,
  background: _white,
  foreground: _black,
  align: PdfTextAlign.center,
  fontSize: 9,
);

void main() {
  const sizes = [Size(612, 792), Size(595, 842), Size(612, 792)];
  final source = PdfSource(
    pageSizes: sizes,
    pages: {
      0: PdfPageText(
        page: 0,
        size: sizes[0],
        codes: const ['eng'],
        paragraphs: [_paragraph('Hello'), _paragraph('World')],
      ),
      // Page 1 not read; page 2 has no text.
      2: PdfPageText(page: 2, size: sizes[2], codes: const ['eng']),
    },
  );

  group('PdfSource', () {
    test('knows its pages', () {
      expect(source.pageCount, 3);
      expect(source.firstPage?.paragraphs, hasLength(2));
      expect([for (final page in source.readPages) page.page], [0, 2]);
      expect(const PdfSource(pageSizes: sizes).firstPage, isNull);
    });

    test('copies and drops a translation', () {
      final busy = source.copyWith(
        partial: {
          1: {
            0: ['x'],
          },
        },
        previewing: true,
        missingData: () => const OcrDataMissingException(germanOcr),
        issue: () => PdfReadIssue.readFailed,
        currentPage: () => 1,
        stage: () => PdfStage.reading,
        writing: true,
      );
      expect(busy.previewing, isTrue);
      expect(busy.missingData, const OcrDataMissingException(germanOcr));
      expect(busy.issue, PdfReadIssue.readFailed);
      expect(busy.currentPage, 1);
      expect(busy.stage, PdfStage.reading);
      expect(busy.writing, isTrue);
      expect(busy, isNot(source));
      final idle = busy.withoutTranslation();
      expect(idle.partial, isEmpty);
      expect(idle.currentPage, isNull);
      expect(idle.stage, isNull);
      expect(idle.writing, isFalse);
      // What was read, and why it can't read, stay.
      expect(idle.pages, source.pages);
      expect(idle.previewing, isTrue);
      expect(idle.issue, PdfReadIssue.readFailed);
      expect(
        busy.copyWith(missingData: () => null, issue: () => null),
        isA<PdfSource>()
            .having((s) => s.missingData, 'missingData', isNull)
            .having((s) => s.issue, 'issue', isNull),
      );
    });

    test('pages and paragraphs compare by value', () {
      expect(_paragraph('a'), _paragraph('a'));
      expect(_paragraph('a'), isNot(_paragraph('b')));
      expect(
        PdfPageText(page: 0, size: sizes[0], codes: const ['eng']),
        PdfPageText(page: 0, size: sizes[0], codes: const ['eng']),
      );
    });
  });

  group('pdfText', () {
    test('the original text page by page', () {
      expect(pdfText(source, const {}, translated: false), 'Hello\n\nWorld');
      expect(
        pdfText(source, const {
          0: ['Hallo', 'Welt'],
        }, translated: false),
        'Hello\n\nWorld',
      );
    });

    test('the translation, the original where a paragraph has none', () {
      expect(
        pdfText(source, const {
          0: ['Hallo', '  '],
        }),
        'Hallo\n\nWorld',
      );
    });

    test('with headings, also for pages without text', () {
      expect(
        pdfText(source, const {
          0: ['Hallo', 'Welt'],
          2: [],
        }, heading: (number) => 'Seite $number'),
        'Seite 1\n\nHallo\n\nWelt\n\n\nSeite 3',
      );
    });
  });

  group('pdfOutputPages', () {
    test('every page, the translated ones with their blocks', () {
      final output = pdfOutputPages(source, const {
        0: [' Hallo ', ''],
        2: [],
      }, direction: (text) => TextDirection.ltr);
      expect(output, [
        PdfOutputPage(
          sourcePage: 0,
          size: sizes[0],
          blocks: const [
            PdfTextBlock(
              rect: Rect.fromLTRB(1, 2, 3, 4),
              text: 'Hallo',
              color: _black,
              background: _white,
              direction: TextDirection.ltr,
              align: PdfTextAlign.center,
              fontSize: 9,
            ),
          ],
        ),
        // Not read: kept as it is.
        PdfOutputPage(sourcePage: 1, size: sizes[1]),
        // No text: kept as it is.
        PdfOutputPage(sourcePage: 2, size: sizes[2]),
      ]);
    });

    test('a read page without a translation is kept', () {
      final output = pdfOutputPages(
        source,
        const {},
        direction: (text) => TextDirection.ltr,
      );
      expect(output.every((page) => page.blocks.isEmpty), isTrue);
      expect(output, hasLength(3));
    });

    test('gives each translation its direction', () {
      final output = pdfOutputPages(
        source,
        const {
          0: ['مرحبا', 'عالم'],
        },
        direction: (text) =>
            pdfTextDirection(const Language(code: 'ar', name: 'Arabic'), text),
      );
      expect(
        output.first.blocks.map((block) => block.direction),
        everyElement(TextDirection.rtl),
      );
    });
  });

  group('pdfTextDirection', () {
    test('from the target language, else from the text', () {
      expect(
        pdfTextDirection(const Language(code: 'he', name: 'Hebrew'), 'abc'),
        TextDirection.rtl,
      );
      expect(
        pdfTextDirection(const Language(code: 'de', name: 'German'), 'שלום'),
        TextDirection.ltr,
      );
      expect(pdfTextDirection(Language.auto, 'שלום עולם'), TextDirection.rtl);
      expect(
        pdfTextDirection(const Language.custom('Pirate speak'), 'Ahoy'),
        TextDirection.ltr,
      );
    });
  });

  group('DocumentFormat.pdf', () {
    test('is a binary format named by its extension', () {
      expect(DocumentFormat.fromFileName('Report.PDF'), DocumentFormat.pdf);
      expect(DocumentFormat.pdf.mimeType, 'application/pdf');
      expect(DocumentFormat.pdf.isBinary, isTrue);
      expect(DocumentFormat.pdf.usesTargetLanguage, isFalse);
      expect(DocumentFormat.pdf.supportsBilingual, isFalse);
      expect(DocumentFormat.allExtensions, contains('pdf'));
      expect(
        translatedFileName('scan.en.pdf', DocumentFormat.pdf, 'de'),
        'scan.de.pdf',
      );
      expect(Chunker.encodingFor(DocumentFormat.pdf), ChunkEncoding.paragraphs);
    });

    test('is sniffed from %PDF- in the first 1024 bytes', () {
      expect(DocumentFormat.isPdfBytes(pdfBytes), isTrue);
      expect(
        DocumentFormat.isPdfBytes([...List.filled(1000, 0x20), ...pdfBytes]),
        isTrue,
      );
      expect(
        DocumentFormat.isPdfBytes([...List.filled(1020, 0x20), ...pdfBytes]),
        isFalse,
      );
      expect(DocumentFormat.isPdfBytes('%PDF'.codeUnits), isFalse);
      expect(DocumentFormat.isPdfBytes('PK\x03\x04'.codeUnits), isFalse);
      expect(DocumentFormat.isPdfBytes(const []), isFalse);
    });

    test('is never parsed as text or as a package', () {
      expect(
        () => parseDocument('%PDF-1.7', DocumentFormat.pdf),
        throwsArgumentError,
      );
    });
  });

  group('the limits', () {
    test('are the same on the Kotlin side', () {
      final kotlin = File(
        'android/app/src/main/kotlin/io/github/aimdi/mozhi/PdfPagesPlugin.kt',
      ).readAsStringSync();
      String constant(String name) =>
          RegExp('const val $name = ([^\\n]+)').firstMatch(kotlin)!.group(1)!;
      expect(constant('CHANNEL'), '"${MethodChannelPdfPages.channelName}"');
      expect(constant('MAX_BYTES'), '25L * 1024 * 1024');
      expect(25 * 1024 * 1024, PdfLimits.maxBytes);
      expect(constant('MAX_PAGES'), '${PdfLimits.maxPages}');
      expect(
        constant('MAX_PIXELS').replaceAll('_', ''),
        '${PdfLimits.maxPixels}L',
      );
      // Password-protected files are refused, not opened.
      expect(kotlin, contains('catch (e: SecurityException)'));
      expect(kotlin, contains('"encrypted"'));
      // Registered with the app's engines.
      expect(
        File(
          'android/app/src/main/kotlin/io/github/aimdi/mozhi/MainActivity.kt',
        ).readAsStringSync(),
        contains('flutterEngine.plugins.add(PdfPagesPlugin())'),
      );
    });
  });

  group('defaultPdfPages', () {
    test('is the plugin on Android, unsupported elsewhere', () {
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(defaultPdfPages(), isA<MethodChannelPdfPages>());
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(defaultPdfPages(), isA<UnsupportedPdfPages>());
    });
  });

  group('defaultPdfScratch', () {
    test('keeps its files in a folder of the cache', () {
      expect(defaultPdfScratch(), isA<FolderPdfScratch>());
    });
  });

  group('FolderPdfScratch', () {
    late Directory folder;

    setUp(() async {
      folder = await Directory.systemTemp.createTemp('pdf_scratch_test');
      addTearDown(() => folder.delete(recursive: true));
    });

    test('writes, takes and deletes files in its folder', () async {
      final inner = Directory('${folder.path}/pdf_pages');
      final scratch = FolderPdfScratch(() async => inner);
      final path = await scratch.write(Uint8List.fromList([1, 2, 3]));
      expect(path, startsWith(inner.path));
      expect(path, endsWith('.pdf'));
      expect(File(path).readAsBytesSync(), [1, 2, 3]);
      expect(await scratch.take(path), [1, 2, 3]);
      expect(File(path).existsSync(), isFalse);
      // Deleting what is gone is fine.
      await scratch.delete(path);
      final other = await scratch.newPath();
      expect(other, isNot(path));
      expect(File(other).existsSync(), isFalse);
      await expectLater(
        scratch.take(other),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('sweeps leftovers older than an hour', () async {
      final inner = Directory('${folder.path}/pdf_pages')..createSync();
      final old = File('${inner.path}/old.pdf')
        ..writeAsBytesSync([1])
        ..setLastModifiedSync(
          DateTime.now().subtract(const Duration(hours: 2)),
        );
      final fresh = File('${inner.path}/fresh.pdf')..writeAsBytesSync([1]);
      Directory('${inner.path}/folder').createSync();
      await FolderPdfScratch(() async => inner).newPath();
      expect(old.existsSync(), isFalse);
      expect(fresh.existsSync(), isTrue);
    });
  });
}
