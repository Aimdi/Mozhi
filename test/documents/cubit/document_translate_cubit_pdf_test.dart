import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/documents/documents.dart';
import 'package:mozhi/documents/pdf/pdf.dart';
import 'package:mozhi/documents/widgets/widgets.dart' show documentRequests;
import 'package:mozhi/image_translate/models/models.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/fakes.dart';
import '../pdf/pdf_fakes.dart';

void main() {
  late MockTranslationRepository repository;
  late FakeDocumentFileService files;
  late List<TranslationRequest> requests;
  late FakePdfScratch scratch;
  late FakePdfPages pages;
  late FakePdfRecognizer recognizer;
  late Map<int, List<String>> textOf;

  setUpAll(registerDocumentFallbacks);

  setUp(() {
    repository = MockTranslationRepository();
    files = FakeDocumentFileService();
    requests = [];
    stubTranslate(repository, requests: requests);
    stubLanguages(repository);
    scratch = FakePdfScratch();
    pages = FakePdfPages(
      pageSizes: const [Size(612, 792), Size(612, 792), Size(595, 842)],
      scratch: scratch,
    );
    textOf = {
      0: ['Hello', 'World'],
      2: ['Last page'],
    };
    recognizer = FakePdfRecognizer(
      layoutFor: (width, height, codes) {
        final page = (width - 100) ~/ 10;
        return layoutOf(width, height, [
          for (final (i, text) in (textOf[page] ?? const <String>[]).indexed)
            paragraph(
              text,
              Rect.fromLTRB(10, 10 + 30.0 * i, 90, 30 + 30.0 * i),
            ),
        ]);
      },
    );
  });

  DocumentTranslateCubit build({
    Language source = english,
    Language target = german,
  }) {
    final translator = DocumentTranslator(
      repository: repository,
      maxAttempts: 1,
      retryDelay: Duration.zero,
    );
    final cubit = DocumentTranslateCubit(
      repository: repository,
      files: files,
      translator: translator,
      engines: const [googleEngine, deeplEngine, aiEngine],
      engine: googleEngine,
      sourceLanguages: sourceLanguages,
      targetLanguages: targetLanguages,
      source: source,
      target: target,
      pdfTranslator: PdfTranslator(
        pages: pages,
        recognizer: recognizer,
        translator: translator,
        scratch: scratch,
      ),
      ocrPreferred: const ['de'],
    );
    addTearDown(cubit.close);
    return cubit;
  }

  /// [cubit] once the PDF is open and its first page read.
  Future<DocumentTranslateCubit> opened(
    DocumentTranslateCubit cubit, {
    String name = 'scan.pdf',
  }) async {
    cubit.loadFile(name, pdfBytes);
    await pumpEventQueue();
    return cubit;
  }

  group('DocumentTranslateCubit with PDFs', () {
    test('opens a PDF and reads its first page for the preview', () async {
      final cubit = build();
      final states = <DocumentTranslateState>[];
      final subscription = cubit.stream.listen(states.add);
      addTearDown(subscription.cancel);
      await opened(cubit);
      final state = cubit.state;
      expect(states.first.status, DocumentStatus.loading);
      expect(states.first.format, DocumentFormat.pdf);
      expect(states.any((s) => s.pdf?.previewing ?? false), isTrue);
      expect(state.status, DocumentStatus.ready);
      expect(state.format, DocumentFormat.pdf);
      expect(state.isPdf, isTrue);
      expect(state.isBinary, isTrue);
      expect(state.hasDocument, isTrue);
      expect(state.fileName, 'scan.pdf');
      expect(state.sizeBytes, pdfBytes.length);
      expect(state.pdf!.pageCount, 3);
      expect(state.pdf!.previewing, isFalse);
      expect(state.pdf!.pages.keys, [0]);
      expect(state.pdf!.pages[0]!.codes, ['eng']);
      expect(state.text, 'Hello\n\nWorld');
      expect(state.chunkCount, 3);
      expect(state.segments, isEmpty);
      expect(state.canTranslate, isTrue);
      expect(state.hasTranslation, isFalse);
      expect(state.error, isNull);
      expect(state.outputFileName, 'scan.de.pdf');
      expect(state.pdfTextFileName, 'scan.de.txt');
      expect(pages.renders.single.page, 0);
      expect(cubit.pdfLanguageData, same(recognizer));
    });

    test('a file that is a PDF is read as one, whatever its name', () async {
      final cubit = await opened(build(), name: 'scan.txt');
      expect(cubit.state.format, DocumentFormat.pdf);
      expect(cubit.state.isPdf, isTrue);
    });

    group('cannot open', () {
      Future<DocumentError?> errorOf(void Function() arrange) async {
        arrange();
        final cubit = await opened(build());
        expect(cubit.state.isPdf, isFalse);
        expect(cubit.state.hasDocument, isFalse);
        expect(cubit.state.format, DocumentFormat.pdf);
        return cubit.state.error;
      }

      test('password-protected, damaged and long PDFs', () async {
        expect(
          await errorOf(
            () => pages.openError = const PdfOpenException(
              kind: PdfOpenErrorKind.encrypted,
            ),
          ),
          DocumentError.encrypted,
        );
        expect(
          await errorOf(
            () => pages.openError = const PdfOpenException(
              kind: PdfOpenErrorKind.damaged,
            ),
          ),
          DocumentError.damagedFile,
        );
        expect(
          await errorOf(
            () => pages.openError = const PdfOpenException(
              kind: PdfOpenErrorKind.unsupported,
            ),
          ),
          DocumentError.pdfNeedsApp,
        );
        expect(
          await errorOf(() {
            pages
              ..openError = null
              ..pageSizes = List.filled(201, const Size(10, 10));
          }),
          DocumentError.tooLarge,
        );
        expect(
          await errorOf(() {
            pages.pageSizes = const [Size(10, 10)];
            scratch.writeError = Exception('disk full');
          }),
          DocumentError.readFailed,
        );
      });

      test('a PDF over 25 MB is not opened', () async {
        final cubit = build()
          ..loadFile(
            'big.pdf',
            Uint8List(PdfLimits.maxBytes + 1)..setAll(0, pdfBytes),
          );
        await pumpEventQueue();
        expect(cubit.state.error, DocumentError.tooLarge);
        expect(pages.opened, isEmpty);
      });

      test('the web app needs the Android app', () async {
        pages.supported = false;
        final cubit = await opened(build());
        expect(cubit.state.error, DocumentError.pdfNeedsApp);
        expect(cubit.state.status, DocumentStatus.empty);
        expect(pages.opened, isEmpty);
      });
    });

    group('the preview', () {
      test('offers missing recognition data, then reads with it', () async {
        final cubit = await opened(build(source: german));
        expect(
          cubit.state.pdf!.missingData,
          const OcrDataMissingException(germanOcr),
        );
        expect(cubit.state.pdf!.pages, isEmpty);
        expect(pages.renders, isEmpty);
        // The data was downloaded from the offer.
        recognizer.installed = {...recognizer.installed, 'deu': 1500};
        await cubit.pdfDataInstalled();
        expect(cubit.state.pdf!.missingData, isNull);
        expect(cubit.state.pdf!.pages[0]!.codes, ['deu']);
      });

      test('says when the source language cannot be read', () async {
        final cubit = await opened(build(source: french));
        expect(cubit.state.pdf!.issue, PdfReadIssue.languageUnsupported);
        recognizer.isSupported = false;
        final other = await opened(build());
        expect(other.state.pdf!.issue, PdfReadIssue.recognitionUnavailable);
      });

      test('says when the first page cannot be read', () async {
        pages.renderErrors[0] = const PdfRenderException(page: 0);
        final cubit = await opened(build());
        expect(cubit.state.pdf!.issue, PdfReadIssue.readFailed);
        expect(cubit.state.canTranslate, isTrue);
      });

      test('reads the first page again for another source language', () async {
        recognizer.installed = {...recognizer.installed, 'deu': 1500};
        final cubit = await opened(build());
        expect(cubit.state.pdf!.pages[0]!.codes, ['eng']);
        cubit.setSource(german);
        await pumpEventQueue();
        expect(cubit.state.pdf!.pages[0]!.codes, ['deu']);
        expect(pages.renders, hasLength(2));
        // Back to English: read with its data again.
        cubit.setSource(english);
        await pumpEventQueue();
        expect(cubit.state.pdf!.pages[0]!.codes, ['eng']);
        expect(pages.renders, hasLength(3));
      });

      test('a change while the first page is read reads it again', () async {
        recognizer.installed = {...recognizer.installed, 'deu': 1500};
        final gate = pages.renderGate = Completer<void>();
        final cubit = build()..loadFile('scan.pdf', pdfBytes);
        await pumpEventQueue();
        expect(cubit.state.pdf!.previewing, isTrue);
        expect(cubit.state.canTranslate, isFalse);
        cubit.setSource(german);
        await pumpEventQueue();
        gate.complete();
        await pumpEventQueue();
        expect(cubit.state.pdf!.previewing, isFalse);
        expect(cubit.state.pdf!.pages[0]!.codes, ['deu']);
      });
    });

    group('translating', () {
      test('reads and translates page by page', () async {
        final cubit = await opened(build());
        final states = <DocumentTranslateState>[];
        final subscription = cubit.stream.listen(states.add);
        addTearDown(subscription.cancel);
        await cubit.translate();
        final state = cubit.state;
        expect(state.status, DocumentStatus.translated);
        expect(state.results, {
          0: ['HELLO', 'WORLD'],
          1: <String>[],
          2: ['LAST PAGE'],
        });
        expect(state.isComplete, isTrue);
        expect(state.hasTranslation, isTrue);
        expect(state.doneChunks, 3);
        expect(state.progress, 1);
        expect(state.output, 'HELLO\n\nWORLD\n\n\nLAST PAGE');
        expect(state.text, 'Hello\n\nWorld\n\n\nLast page');
        expect(state.pdf!.currentPage, isNull);
        expect(state.pdf!.stage, isNull);
        // The first page was read for the preview already.
        expect(pages.renders.map((r) => r.page), [0, 1, 2]);
        expect(
          states.any(
            (s) =>
                s.isTranslating &&
                s.pdf?.currentPage == 2 &&
                s.pdf?.stage == PdfStage.translating,
          ),
          isTrue,
        );
        expect(
          states.any(
            (s) => s.pdf?.currentPage == 1 && s.pdf?.stage == PdfStage.reading,
          ),
          isTrue,
        );
        expect(requests.map((r) => r.text), ['Hello\n\nWorld', 'Last page']);
      });

      test('no text on any page says so', () async {
        textOf = {};
        final cubit = await opened(build());
        await cubit.translate();
        expect(cubit.state.status, DocumentStatus.ready);
        expect(cubit.state.error, DocumentError.pdfNoText);
        expect(cubit.state.results, isEmpty);
        expect(cubit.state.hasTranslation, isFalse);
        expect(requests, isEmpty);
      });

      test('missing recognition data is offered instead of a run', () async {
        final cubit = await opened(build(source: german));
        await cubit.translate();
        expect(cubit.state.status, DocumentStatus.ready);
        expect(
          cubit.state.pdf!.missingData,
          const OcrDataMissingException(germanOcr),
        );
        expect(requests, isEmpty);
        final unsupported = await opened(build(source: french));
        await unsupported.translate();
        expect(unsupported.state.pdf!.issue, PdfReadIssue.languageUnsupported);
      });

      test(
        'data missing half-way stops, then goes on once installed',
        () async {
          recognizer.installed = {...recognizer.installed, 'deu': 1500};
          final cubit = await opened(build(source: german));
          // The data went missing after the first page was read.
          recognizer.errorsByWidth[FakePdfPages.widthOf(1)] =
              const OcrDataMissingException(germanOcr);
          await cubit.translate();
          expect(cubit.state.status, DocumentStatus.translated);
          expect(cubit.state.failures.keys, [1]);
          expect(
            cubit.state.pdf!.missingData,
            const OcrDataMissingException(germanOcr),
          );
          expect(cubit.state.isComplete, isFalse);
          expect(cubit.state.pendingChunks, 2);
          recognizer.errorsByWidth.clear();
          await cubit.pdfDataInstalled();
          expect(cubit.state.isComplete, isTrue);
          expect(cubit.state.failures, isEmpty);
        },
      );

      test('retrying one failed page keeps the others failed', () async {
        pages.renderErrors
          ..[0] = const PdfRenderException(page: 0)
          ..[2] = const PdfRenderException(page: 2);
        final cubit = build()..loadFile('scan.pdf', pdfBytes);
        await pumpEventQueue();
        await cubit.translate();
        expect(cubit.state.failures.keys, [0, 2]);
        pages.renderErrors.remove(2);
        await cubit.retryChunk(2);
        expect(cubit.state.failures.keys, [0]);
        expect(cubit.state.results.keys, containsAll([1, 2]));
      });

      test('a failed page is retried on its own', () async {
        pages.renderErrors[2] = const PdfRenderException(page: 2);
        final cubit = await opened(build());
        await cubit.translate();
        expect(cubit.state.failures.keys, [2]);
        expect(cubit.state.status, DocumentStatus.translated);
        expect(cubit.state.isComplete, isFalse);
        pages.renderErrors.clear();
        requests.clear();
        await cubit.retryChunk(2);
        expect(cubit.state.failures, isEmpty);
        expect(cubit.state.isComplete, isTrue);
        expect(requests.single.text, 'Last page');
      });

      test('consent stops the run and counts what is left', () async {
        const consent = ConsentRequiredException(
          kind: ConsentKind.pair,
          destination: PublicInstanceDestination(
            'mozhi.example',
            engine: 'google',
          ),
          engineId: 'mozhi:google',
        );
        stubTranslate(repository, respond: (_) => Stream.error(consent));
        final cubit = await opened(build());
        await cubit.translate();
        expect(cubit.state.failures, {0: consent});
        expect(pages.renders, hasLength(1));
        // Page 0's request (and, if its batch comes apart, one per
        // paragraph), pages 1 and 2 not read yet.
        expect(documentRequests(cubit.state), 3 + 3 + 3);
      });

      group('a one-time consent', () {
        const consent = ConsentRequiredException(
          kind: ConsentKind.pair,
          destination: PublicInstanceDestination(
            'mozhi.example',
            engine: 'google',
          ),
          engineId: 'mozhi:google',
          source: 'en',
          target: 'de',
        );

        /// Stops the requests for [stoppedText] (all when null) until the
        /// user allows them ("Once").
        void refuse({String? stoppedText}) {
          var refusing = true;
          stubTranslate(
            repository,
            requests: requests,
            respond: (request) =>
                refusing && (stoppedText ?? request.text) == request.text
                ? Stream.error(consent)
                : Stream.value(result(request.text.toUpperCase())),
          );
          when(
            () =>
                repository.allowOnce(consent, requests: any(named: 'requests')),
          ).thenAnswer((_) => refusing = false);
        }

        test('is withdrawn when the PDF is done', () async {
          refuse();
          final cubit = await opened(build());
          addTearDown(cubit.close);
          await cubit.translate();
          expect(cubit.state.failures, {0: consent});
          // What the prompt does on "Once": one approval for 9 requests.
          repository.allowOnce(
            consent,
            requests: documentRequests(cubit.state),
          );
          requests.clear();
          await cubit.consentGranted();
          expect(cubit.state.isComplete, isTrue);
          // Two requests sent; the other 7 are withdrawn.
          expect(requests, hasLength(2));
          verify(() => repository.revokeOnce(consent)).called(1);
        });

        test('is withdrawn when the run cannot read the pages', () async {
          refuse();
          recognizer.installed = {...recognizer.installed, 'deu': 1500};
          final cubit = await opened(build(source: german));
          addTearDown(cubit.close);
          await cubit.translate();
          expect(cubit.state.failures, {0: consent});
          recognizer.installed = {
            for (final entry in recognizer.installed.entries)
              if (entry.key != 'deu') entry.key: entry.value,
          };
          await cubit.consentGranted();
          expect(cubit.state.pdf!.missingData, isNotNull);
          verify(() => repository.revokeOnce(consent)).called(1);
        });

        test('is withdrawn at once when nothing can start', () async {
          refuse(stoppedText: 'Last page');
          final cubit = await opened(build());
          addTearDown(cubit.close);
          await cubit.translate();
          expect(cubit.state.failures, {2: consent});
          // The translated PDF is being written: nothing translates now.
          final gate = pages.writeGate = Completer<void>();
          final saving = cubit.save();
          await pumpEventQueue();
          expect(cubit.state.canTranslate, isFalse);
          await cubit.consentGranted();
          verify(() => repository.revokeOnce(consent)).called(1);
          expect(cubit.state.failures, {2: consent});
          gate.complete();
          await saving;
        });
      });

      test('cancel keeps what is done', () async {
        final cubit = await opened(build());
        final gate = pages.renderGate = Completer<void>();
        final run = cubit.translate();
        await pumpEventQueue();
        expect(cubit.state.isTranslating, isTrue);
        expect(cubit.state.canTranslate, isFalse);
        cubit.cancel();
        await run;
        gate.complete();
        await pumpEventQueue();
        expect(cubit.state.status, DocumentStatus.translated);
        expect(cubit.state.results.keys, [0]);
        cubit.cancel();
        expect(cubit.state.status, DocumentStatus.translated);
      });

      test('cancel before reading starts', () async {
        final cubit = await opened(build());
        final run = cubit.translate();
        cubit.cancel();
        await run;
        await pumpEventQueue();
        expect(cubit.state.status, DocumentStatus.ready);
        expect(requests, isEmpty);
      });

      test(
        'another engine or target drops the translation, not the pages',
        () async {
          final cubit = await opened(build());
          await cubit.translate();
          cubit.setTarget(spanish);
          expect(cubit.state.results, isEmpty);
          expect(cubit.state.pdf!.pages.keys, [0, 1, 2]);
          pages.renders.clear();
          await cubit.translate();
          expect(pages.renders, isEmpty);
          expect(cubit.state.isComplete, isTrue);
        },
      );

      test('counts the personal data kept on the device', () async {
        stubTranslate(
          repository,
          respond: (request) => Stream.value(
            TranslationResult(
              engineId: 'mozhi:google',
              engineName: 'Google',
              text: request.text,
              maskedPersonalData: 1,
            ),
          ),
        );
        final cubit = await opened(build());
        await cubit.translate();
        expect(cubit.state.maskedPersonalData, 2);
      });
    });

    group('saving', () {
      Future<DocumentTranslateCubit> translated() async {
        final cubit = await opened(build());
        await cubit.translate();
        return cubit;
      }

      test('saves the translated PDF, written once', () async {
        final cubit = await translated();
        final states = <DocumentTranslateState>[];
        final subscription = cubit.stream.listen(states.add);
        addTearDown(subscription.cancel);
        await cubit.save();
        expect(files.saved.single.fileName, 'scan.de.pdf');
        expect(files.saved.single.mimeType, 'application/pdf');
        expect(files.saved.single.bytes, pages.written);
        expect(states.any((s) => s.pdf?.writing ?? false), isTrue);
        expect(cubit.state.pdf!.writing, isFalse);
        expect(cubit.state.notice, DocumentNotice.saved);
        final written = pages.writes.single.pages;
        expect(written.map((p) => p.sourcePage), [0, 1, 2]);
        expect(written[0].blocks.map((b) => b.text), ['HELLO', 'WORLD']);
        expect(written[0].blocks.first.direction, TextDirection.ltr);
        expect(written[1].blocks, isEmpty);
        expect(written[2].size, const Size(595, 842));
        await cubit.share();
        expect(files.shared.single.bytes, pages.written);
        expect(files.shared.single.mimeType, 'application/pdf');
        expect(pages.writes, hasLength(1));
      });

      test('a failed write is a failed save', () async {
        final cubit = await translated();
        pages.writeError = const PdfWriteException(cause: 'io');
        await cubit.save();
        expect(cubit.state.notice, DocumentNotice.saveFailed);
        expect(cubit.state.pdf!.writing, isFalse);
        await cubit.share();
        expect(cubit.state.notice, DocumentNotice.shareFailed);
      });

      test('saves the text page by page', () async {
        final cubit = await translated();
        await cubit.saveText(pageHeading: (number) => 'Seite $number');
        final saved = files.saved.single;
        expect(saved.fileName, 'scan.de.txt');
        expect(saved.mimeType, 'text/plain');
        expect(
          utf8.decode(saved.bytes),
          'Seite 1\n\nHELLO\n\nWORLD\n\n\nSeite 2\n\n\nSeite 3\n\nLAST PAGE',
        );
        expect(cubit.state.notice, DocumentNotice.saved);
        files.saveError = Exception('denied');
        await cubit.saveText();
        expect(cubit.state.notice, DocumentNotice.saveFailed);
        await cubit.copy();
        expect(files.copied.single, 'HELLO\n\nWORLD\n\n\nLAST PAGE');
      });

      test('nothing to save before a translation', () async {
        final cubit = await opened(build());
        await cubit.saveText();
        await cubit.save();
        expect(files.saved, isEmpty);
        expect(pages.writes, isEmpty);
      });

      test('another translation is written again', () async {
        final cubit = await translated();
        await cubit.save();
        await cubit.translate();
        await cubit.save();
        expect(pages.writes, hasLength(2));
      });
    });

    test("without a PDF translator, the platform's is used", () async {
      final cubit = DocumentTranslateCubit(
        repository: repository,
        files: files,
        engines: const [googleEngine],
        engine: googleEngine,
      );
      addTearDown(cubit.close);
      cubit.loadFile('scan.pdf', pdfBytes);
      await pumpEventQueue(times: 50);
      // No Android plugin in a test: it can't be opened.
      expect(cubit.state.isPdf, isFalse);
      expect(
        cubit.state.error,
        isIn([DocumentError.readFailed, DocumentError.pdfNeedsApp]),
      );
      expect(cubit.pdfLanguageData, isNotNull);
    });

    group('the document', () {
      test('is closed when removed, replaced or the screen closes', () async {
        final cubit = await opened(build());
        cubit.clear();
        await pumpEventQueue();
        expect(pages.closes, 1);
        expect(cubit.state.isPdf, isFalse);
        await opened(cubit);
        cubit.loadFile('a.txt', bytesOf('Hello'));
        await pumpEventQueue();
        expect(pages.closes, 2);
        await opened(cubit);
        await cubit.close();
        await pumpEventQueue();
        expect(pages.closes, 3);
      });

      test('waits in file mode while text is pasted', () async {
        final cubit = await opened(build());
        cubit.setMode(DocumentInputMode.text);
        expect(cubit.state.isPdf, isFalse);
        cubit.setMode(DocumentInputMode.file);
        expect(cubit.state.isPdf, isTrue);
        await pumpEventQueue();
        expect(cubit.state.pdf!.pages.keys, [0]);
        // Read once.
        expect(pages.renders, hasLength(1));
      });

      test(
        'a PDF opened while text is shown waits for the file mode',
        () async {
          final gate = Completer<void>();
          pages.renderGate = gate;
          final cubit = build()..loadFile('scan.pdf', pdfBytes);
          await pumpEventQueue();
          cubit.setMode(DocumentInputMode.text);
          gate.complete();
          await pumpEventQueue();
          expect(cubit.state.isPdf, isFalse);
          cubit.setMode(DocumentInputMode.file);
          await pumpEventQueue();
          expect(cubit.state.pdf!.pages.keys, [0]);
        },
      );

      test('removed while it opens, it is not shown', () async {
        final cubit = build()
          ..loadFile('scan.pdf', pdfBytes)
          ..clear();
        await pumpEventQueue();
        expect(cubit.state.isPdf, isFalse);
        expect(cubit.state.hasDocument, isFalse);
      });
    });

    blocTest<DocumentTranslateCubit, DocumentTranslateState>(
      'a page without text keeps the original in the text',
      build: build,
      act: (cubit) async {
        textOf = {
          1: ['Only'],
        };
        cubit.loadFile('scan.pdf', pdfBytes);
        await pumpEventQueue();
        await cubit.translate();
      },
      skip: 1,
      verify: (cubit) {
        expect(cubit.state.output, 'ONLY');
        expect(cubit.state.results[0], isEmpty);
      },
    );
  });
}
