import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/web_translate/web_translate.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

final _offline = TranslationEngine.offline();

final _offlineToSpanish = WebTranslateSelection(
  engine: _offline,
  source: Language.auto,
  target: spanish,
);

/// A translation-specialised AI model (needs a source language).
const _gemma = TranslationEngine(
  id: 'ai:gemma',
  kind: EngineKind.ai,
  name: 'TranslateGemma',
  isLocal: true,
  promptProfile: PromptProfile.translateGemma,
);

const _title = 'Sample page';

/// The translatable blocks of [samplePageHtml] (the code block is not).
const _blocks = [
  'First paragraph of the sample page, long enough to be content.',
  'Section',
  'Apples',
  'Pears',
  'One',
  'A wise quote.',
  'A picture of fruit',
  'Last paragraph.',
];

/// Index of the code block among the page's blocks.
const _codeIndex = 6;

/// The page's translations: [translate] applied to every translatable
/// block.
List<String?> _translations(String Function(String text) translate) {
  final translations = <String?>[];
  var next = 0;
  for (var i = 0; i < _blocks.length + 1; i++) {
    translations.add(i == _codeIndex ? null : translate(_blocks[next++]));
  }
  return translations;
}

String _upper(String text) => text.toUpperCase();

/// Like the on-device engine: with an auto source, text shorter than 20
/// characters cannot be identified and longer text is English; with an
/// explicit source the text is upper-cased.
Stream<TranslationResult> _offlineTranslator(
  TranslationEngine engine,
  TranslationRequest request,
) {
  if (request.source.isAuto) {
    if (request.text.length < 20) {
      return Stream.error(SourceLanguageRequiredException(engineId: engine.id));
    }
    return Stream.value(
      result(request.text.toUpperCase(), detected: 'en', engine: engine),
    );
  }
  return Stream.value(result(request.text.toUpperCase(), engine: engine));
}

/// The language detector of the device: English.
Future<DetectedLanguage> _english(String text, TranslationEngine? engine) =>
    Future.value(const DetectedLanguage(code: 'en'));

void main() {
  late FakeTranslationRepository repository;

  setUp(() {
    repository = FakeTranslationRepository(_offlineTranslator)
      ..offlineEngine = true;
  });

  WebTranslateCubit build({
    BlockBatcher batcher = const BlockBatcher(maxItems: 1),
    int concurrency = 1,
    ReadablePageExtractor? extract,
  }) {
    final cubit = WebTranslateCubit(
      repository: repository,
      fetcher: WebPageFetcher(isWeb: false, client: htmlClient(samplePageHtml)),
      batcher: batcher,
      concurrency: concurrency,
      initialUrl: 'example.com/sample',
      extract: extract,
    );
    addTearDown(cubit.close);
    return cubit;
  }

  /// Sources of the requests for [text].
  List<String> sourcesOf(String text) => [
    for (final request in repository.requests)
      if (request.text == text) request.source.code,
  ];

  group('WebTranslateCubit language detection', () {
    test('identifies the page language once on the device and translates '
        'every block from it', () async {
      repository.detector = _english;
      final cubit = build(concurrency: 2);
      await cubit.load(selection: _offlineToSpanish);

      final (sample, engine) = repository.detections.single;
      expect(engine, _offline);
      expect(sample, [_title, ..._blocks].join('\n\n'));
      expect(repository.requests, hasLength(1 + _blocks.length));
      expect(
        repository.requests.map((r) => r.source),
        everyElement(LanguageCatalog.byCode('en')),
      );
      final state = cubit.state;
      expect(state.status, WebTranslateStatus.translated);
      expect(state.error, isNull);
      expect(state.detectedSource, 'en');
      expect(state.translatedTitle, _title.toUpperCase());
      expect(state.translations, _translations(_upper));
    });

    test('translates a batch from the identified language', () async {
      repository.detector = _english;
      final cubit = build(batcher: const BlockBatcher());
      await cubit.load(selection: _offlineToSpanish);

      expect(repository.detections, hasLength(1));
      expect(repository.requests.single.source.code, 'en');
      expect(cubit.state.status, WebTranslateStatus.translated);
      expect(cubit.state.translations, _translations(_upper));
    });

    test('keeps a block whose language cannot be told when none is known '
        'yet', () async {
      // The device cannot tell the page's language either.
      final cubit = build();
      await cubit.load(selection: _offlineToSpanish);

      expect(repository.detections, hasLength(1));
      final state = cubit.state;
      expect(state.status, WebTranslateStatus.translated);
      expect(state.error, isNull);
      // The title comes first: nothing was detected before it.
      expect(state.translatedTitle, _title);
      expect(sourcesOf(_title), ['auto']);
      expect(state.translations.first, _blocks.first.toUpperCase());
      expect(state.detectedSource, 'en');
    });

    test('translates later undetectable blocks from the language detected '
        'for earlier ones', () async {
      final cubit = build();
      await cubit.load(selection: _offlineToSpanish);

      expect(sourcesOf('Section'), ['auto', 'en']);
      expect(sourcesOf('Apples'), ['auto', 'en']);
      expect(sourcesOf(_blocks.first), ['auto']);
      expect(cubit.state.translations, _translations(_upper));
    });

    test('keeps a whole batch whose language cannot be told', () async {
      repository.translator = (engine, request) =>
          Stream.error(SourceLanguageRequiredException(engineId: engine.id));
      final cubit = build(batcher: const BlockBatcher());
      await cubit.load(selection: _offlineToSpanish);

      // Not retried block by block.
      expect(repository.requests, hasLength(1));
      final state = cubit.state;
      expect(state.status, WebTranslateStatus.translated);
      expect(state.error, isNull);
      expect(state.translatedTitle, _title);
      expect(state.translations, _translations((text) => text));
      expect(state.detectedSource, isNull);
    });

    test('resume reuses the language detected before', () async {
      var fail = true;
      repository.translator = (engine, request) {
        if (fail && request.text == 'Pears') {
          return Stream.error(const MozhiApiException('down'));
        }
        return _offlineTranslator(engine, request);
      };
      final cubit = build();
      await cubit.load(selection: _offlineToSpanish);
      expect(cubit.state.status, WebTranslateStatus.failure);
      expect(cubit.state.detectedSource, 'en');

      fail = false;
      repository.requests.clear();
      await cubit.resume();
      expect(cubit.state.status, WebTranslateStatus.translated);
      // "One" is short: translated from the language detected before.
      expect(sourcesOf('One'), ['auto', 'en']);
      expect(cubit.state.translations, _translations(_upper));
    });

    test(
      'identifies on the device for translation-specialised models',
      () async {
        repository.detector = (text, engine) async =>
            const DetectedLanguage(code: 'de');
        final cubit = build();
        await cubit.load(
          selection: const WebTranslateSelection(
            engine: _gemma,
            source: Language.auto,
            target: spanish,
          ),
        );

        // Asked with the offline engine: the on-device identifier answers.
        expect(repository.detections.single.$2, _offline);
        expect(
          repository.requests.map((r) => r.source),
          everyElement(LanguageCatalog.byCode('de')),
        );
        expect(cubit.state.detectedSource, 'de');
        expect(cubit.state.status, WebTranslateStatus.translated);
      },
    );

    test('engines that detect per request are not identified first', () async {
      repository
        ..detector = _english
        ..translator = upperCaseTranslator;
      final cubit = build();
      await cubit.load(selection: googleToSpanish);

      expect(repository.detections, isEmpty);
      expect(
        repository.requests.map((r) => r.source),
        everyElement(Language.auto),
      );
      expect(cubit.state.detectedSource, 'en');
    });

    test('nothing is identified without an on-device engine', () async {
      repository
        ..offlineEngine = false
        ..detector = _english;
      final cubit = build();
      await cubit.load(selection: _offlineToSpanish);

      expect(repository.detections, isEmpty);
      expect(sourcesOf(_blocks.first), ['auto']);
      expect(cubit.state.status, WebTranslateStatus.translated);
    });

    test('a language missing from the catalogue is used by its code', () async {
      repository.detector = (text, engine) async =>
          const DetectedLanguage(code: 'qaa');
      final cubit = build();
      await cubit.load(selection: _offlineToSpanish);

      expect(
        repository.requests.map((r) => (r.source.code, r.source.name)).toSet(),
        {('qaa', 'qaa')},
      );
      expect(cubit.state.detectedSource, 'qaa');
    });

    test('a blank detection is ignored', () async {
      repository.detector = (text, engine) async =>
          const DetectedLanguage(code: ' ');
      final cubit = build();
      await cubit.load(selection: _offlineToSpanish);

      expect(repository.detections, hasLength(1));
      expect(sourcesOf(_blocks.first), ['auto']);
      expect(cubit.state.status, WebTranslateStatus.translated);
    });

    test('an explicit source is never identified and its errors still fail '
        'the page', () async {
      repository
        ..detector = _english
        ..translator = (engine, request) =>
            Stream.error(SourceLanguageRequiredException(engineId: engine.id));
      final cubit = build();
      await cubit.load(
        selection: WebTranslateSelection(
          engine: _offline,
          source: const Language(code: 'en', name: 'English'),
          target: spanish,
        ),
      );

      expect(repository.detections, isEmpty);
      expect(cubit.state.status, WebTranslateStatus.failure);
      expect(cubit.state.error, isA<SourceLanguageRequiredException>());
    });

    test('cancelling while the language is identified sends nothing', () async {
      final detection = Completer<DetectedLanguage>();
      repository.detector = (text, engine) => detection.future;
      final cubit = build();
      unawaited(cubit.load(selection: _offlineToSpanish));
      await waitFor(cubit, (s) => s.status == WebTranslateStatus.translating);
      await pumpEventQueue();
      expect(repository.detections, hasLength(1));

      await cubit.cancel();
      detection.complete(const DetectedLanguage(code: 'en'));
      await pumpEventQueue();
      expect(repository.requests, isEmpty);
      expect(cubit.state.status, WebTranslateStatus.stopped);
      expect(cubit.state.detectedSource, isNull);
    });

    test('the sample is capped without splitting a surrogate pair', () async {
      repository.detector = _english;
      final emoji = '😀' * 3000;
      final cubit = build(
        extract: (page) async => ReadablePage(
          title: 'T',
          blocks: [
            ReadableBlock(kind: ReadableBlockKind.paragraph, text: emoji),
            const ReadableBlock(
              kind: ReadableBlockKind.paragraph,
              text: 'Second block of the page.',
            ),
          ],
        ),
      );
      await cubit.load(selection: _offlineToSpanish);

      final sample = repository.detections.single.$1;
      // "T", a blank line, and whole emoji up to the limit.
      expect(sample.length, WebTranslateCubit.detectionSampleLength - 1);
      expect(sample, 'T\n\n${'😀' * 1998}');
      expect(cubit.state.status, WebTranslateStatus.translated);
    });
  });
}
