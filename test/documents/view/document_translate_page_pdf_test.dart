import 'dart:async';
import 'dart:convert';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/documents/documents.dart';
import 'package:mozhi/documents/pdf/pdf.dart';
import 'package:mozhi/documents/widgets/widgets.dart'
    show documentPdfProgressLabel;
import 'package:mozhi/image_translate/widgets/ocr_language_offer.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/on_device_ai/view/on_device_ai_paused_notice.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers/helpers.dart';
import '../helpers/fakes.dart';
import '../pdf/pdf_fakes.dart';

void main() {
  late MockTranslateCubit translateCubit;
  late MockTranslationRepository repository;
  late FakeDocumentFileService files;
  late FakePdfScratch scratch;
  late FakePdfPages pages;
  late FakePdfRecognizer recognizer;
  late Map<int, List<String>> textOf;

  setUpAll(registerDocumentFallbacks);

  setUp(() {
    translateCubit = MockTranslateCubit();
    repository = MockTranslationRepository();
    files = FakeDocumentFileService();
    stubTranslate(repository);
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

  Future<void> pumpPdf(
    WidgetTester tester, {
    TranslateState state = readyTranslateState,
    Size size = const Size(600, 3000),
    bool open = true,
    bool settle = true,
    SettingsCubit? settings,
  }) async {
    setSurface(tester, size);
    whenListen(
      translateCubit,
      const Stream<TranslateState>.empty(),
      initialState: state,
    );
    final translator = DocumentTranslator(
      repository: repository,
      maxAttempts: 1,
      retryDelay: Duration.zero,
    );
    await tester.pumpApp(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<TranslationRepository>.value(value: repository),
          // The offer's "Download over Wi-Fi only".
          RepositoryProvider<KeyValueStore>.value(value: MemoryStore()),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<TranslateCubit>.value(value: translateCubit),
            if (settings != null)
              BlocProvider<SettingsCubit>.value(value: settings),
          ],
          child: DocumentTranslatePage(
            initialFile: open
                ? PickedFile(name: 'scan.pdf', bytes: pdfBytes)
                : null,
            fileService: files,
            translator: translator,
            pdfTranslator: PdfTranslator(
              pages: pages,
              recognizer: recognizer,
              translator: translator,
              scratch: scratch,
            ),
          ),
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      // An indeterminate progress bar never settles.
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
    }
  }

  DocumentTranslateCubit cubitOf(WidgetTester tester) =>
      tester.element(find.byType(DocumentTranslateView)).read();

  Future<void> translate(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('documents_translate')));
    await tester.pumpAndSettle();
  }

  group('DocumentTranslatePage with a PDF', () {
    testWidgets('offers PDFs on Android', (tester) async {
      await pumpPdf(tester, open: false);
      expect(
        find.textContaining('OpenDocument, EPUB and PDF files'),
        findsOneWidget,
      );
    });

    testWidgets('shows its pages and the first page read', (tester) async {
      await pumpPdf(tester);
      expect(find.text('scan.pdf'), findsOneWidget);
      expect(find.text('PDF document'), findsOneWidget);
      expect(find.byIcon(Icons.picture_as_pdf_outlined), findsWidgets);
      expect(find.byKey(const Key('documents_pdf_pages')), findsOneWidget);
      expect(find.text('3 pages'), findsOneWidget);
      // No segment or request counts: the text is read as it translates.
      expect(find.textContaining('segment'), findsNothing);
      expect(find.byKey(const Key('documents_pdf_hint')), findsOneWidget);
      expect(find.text('Page 1'), findsOneWidget);
      expect(find.text('Hello\n\nWorld'), findsOneWidget);
      expect(
        find.text('2 more pages are read when you translate.'),
        findsOneWidget,
      );
      // The office notes are not a PDF's.
      expect(
        find.byKey(const Key('documents_preview_text_only')),
        findsNothing,
      );
    });

    testWidgets('says when the first page has no text', (tester) async {
      textOf = {};
      await pumpPdf(tester);
      expect(
        find.text(
          'No text was found on the first page. The other pages are read '
          'when you translate.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('reading the first page shows progress', (tester) async {
      final gate = pages.renderGate = Completer<void>();
      await pumpPdf(tester, settle: false);
      expect(find.byKey(const Key('documents_pdf_previewing')), findsOneWidget);
      expect(find.text('Reading the first page…'), findsOneWidget);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('documents_pdf_previewing')), findsNothing);
    });

    testWidgets('translates page by page and offers both saves', (
      tester,
    ) async {
      await pumpPdf(tester);
      final gate = pages.renderGate = Completer<void>();
      await tester.tap(find.byKey(const Key('documents_translate')));
      await tester.pump();
      await tester.pump();
      expect(find.text('Page 2 of 3: reading the text…'), findsOneWidget);
      expect(find.byType(OnDeviceAiPausedNotice), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byKey(const Key('documents_progress')),
            )
            .semanticsLabel,
        '1 of 3 pages done',
      );
      pages.renderGate = null;
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Translation complete'), findsOneWidget);
      expect(find.byKey(const Key('documents_save')), findsOneWidget);
      expect(find.byKey(const Key('documents_save_text')), findsOneWidget);
      expect(find.text('Save the text'), findsOneWidget);
      expect(find.text('File name: scan.de.pdf'), findsOneWidget);
      expect(find.text('Text: scan.de.txt'), findsOneWidget);
      // The translation tab, page by page.
      expect(find.text('HELLO\n\nWORLD'), findsOneWidget);
      expect(find.text('LAST PAGE'), findsOneWidget);
      expect(
        find.text('No text was found on this page: it is kept as it is.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Original'));
      await tester.pumpAndSettle();
      expect(find.text('Hello\n\nWorld'), findsOneWidget);
    });

    testWidgets('shows the page being translated', (tester) async {
      final answer = Completer<void>();
      stubTranslate(
        repository,
        respond: (request) async* {
          await answer.future;
          yield result(request.text.toUpperCase());
        },
      );
      final settings = MockSettingsCubit();
      whenListen(
        settings,
        const Stream<AppSettings>.empty(),
        initialState: const AppSettings(),
      );
      await pumpPdf(tester, settings: settings);
      await tester.tap(find.byKey(const Key('documents_translate')));
      await tester.pump();
      await tester.pump();
      expect(find.text('Page 1 of 3: translating…'), findsOneWidget);
      answer.complete();
      await tester.pumpAndSettle();
      expect(find.text('Translation complete'), findsOneWidget);
    });

    test('names the progress between pages', () {
      final l10n = lookupAppLocalizations(const Locale('en'));
      const sizes = [Size(1, 1), Size(1, 1)];
      DocumentTranslateState at(int? page, PdfStage? stage) =>
          DocumentTranslateState(
            pdf: PdfSource(pageSizes: sizes, currentPage: page, stage: stage),
            results: const {
              0: ['A'],
            },
          );
      expect(
        documentPdfProgressLabel(l10n, at(null, null)),
        '1 of 2 pages done',
      );
      expect(
        documentPdfProgressLabel(l10n, at(1, PdfStage.reading)),
        'Page 2 of 2: reading the text…',
      );
      expect(
        documentPdfProgressLabel(l10n, at(1, PdfStage.translating)),
        'Page 2 of 2: translating…',
      );
      expect(
        documentPdfProgressLabel(l10n, at(1, PdfStage.cooling)),
        'Page 2 of 2: the phone is hot, waiting for it to cool down…',
      );
      // A stage without a page names the pages done.
      expect(
        documentPdfProgressLabel(l10n, at(null, PdfStage.reading)),
        '1 of 2 pages done',
      );
    });

    testWidgets('writing the PDF shows progress and saves it', (tester) async {
      await pumpPdf(tester);
      await translate(tester);
      final gate = pages.writeGate = Completer<void>();
      await tester.tap(find.byKey(const Key('documents_save')));
      await tester.pump();
      expect(find.byKey(const Key('documents_pdf_writing')), findsOneWidget);
      expect(find.text('Writing the PDF…'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('documents_save')))
            .onPressed,
        isNull,
      );
      expect(cubitOf(tester).state.canTranslate, isFalse);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('documents_pdf_writing')), findsNothing);
      expect(files.saved.single.fileName, 'scan.de.pdf');
      expect(find.text('File saved'), findsOneWidget);

      await tester.tap(find.byKey(const Key('documents_save_text')));
      await tester.pumpAndSettle();
      final text = files.saved.last;
      expect(text.fileName, 'scan.de.txt');
      expect(
        utf8.decode(text.bytes),
        'Page 1\n\nHELLO\n\nWORLD\n\n\nPage 2\n\n\nPage 3\n\nLAST PAGE',
      );
    });

    testWidgets('lists failed pages with a retry', (tester) async {
      pages.renderErrors[2] = const PdfRenderException(page: 2);
      await pumpPdf(tester);
      await translate(tester);
      expect(find.text('Failed pages'), findsOneWidget);
      expect(find.text('Page 3'), findsWidgets);
      expect(find.text('This page could not be read.'), findsOneWidget);
      expect(find.text("1 page isn't translated yet"), findsOneWidget);
      expect(find.text('Translate missing pages'), findsOneWidget);
      expect(
        find.text('Untranslated pages keep their original text.'),
        findsOneWidget,
      );
      pages.renderErrors.clear();
      await tester.tap(find.byTooltip('Retry page 3'));
      await tester.pumpAndSettle();
      expect(find.text('Failed pages'), findsNothing);
      expect(find.text('Translation complete'), findsOneWidget);
    });

    testWidgets('a failed translation is described', (tester) async {
      stubTranslate(
        repository,
        respond: (_) =>
            Stream.error(const LlmApiException('bad', statusCode: 400)),
      );
      await pumpPdf(tester);
      await translate(tester);
      expect(find.text('Failed pages'), findsOneWidget);
      expect(find.text('Page 1'), findsWidgets);
      expect(find.text('This page could not be read.'), findsNothing);
    });

    testWidgets('offers the recognition data of the source language', (
      tester,
    ) async {
      await pumpPdf(
        tester,
        state: readyTranslateState.copyWith(source: german),
      );
      expect(find.byType(OcrLanguageOffer), findsOneWidget);
      // Downloaded from the offer (the fake installs it): read with it.
      await tester.tap(find.byKey(const Key('image_translate_ocr_download')));
      await tester.pumpAndSettle();
      expect(recognizer.installed.keys, contains('deu'));
      expect(find.byType(OcrLanguageOffer), findsNothing);
      expect(cubitOf(tester).state.pdf!.pages[0]!.codes, ['deu']);
      expect(find.text('Hello\n\nWorld'), findsOneWidget);
    });

    testWidgets('says when the source language cannot be read', (tester) async {
      await pumpPdf(
        tester,
        state: readyTranslateState.copyWith(
          sourceLanguages: [...sourceLanguages, french],
          source: french,
        ),
      );
      expect(
        find.text(
          "Text in French can't be read on this device. Choose the language "
          'of the PDF as the source language.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('says when pages cannot be read at all', (tester) async {
      recognizer.isSupported = false;
      await pumpPdf(tester);
      expect(
        find.text(
          "Text recognition isn't available on this device, so PDF pages "
          "can't be read.",
        ),
        findsOneWidget,
      );
    });

    testWidgets('the first page that cannot be read says so', (tester) async {
      pages.renderErrors[0] = const PdfRenderException(page: 0);
      await pumpPdf(tester);
      expect(find.byKey(const Key('documents_pdf_issue')), findsOneWidget);
      expect(find.text('This page could not be read.'), findsOneWidget);
    });

    group('cannot be opened', () {
      testWidgets('in the web app', (tester) async {
        pages.supported = false;
        await pumpPdf(tester);
        expect(
          find.text(
            'PDF files are translated in the Android app, where their pages '
            'are read on the phone.',
          ),
          findsOneWidget,
        );
      });

      testWidgets('with a password', (tester) async {
        pages.openError = const PdfOpenException(
          kind: PdfOpenErrorKind.encrypted,
        );
        await pumpPdf(tester);
        expect(
          find.textContaining('This PDF is password-protected.'),
          findsOneWidget,
        );
      });

      testWidgets('too long', (tester) async {
        pages.openError = const PdfOpenException(
          kind: PdfOpenErrorKind.tooLarge,
        );
        await pumpPdf(tester);
        expect(
          find.text(
            'This PDF is too large. PDFs of up to 200 pages and 25 MB can be '
            'translated.',
          ),
          findsOneWidget,
        );
      });

      testWidgets('damaged', (tester) async {
        pages.openError = const PdfOpenException(
          kind: PdfOpenErrorKind.damaged,
        );
        await pumpPdf(tester);
        expect(
          find.text("This file is damaged, or it isn't really a PDF document."),
          findsOneWidget,
        );
      });

      testWidgets('without any text', (tester) async {
        textOf = {};
        await pumpPdf(tester);
        await translate(tester);
        expect(find.textContaining('No text was found in this PDF.'), findsOne);
        // A note, not an error.
        expect(find.byIcon(Icons.info_outline), findsOneWidget);
      });
    });

    testWidgets('wide screens show paragraphs side by side', (tester) async {
      await pumpPdf(tester, size: const Size(1200, 1600));
      expect(find.byKey(const Key('documents_pdf_side_by_side')), findsOne);
      expect(find.text('Hello'), findsOneWidget);
      expect(find.text('…'), findsNWidgets(2));
      await translate(tester);
      expect(find.text('HELLO'), findsOneWidget);
      expect(find.text('WORLD'), findsOneWidget);
      expect(find.text('Page 3'), findsOneWidget);
      expect(find.text('LAST PAGE'), findsOneWidget);
    });

    testWidgets('a long PDF previews the first characters', (tester) async {
      pages.pageSizes = List.filled(30, const Size(612, 792));
      textOf = {
        for (var i = 0; i < 30; i++) i: ['Word ' * 200],
      };
      await pumpPdf(tester);
      await translate(tester);
      await tester.tap(find.text('Original'));
      await tester.pumpAndSettle();
      expect(find.textContaining('characters'), findsOneWidget);
    });
  });
}
