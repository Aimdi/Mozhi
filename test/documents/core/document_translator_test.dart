import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/documents/core/core.dart';
import 'package:translation_repository/translation_repository.dart';

class _MockRepository extends Mock implements TranslationRepository;

const _mozhi = TranslationEngine(
  id: 'mozhi:google',
  kind: EngineKind.mozhi,
  name: 'Google',
  mozhiEngine: 'google',
);
const _ai = TranslationEngine(
  id: 'ai:openai',
  kind: EngineKind.ai,
  name: 'OpenAI',
  providerId: 'openai',
);
const _en = Language(code: 'en', name: 'English');
const _de = Language(code: 'de', name: 'German');

TranslationResult _result(String text, {bool complete = true}) =>
    TranslationResult(
      engineId: 'mozhi:google',
      engineName: 'Google',
      text: text,
      isComplete: complete,
    );

void main() {
  late _MockRepository repository;
  late List<TranslationRequest> requests;

  setUpAll(() {
    registerFallbackValue(_mozhi);
    registerFallbackValue(
      const TranslationRequest(text: '', source: _en, target: _de),
    );
  });

  setUp(() {
    repository = _MockRepository();
    requests = [];
  });

  /// Stubs translate() with [respond] (default: upper-case the text).
  void stub([Stream<TranslationResult> Function(TranslationRequest)? respond]) {
    when(() => repository.translate(any(), any())).thenAnswer((invocation) {
      final request = invocation.positionalArguments[1] as TranslationRequest;
      requests.add(request);
      return respond?.call(request) ??
          Stream.value(_result(request.text.toUpperCase()));
    });
  }

  DocumentTranslator translator({int concurrency = 2, int maxAttempts = 3}) =>
      DocumentTranslator(
        repository: repository,
        concurrency: concurrency,
        maxAttempts: maxAttempts,
        retryDelay: Duration.zero,
      );

  ChunkPlan plan(List<String> texts, {int maxUnits = 40}) => Chunker(
    maxUnits: maxUnits,
  ).planSegments([for (final t in texts) Segment(t)], ChunkEncoding.markers);

  group('DocumentTranslator', () {
    test('translates every chunk and reports progress', () async {
      stub();
      final chunks = plan(['one', 'two', 'three'], maxUnits: 2);
      final events = await translator()
          .translate(chunks, engine: _mozhi, source: _en, target: _de)
          .toList();

      expect(events.first, const DocumentProgress(total: 2));
      expect(events.map((e) => e.done), [0, 1, 2, 2]);
      expect(events.map((e) => e.isComplete), [false, false, false, true]);
      final last = events.last;
      expect(last.fraction, 1);
      expect(last.failed, 0);
      expect(chunks.assemble(last.results), ['ONE', 'TWO', 'THREE']);
      expect(requests.first.text, '⟦1⟧ one\n⟦2⟧ two');
      expect(requests.first.source, _en);
      expect(requests.first.target, _de);
      expect(requests.first.options.preserveFormatting, isTrue);
      expect(requests.first.options.instructions, isEmpty);
    });

    test('uses the final result of streaming engines', () async {
      stub(
        (request) => Stream.fromIterable([
          _result('partial', complete: false),
          _result('  Done  '),
        ]),
      );
      final last = await translator()
          .translate(plan(['x']), engine: _ai, source: _en, target: _de)
          .last;
      expect(last.results, {
        0: ['Done'],
      });
    });

    test('tells AI engines to keep markers and placeholders', () async {
      stub();
      await translator()
          .translate(
            plan(['a', 'b ⟨1⟩']),
            engine: _ai,
            source: _en,
            target: _de,
            options: const TranslationOptions(
              instructions: 'Be brief',
              preserveFormatting: false,
            ),
          )
          .drain<void>();
      final options = requests.single.options;
      expect(options.preserveFormatting, isTrue);
      expect(
        options.instructions,
        '${DocumentTranslator.markerInstruction} Be brief',
      );
    });

    test('plain AI requests keep the user instructions', () async {
      stub();
      await translator()
          .translate(
            plan(['plain']),
            engine: _ai,
            source: _en,
            target: _de,
            options: const TranslationOptions(instructions: 'Be brief'),
          )
          .drain<void>();
      expect(requests.single.options.instructions, 'Be brief');
    });

    test(
      'falls back to unit-by-unit translation when markers are lost',
      () async {
        stub((request) {
          final text = request.text.replaceAll(BatchCodec.markerPattern, '');
          return Stream.value(_result(text.toUpperCase()));
        });
        final chunks = plan(['one', 'two']);
        final last = await translator()
            .translate(chunks, engine: _mozhi, source: _en, target: _de)
            .last;
        expect(requests.map((r) => r.text), ['⟦1⟧ one\n⟦2⟧ two', 'one', 'two']);
        expect(chunks.assemble(last.results), ['ONE', 'TWO']);
      },
    );

    test('retries retryable failures', () async {
      var calls = 0;
      stub((request) {
        calls++;
        if (calls < 3) {
          return Stream.error(const MozhiApiException('busy', statusCode: 503));
        }
        return Stream.value(_result('OK'));
      });
      final last = await translator()
          .translate(plan(['x']), engine: _mozhi, source: _en, target: _de)
          .last;
      expect(calls, 3);
      expect(last.results[0], ['OK']);
      expect(last.failures, isEmpty);
    });

    test('reports chunks that keep failing and continues', () async {
      stub((request) {
        if (request.text.contains('bad')) {
          return Stream.error(const MozhiApiException('down'));
        }
        return Stream.value(_result(request.text.toUpperCase()));
      });
      final chunks = plan(['bad', 'good'], maxUnits: 1);
      final last = await translator(maxAttempts: 2)
          .translate(chunks, engine: _mozhi, source: _en, target: _de)
          .last;
      expect(last.isComplete, isTrue);
      expect(last.failures.keys, [0]);
      expect(last.failures[0], isA<MozhiApiException>());
      expect(last.results.keys, [1]);
      expect(requests.where((r) => r.text == 'bad').length, 2);
    });

    test('does not retry errors that cannot succeed', () async {
      stub((request) => Stream.error(ArgumentError('custom target')));
      final last = await translator()
          .translate(plan(['x']), engine: _mozhi, source: _en, target: _de)
          .last;
      expect(requests.length, 1);
      expect(last.failures[0], isA<ArgumentError>());
    });

    test('empty translations fail the chunk', () async {
      stub((request) => const Stream.empty());
      final last = await translator(maxAttempts: 1)
          .translate(plan(['x']), engine: _mozhi, source: _en, target: _de)
          .last;
      expect(last.failures[0], isA<EmptyTranslationException>());
      expect(const EmptyTranslationException().toString(), isNotEmpty);
    });

    test('keeps at most `concurrency` requests in flight', () async {
      final pending = <Completer<String>>[];
      var inFlight = 0;
      var maxInFlight = 0;
      stub((request) {
        final completer = Completer<String>();
        pending.add(completer);
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        return Stream.fromFuture(
          completer.future.then((text) {
            inFlight--;
            return _result(text);
          }),
        );
      });
      final chunks = plan(['a', 'b', 'c', 'd', 'e'], maxUnits: 1);
      final done = translator()
          .translate(chunks, engine: _mozhi, source: _en, target: _de)
          .last;
      var completed = 0;
      while (completed < 5) {
        await pumpEventQueue();
        final open = pending.where((c) => !c.isCompleted).toList();
        expect(open.length, lessThanOrEqualTo(2));
        for (final completer in open) {
          completer.complete('T$completed');
          completed++;
        }
      }
      final last = await done;
      expect(maxInFlight, 2);
      expect(last.done, 5);
    });

    test('skips completed chunks and runs only the requested ones', () async {
      stub();
      final chunks = plan(['a', 'b', 'c'], maxUnits: 1);
      final events = await translator()
          .translate(
            chunks,
            engine: _mozhi,
            source: _en,
            target: _de,
            completed: const {
              0: ['A!'],
            },
            only: const [0, 2, 7],
          )
          .toList();
      expect(requests.map((r) => r.text), ['c']);
      expect(events.first.done, 1);
      expect(events.last.results, {
        0: ['A!'],
        2: ['C'],
      });
    });

    test('a run with nothing to do completes immediately', () async {
      stub();
      final events = await translator()
          .translate(
            plan(['a']),
            engine: _mozhi,
            source: _en,
            target: _de,
            completed: const {
              0: ['A'],
            },
          )
          .toList();
      expect(events.length, 1);
      expect(events.single.isComplete, isTrue);
      expect(const DocumentProgress(total: 0).fraction, 1);
    });

    test(
      'cancelling stops scheduling and cancels in-flight requests',
      () async {
        var cancelled = 0;
        stub((request) {
          late final StreamController<TranslationResult> controller;
          controller = StreamController(onCancel: () => cancelled++);
          return controller.stream;
        });
        final chunks = plan(['a', 'b', 'c'], maxUnits: 1);
        final events = <DocumentProgress>[];
        final subscription = translator()
            .translate(chunks, engine: _mozhi, source: _en, target: _de)
            .listen(events.add);
        await pumpEventQueue();
        expect(requests.length, 2);
        await subscription.cancel();
        await pumpEventQueue();
        expect(cancelled, 2);
        expect(requests.length, 2);
        expect(events.length, 1);
      },
    );

    test('cancelling during a retry delay stops the retry', () async {
      stub((request) => Stream.error(const MozhiApiException('busy')));
      final events = <DocumentProgress>[];
      final subscription =
          DocumentTranslator(
                repository: repository,
                retryDelay: const Duration(hours: 1),
              )
              .translate(plan(['a']), engine: _mozhi, source: _en, target: _de)
              .listen(events.add);
      await pumpEventQueue();
      expect(requests.length, 1);
      await subscription.cancel();
      await pumpEventQueue();
      expect(requests.length, 1);
      expect(events.length, 1);
    });

    test('cancelling between chunks emits nothing more', () async {
      final gate = Completer<void>();
      stub(
        (request) => Stream.fromFuture(
          gate.future.then((_) => _result(request.text.toUpperCase())),
        ),
      );
      final events = <DocumentProgress>[];
      final subscription = translator(concurrency: 1)
          .translate(
            plan(['a', 'b'], maxUnits: 1),
            engine: _mozhi,
            source: _en,
            target: _de,
          )
          .listen(events.add);
      await pumpEventQueue();
      gate.complete();
      await subscription.cancel();
      await pumpEventQueue();
      expect(events.length, 1);
    });
  });

  group('isRetryableError', () {
    test('classifies errors', () {
      bool retry(Object error) => DocumentTranslator.isRetryableError(error);
      expect(retry(const LlmRefusalException('no')), isFalse);
      expect(retry(const LlmApiException('x', statusCode: 401)), isFalse);
      expect(retry(const LlmApiException('x', statusCode: 404)), isFalse);
      expect(retry(const LlmApiException('x', statusCode: 429)), isTrue);
      expect(retry(const LlmApiException('x', statusCode: 408)), isTrue);
      expect(retry(const LlmApiException('x', statusCode: 502)), isTrue);
      expect(retry(const LlmApiException('x')), isTrue);
      expect(retry(const MozhiApiException('x')), isTrue);
      expect(retry(const MozhiApiException('x', statusCode: 400)), isFalse);
      expect(retry(ArgumentError()), isFalse);
      expect(retry(StateError('x')), isFalse);
      expect(retry(UnsupportedError('x')), isFalse);
      expect(retry(TimeoutException('x')), isTrue);
      expect(retry(const EmptyTranslationException()), isTrue);
    });
  });
}
