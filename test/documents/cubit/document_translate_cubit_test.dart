import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/documents/documents.dart';
import 'package:translation_repository/translation_repository.dart';

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
    TranslationEngine? engine = googleEngine,
    Language source = Language.auto,
    Language target = german,
    int maxBytes = DocumentTranslateCubitDefaults.maxBytes,
    Chunker chunker = const Chunker(),
  }) => DocumentTranslateCubit(
    repository: repository,
    files: files,
    translator: DocumentTranslator(
      repository: repository,
      maxAttempts: 1,
      retryDelay: Duration.zero,
    ),
    chunker: chunker,
    maxBytes: maxBytes,
    engines: const [googleEngine, deeplEngine, aiEngine],
    engine: engine,
    sourceLanguages: sourceLanguages,
    targetLanguages: targetLanguages,
    source: source,
    target: target,
  );

  group('DocumentTranslateCubit', () {
    test('starts empty with the given engine and languages', () {
      final cubit = build();
      final state = cubit.state;
      expect(state.status, DocumentStatus.empty);
      expect(state.mode, DocumentInputMode.file);
      expect(state.engine, googleEngine);
      expect(state.engines, hasLength(3));
      expect(state.source, Language.auto);
      expect(state.target, german);
      expect(state.canTranslate, isFalse);
      expect(state.estimate, Duration.zero);
      expect(state.progress, 0);
      expect(cubit.canShareFiles, isTrue);
      addTearDown(cubit.close);
    });

    group('loading', () {
      test('loads and plans a subtitle file', () {
        final cubit = build()..loadFile('movie.en.srt', bytesOf(srtText));
        addTearDown(cubit.close);
        final state = cubit.state;
        expect(state.status, DocumentStatus.ready);
        expect(state.format, DocumentFormat.srt);
        expect(state.fileName, 'movie.en.srt');
        expect(state.sizeBytes, srtText.length);
        expect(state.text, srtText);
        expect(state.segmentCount, 2);
        expect(state.chunkCount, 1);
        expect(state.characterCount, greaterThan(10));
        expect(state.error, isNull);
        expect(state.canTranslate, isTrue);
        expect(state.estimate, const Duration(seconds: 2));
        expect(state.outputFileName, 'movie.de.srt');
        expect(state.supportsBilingual, isTrue);
      });

      test('reports unsupported, oversized and binary files', () {
        final cubit = build(maxBytes: 100);
        addTearDown(cubit.close);

        cubit.loadFile('image.png', Uint8List(4));
        expect(cubit.state.error, DocumentError.unsupportedFormat);
        expect(cubit.state.fileName, 'image.png');
        expect(cubit.state.hasDocument, isFalse);

        cubit.loadFile('big.txt', Uint8List(101));
        expect(cubit.state.error, DocumentError.tooLarge);
        expect(cubit.state.format, DocumentFormat.plainText);

        cubit.loadFile('bin.txt', Uint8List.fromList([65, 0, 66]));
        expect(cubit.state.error, DocumentError.notText);
        expect(cubit.state.status, DocumentStatus.empty);
      });

      test('reports invalid JSON and documents without text', () {
        final cubit = build()..loadFile('en.json', bytesOf('{"a": '));
        addTearDown(cubit.close);
        expect(cubit.state.error, DocumentError.invalidJson);
        expect(cubit.state.status, DocumentStatus.empty);

        cubit.loadFile('n.json', bytesOf('{"a": 1}'));
        expect(cubit.state.error, DocumentError.nothingToTranslate);
        expect(cubit.state.status, DocumentStatus.ready);
        expect(cubit.state.canTranslate, isFalse);
      });

      test('pickFile loads the chosen file', () async {
        files.pickResult = PickedFile(name: 'a.md', bytes: bytesOf('# Hi'));
        final cubit = build();
        addTearDown(cubit.close);
        final statuses = <DocumentStatus>[];
        final sub = cubit.stream.listen((s) => statuses.add(s.status));
        await cubit.pickFile();
        await sub.cancel();
        expect(files.pickCalls.single, DocumentFormat.allExtensions);
        expect(statuses.first, DocumentStatus.loading);
        expect(cubit.state.status, DocumentStatus.ready);
        expect(cubit.state.format, DocumentFormat.markdown);
      });

      test('pickFile keeps the previous document when cancelled', () async {
        final cubit = build()..loadFile('a.txt', bytesOf('Hello'));
        addTearDown(cubit.close);
        final before = cubit.state;
        await cubit.pickFile();
        expect(cubit.state, before);
      });

      test('pickFile reports picker errors', () async {
        files.pickError = Exception('denied');
        final cubit = build();
        addTearDown(cubit.close);
        await cubit.pickFile();
        expect(cubit.state.error, DocumentError.readFailed);
        expect(cubit.state.status, DocumentStatus.empty);
      });

      test('pickFile is ignored while a pick is in progress', () async {
        files.pickGate = Completer();
        final cubit = build();
        addTearDown(cubit.close);
        final first = cubit.pickFile();
        await cubit.pickFile();
        expect(files.pickCalls, hasLength(1));
        files.pickGate!.complete(null);
        await first;
        expect(cubit.state.status, DocumentStatus.empty);
      });

      test('pasted text is sniffed and can be re-read as another format', () {
        final cubit = build()..setText('# Title\n\nBody');
        addTearDown(cubit.close);
        expect(cubit.state.mode, DocumentInputMode.text);
        expect(cubit.state.format, DocumentFormat.markdown);
        expect(cubit.state.fileName, isNull);
        expect(cubit.state.outputFileName, 'translation.de.md');

        cubit.setFormat(DocumentFormat.plainText);
        expect(cubit.state.format, DocumentFormat.plainText);
        expect(cubit.state.segmentCount, 2);

        // The chosen format sticks while editing.
        cubit.setText('# Other');
        expect(cubit.state.format, DocumentFormat.plainText);

        // Clearing the text forgets it.
        cubit.setText('  ');
        expect(cubit.state.hasDocument, isFalse);
        cubit.setText('WEBVTT\n\n00:01.000 --> 00:02.000\nHi');
        expect(cubit.state.format, DocumentFormat.vtt);
        expect(cubit.state.sizeBytes, greaterThan(10));
      });

      test('setFormat re-reads a file and is ignored without input', () {
        final cubit = build()..setFormat(DocumentFormat.markdown);
        addTearDown(cubit.close);
        expect(cubit.state.hasDocument, isFalse);

        cubit.loadFile('notes.txt', bytesOf('- a\n- b'));
        expect(cubit.state.segmentCount, 1);
        cubit.setFormat(DocumentFormat.markdown);
        expect(cubit.state.format, DocumentFormat.markdown);
        expect(cubit.state.segmentCount, 2);
        expect(cubit.state.fileName, 'notes.txt');

        // Switching modes keeps the override for the file.
        cubit
          ..setMode(DocumentInputMode.text)
          ..setMode(DocumentInputMode.file);
        expect(cubit.state.format, DocumentFormat.markdown);
      });

      test('modes keep their own input', () {
        final cubit = build()..setMode(DocumentInputMode.text);
        addTearDown(cubit.close);
        expect(cubit.state.hasDocument, isFalse);
        cubit.setText('Pasted');
        cubit.setMode(DocumentInputMode.file);
        expect(cubit.state.hasDocument, isFalse);
        expect(cubit.state.mode, DocumentInputMode.file);

        cubit.loadFile('a.txt', bytesOf('From file'));
        cubit.setMode(DocumentInputMode.text);
        expect(cubit.state.text, 'Pasted');
        cubit.setMode(DocumentInputMode.file);
        expect(cubit.state.text, 'From file');
        expect(cubit.state.fileName, 'a.txt');
        cubit.setMode(DocumentInputMode.file);
        expect(cubit.state.text, 'From file');
      });

      test('pasteText uses the clipboard or reports it is empty', () async {
        final cubit = build();
        addTearDown(cubit.close);
        await cubit.pasteText();
        expect(cubit.state.notice, DocumentNotice.clipboardEmpty);
        expect(cubit.state.noticeId, 1);

        files.pasteError = Exception('no access');
        await cubit.pasteText();
        expect(cubit.state.noticeId, 2);

        files
          ..pasteError = null
          ..clipboard = 'Clipboard text';
        await cubit.pasteText();
        expect(cubit.state.text, 'Clipboard text');
        expect(cubit.state.mode, DocumentInputMode.text);
      });

      test('clear removes the input of the current mode', () {
        final cubit = build()..loadFile('a.txt', bytesOf('Hello'));
        addTearDown(cubit.close);
        cubit.clear();
        expect(cubit.state.hasDocument, isFalse);
        expect(cubit.state.fileName, isNull);
        cubit.setMode(DocumentInputMode.text);
        cubit.setMode(DocumentInputMode.file);
        expect(cubit.state.hasDocument, isFalse);

        cubit.setText('Typed');
        cubit.clear();
        expect(cubit.state.text, '');
        cubit.setMode(DocumentInputMode.file);
        cubit.setMode(DocumentInputMode.text);
        expect(cubit.state.text, '');
      });
    });

    group('translation', () {
      test('translates the document and renders the output', () async {
        final cubit = build(source: english)
          ..loadFile('movie.srt', bytesOf(srtText));
        addTearDown(cubit.close);
        final statuses = <DocumentStatus>[];
        final sub = cubit.stream.listen((s) => statuses.add(s.status));
        await cubit.translate();
        await sub.cancel();

        expect(statuses, contains(DocumentStatus.translating));
        final state = cubit.state;
        expect(state.status, DocumentStatus.translated);
        expect(state.isComplete, isTrue);
        expect(state.progress, 1);
        expect(state.translations, ['HELLO THERE.', 'GOOD ⟨1⟩BYE⟨2⟩.']);
        expect(
          state.output,
          '1\n00:00:01,000 --> 00:00:02,000\nHELLO THERE.\n\n'
          '2\n00:00:03,000 --> 00:00:04,000\nGOOD <i>BYE</i>.\n',
        );
        expect(requests.single.source, english);
        expect(requests.single.target, german);
        expect(state.canTranslate, isTrue);
      });

      test('bilingual output for subtitles', () async {
        final cubit = build()..loadFile('movie.srt', bytesOf(srtText));
        addTearDown(cubit.close);
        await cubit.translate();
        cubit.setBilingual(enabled: true);
        expect(cubit.state.output, contains('Hello there.\nHELLO THERE.\n'));
        cubit.setBilingual(enabled: true);
        cubit.setBilingual(enabled: false);
        expect(cubit.state.output, isNot(contains('Hello there.')));
      });

      test('failed chunks can be retried one by one or all at once', () async {
        var failing = true;
        stubTranslate(
          repository,
          requests: requests,
          respond: (request) => failing && request.text.contains('two')
              ? Stream.error(const MozhiApiException('down'))
              : Stream.value(result(request.text.toUpperCase())),
        );
        final cubit = build(chunker: const Chunker(maxUnits: 1))
          ..loadFile('a.txt', bytesOf('one\n\ntwo\n\nthree two'));
        addTearDown(cubit.close);
        await cubit.translate();
        expect(cubit.state.failures.keys.toSet(), {1, 2});
        expect(cubit.state.pendingChunks, 2);
        expect(cubit.state.isComplete, isFalse);
        expect(cubit.state.output, 'ONE\n\ntwo\n\nthree two');

        failing = false;
        await cubit.retryChunk(2);
        expect(cubit.state.failures.keys, [1]);
        expect(cubit.state.output, 'ONE\n\ntwo\n\nTHREE TWO');

        await cubit.retryFailed();
        expect(cubit.state.failures, isEmpty);
        expect(cubit.state.isComplete, isTrue);
        expect(cubit.state.output, 'ONE\n\nTWO\n\nTHREE TWO');
      });

      test('cancel keeps finished chunks and stops requests', () async {
        final gates = <Completer<void>>[];
        var cancelled = 0;
        stubTranslate(
          repository,
          requests: requests,
          respond: (request) {
            final gate = Completer<void>();
            gates.add(gate);
            late final StreamController<TranslationResult> controller;
            controller = StreamController(
              onListen: () => gate.future.then((_) {
                controller
                  ..add(result(request.text.toUpperCase()))
                  ..close();
              }),
              onCancel: () => cancelled++,
            );
            return controller.stream;
          },
        );
        final cubit = build(chunker: const Chunker(maxUnits: 1))
          ..loadFile('a.txt', bytesOf('one\n\ntwo\n\nthree'));
        addTearDown(cubit.close);
        final done = cubit.translate();
        await pumpEventQueue();
        expect(cubit.state.isTranslating, isTrue);
        expect(cubit.state.canTranslate, isFalse);
        gates.first.complete();
        await pumpEventQueue();
        expect(cubit.state.doneChunks, 1);

        cubit.cancel();
        await done;
        expect(cubit.state.status, DocumentStatus.translated);
        expect(cubit.state.doneChunks, 1);
        expect(cubit.state.pendingChunks, 2);
        expect(cancelled, greaterThanOrEqualTo(1));
        cubit.cancel(); // No-op when idle.
      });

      test('cancel before any result returns to ready', () async {
        stubTranslate(
          repository,
          respond: (request) => StreamController<TranslationResult>().stream,
        );
        final cubit = build()..loadFile('a.txt', bytesOf('one'));
        addTearDown(cubit.close);
        unawaited(cubit.translate());
        await pumpEventQueue();
        cubit.cancel();
        expect(cubit.state.status, DocumentStatus.ready);
      });

      test(
        'changing languages or the document discards translations',
        () async {
          final cubit = build()..loadFile('a.txt', bytesOf('one'));
          addTearDown(cubit.close);
          await cubit.translate();
          expect(cubit.state.hasTranslation, isTrue);

          cubit.setTarget(spanish);
          expect(cubit.state.hasTranslation, isFalse);
          expect(cubit.state.output, '');
          expect(cubit.state.status, DocumentStatus.ready);

          await cubit.translate();
          cubit.setSource(english);
          expect(cubit.state.hasTranslation, isFalse);

          await cubit.translate();
          cubit.setText('new text');
          expect(cubit.state.hasTranslation, isFalse);
        },
      );

      test('ignores input changes while translating', () async {
        stubTranslate(
          repository,
          respond: (request) => StreamController<TranslationResult>().stream,
        );
        final cubit = build()..loadFile('a.txt', bytesOf('one'));
        addTearDown(cubit.close);
        unawaited(cubit.translate());
        await pumpEventQueue();
        final before = cubit.state;
        cubit
          ..setTarget(spanish)
          ..setSource(english)
          ..swapLanguages()
          ..setText('x')
          ..setMode(DocumentInputMode.text)
          ..loadFile('b.txt', bytesOf('b'))
          ..setFormat(DocumentFormat.markdown);
        await cubit.selectEngine(deeplEngine);
        await cubit.pickFile();
        await cubit.pasteText();
        await cubit.translate();
        expect(cubit.state, before);
      });

      test('translate does nothing without an engine or document', () async {
        final cubit = build(engine: null);
        addTearDown(cubit.close);
        await cubit.translate();
        cubit.loadFile('a.txt', bytesOf('one'));
        await cubit.translate();
        expect(requests, isEmpty);
        expect(cubit.state.canTranslate, isFalse);
      });

      test('closing stops a running translation', () async {
        stubTranslate(
          repository,
          respond: (request) => StreamController<TranslationResult>().stream,
        );
        final cubit = build()..loadFile('a.txt', bytesOf('one'));
        final done = cubit.translate();
        await pumpEventQueue();
        await cubit.close();
        await done;
      });
    });

    group('engine and languages', () {
      test('selectEngine loads and remaps languages', () async {
        stubLanguages(
          repository,
          sources: const [english, spanish],
          targets: const [spanish, french],
        );
        final cubit = build(source: english);
        addTearDown(cubit.close);
        final future = cubit.selectEngine(deeplEngine);
        expect(cubit.state.engine, deeplEngine);
        expect(cubit.state.languagesLoading, isTrue);
        expect(cubit.state.canTranslate, isFalse);
        await future;
        expect(cubit.state.languagesLoading, isFalse);
        expect(cubit.state.sourceLanguages, const [english, spanish]);
        expect(cubit.state.source, english);
        // German is not offered: falls back to the first target.
        expect(cubit.state.target, spanish);

        await cubit.selectEngine(deeplEngine); // Same engine: no-op.
        verify(() => repository.getSourceLanguages(deeplEngine)).called(1);
      });

      test('selectEngine falls back to auto/English', () async {
        stubLanguages(
          repository,
          sources: const [Language.auto, spanish],
          targets: const [english, spanish],
        );
        final cubit = build(
          source: german,
          target: const Language.custom('Pirate'),
        );
        addTearDown(cubit.close);
        await cubit.selectEngine(deeplEngine);
        expect(cubit.state.source, Language.auto);
        expect(cubit.state.target, english);

        stubLanguages(repository, sources: const [spanish], targets: const []);
        await cubit.selectEngine(googleEngine);
        expect(cubit.state.source, spanish);
        expect(cubit.state.target, english);
      });

      test('AI engines keep custom targets', () async {
        final cubit = build(target: const Language.custom('Pirate'));
        addTearDown(cubit.close);
        await cubit.selectEngine(aiEngine);
        expect(cubit.state.target, const Language.custom('Pirate'));
      });

      test('selectEngine reports failures and ignores stale results', () async {
        final gate = Completer<List<Language>>();
        when(() => repository.getSourceLanguages(deeplEngine))
            .thenAnswer((_) => gate.future);
        when(() => repository.getSourceLanguages(aiEngine))
            .thenThrow(Exception('offline'));
        final cubit = build();
        addTearDown(cubit.close);
        final stale = cubit.selectEngine(deeplEngine);
        await cubit.selectEngine(aiEngine);
        expect(cubit.state.notice, DocumentNotice.languagesFailed);
        expect(cubit.state.languagesLoading, isFalse);
        expect(cubit.state.engine, aiEngine);
        gate.complete(const [french]);
        await stale;
        expect(cubit.state.engine, aiEngine);
        expect(cubit.state.sourceLanguages, sourceLanguages);

        final failing = Completer<List<Language>>();
        when(() => repository.getSourceLanguages(googleEngine))
            .thenAnswer((_) => failing.future);
        final staleFailure = cubit.selectEngine(googleEngine);
        await cubit.selectEngine(deeplEngine);
        failing.completeError(Exception('late'));
        await staleFailure;
        expect(cubit.state.engine, deeplEngine);
      });

      test('swapLanguages swaps concrete languages only', () {
        final cubit = build();
        addTearDown(cubit.close);
        cubit.swapLanguages();
        expect(cubit.state.source, Language.auto);

        cubit
          ..setSource(english)
          ..swapLanguages();
        expect(cubit.state.source, german);
        expect(cubit.state.target, english);
        expect(cubit.state.canSwap, isTrue);

        cubit
          ..setSource(english)
          ..setTarget(Language.auto)
          ..setTarget(german);
        expect(cubit.state.target, german);
      });

      test('syncEngines follows the translate screen until changed here', () {
        final cubit = build(engine: null);
        addTearDown(cubit.close);
        cubit.syncEngines(
          engines: const [googleEngine, deeplEngine],
          engine: deeplEngine,
          sourceLanguages: const [Language.auto, english],
          targetLanguages: const [english, french],
          source: english,
          target: french,
          options: const TranslationOptions(context: 'ctx'),
        );
        expect(cubit.state.engine, deeplEngine);
        expect(cubit.state.target, french);
        expect(cubit.state.options.context, 'ctx');
        expect(cubit.state.targetLanguages, const [english, french]);

        // The user picks their own target: further syncs keep it.
        cubit.setTarget(english);
        cubit.syncEngines(
          engines: const [googleEngine, deeplEngine, aiEngine],
          engine: googleEngine,
          target: spanish,
        );
        expect(cubit.state.engine, deeplEngine);
        expect(cubit.state.target, english);
        expect(cubit.state.engines, hasLength(3));

        // The chosen engine disappears: follow the translate screen again.
        cubit.syncEngines(
          engines: const [googleEngine],
          engine: googleEngine,
          sourceLanguages: sourceLanguages,
          targetLanguages: targetLanguages,
          target: spanish,
        );
        expect(cubit.state.engine, googleEngine);
        expect(cubit.state.target, spanish);
      });

      test('syncEngines keeps a finished translation', () async {
        final cubit = build()..loadFile('a.txt', bytesOf('one'));
        addTearDown(cubit.close);
        await cubit.translate();
        cubit.syncEngines(
          engines: const [googleEngine, deeplEngine],
          engine: deeplEngine,
        );
        expect(cubit.state.engine, googleEngine);
        expect(cubit.state.hasTranslation, isTrue);

        // Re-selecting the same target keeps the results too.
        cubit.setTarget(german);
        expect(cubit.state.hasTranslation, isTrue);
      });

      test('syncEngines without changes keeps the translation', () async {
        final cubit = build(engine: null)
          ..syncEngines(engines: const [googleEngine], engine: googleEngine);
        addTearDown(cubit.close);
        cubit.loadFile('a.txt', bytesOf('one'));
        cubit.syncEngines(
          engines: const [googleEngine],
          engine: googleEngine,
          target: german,
        );
        expect(cubit.state.status, DocumentStatus.ready);
      });
    });

    group('export', () {
      Future<DocumentTranslateCubit> translated(
        String name,
        List<int> bytes,
      ) async {
        final cubit = build()..loadFile(name, Uint8List.fromList(bytes));
        addTearDown(cubit.close);
        await cubit.translate();
        return cubit;
      }

      test('does nothing before a translation exists', () async {
        final cubit = build()..loadFile('a.txt', bytesOf('one'));
        addTearDown(cubit.close);
        await cubit.save();
        await cubit.share();
        await cubit.copy();
        expect(files.saved, isEmpty);
        expect(files.shared, isEmpty);
        expect(files.copied, isEmpty);
      });

      test('save writes the translated file', () async {
        final cubit = await translated('notes.en.txt', bytesOf('hello'));
        await cubit.save();
        final saved = files.saved.single;
        expect(saved.fileName, 'notes.de.txt');
        expect(utf8.decode(saved.bytes), 'HELLO');
        expect(saved.mimeType, 'text/plain');
        expect(cubit.state.notice, DocumentNotice.saved);

        files.saveResult = false;
        await cubit.save();
        expect(cubit.state.noticeId, 1);

        files.saveError = Exception('disk full');
        await cubit.save();
        expect(cubit.state.notice, DocumentNotice.saveFailed);
      });

      test('keeps the original encoding', () async {
        final bytes = encodeText('hello', TextEncoding.utf16le);
        final cubit = await translated('a.txt', bytes);
        expect(cubit.outputBytes, encodeText('HELLO', TextEncoding.utf16le));
      });

      test('pasted text is exported as UTF-8', () async {
        final cubit = build()..setText('hello');
        addTearDown(cubit.close);
        await cubit.translate();
        expect(cubit.outputBytes, utf8.encode('HELLO'));
      });

      test('share sends the file and reports problems', () async {
        final cubit = await translated('movie.srt', bytesOf(srtText));
        const origin = Rect.fromLTWH(1, 2, 3, 4);
        await cubit.share(origin: origin);
        final shared = files.shared.single;
        expect(shared.fileName, 'movie.de.srt');
        expect(shared.mimeType, 'application/x-subrip');
        expect(shared.origin, origin);

        files.shareError = const ShareUnsupportedException();
        await cubit.share();
        expect(cubit.state.notice, DocumentNotice.shareUnsupported);

        files.shareError = Exception('boom');
        await cubit.share();
        expect(cubit.state.notice, DocumentNotice.shareFailed);
        expect(const ShareUnsupportedException().toString(), isNotEmpty);
      });

      test('copy copies the output', () async {
        final cubit = await translated('a.txt', bytesOf('hello'));
        await cubit.copy();
        expect(files.copied, ['HELLO']);
        expect(cubit.state.notice, DocumentNotice.copied);
      });
    });
  });
}
