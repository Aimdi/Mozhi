import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/core/core.dart';
import 'package:mozhi/documents/pdf/pdf.dart';
import 'package:mozhi/image_translate/data/text_recognition_plan.dart';
import 'package:mozhi/image_translate/data/text_recognition_service.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:mozhi/platform/device_conditions.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/fakes.dart';
import 'pdf_fakes.dart';

/// A recognizer without raw-pixel reading (the Play variant's ML Kit).
class _PhotoOnlyRecognizer implements TextRecognitionService {
  @override
  bool get isSupported => true;

  @override
  Future<String> recognize(PickedImage image, {required Language source}) =>
      throw UnimplementedError();
}

void main() {
  late MockTranslationRepository repository;
  late List<TranslationRequest> requests;
  late FakePdfScratch scratch;
  late FakePdfPages pages;
  late FakePdfRecognizer recognizer;

  setUpAll(registerDocumentFallbacks);

  /// Page n's paragraphs (by the width its image is rendered with).
  late Map<int, List<String>> textOf;

  setUp(() {
    repository = MockTranslationRepository();
    requests = [];
    stubTranslate(repository, requests: requests);
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

  PdfTranslator build({
    TextRecognitionService? withRecognizer,
    int maxFailedPagesInARow = 3,
    DeviceConditions? conditions,
    Duration coolingCheck = const Duration(seconds: 30),
  }) => PdfTranslator(
    pages: pages,
    recognizer: withRecognizer ?? recognizer,
    translator: DocumentTranslator(
      repository: repository,
      maxAttempts: 1,
      retryDelay: Duration.zero,
    ),
    scratch: scratch,
    maxFailedPagesInARow: maxFailedPagesInARow,
    conditions: conditions,
    coolingCheck: coolingCheck,
  );

  Stream<PdfProgress> translate(
    PdfTranslator translator, {
    List<String> codes = const ['eng'],
    Map<int, PdfPageText> known = const {},
    Map<int, List<String>> completed = const {},
    Map<int, Map<int, List<String>>> partial = const {},
    Iterable<int>? only,
  }) => translator.translate(
    pageSizes: pages.pageSizes,
    codes: codes,
    engine: googleEngine,
    source: english,
    target: german,
    known: known,
    completed: completed,
    partial: partial,
    only: only,
  );

  group('PdfTranslator.platform', () {
    test("uses the platform's pages and recognizer", () {
      final translator = PdfTranslator.platform(
        translator: DocumentTranslator(repository: repository),
      );
      // Tests run as Android.
      expect(translator.isSupported, isTrue);
      expect(translator.languageData, isNotNull);
    });
  });

  group('PdfTranslator.open', () {
    test('opens a private copy and deletes it', () async {
      final info = await build().open(pdfBytes);
      expect(info.pageCount, 3);
      final copy = pages.opened.single;
      expect(copy, startsWith('/cache/pdf_pages/'));
      expect(scratch.deleted, [copy]);
      expect(scratch.files, isEmpty);
    });

    test('refuses what is no PDF, too large or not supported', () async {
      final translator = build();
      await expectLater(
        translator.open(Uint8List.fromList('PK\x03\x04'.codeUnits)),
        throwsA(const PdfOpenException(kind: PdfOpenErrorKind.damaged)),
      );
      await expectLater(
        translator.open(Uint8List(PdfLimits.maxBytes + 1)..setAll(0, pdfBytes)),
        throwsA(const PdfOpenException(kind: PdfOpenErrorKind.tooLarge)),
      );
      pages.supported = false;
      await expectLater(
        translator.open(pdfBytes),
        throwsA(const PdfOpenException(kind: PdfOpenErrorKind.unsupported)),
      );
      expect(pages.opened, isEmpty);
    });

    test('closes a PDF with too many pages', () async {
      pages.pageSizes = List.filled(PdfLimits.maxPages + 1, const Size(1, 1));
      await expectLater(
        build().open(pdfBytes),
        throwsA(const PdfOpenException(kind: PdfOpenErrorKind.tooLarge)),
      );
      expect(pages.closes, 1);
      expect(scratch.files, isEmpty);
    });

    test('deletes the copy when opening fails', () async {
      pages.openError = const PdfOpenException(
        kind: PdfOpenErrorKind.encrypted,
      );
      await expectLater(
        build().open(pdfBytes),
        throwsA(const PdfOpenException(kind: PdfOpenErrorKind.encrypted)),
      );
      expect(scratch.files, isEmpty);
      expect(scratch.deleted, hasLength(1));
    });
  });

  group('PdfTranslator.plan', () {
    test('plans with the installed recognition data', () async {
      final translator = build();
      expect(translator.isSupported, isTrue);
      expect(translator.canRead, isTrue);
      expect(translator.languageData, same(recognizer));
      expect(
        await translator.plan(english),
        const TextRecognitionReady(['eng']),
      );
      expect(
        await translator.plan(german),
        const TextRecognitionNeedsData(OcrDataMissingException(germanOcr)),
      );
      expect(await translator.plan(french), const TextRecognitionUnsupported());
      expect(
        await translator.plan(Language.auto, preferred: const ['de']),
        const TextRecognitionReady(['eng']),
      );
    });

    test('cannot read without raw-pixel recognition', () async {
      final translator = build(withRecognizer: _PhotoOnlyRecognizer());
      expect(translator.canRead, isFalse);
      expect(translator.languageData, isNull);
      expect(
        await translator.plan(english),
        const TextRecognitionUnsupported(),
      );
      await expectLater(
        translator.read(0, const Size(10, 10), ['eng']),
        throwsA(
          const ImageTranslateException(
            ImageTranslateErrorKind.recognitionFailed,
          ),
        ),
      );
      recognizer.isSupported = false;
      expect(build().canRead, isFalse);
    });
  });

  group('PdfTranslator.translate', () {
    test('reads and translates page by page', () async {
      final events = await translate(build()).toList();
      expect(
        [for (final e in events) (e.page, e.stage, e.done, e.isComplete)],
        [
          (null, null, 0, false),
          (0, PdfStage.reading, 0, false),
          (0, PdfStage.translating, 0, false),
          (null, null, 1, false),
          (1, PdfStage.reading, 1, false),
          (null, null, 2, false),
          (2, PdfStage.reading, 2, false),
          (2, PdfStage.translating, 2, false),
          (null, null, 3, false),
          (null, null, 3, true),
        ],
      );
      final last = events.last;
      expect(last.total, 3);
      expect(last.results, {
        0: ['HELLO', 'WORLD'],
        // A page without text is done, with nothing to draw.
        1: <String>[],
        2: ['LAST PAGE'],
      });
      expect(last.failures, isEmpty);
      expect(last.partial, isEmpty);
      expect(last.pages.keys, [0, 1, 2]);
      expect(last.pages[1]!.isEmpty, isTrue);
      // The paragraphs of a page are one request.
      expect(
        [for (final r in requests) r.text],
        ['Hello\n\nWorld', 'Last page'],
      );
      expect(requests.first.source, english);
      expect(requests.first.target, german);
      // Rendered at 300 dpi within 8 megapixels.
      expect(pages.renders.map((r) => r.maxPixels), [
        PdfLimits.maxPixels,
        PdfLimits.maxPixels,
        PdfLimits.maxPixels,
      ]);
      expect(recognizer.reads.map((read) => read.codes), everyElement(['eng']));
    });

    test('reuses pages read with the same data, reads others again', () async {
      final translator = build();
      final first = (await translate(translator).toList()).last;
      pages.renders.clear();
      requests.clear();
      final again = (await translate(
        translator,
        known: first.pages,
      ).toList()).last;
      expect(pages.renders, isEmpty);
      expect(again.results, first.results);
      expect(requests, hasLength(2));
      final reread = (await translate(
        translator,
        codes: const ['eng', 'deu'],
        known: first.pages,
        only: const [0],
      ).toList()).last;
      expect(pages.renders.single.page, 0);
      expect(reread.pages[0]!.codes, ['eng', 'deu']);
    });

    test('skips finished pages and takes only those asked for', () async {
      final events = await translate(
        build(),
        completed: const {
          0: ['DONE', 'BEFORE'],
        },
        only: const [0, 2, 7, -1],
      ).toList();
      expect(pages.renders.map((r) => r.page), [2]);
      expect(events.last.results, {
        0: ['DONE', 'BEFORE'],
        2: ['LAST PAGE'],
      });
    });

    test('nothing to do completes at once', () async {
      final events = await translate(build(), only: const []).toList();
      expect(events, hasLength(1));
      expect(events.single.isComplete, isTrue);
    });

    test('a page that cannot be rendered fails, the others go on', () async {
      pages.renderErrors[0] = const PdfRenderException(page: 0);
      final last = (await translate(build()).toList()).last;
      expect(last.failures.keys, [0]);
      expect(last.failures[0], isA<PdfRenderException>());
      expect(last.results.keys, [1, 2]);
      expect(last.isComplete, isTrue);
    });

    test('missing recognition data stops the run', () async {
      recognizer.errorsByWidth[FakePdfPages.widthOf(0)] =
          const OcrDataMissingException(germanOcr);
      final last = (await translate(build()).toList()).last;
      expect(last.failures, {0: const OcrDataMissingException(germanOcr)});
      expect(pages.renders, hasLength(1));
      expect(last.results, isEmpty);
      expect(last.isComplete, isTrue);
    });

    test('a request the privacy settings stop stops the run', () async {
      const consent = ConsentRequiredException(
        kind: ConsentKind.pair,
        destination: PublicInstanceDestination(
          'mozhi.example',
          engine: 'google',
        ),
        engineId: 'mozhi:google',
      );
      stubTranslate(repository, respond: (_) => Stream.error(consent));
      final last = (await translate(build()).toList()).last;
      expect(last.failures, {0: consent});
      // Not read any further before the user is asked.
      expect(pages.renders, hasLength(1));
      expect(last.partial, {0: <int, List<String>>{}});
    });

    test('stops after pages failing in a row', () async {
      stubTranslate(
        repository,
        respond: (_) =>
            Stream.error(const LlmApiException('bad', statusCode: 400)),
      );
      textOf[1] = ['Middle'];
      final last = (await translate(
        build(maxFailedPagesInARow: 2),
      ).toList()).last;
      expect(last.failures.keys, [0, 1]);
      expect(pages.renders, hasLength(2));
      expect(last.isComplete, isTrue);
    });

    test('a page that failed half-way resumes with its other chunks', () async {
      // Two chunks: the second paragraph does not fit with the first.
      textOf[0] = ['A' * 1000, 'B' * 1000];
      var calls = 0;
      stubTranslate(
        repository,
        respond: (request) => ++calls == 2
            ? Stream.error(const LlmApiException('bad', statusCode: 400))
            : Stream.value(result(request.text.toLowerCase())),
      );
      final translator = build();
      final failed = (await translate(
        translator,
        only: const [0],
      ).toList()).last;
      expect(failed.failures.keys, [0]);
      expect(failed.partial[0], {
        0: ['a' * 1000],
      });
      requests.clear();
      stubTranslate(repository, requests: requests);
      final resumed = (await translate(
        translator,
        known: failed.pages,
        partial: failed.partial,
        only: const [0],
      ).toList()).last;
      expect(requests.single.text, 'B' * 1000);
      expect(resumed.results[0], ['a' * 1000, 'B' * 1000]);
      expect(resumed.partial, isEmpty);
    });

    test('a page read again drops its half-done chunks', () async {
      final last = (await translate(
        build(),
        codes: const ['deu'],
        known: {
          0: PdfPageText(
            page: 0,
            size: pages.pageSizes[0],
            codes: const ['eng'],
          ),
        },
        partial: const {
          0: {
            0: ['old'],
          },
        },
        only: const [0],
      ).toList()).last;
      expect(last.results[0], ['HELLO', 'WORLD']);
      expect(last.partial, isEmpty);
    });

    test('cancelling stops reading and the requests', () async {
      final translating = Completer<void>();
      var cancelled = false;
      stubTranslate(
        repository,
        respond: (request) {
          translating.complete();
          late final StreamController<TranslationResult> controller;
          controller = StreamController(onCancel: () => cancelled = true);
          return controller.stream;
        },
      );
      final events = <PdfProgress>[];
      final subscription = translate(build()).listen(events.add);
      await translating.future;
      await subscription.cancel();
      await pumpEventQueue();
      expect(cancelled, isTrue);
      expect(events.last.stage, PdfStage.translating);
      expect(events.any((e) => e.isComplete), isFalse);
      expect(pages.renders, hasLength(1));
    });

    test('cancelling while a page is read ignores it', () async {
      final gate = pages.renderGate = Completer<void>();
      final events = <PdfProgress>[];
      final subscription = translate(build()).listen(events.add);
      await pumpEventQueue();
      expect(events.last.stage, PdfStage.reading);
      await subscription.cancel();
      gate.complete();
      await pumpEventQueue();
      expect(events.last.stage, PdfStage.reading);
      expect(requests, isEmpty);

      // A failed read after cancelling is ignored too.
      pages
        ..renderGate = Completer<void>()
        ..renderErrors[0] = const PdfRenderException(page: 0);
      final more = <PdfProgress>[];
      final again = translate(build()).listen(more.add);
      await pumpEventQueue();
      await again.cancel();
      pages.renderGate!.complete();
      await pumpEventQueue();
      expect(more.last.failures, isEmpty);
    });

    test('waits while on-device AI pauses, then goes on', () async {
      // A paused engine answers late: the page waits, nothing fails.
      final resume = Completer<void>();
      stubTranslate(
        repository,
        respond: (request) async* {
          await resume.future;
          yield result(request.text.toUpperCase());
        },
      );
      final events = <PdfProgress>[];
      final done = translate(build(), only: const [0]).listen(events.add);
      addTearDown(done.cancel);
      await pumpEventQueue();
      expect(events.last.page, 0);
      expect(events.last.stage, PdfStage.translating);
      resume.complete();
      await done.asFuture<void>();
      expect(events.last.isComplete, isTrue);
      expect(events.last.results[0], ['HELLO', 'WORLD']);
      expect(events.last.failures, isEmpty);
    });

    test('counts the personal data kept on the device', () async {
      stubTranslate(
        repository,
        respond: (request) => Stream.value(
          TranslationResult(
            engineId: 'mozhi:google',
            engineName: 'Google',
            text: request.text,
            maskedPersonalData: 2,
          ),
        ),
      );
      final last = (await translate(build()).toList()).last;
      expect(last.maskedPersonalData, 4);
    });

    test('progress compares by value', () {
      expect(const PdfProgress(total: 1), const PdfProgress(total: 1));
      expect(
        const PdfProgress(total: 1),
        isNot(const PdfProgress(total: 1, isComplete: true)),
      );
    });
  });

  group('PdfTranslator text layers (Android 15+)', () {
    /// A text layer with [text] in one line.
    List<PdfTextLine> layer(String text) => [
      PdfTextLine(text: text, rect: const Rect.fromLTRB(72, 72, 400, 84)),
    ];

    const fromTheFile = 'Exactly the text of the file';

    test(
      'pages with a text layer are not recognised, the others are',
      () async {
        pages
          ..textLayers[0] = layer(fromTheFile)
          // Too little text: recognised.
          ..textLayers[2] = layer('2');
        final events = await translate(build()).toList();
        final last = events.last;
        expect(last.failures, isEmpty);
        expect(last.results, {
          0: [fromTheFile.toUpperCase()],
          1: <String>[],
          2: ['LAST PAGE'],
        });
        expect(last.pages[0]!.fromTextLayer, isTrue);
        expect(last.pages[2]!.fromTextLayer, isFalse);
        // Only pages 1 and 2 went through text recognition.
        expect(recognizer.reads.map((read) => read.width), [
          FakePdfPages.widthOf(1),
          FakePdfPages.widthOf(2),
        ]);
        expect(pages.renders.map((render) => render.maxPixels), [
          // Letter at 144 dpi, for the colours only.
          1224 * 1584,
          PdfLimits.maxPixels,
          PdfLimits.maxPixels,
        ]);
        expect(
          [for (final request in requests) request.text],
          [fromTheFile, 'Last page'],
        );
        expect(
          [for (final e in events) (e.page, e.stage)],
          containsAllInOrder([
            (0, PdfStage.reading),
            (0, PdfStage.translating),
            (1, PdfStage.reading),
          ]),
        );
      },
    );

    test('a page from its text layer is reused with any data', () async {
      pages.textLayers[0] = layer(fromTheFile);
      final translator = build();
      final first = await translator.read(0, pages.pageSizes[0], const []);
      final last = (await translate(
        translator,
        codes: const ['eng', 'deu'],
        known: {0: first},
        only: const [0],
      ).toList()).last;
      expect(last.pages[0], same(first));
      expect(last.results[0], [fromTheFile.toUpperCase()]);
    });

    test('plan needs no data when the first pages have a text layer', () async {
      pages.textLayers[1] = layer(fromTheFile);
      final translator = build();
      // Not open: nothing to probe.
      expect(
        await translator.plan(german),
        const TextRecognitionNeedsData(OcrDataMissingException(germanOcr)),
      );
      await translator.open(pdfBytes);
      expect(await translator.plan(german), const TextRecognitionReady([]));
      expect(await translator.plan(french), const TextRecognitionReady([]));
      // Probed once per PDF.
      expect(pages.textReads, [0, 1]);
      // Installed data is used for the pages without one.
      expect(
        await translator.plan(english),
        const TextRecognitionReady(['eng']),
      );
      expect(translator.canRead, isTrue);

      // Reopened: probed again.
      pages.textLayers
        ..clear()
        ..[0] = const [];
      await translator.open(pdfBytes);
      expect(
        await translator.plan(german),
        const TextRecognitionNeedsData(OcrDataMissingException(germanOcr)),
      );
      expect(pages.textReads, [0, 1, 0, 1, 2]);
    });

    test('only the first pages are probed', () async {
      pages
        ..pageSizes = List.filled(5, const Size(612, 792))
        ..textLayers[4] = layer(fromTheFile);
      final translator = build();
      await translator.open(pdfBytes);
      expect(await translator.plan(french), const TextRecognitionUnsupported());
      expect(pages.textReads, [0, 1, 2]);
      await translator.close();
      expect(await translator.plan(french), const TextRecognitionUnsupported());
    });

    test('without data a page without a text layer asks for it', () async {
      pages.textLayers[0] = layer(fromTheFile);
      final translator = build();
      await translator.open(pdfBytes);
      expect(await translator.plan(german), const TextRecognitionReady([]));
      expect(
        (await translator.read(0, pages.pageSizes[0], const [])).fromTextLayer,
        isTrue,
      );
      await expectLater(
        translator.read(1, pages.pageSizes[1], const []),
        throwsA(const OcrDataMissingException(germanOcr)),
      );
      // A language no data reads: the page cannot be read.
      expect(await translator.plan(french), const TextRecognitionReady([]));
      await expectLater(
        translator.read(1, pages.pageSizes[1], const []),
        throwsA(
          const ImageTranslateException(
            ImageTranslateErrorKind.recognitionFailed,
          ),
        ),
      );
      expect(recognizer.reads, isEmpty);
    });

    test('a run without data stops at the first page without one', () async {
      pages
        ..textLayers[0] = layer(fromTheFile)
        ..textLayers[2] = layer('The last page has its text too');
      final translator = build();
      await translator.open(pdfBytes);
      expect(await translator.plan(german), const TextRecognitionReady([]));
      final last = (await translate(translator, codes: const []).toList()).last;
      expect(last.results, {
        0: [fromTheFile.toUpperCase()],
      });
      expect(last.failures, {1: const OcrDataMissingException(germanOcr)});
      expect(recognizer.reads, isEmpty);
      expect(last.isComplete, isTrue);
    });

    test(
      'a page the language has no data for fails, the run goes on',
      () async {
        pages
          ..textLayers[0] = layer(fromTheFile)
          ..textLayers[2] = layer('The last page has its text too');
        final translator = build();
        await translator.open(pdfBytes);
        expect(await translator.plan(french), const TextRecognitionReady([]));
        final last = (await translate(
          translator,
          codes: const [],
        ).toList()).last;
        expect(last.results.keys, [0, 2]);
        expect(last.failures[1], isA<ImageTranslateException>());
      },
    );

    test('a text layer is read without raw-pixel recognition', () async {
      pages.textLayers[0] = layer(fromTheFile);
      final translator = build(withRecognizer: _PhotoOnlyRecognizer());
      await translator.open(pdfBytes);
      expect(translator.canRead, isFalse);
      // No language data: unsupported, but the text layer reads it.
      expect(await translator.plan(english), const TextRecognitionReady([]));
      expect(translator.canRead, isTrue);
      expect(
        (await translator.read(0, pages.pageSizes[0], ['eng'])).fromTextLayer,
        isTrue,
      );
    });
  });

  group('PdfTranslator while the phone is hot', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    late StreamController<Object?> pushes;
    late DeviceConditions conditions;

    setUp(() async {
      pushes = StreamController<Object?>();
      // Listening (changes) before anything is asked: pushes only.
      conditions = DeviceConditions(
        channel: const MethodChannel('test/device_conditions'),
        isAndroid: true,
        events: pushes.stream,
      )..changes.listen((_) {});
      pushes.add({'thermal': 3, 'powerSave': false});
      await pumpEventQueue();
      expect(conditions.latest.thermal, ThermalStatus.severe);
    });

    tearDown(() async {
      await conditions.dispose();
      await pushes.close();
    });

    test('text recognition waits until it cooled down', () async {
      final events = <PdfProgress>[];
      final run = translate(
        build(conditions: conditions),
        only: const [0],
      ).listen(events.add);
      addTearDown(run.cancel);
      await pumpEventQueue();
      expect(events.last.page, 0);
      expect(events.last.stage, PdfStage.cooling);
      expect(recognizer.reads, isEmpty);
      // Still hot: still waiting.
      pushes.add({'thermal': 4, 'powerSave': false});
      await pumpEventQueue();
      expect(events.last.stage, PdfStage.cooling);

      pushes.add({'thermal': 1, 'powerSave': false});
      await run.asFuture<void>();
      expect(
        [for (final e in events) (e.page, e.stage)],
        containsAllInOrder([
          (0, PdfStage.reading),
          (0, PdfStage.cooling),
          (0, PdfStage.reading),
          (0, PdfStage.translating),
        ]),
      );
      expect(recognizer.reads, hasLength(1));
      expect(events.last.results[0], ['HELLO', 'WORLD']);
    });

    test('looks again every coolingCheck', () async {
      final events = <PdfProgress>[];
      final run = translate(
        build(
          conditions: conditions,
          coolingCheck: const Duration(milliseconds: 1),
        ),
        only: const [0],
      ).listen(events.add);
      addTearDown(run.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(events.last.stage, PdfStage.cooling);
      // A change that does not wake the run; the next look sees it.
      pushes.add({'thermal': 2, 'powerSave': true});
      await run.asFuture<void>();
      expect(events.last.isComplete, isTrue);
    });

    test('reading a text layer never waits', () async {
      pages.textLayers[0] = [
        const PdfTextLine(
          text: 'The text layer of this page',
          rect: Rect.fromLTRB(72, 72, 400, 84),
        ),
      ];
      final events = await translate(
        build(conditions: conditions),
        only: const [0],
      ).toList();
      expect(events.map((e) => e.stage), isNot(contains(PdfStage.cooling)));
      expect(events.last.results[0], ['THE TEXT LAYER OF THIS PAGE']);
    });

    test('cancelling stops the wait', () async {
      final events = <PdfProgress>[];
      final run = translate(
        build(conditions: conditions),
        only: const [0],
      ).listen(events.add);
      await pumpEventQueue();
      expect(events.last.stage, PdfStage.cooling);
      await run.cancel();
      pushes.add({'thermal': 0, 'powerSave': false});
      await pumpEventQueue();
      expect(events.last.stage, PdfStage.cooling);
      expect(recognizer.reads, isEmpty);
    });
  });

  group('PdfTranslator.write', () {
    const output = [PdfOutputPage(sourcePage: 0, size: Size(612, 792))];

    test('writes to a private file and returns its bytes', () async {
      final bytes = await build().write(output);
      expect(bytes, pages.written);
      expect(pages.writes.single.pages, output);
      expect(pages.writes.single.path, startsWith('/cache/pdf_pages/'));
      expect(scratch.files, isEmpty);
    });

    test('fails with PdfWriteException and leaves no file', () async {
      pages.writeError = const PdfWriteException(cause: 'io');
      await expectLater(
        build().write(output),
        throwsA(isA<PdfWriteException>().having((e) => e.cause, 'cause', 'io')),
      );
      pages
        ..writeError = null
        ..scratch = null;
      // Written but not found: wrapped.
      await expectLater(
        build().write(output),
        throwsA(
          isA<PdfWriteException>().having(
            (e) => e.cause,
            'cause',
            isStateError,
          ),
        ),
      );
      expect(scratch.files, isEmpty);
    });

    test('close closes the PDF', () async {
      await build().close();
      expect(pages.closes, 1);
    });
  });
}
