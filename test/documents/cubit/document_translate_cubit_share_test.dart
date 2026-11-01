import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/documents.dart';
import 'package:mozhi/transcribe/data/screen_awake.dart';

import '../helpers/fakes.dart';

class _FakeScreenAwake extends ScreenAwake {
  new() : super(isWeb: false);

  final calls = <bool>[];

  @override
  Future<void> setEnabled({required bool enabled}) async => calls.add(enabled);
}

void main() {
  late MockTranslationRepository repository;
  late FakeDocumentFileService files;
  late _FakeScreenAwake awake;
  late List<Completer<void>> gates;

  setUpAll(registerDocumentFallbacks);

  setUp(() {
    repository = MockTranslationRepository();
    files = FakeDocumentFileService();
    awake = _FakeScreenAwake();
    gates = [];
    // Each chunk is answered once its gate opens.
    stubTranslate(
      repository,
      respond: (request) {
        final gate = Completer<void>();
        gates.add(gate);
        return Stream.fromFuture(
          gate.future.then((_) => result(request.text.toUpperCase())),
        );
      },
    );
    stubLanguages(repository);
  });

  DocumentTranslateCubit build() => DocumentTranslateCubit(
    repository: repository,
    files: files,
    translator: DocumentTranslator(
      repository: repository,
      maxAttempts: 1,
      retryDelay: Duration.zero,
    ),
    engines: const [googleEngine],
    engine: googleEngine,
    sourceLanguages: sourceLanguages,
    targetLanguages: targetLanguages,
    target: german,
    screenAwake: awake,
  );

  Uint8List bytes(String text) => Uint8List.fromList(text.codeUnits);

  group('fileUnavailable', () {
    test('says that a named file was too large', () {
      final cubit = build()..fileUnavailable(name: 'big.docx', tooLarge: true);
      addTearDown(cubit.close);
      expect(cubit.state.error, DocumentError.tooLarge);
      expect(cubit.state.fileName, 'big.docx');
      expect(cubit.state.format, DocumentFormat.docx);
      expect(cubit.state.mode, DocumentInputMode.file);
      expect(cubit.state.hasDocument, isFalse);
    });

    test('a file of no known format could not be opened at any size', () {
      final cubit = build()
        ..fileUnavailable(name: 'holiday.mp4', tooLarge: true);
      addTearDown(cubit.close);
      expect(cubit.state.error, DocumentError.unsupportedFormat);
      cubit.fileUnavailable(tooLarge: true);
      expect(cubit.state.error, DocumentError.unsupportedFormat);
      expect(cubit.state.fileName, isNull);
    });

    test('says that a file could not be read, replacing the document', () {
      final cubit = build()..loadFile('a.txt', bytes('Hello'));
      addTearDown(cubit.close);
      expect(cubit.state.hasDocument, isTrue);
      cubit.fileUnavailable(name: 'b.srt', tooLarge: false);
      expect(cubit.state.error, DocumentError.readFailed);
      expect(cubit.state.fileName, 'b.srt');
      expect(cubit.state.hasDocument, isFalse);
    });

    test('is ignored while translating', () async {
      final cubit = build()..loadFile('a.txt', bytes('Hello'));
      addTearDown(cubit.close);
      final run = cubit.translate();
      await pumpEventQueue();
      expect(cubit.state.isTranslating, isTrue);
      cubit.fileUnavailable(name: 'b.srt', tooLarge: false);
      expect(cubit.state.error, isNull);
      expect(cubit.state.fileName, 'a.txt');
      for (final gate in gates) {
        gate.complete();
      }
      await run;
    });
  });

  group('keeps the screen on', () {
    test('while translating', () async {
      final cubit = build()..loadFile('a.txt', bytes('Hello'));
      addTearDown(cubit.close);
      expect(awake.calls, isEmpty);
      final run = cubit.translate();
      await pumpEventQueue();
      expect(awake.calls, [true]);
      for (final gate in gates) {
        gate.complete();
      }
      await run;
      expect(cubit.state.output, 'HELLO');
      expect(awake.calls, [true, false]);
    });

    test('until cancelled', () async {
      final cubit = build()..loadFile('a.txt', bytes('Hello'));
      addTearDown(cubit.close);
      unawaited(cubit.translate());
      await pumpEventQueue();
      cubit.cancel();
      expect(awake.calls, [true, false]);
    });

    test('until the screen closes', () async {
      final cubit = build()..loadFile('a.txt', bytes('Hello'));
      unawaited(cubit.translate());
      await pumpEventQueue();
      await cubit.close();
      expect(awake.calls, [true, false]);
    });

    test('not when nothing was translated', () async {
      await build().close();
      expect(awake.calls, isEmpty);
    });

    test('with the platform by default', () async {
      final cubit = DocumentTranslateCubit(
        repository: repository,
        files: files,
        engine: googleEngine,
      );
      await cubit.close();
    });
  });
}
