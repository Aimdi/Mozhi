// XML fixtures are written as adjacent string literals.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/core/office/office.dart';
import 'package:mozhi/documents/documents.dart';
import 'package:translation_repository/translation_repository.dart';

import '../core/office/office_fixtures.dart';
import '../helpers/fakes.dart';

void main() {
  late MockTranslationRepository repository;
  late FakeDocumentFileService files;
  late List<TranslationRequest> requests;

  setUpAll(registerDocumentFallbacks);

  setUp(() {
    repository = MockTranslationRepository();
    files = FakeDocumentFileService();
    requests = [];
    stubTranslate(repository, requests: requests);
    stubLanguages(repository);
  });

  DocumentTranslateCubit build({
    Language target = german,
    int maxPackageBytes = DocumentTranslateCubitDefaults.maxPackageBytes,
    int backgroundBytes = DocumentTranslateCubitDefaults.backgroundBytes,
    TextDocumentParser parser = parseDocument,
  }) {
    final cubit = DocumentTranslateCubit(
      repository: repository,
      files: files,
      translator: DocumentTranslator(
        repository: repository,
        maxAttempts: 1,
        retryDelay: Duration.zero,
      ),
      maxPackageBytes: maxPackageBytes,
      backgroundBytes: backgroundBytes,
      parser: parser,
      engines: const [googleEngine, deeplEngine, aiEngine],
      engine: googleEngine,
      sourceLanguages: sourceLanguages,
      targetLanguages: targetLanguages,
      target: target,
    );
    addTearDown(cubit.close);
    return cubit;
  }

  final report = docx(
    '<w:p><w:r><w:t>Hello world</w:t></w:r></w:p>'
    '<w:p><w:r><w:t xml:space="preserve">Read </w:t></w:r>'
    '<w:r><w:rPr><w:b/></w:rPr><w:t>this</w:t></w:r></w:p>',
  );

  String? languageOf(DocumentTranslateCubit cubit) =>
      (cubit.state.packagedDocument! as OfficePackage).language?.bcp47;

  group('DocumentTranslateCubit with office documents', () {
    test('loads a DOCX as bytes and shows its text', () {
      final cubit = build()..loadFile('report.docx', report);
      final state = cubit.state;
      expect(state.status, DocumentStatus.ready);
      expect(state.format, DocumentFormat.docx);
      expect(state.isBinary, isTrue);
      expect(state.hasDocument, isTrue);
      expect(state.document, isNull);
      expect(state.packagedDocument, isNotNull);
      expect(state.text, 'Hello world\n\nRead this');
      expect(state.segmentCount, 2);
      expect(
        state.characterCount,
        'Hello world'.length + 'Read ⟨1⟩this⟨2⟩'.length,
      );
      expect(state.chunkCount, 1);
      expect(state.plan!.chunks.single.encoding, ChunkEncoding.paragraphs);
      expect(state.supportsBilingual, isFalse);
      expect(state.outputFileName, 'report.de.docx');
      expect(state.segmentSource(1), 'Read this');
      expect(state.segmentOutput(1, 'Lies ⟨1⟩das⟨2⟩'), 'Lies das');
      expect(state.canTranslate, isTrue);
      expect(languageOf(cubit), 'de');
    });

    test('translates, previews and saves the same format', () async {
      final cubit = build()..loadFile('report.en.docx', report);
      await cubit.translate();
      final state = cubit.state;
      expect(state.status, DocumentStatus.translated);
      expect(state.isComplete, isTrue);
      expect(state.translations, ['HELLO WORLD', 'READ ⟨1⟩THIS⟨2⟩']);
      expect(state.output, 'HELLO WORLD\n\nREAD THIS');
      expect(requests.single.text, 'Hello world\n\nRead ⟨1⟩this⟨2⟩');

      final bytes = cubit.outputBytes;
      expect(entryText(bytes, 'word/document.xml'), contains('HELLO WORLD'));
      expect(
        entryText(bytes, 'word/document.xml'),
        contains(
          '<w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">THIS</w:t>'
          '</w:r>',
        ),
      );

      await cubit.save();
      final saved = files.saved.single;
      expect(saved.fileName, 'report.de.docx');
      expect(saved.mimeType, DocumentFormat.docx.mimeType);
      expect(saved.bytes, bytes);
      expect(cubit.state.notice, DocumentNotice.saved);

      await cubit.share();
      expect(files.shared.single.fileName, 'report.de.docx');
      expect(files.shared.single.mimeType, DocumentFormat.docx.mimeType);
      expect(textsOf(parsePackagedDocument(files.shared.single.bytes, .docx)), [
        'HELLO WORLD',
        'READ ⟨1⟩THIS⟨2⟩',
      ]);

      await cubit.copy();
      expect(files.copied.single, 'HELLO WORLD\n\nREAD THIS');
    });

    test('reports files it cannot read', () {
      final cubit = build(maxPackageBytes: 100)..loadFile('big.docx', report);
      expect(cubit.state.error, DocumentError.tooLarge);
      expect(cubit.state.format, DocumentFormat.docx);
      expect(cubit.state.isBinary, isTrue);

      final other = build()..loadFile('broken.docx', Uint8List(10));
      expect(other.state.error, DocumentError.damagedFile);
      expect(other.state.hasDocument, isFalse);
      expect(other.state.status, DocumentStatus.empty);

      other.loadFile(
        'locked.odt',
        odf(
          'text',
          '<office:text><text:p>x</text:p></office:text>',
          manifestExtra: '<manifest:encryption-data/>',
        ),
      );
      expect(other.state.error, DocumentError.encrypted);

      other.loadFile('evil.docx', docx('<w:p/>', extra: {'../evil': 'x'}));
      expect(other.state.error, DocumentError.unsafeFile);

      other.loadFile(
        'numbers.docx',
        docx('<w:p><w:r><w:t>42</w:t></w:r></w:p>'),
      );
      expect(other.state.error, DocumentError.nothingToTranslate);
      expect(other.state.canTranslate, isFalse);
    });

    test('office documents keep their format and are never pasted', () {
      final cubit = build()
        ..loadFile('report.docx', report)
        ..setFormat(DocumentFormat.plainText)
        ..setFormat(DocumentFormat.pptx);
      expect(cubit.state.format, DocumentFormat.docx);

      cubit
        ..setText('Pasted text')
        ..setFormat(DocumentFormat.docx);
      expect(cubit.state.format, DocumentFormat.plainText);
      expect(cubit.state.isBinary, isFalse);

      // Back in file mode the document is there again.
      cubit.setMode(DocumentInputMode.file);
      expect(cubit.state.format, DocumentFormat.docx);
      expect(cubit.state.segmentCount, 2);
      expect(cubit.state.fileName, 'report.docx');
    });

    test('a new target language is written into the document', () async {
      final cubit = build()..loadFile('report.docx', report);
      expect(languageOf(cubit), 'de');
      cubit.setTarget(spanish);
      expect(languageOf(cubit), 'es');
      await cubit.translate();
      expect(
        entryText(cubit.outputBytes, 'docProps/core.xml'),
        contains('<dc:language>es-ES</dc:language>'),
      );

      // Custom AI "languages" leave the language as it is.
      cubit.setTarget(const Language.custom('Pirate speak'));
      expect(languageOf(cubit), isNull);
      cubit
        ..setTarget(spanish)
        ..setTarget(spanish);
      expect(languageOf(cubit), 'es');

      // Changed in text mode, the file follows when it is shown again.
      cubit
        ..setMode(DocumentInputMode.text)
        ..setText('Text')
        ..setSource(english)
        ..swapLanguages()
        ..setMode(DocumentInputMode.file);
      expect(cubit.state.target, english);
      expect(languageOf(cubit), 'en');

      await cubit.selectEngine(deeplEngine);
      expect(cubit.state.target, english);
      cubit.syncEngines(
        engines: const [googleEngine],
        engine: googleEngine,
        target: german,
      );
      expect(languageOf(cubit), 'de');
    });

    group('in the background', () {
      test('large files are parsed and rendered in an isolate', () async {
        final cubit = build(backgroundBytes: 0)
          ..loadFile('report.docx', report);
        expect(cubit.state.status, DocumentStatus.loading);
        expect(cubit.state.fileName, 'report.docx');
        expect(cubit.state.format, DocumentFormat.docx);
        final ready = await cubit.stream.firstWhere(
          (state) => state.status == DocumentStatus.ready,
        );
        expect(ready.segmentCount, 2);
        await cubit.translate();
        await cubit.save();
        expect(
          entryText(files.saved.single.bytes, 'word/document.xml'),
          contains('HELLO WORLD'),
        );
      });

      test('errors are reported', () async {
        final cubit = build(backgroundBytes: 0)
          ..loadFile('broken.xlsx', Uint8List(50));
        final failed = await cubit.stream.firstWhere(
          (state) => state.status != DocumentStatus.loading,
        );
        expect(failed.error, DocumentError.damagedFile);
        expect(failed.hasDocument, isFalse);
      });

      test('a file replaced or removed meanwhile is ignored', () async {
        final cubit = build(backgroundBytes: 0)
          ..loadFile('a.docx', report)
          ..clear();
        expect(cubit.state.hasDocument, isFalse);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(cubit.state.hasDocument, isFalse);
        expect(cubit.state.status, DocumentStatus.empty);
      });

      test('pasting text meanwhile keeps the file for the file mode', () async {
        final cubit = build(backgroundBytes: 0)
          ..loadFile('a.docx', report)
          ..setText('Pasted');
        expect(cubit.state.mode, DocumentInputMode.text);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(cubit.state.text, 'Pasted');
        cubit.setMode(DocumentInputMode.file);
        expect(cubit.state.fileName, 'a.docx');
        expect(cubit.state.segmentCount, 2);
      });
    });

    test('closing while a file is read in the background', () async {
      final cubit = build(backgroundBytes: 0)..loadFile('a.docx', report);
      await cubit.close();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(cubit.isClosed, isTrue);
    });
  });

  group('DocumentTranslateCubit target languages of text formats', () {
    late List<(DocumentFormat, String?)> parsed;

    ParsedDocument fakeParser(
      String text,
      DocumentFormat format, {
      String? targetLanguage,
    }) {
      parsed.add((format, targetLanguage));
      if (text.contains('bad')) throw const DocumentParseException('bad');
      return parsePlainText(text);
    }

    setUp(() => parsed = []);

    test('formats that record the target are parsed again for it', () {
      final cubit = build(parser: fakeParser)
        ..loadFile('app.po', bytesOf('Hello'));
      expect(parsed, [(DocumentFormat.po, 'de')]);
      cubit.setTarget(spanish);
      expect(parsed.last, (DocumentFormat.po, 'es'));
      expect(cubit.state.segmentCount, 1);
      // The same target again: nothing to do.
      cubit.syncEngines(engines: const [googleEngine], engine: googleEngine);
      expect(parsed, hasLength(2));
      cubit.setTarget(const Language.custom('Pirate'));
      expect(parsed.last, (DocumentFormat.po, null));
    });

    test('other formats are parsed once', () {
      build(parser: fakeParser)
        ..loadFile('notes.txt', bytesOf('Hello'))
        ..setTarget(spanish);
      expect(parsed, [(DocumentFormat.plainText, 'de')]);
    });

    test('a target the document cannot take keeps the document', () {
      var fail = false;
      ParsedDocument parser(
        String text,
        DocumentFormat format, {
        String? targetLanguage,
      }) {
        if (fail) throw StateError('parser bug');
        return parsePlainText(text);
      }

      final cubit = build(parser: parser)..loadFile('a.xlf', bytesOf('Hello'));
      final document = cubit.state.document;
      fail = true;
      cubit.setTarget(spanish);
      expect(cubit.state.document, same(document));
      expect(cubit.state.target, spanish);
    });

    test('invalid text is reported for its format', () {
      final cubit = build(parser: fakeParser)
        ..loadFile('bad.po', bytesOf('bad'));
      expect(cubit.state.error, DocumentError.invalidFormat);
      cubit.loadFile('bad.json', bytesOf('bad'));
      expect(cubit.state.error, DocumentError.invalidJson);
    });
  });
}
