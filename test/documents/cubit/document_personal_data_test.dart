import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/documents.dart';

import '../helpers/fakes.dart';

// What the personal data shield kept on the device while a document was
// translated (`TranslationResult.maskedPersonalData`), for the note under
// the translation.
void main() {
  late MockTranslationRepository repository;
  late FakeDocumentFileService files;
  late bool failing;

  setUpAll(registerDocumentFallbacks);

  setUp(() {
    repository = MockTranslationRepository();
    files = FakeDocumentFileService();
    failing = false;
    stubTranslate(
      repository,
      respond: (request) {
        if (failing && request.text.contains('two')) {
          return Stream.error(Exception('down'));
        }
        return Stream.value(
          result(request.text.toUpperCase()).copyWith(maskedPersonalData: 1),
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
    // One request per paragraph.
    chunker: const Chunker(maxUnits: 1),
    engines: const [googleEngine],
    engine: googleEngine,
    sourceLanguages: sourceLanguages,
    targetLanguages: targetLanguages,
    target: german,
  );

  test('counts what each request kept, across retries', () async {
    final cubit = build()..loadFile('a.txt', bytesOf('one\n\ntwo\n\nthree'));
    addTearDown(cubit.close);
    expect(cubit.state.maskedPersonalData, 0);

    failing = true;
    await cubit.translate();
    expect(cubit.state.failures, hasLength(1));
    expect(cubit.state.maskedPersonalData, 2);

    failing = false;
    await cubit.retryFailed();
    expect(cubit.state.isComplete, isTrue);
    expect(cubit.state.maskedPersonalData, 3);

    // A fresh translation starts over.
    await cubit.translate();
    expect(cubit.state.maskedPersonalData, 3);
  });

  test('another document starts over', () async {
    final cubit = build()..loadFile('a.txt', bytesOf('one'));
    addTearDown(cubit.close);
    await cubit.translate();
    expect(cubit.state.maskedPersonalData, 1);
    cubit.loadFile('b.txt', bytesOf('two'));
    expect(cubit.state.maskedPersonalData, 0);
  });

  test('is part of the state', () {
    const state = DocumentTranslateState();
    expect(state.copyWith(maskedPersonalData: 2).maskedPersonalData, 2);
    expect(state.copyWith(maskedPersonalData: 2), isNot(state));
  });
}
