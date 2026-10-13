import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mozhi/web_translate/web_translate.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

const sampleTitle = 'Sample page';
const sampleTexts = [
  'First paragraph of the sample page, long enough to be content.',
  'Section',
  'Apples',
  'Pears',
  'One',
  'A wise quote.',
  'let x = 1;',
  'A picture of fruit',
  'Last paragraph.',
];
const codeIndex = 6;

WebTranslateCubit buildCubit({
  http.Client? client,
  FakeTranslationRepository? repository,
  BlockBatcher batcher = const BlockBatcher(),
  int concurrency = 2,
  String url = 'example.com/sample',
  ReadablePageExtractor? extract,
}) => WebTranslateCubit(
  repository: repository ?? FakeTranslationRepository(),
  fetcher: WebPageFetcher(
    isWeb: false,
    client: client ?? htmlClient(samplePageHtml),
  ),
  batcher: batcher,
  concurrency: concurrency,
  initialUrl: url,
  extract: extract,
);

List<String?> upperTranslations() => [
  for (var i = 0; i < sampleTexts.length; i++)
    i == codeIndex ? null : sampleTexts[i].toUpperCase(),
];

void main() {
  group('WebTranslateCubit', () {
    test('initial state carries the initial address', () async {
      final cubit = buildCubit(url: 'https://a.example');
      expect(cubit.state, const WebTranslateState(url: 'https://a.example'));
      await cubit.close();
    });

    blocTest<WebTranslateCubit, WebTranslateState>(
      'setUrl updates the address and clears the invalid flag',
      build: buildCubit,
      seed: () => const WebTranslateState(url: 'x', urlInvalid: true),
      act: (cubit) => cubit
        ..setUrl('x')
        ..setUrl('x')
        ..setUrl('example.org'),
      expect: () => const [
        WebTranslateState(url: 'x'),
        WebTranslateState(url: 'example.org'),
      ],
    );

    blocTest<WebTranslateCubit, WebTranslateState>(
      'setMode changes the reader mode once',
      build: buildCubit,
      act: (cubit) => cubit
        ..setMode(ReaderMode.original)
        ..setMode(ReaderMode.original),
      expect: () => const [
        WebTranslateState(url: 'example.com/sample', mode: ReaderMode.original),
      ],
    );

    blocTest<WebTranslateCubit, WebTranslateState>(
      'load flags an invalid address',
      build: () => buildCubit(url: 'not a url'),
      act: (cubit) => cubit.load(),
      expect: () => const [
        WebTranslateState(url: 'not a url', urlInvalid: true),
      ],
    );

    test('load without a selection only loads the page', () async {
      final repository = FakeTranslationRepository();
      final cubit = buildCubit(repository: repository);
      final states = <WebTranslateState>[];
      final sub = cubit.stream.listen(states.add);
      await cubit.load();
      await sub.cancel();

      expect(states.map((s) => s.status), [
        WebTranslateStatus.loading,
        WebTranslateStatus.loaded,
      ]);
      expect(states.first.url, 'https://example.com/sample');
      final state = cubit.state;
      expect(state.page!.title, sampleTitle);
      expect(state.page!.blocks.map((b) => b.text), sampleTexts);
      expect(state.pageUri, Uri.parse('https://example.com/sample'));
      expect(
        state.translations,
        List<String?>.filled(sampleTexts.length, null),
      );
      expect(state.truncated, isFalse);
      expect(state.selection, isNull);
      expect(repository.requests, isEmpty);
      await cubit.close();
    });

    test('load with a selection translates every block in one batch', () async {
      final repository = FakeTranslationRepository();
      final cubit = buildCubit(repository: repository);
      final statuses = <WebTranslateStatus>[];
      final sub = cubit.stream.listen((s) => statuses.add(s.status));
      await cubit.load(selection: googleToSpanish);
      await sub.cancel();

      expect(statuses.first, WebTranslateStatus.loading);
      expect(statuses, contains(WebTranslateStatus.loaded));
      expect(statuses, contains(WebTranslateStatus.translating));
      expect(statuses.last, WebTranslateStatus.translated);

      final state = cubit.state;
      expect(state.selection, googleToSpanish);
      expect(state.translatedTitle, sampleTitle.toUpperCase());
      expect(state.translations, upperTranslations());
      expect(state.detectedSource, 'en');
      expect(state.doneItems, state.totalItems);
      expect(state.totalItems, 9);

      final request = repository.requests.single;
      expect(request.source, Language.auto);
      expect(request.target, spanish);
      expect(request.options.preserveFormatting, isTrue);
      expect(
        request.text,
        [
          sampleTitle,
          for (final (i, t) in sampleTexts.indexed)
            if (i != codeIndex) t,
        ].join('\n\n'),
      );
      await cubit.close();
    });

    test('translates block by block when a batch cannot be split', () async {
      final repository = FakeTranslationRepository(
        (engine, request) => Stream.value(
          // Merges paragraphs: the batch result has no blank lines.
          result(request.text.replaceAll('\n\n', ' ').toUpperCase()),
        ),
      );
      final cubit = buildCubit(repository: repository);
      await cubit.load(selection: googleToSpanish);

      expect(cubit.state.status, WebTranslateStatus.translated);
      expect(cubit.state.translations, upperTranslations());
      // One batch request plus one request per item.
      expect(repository.requests, hasLength(1 + 9));
      await cubit.close();
    });

    test('uses only the final result of streaming engines', () async {
      final repository = FakeTranslationRepository(
        (engine, request) => Stream.fromIterable([
          result('partial', complete: false, engine: aiEngine),
          result(request.text.toLowerCase(), engine: aiEngine),
        ]),
      );
      final cubit = buildCubit(
        repository: repository,
        batcher: const BlockBatcher(maxItems: 1),
      );
      await cubit.load(
        selection: const WebTranslateSelection(
          engine: aiEngine,
          source: Language.auto,
          target: spanish,
        ),
      );
      expect(cubit.state.translatedTitle, 'sample page');
      expect(cubit.state.translations.first, sampleTexts.first.toLowerCase());
      expect(cubit.state.detectedSource, isNull);
      await cubit.close();
    });

    test('keeps the original text when a translation is empty', () async {
      final repository = FakeTranslationRepository(
        (engine, request) => const Stream.empty(),
      );
      final cubit = buildCubit(
        repository: repository,
        batcher: const BlockBatcher(maxItems: 1),
      );
      await cubit.load(selection: googleToSpanish);
      expect(cubit.state.status, WebTranslateStatus.translated);
      expect(cubit.state.translatedTitle, sampleTitle);
      expect(cubit.state.translations.first, sampleTexts.first);
      await cubit.close();
    });

    test('runs at most `concurrency` requests at once', () async {
      var inFlight = 0;
      var maxInFlight = 0;
      final repository = FakeTranslationRepository((engine, request) async* {
        inFlight++;
        maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
        await Future<void>.delayed(const Duration(milliseconds: 2));
        inFlight--;
        yield result(request.text.toUpperCase());
      });
      final cubit = buildCubit(
        repository: repository,
        batcher: const BlockBatcher(maxItems: 1),
      );
      final progress = <int>[];
      final sub = cubit.stream.listen((s) => progress.add(s.doneItems));
      await cubit.load(selection: googleToSpanish);
      await sub.cancel();

      expect(maxInFlight, 2);
      expect(repository.requests, hasLength(9));
      expect(cubit.state.translations, upperTranslations());
      // Progress grows one item per completed batch.
      expect(progress.toSet().containsAll([1, 5, 9]), isTrue);
      await cubit.close();
    });

    test('a failed batch fails the translation and resume continues', () async {
      var fail = true;
      final repository = FakeTranslationRepository((engine, request) {
        if (fail && request.text == 'Pears') {
          return Stream.error(const MozhiApiException('down', statusCode: 503));
        }
        return Stream.value(result(request.text.toUpperCase()));
      });
      final cubit = buildCubit(
        repository: repository,
        batcher: const BlockBatcher(maxItems: 1),
        concurrency: 1,
      );
      await cubit.load(selection: googleToSpanish);

      expect(cubit.state.status, WebTranslateStatus.failure);
      expect(cubit.state.error, isA<MozhiApiException>());
      expect(cubit.state.translations.take(3), [
        sampleTexts[0].toUpperCase(),
        sampleTexts[1].toUpperCase(),
        sampleTexts[2].toUpperCase(),
      ]);
      expect(cubit.state.translations[3], isNull);
      expect(cubit.state.hasUntranslated, isTrue);

      fail = false;
      repository.requests.clear();
      await cubit.resume();
      expect(cubit.state.status, WebTranslateStatus.translated);
      expect(cubit.state.error, isNull);
      expect(cubit.state.translations, upperTranslations());
      // Only the missing items were requested again.
      expect(repository.requests.map((r) => r.text), [
        for (final (i, t) in sampleTexts.indexed)
          if (i >= 3 && i != codeIndex) t,
      ]);
      await cubit.close();
    });

    test('cancel stops the translation and resume finishes it', () async {
      final gates = <Completer<void>>[];
      final repository = FakeTranslationRepository((engine, request) async* {
        final gate = Completer<void>();
        gates.add(gate);
        await gate.future;
        yield result(request.text.toUpperCase());
      });
      final cubit = buildCubit(
        repository: repository,
        batcher: const BlockBatcher(maxItems: 1),
      );
      unawaited(cubit.load(selection: googleToSpanish));
      await waitFor(cubit, (s) => s.status == WebTranslateStatus.translating);
      await pumpEventQueue();
      expect(gates, hasLength(2));
      gates.first.complete();
      await waitFor(cubit, (s) => s.doneItems == 1);

      await cubit.cancel();
      expect(cubit.state.status, WebTranslateStatus.stopped);
      final done = cubit.state.doneItems;
      // Releasing a cancelled request changes nothing.
      for (final gate in gates) {
        if (!gate.isCompleted) gate.complete();
      }
      await pumpEventQueue();
      expect(cubit.state.status, WebTranslateStatus.stopped);
      expect(cubit.state.doneItems, done);

      repository.translator = upperCaseTranslator;
      await cubit.resume();
      expect(cubit.state.status, WebTranslateStatus.translated);
      expect(cubit.state.translations, upperTranslations());
      await cubit.close();
    });

    test('cancel while loading returns to idle and ignores the page', () async {
      final response = Completer<http.Response>();
      final cubit = buildCubit(client: MockClient((_) => response.future));
      unawaited(cubit.load(selection: googleToSpanish));
      await waitFor(cubit, (s) => s.status == WebTranslateStatus.loading);
      await cubit.cancel();
      expect(cubit.state.status, WebTranslateStatus.idle);
      response.complete(http.Response(samplePageHtml, 200));
      await pumpEventQueue();
      expect(cubit.state.status, WebTranslateStatus.idle);
      expect(cubit.state.page, isNull);
      await cubit.close();
    });

    test('cancel does nothing when idle', () async {
      final cubit = buildCubit();
      await cubit.cancel();
      expect(cubit.state.status, WebTranslateStatus.idle);
      await cubit.close();
    });

    test('a newer load wins over an older one', () async {
      final first = Completer<http.Response>();
      final cubit = buildCubit(
        client: MockClient(
          (request) => request.url.path == '/old'
              ? first.future
              : Future.value(
                  http.Response('<title>New</title><p>New page text.</p>', 200),
                ),
        ),
        url: 'example.com/old',
      );
      unawaited(cubit.load());
      await waitFor(cubit, (s) => s.status == WebTranslateStatus.loading);
      cubit.setUrl('example.com/new');
      await cubit.load();
      first.complete(http.Response('<title>Old</title><p>Old.</p>', 200));
      await pumpEventQueue();
      expect(cubit.state.page!.title, 'New');
      expect(cubit.state.status, WebTranslateStatus.loaded);
      await cubit.close();
    });

    test('reports download failures', () async {
      final cubit = buildCubit(client: htmlClient('gone', status: 404));
      await cubit.load(selection: googleToSpanish);
      expect(cubit.state.status, WebTranslateStatus.failure);
      expect(
        cubit.state.error,
        isA<WebPageException>()
            .having((e) => e.error, 'error', WebPageError.httpStatus)
            .having((e) => e.statusCode, 'statusCode', 404),
      );
      expect(cubit.state.page, isNull);
      await cubit.close();
    });

    test('reports extraction failures', () async {
      final cubit = buildCubit(
        extract: (page) async => throw StateError('broken'),
      );
      await cubit.load();
      expect(cubit.state.status, WebTranslateStatus.failure);
      expect(cubit.state.error, isA<StateError>());
      await cubit.close();
    });

    test('reports pages without readable content', () async {
      final cubit = buildCubit(
        client: htmlClient('<div id="app"></div><script>x()</script>'),
      );
      await cubit.load(selection: googleToSpanish);
      expect(cubit.state.status, WebTranslateStatus.failure);
      expect(
        cubit.state.error,
        isA<WebPageException>().having(
          (e) => e.error,
          'error',
          WebPageError.noContent,
        ),
      );
      expect(cubit.state.pageUri, Uri.parse('https://example.com/sample'));
      await cubit.close();
    });

    test('keeps truncation and charset information', () async {
      final cubit = WebTranslateCubit(
        repository: FakeTranslationRepository(),
        fetcher: WebPageFetcher(
          isWeb: false,
          maxBytes: 200,
          client: htmlClient(
            '<p>${'Long text, with commas. ' * 40}</p>',
            headers: {'content-type': 'text/html; charset=big5'},
          ),
        ),
        initialUrl: 'example.com',
      );
      await cubit.load();
      expect(cubit.state.truncated, isTrue);
      expect(cubit.state.unsupportedCharset, 'big5');
      await cubit.close();
    });

    test('translate restarts with a new selection', () async {
      final repository = FakeTranslationRepository();
      final cubit = buildCubit(repository: repository);
      await cubit.load(selection: googleToSpanish);
      repository.translator = (engine, request) =>
          Stream.value(result('[${request.target.code}] ${request.text}'));

      const toArabic = WebTranslateSelection(
        engine: googleEngine,
        source: Language.auto,
        target: arabic,
      );
      final translating = cubit.translate(toArabic);
      expect(cubit.state.status, WebTranslateStatus.translating);
      expect(cubit.state.translatedTitle, isNull);
      expect(cubit.state.translations.every((t) => t == null), isTrue);
      await translating;

      expect(cubit.state.selection, toArabic);
      expect(cubit.state.translatedTitle, startsWith('[ar]'));
      expect(cubit.state.status, WebTranslateStatus.translated);
      await cubit.close();
    });

    test('translate and resume need a page', () async {
      final repository = FakeTranslationRepository();
      final cubit = buildCubit(repository: repository);
      await cubit.translate(googleToSpanish);
      await cubit.resume();
      expect(cubit.state.status, WebTranslateStatus.idle);
      expect(repository.requests, isEmpty);
      await cubit.close();
    });

    test('close cancels in-flight work and closes the fetcher', () async {
      final gate = Completer<void>();
      final repository = FakeTranslationRepository((engine, request) async* {
        await gate.future;
        yield result('late');
      });
      final cubit = buildCubit(repository: repository);
      unawaited(cubit.load(selection: googleToSpanish));
      await waitFor(cubit, (s) => s.status == WebTranslateStatus.translating);
      await cubit.close();
      gate.complete();
      await pumpEventQueue();
      expect(cubit.isClosed, isTrue);
    });

    test('translates plain text documents', () async {
      final cubit = buildCubit(
        client: htmlClient(
          'Hello there.\n\nSecond paragraph.',
          headers: {'content-type': 'text/plain'},
        ),
        url: 'example.com/notes.txt',
      );
      await cubit.load(selection: googleToSpanish);
      expect(cubit.state.page!.title, 'notes.txt');
      expect(cubit.state.translations, ['HELLO THERE.', 'SECOND PARAGRAPH.']);
      await cubit.close();
    });
  });
}
