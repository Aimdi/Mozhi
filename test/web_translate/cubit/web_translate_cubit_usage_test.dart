import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/usage/usage.dart';
import 'package:mozhi/web_translate/web_translate.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

class _MockUsageTracker extends Mock implements UsageTracker;

/// An AI engine of a bring-your-own-key provider.
const _claude = TranslationEngine(
  id: 'ai:claude',
  kind: EngineKind.ai,
  name: 'Claude',
  providerId: 'claude',
);

const _claudeToSpanish = WebTranslateSelection(
  engine: _claude,
  source: Language.auto,
  target: spanish,
);

/// The page title and the translatable blocks of [samplePageHtml].
const _items = [
  'Sample page',
  'First paragraph of the sample page, long enough to be content.',
  'Section',
  'Apples',
  'Pears',
  'One',
  'A wise quote.',
  'A picture of fruit',
  'Last paragraph.',
];

void main() {
  late _MockUsageTracker tracker;

  setUp(() {
    tracker = _MockUsageTracker();
    when(
      () => tracker.recordText(
        any(),
        input: any(named: 'input'),
        output: any(named: 'output'),
      ),
    ).thenAnswer((_) async => const UsageStats(requests: 1));
  });

  WebTranslateCubit build(
    FakeTranslationRepository repository, {
    BlockBatcher batcher = const BlockBatcher(),
    int concurrency = 2,
    UsageTracker? usageTracker,
    bool withTracker = true,
  }) {
    final cubit = WebTranslateCubit(
      repository: repository,
      fetcher: WebPageFetcher(isWeb: false, client: htmlClient(samplePageHtml)),
      batcher: batcher,
      concurrency: concurrency,
      initialUrl: 'example.com/sample',
      usageTracker: withTracker ? usageTracker ?? tracker : null,
    );
    addTearDown(cubit.close);
    return cubit;
  }

  /// (provider, input, output) of every recorded request.
  List<(String, String, String)> recorded() {
    final captured = verify(
      () => tracker.recordText(
        captureAny(),
        input: captureAny(named: 'input'),
        output: captureAny(named: 'output'),
      ),
    ).captured;
    return [
      for (var i = 0; i < captured.length; i += 3)
        (
          captured[i] as String,
          captured[i + 1] as String,
          captured[i + 2] as String,
        ),
    ];
  }

  void verifyNothingRecorded() => verifyNever(
    () => tracker.recordText(
      any(),
      input: any(named: 'input'),
      output: any(named: 'output'),
    ),
  );

  /// Streams a partial, then the upper-cased result on [_claude].
  Stream<TranslationResult> streamingUpperCase(
    TranslationEngine engine,
    TranslationRequest request,
  ) => Stream.fromIterable([
    result('…', complete: false, engine: _claude),
    result(request.text.toUpperCase(), engine: _claude),
  ]);

  group('WebTranslateCubit usage', () {
    test('counts each answered batch once', () async {
      final repository = FakeTranslationRepository(streamingUpperCase);
      final cubit = build(repository);

      await cubit.load(selection: _claudeToSpanish);
      await pumpEventQueue();

      expect(cubit.state.status, WebTranslateStatus.translated);
      final batch = _items.join('\n\n');
      expect(recorded(), [('claude', batch, batch.toUpperCase())]);
    });

    test('counts every request of a page translated block by block', () async {
      final repository = FakeTranslationRepository(streamingUpperCase);
      final cubit = build(
        repository,
        batcher: const BlockBatcher(maxItems: 1),
        concurrency: 1,
      );

      await cubit.load(selection: _claudeToSpanish);
      await pumpEventQueue();

      expect(recorded(), [
        for (final item in _items) ('claude', item, item.toUpperCase()),
      ]);
    });

    test(
      'counts the batch and the retries when a batch cannot be split',
      () async {
        final repository = FakeTranslationRepository(
          (engine, request) => Stream.value(
            // Merges paragraphs: the batch result has no blank lines.
            result(
              request.text.replaceAll('\n\n', ' ').toUpperCase(),
              engine: _claude,
            ),
          ),
        );
        final cubit = build(
          repository,
          batcher: const BlockBatcher(maxItems: 3),
        );

        await cubit.load(selection: _claudeToSpanish);
        await pumpEventQueue();

        expect(cubit.state.status, WebTranslateStatus.translated);
        // Three batches of three, then each item on its own.
        expect(recorded(), hasLength(3 + 9));
      },
    );

    test('does not count results from the cache', () async {
      final repository = FakeTranslationRepository(
        (engine, request) => Stream.value(
          result(
            request.text.toUpperCase(),
            engine: _claude,
          ).copyWith(fromCache: true),
        ),
      );
      final cubit = build(repository);

      await cubit.load(selection: _claudeToSpanish);
      await pumpEventQueue();

      expect(cubit.state.status, WebTranslateStatus.translated);
      verifyNothingRecorded();
    });

    test('does not count a stream without a complete result', () async {
      final repository = FakeTranslationRepository(
        (engine, request) =>
            Stream.value(result('…', complete: false, engine: _claude)),
      );
      final cubit = build(repository, batcher: const BlockBatcher(maxItems: 1));

      await cubit.load(selection: _claudeToSpanish);
      await pumpEventQueue();

      expect(cubit.state.status, WebTranslateStatus.translated);
      verifyNothingRecorded();
    });

    test('does not count engines without a provider id', () async {
      final repository = FakeTranslationRepository();
      final cubit = build(repository);

      await cubit.load(selection: googleToSpanish);
      await pumpEventQueue();

      expect(cubit.state.status, WebTranslateStatus.translated);
      expect(repository.requests, isNotEmpty);
      verifyNothingRecorded();
    });

    test('does not count failed requests', () async {
      final repository = FakeTranslationRepository((engine, request) {
        if (request.text == 'Pears') {
          return Stream.fromIterable([
            result('…', complete: false, engine: _claude),
          ]).followedBy(const LlmApiException('Overloaded'));
        }
        return Stream.value(
          result(request.text.toUpperCase(), engine: _claude),
        );
      });
      final cubit = build(
        repository,
        batcher: const BlockBatcher(maxItems: 1),
        concurrency: 1,
      );

      await cubit.load(selection: _claudeToSpanish);
      await pumpEventQueue();

      expect(cubit.state.status, WebTranslateStatus.failure);
      expect(recorded().map((entry) => entry.$2), [
        'Sample page',
        'First paragraph of the sample page, long enough to be content.',
        'Section',
        'Apples',
      ]);
    });

    test('does not count cancelled requests', () async {
      final gates = <Completer<void>>[];
      final repository = FakeTranslationRepository((engine, request) async* {
        final gate = Completer<void>();
        gates.add(gate);
        await gate.future;
        yield result(request.text.toUpperCase(), engine: _claude);
      });
      final cubit = build(repository, batcher: const BlockBatcher(maxItems: 1));
      unawaited(cubit.load(selection: _claudeToSpanish));
      await waitFor(cubit, (s) => s.status == WebTranslateStatus.translating);
      await pumpEventQueue();
      expect(gates, hasLength(2));
      gates.first.complete();
      await waitFor(cubit, (s) => s.translatedTitle != null);

      await cubit.cancel();
      for (final gate in gates) {
        if (!gate.isCompleted) gate.complete();
      }
      await pumpEventQueue();

      expect(cubit.state.status, WebTranslateStatus.stopped);
      expect(recorded(), [('claude', 'Sample page', 'SAMPLE PAGE')]);
    });

    test('works without a tracker', () async {
      final repository = FakeTranslationRepository(streamingUpperCase);
      final cubit = build(repository, withTracker: false);

      await cubit.load(selection: _claudeToSpanish);

      expect(cubit.state.status, WebTranslateStatus.translated);
      verifyNothingRecorded();
    });

    test('ignores tracker errors', () async {
      final throwing = _MockUsageTracker();
      when(
        () => throwing.recordText(
          any(),
          input: any(named: 'input'),
          output: any(named: 'output'),
        ),
      ).thenThrow(StateError('broken'));
      final cubit = build(
        FakeTranslationRepository(streamingUpperCase),
        usageTracker: throwing,
      );
      await cubit.load(selection: _claudeToSpanish);
      expect(cubit.state.status, WebTranslateStatus.translated);

      final failing = _MockUsageTracker();
      when(
        () => failing.recordText(
          any(),
          input: any(named: 'input'),
          output: any(named: 'output'),
        ),
      ).thenAnswer((_) async => throw StateError('disk full'));
      final other = build(
        FakeTranslationRepository(streamingUpperCase),
        usageTracker: failing,
      );
      await other.load(selection: _claudeToSpanish);
      await pumpEventQueue();
      expect(other.state.status, WebTranslateStatus.translated);
    });
  });
}

extension<T> on Stream<T> {
  /// This stream's events, then [error].
  Stream<T> followedBy(Exception error) async* {
    yield* this;
    throw error;
  }
}
