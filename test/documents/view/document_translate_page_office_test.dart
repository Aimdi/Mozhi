// XML fixtures are written as adjacent string literals.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'dart:math';
import 'dart:typed_data';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/documents/documents.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';

import '../core/office/office_fixtures.dart';
import '../helpers/fakes.dart';

void main() {
  late MockTranslateCubit translateCubit;
  late MockTranslationRepository repository;
  late FakeDocumentFileService files;

  setUpAll(registerDocumentFallbacks);

  setUp(() {
    translateCubit = MockTranslateCubit();
    repository = MockTranslationRepository();
    files = FakeDocumentFileService();
    stubTranslate(repository);
    stubLanguages(repository);
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    Size size = const Size(600, 3000),
    PickedFile? initialFile,
  }) async {
    setSurface(tester, size);
    whenListen(
      translateCubit,
      const Stream<TranslateState>.empty(),
      initialState: readyTranslateState,
    );
    await tester.pumpDocuments(
      translateCubit: translateCubit,
      repository: repository,
      files: files,
      initialFile: initialFile,
      translator: DocumentTranslator(
        repository: repository,
        maxAttempts: 1,
        retryDelay: Duration.zero,
      ),
    );
  }

  DocumentTranslateCubit cubitOf(WidgetTester tester) =>
      tester.element(find.byType(DocumentTranslateView)).read();

  Future<void> pick(WidgetTester tester, String name, Uint8List bytes) async {
    files.pickResult = PickedFile(name: name, bytes: bytes);
    final pickButton = find.byKey(const Key('documents_pick_file'));
    await tester.tap(
      pickButton.evaluate().isEmpty
          ? find.byKey(const Key('documents_replace_file'))
          : pickButton,
    );
    await tester.pumpAndSettle();
  }

  final report = docx(
    '<w:p><w:r><w:t>Hello world</w:t></w:r></w:p>'
    '<w:p><w:r><w:t xml:space="preserve">Read </w:t></w:r>'
    '<w:r><w:rPr><w:b/></w:rPr><w:t>this</w:t></w:r></w:p>',
  );

  group('DocumentTranslatePage with office documents', () {
    testWidgets('picks, translates and saves a Word document', (tester) async {
      await pumpPage(tester);
      expect(
        // PDFs too, in the Android app (W7-B).
        find.textContaining(
          'Word, PowerPoint, Excel, OpenDocument, EPUB and PDF',
        ),
        findsOneWidget,
      );
      await pick(tester, 'report.docx', report);

      expect(find.text('report.docx'), findsOneWidget);
      expect(find.text('Word document (DOCX)'), findsOneWidget);
      // The format of an office document can't be changed.
      expect(
        tester.widget(find.byKey(const Key('documents_format'))),
        isA<Chip>(),
      );
      expect(find.text('2 segments'), findsOneWidget);
      expect(
        find.byKey(const Key('documents_preview_text_only')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('documents_keeps_macros')), findsNothing);
      expect(find.textContaining('Hello world\n\nRead this'), findsOneWidget);

      await tester.tap(find.byKey(const Key('documents_translate')));
      await tester.pumpAndSettle();
      expect(find.text('Translation complete'), findsOneWidget);
      expect(find.textContaining('HELLO WORLD\n\nREAD THIS'), findsOneWidget);
      expect(find.byKey(const Key('documents_bilingual')), findsNothing);
      expect(find.text('File name: report.de.docx'), findsOneWidget);

      await tester.tap(find.byKey(const Key('documents_save')));
      await tester.pumpAndSettle();
      expect(find.text('File saved'), findsOneWidget);
      final saved = files.saved.single;
      expect(saved.fileName, 'report.de.docx');
      expect(saved.mimeType, DocumentFormat.docx.mimeType);
      expect(entryText(saved.bytes, 'word/document.xml'), contains('HELLO'));
    });

    testWidgets('explains files it cannot read', (tester) async {
      await pumpPage(tester);
      await pick(tester, 'broken.pptx', Uint8List.fromList([1, 2, 3]));
      expect(
        find.text(
          "This file is damaged, or it isn't really a PowerPoint "
          'presentation (PPTX).',
        ),
        findsOneWidget,
      );

      await pick(
        tester,
        'locked.odt',
        odf(
          'text',
          '<office:text><text:p>x</text:p></office:text>',
          manifestExtra: '<manifest:encryption-data/>',
        ),
      );
      expect(
        find.text(
          'This document is password-protected or has DRM. Remove the '
          'protection and try again.',
        ),
        findsOneWidget,
      );

      await pick(tester, 'evil.docx', docx('<w:p/>', extra: {'/x': 'y'}));
      expect(find.textContaining('keep your device safe'), findsOneWidget);

      cubitOf(tester).loadFile(
        'huge.epub',
        Uint8List(DocumentTranslateCubitDefaults.maxPackageBytes + 1),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('This file is too large. The limit is 25 MB.'),
        findsOneWidget,
      );

      await pick(tester, 'bad.xliff', bytesOf('<xliff'));
      expect(find.textContaining("can't be read as XLIFF"), findsOneWidget);
    });

    testWidgets('pasted text offers only text formats', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text('Text'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('documents_text_field')),
        'Some text',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('documents_format')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('documents_format_markdown')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('documents_format_docx')), findsNothing);
      expect(find.byKey(const Key('documents_format_epub')), findsNothing);
    });

    testWidgets('large documents are read in the background', (tester) async {
      final random = Random(1);
      final large = docx(
        '<w:p><w:r><w:t>Big document</w:t></w:r></w:p>',
        extra: {
          'word/media/photo.bin': Uint8List.fromList(
            List.generate(300 * 1024, (_) => random.nextInt(256)),
          ),
        },
      );
      await pumpPage(
        tester,
        initialFile: PickedFile(name: 'big.docx', bytes: large),
      );
      expect(find.byKey(const Key('documents_reading')), findsOneWidget);
      expect(find.text('Reading the document…'), findsOneWidget);
      expect(cubitOf(tester).state.status, DocumentStatus.loading);

      // The isolate answers in real time; a pump delivers the result.
      for (var i = 0; i < 100; i++) {
        if (cubitOf(tester).state.status != DocumentStatus.loading) break;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('documents_reading')), findsNothing);
      expect(find.text('1 segment'), findsOneWidget);
    });

    testWidgets('documents with macros say the translation keeps them', (
      tester,
    ) async {
      final macros = docx(
        '<w:p><w:r><w:t>Hello world</w:t></w:r></w:p>',
        extra: {'word/vbaProject.bin': 'VBA'},
      );
      await pumpPage(
        tester,
        initialFile: PickedFile(name: 'macros.docx', bytes: macros),
      );
      expect(find.byKey(const Key('documents_keeps_macros')), findsOneWidget);
      expect(
        find.text(
          'This document contains macros or ActiveX controls: the '
          'translated file keeps them as they are.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('wide layout lists the text of each segment', (tester) async {
      await pumpPage(
        tester,
        size: const Size(1200, 900),
        initialFile: PickedFile(name: 'report.docx', bytes: report),
      );
      expect(find.byKey(const Key('documents_side_by_side')), findsOneWidget);
      expect(
        find.byKey(const Key('documents_preview_text_only')),
        findsOneWidget,
      );
      expect(find.text('Read this'), findsOneWidget);
      await tester.tap(find.byKey(const Key('documents_translate')));
      await tester.pumpAndSettle();
      expect(find.text('READ THIS'), findsOneWidget);
    });
  });
}
