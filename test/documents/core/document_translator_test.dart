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
    test('sums what the personal data shield kept on the device', () async {
      stub(
        (request) => Stream.fromIterable([
          _result('…', complete: false).copyWith(maskedPersonalData: 9),
          _result(request.text.toUpperCase()).copyWith(maskedPersonalData: 2),
        ]),
      );
      final events = await translator()
          .translate(
            plan(['one', 'two', 'three'], maxUnits: 1),
            engine: _mozhi,
            source: _en,
            target: _de,
          )
          .toList();
      // Each request's final result counts once.
      expect(events.first.maskedPersonalData, 0);
      expect(events.last.isComplete, isTrue);
      expect(events.last.maskedPersonalData, 6);
      expect(
        events.last,
        isNot(
          DocumentProgress(
            total: events.last.total,
            results: events.last.results,
            isComplete: true,
          ),
        ),
      );
    });

    group('onTranslated', () {
      test('reports each answered request but not cache hits', () async {
        stub(
          (request) => Stream.value(
            _result(request.text.toUpperCase())
                .copyWith(fromCache: request.text.contains('two')),
          ),
        );
        final calls = <(String, String, String)>[];
        final chunks = plan(['one', 'two', 'three'], maxUnits: 1);
        await DocumentTranslator(
          repository: repository,
          retryDelay: Duration.zero,
          onTranslated: (engine, request, result) =>
              calls.add((engine.id, request.text, result.text)),
        ).translate(chunks, engine: _ai, source: _en, target: _de).toList();

        expect(calls, hasLength(2));
        expect(calls.map((c) => c.$1).toSet(), {'ai:openai'});
        expect(calls.map((c) => c.$3), containsAll(['ONE', 'THREE']));
      });

      test('ignores errors thrown by the callback', () async {
        stub();
        final chunks = plan(['one']);
        final last = await DocumentTranslator(
          repository: repository,
          retryDelay: Duration.zero,
          onTranslated: (_, _, _) => throw StateError('broken'),
        ).translate(chunks, engine: _ai, source: _en, target: _de).last;

        expect(last.failed, 0);
        expect(chunks.assemble(last.results), ['ONE']);
      });
    });

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

  group('language detection', () {
    final offline = TranslationEngine.offline();
    const gemma = TranslationEngine(
      id: 'ai:gemma',
      kind: EngineKind.ai,
      name: 'TranslateGemma',
      isLocal: true,
      promptProfile: PromptProfile.translateGemma,
    );
    const long = 'A paragraph that is long enough to tell its language.';

    /// Like the on-device engine: with an auto source, text shorter than 20
    /// characters cannot be identified and longer text is English; with an
    /// explicit source the text is upper-cased.
    void stubOffline() => stub((request) {
      if (request.source.isAuto) {
        if (request.text.length < 20) {
          return Stream.error(
            const SourceLanguageRequiredException(engineId: 'offline:mlkit'),
          );
        }
        return Stream.value(
          _result(request.text.toUpperCase()).copyWith(detectedSource: 'en'),
        );
      }
      return Stream.value(_result(request.text.toUpperCase()));
    });

    /// Stubs detectLanguage with [detect] (default: cannot tell).
    void stubDetection([
      Future<DetectedLanguage> Function(String text)? detect,
    ]) {
      when(() => repository.detectLanguage(any(), engine: any(named: 'engine')))
          .thenAnswer((invocation) async {
            final text = invocation.positionalArguments.single as String;
            if (detect == null) throw const SourceLanguageRequiredException();
            return await detect(text);
          });
    }

    Future<DetectedLanguage> english(String text) async =>
        const DetectedLanguage(code: 'en');

    /// (sample, engine) of every detectLanguage call.
    List<(String, TranslationEngine?)> detections() {
      final captured = verify(
        () => repository.detectLanguage(
          captureAny(),
          engine: captureAny(named: 'engine'),
        ),
      ).captured;
      return [
        for (var i = 0; i < captured.length; i += 2)
          (captured[i] as String, captured[i + 1] as TranslationEngine?),
      ];
    }

    /// Sources of the requests for [text].
    List<String> sourcesOf(String text) => [
      for (final request in requests)
        if (request.text == text) request.source.code,
    ];

    setUp(() {
      when(() => repository.hasOfflineEngine).thenReturn(true);
      stubDetection();
      stubOffline();
    });

    test('identifies the document language once on the device and '
        'translates every chunk from it', () async {
      stubDetection(english);
      final chunks = plan(['Hi', long, 'Bye'], maxUnits: 1);
      final last = await translator()
          .translate(
            chunks,
            engine: offline,
            source: Language.auto,
            target: _de,
          )
          .last;

      expect(detections(), [('Hi\n\n$long\n\nBye', offline)]);
      expect(requests, hasLength(3));
      expect(requests.map((r) => r.source.code).toSet(), {'en'});
      expect(last.failures, isEmpty);
      expect(chunks.assemble(last.results), ['HI', long.toUpperCase(), 'BYE']);
    });

    test('keeps a chunk whose language cannot be told when none is known '
        'yet', () async {
      final chunks = plan(['Hi', long], maxUnits: 1);
      final last = await translator(concurrency: 1)
          .translate(
            chunks,
            engine: offline,
            source: Language.auto,
            target: _de,
          )
          .last;

      expect(detections(), hasLength(1));
      expect(last.isComplete, isTrue);
      expect(last.failures, isEmpty);
      expect(chunks.assemble(last.results), ['Hi', long.toUpperCase()]);
      // Not retried.
      expect(sourcesOf('Hi'), ['auto']);
    });

    test('translates later undetectable chunks from the language detected '
        'for earlier ones', () async {
      final chunks = plan([long, 'Hi', 'Bye'], maxUnits: 1);
      final last = await translator(concurrency: 1)
          .translate(
            chunks,
            engine: offline,
            source: Language.auto,
            target: _de,
          )
          .last;

      expect(sourcesOf(long), ['auto']);
      expect(sourcesOf('Hi'), ['auto', 'en']);
      expect(sourcesOf('Bye'), ['auto', 'en']);
      expect(last.failures, isEmpty);
      expect(chunks.assemble(last.results), [long.toUpperCase(), 'HI', 'BYE']);
    });

    test('keeps a whole batch whose language cannot be told', () async {
      final chunks = plan(['one', 'two']);
      final last = await translator()
          .translate(
            chunks,
            engine: offline,
            source: Language.auto,
            target: _de,
          )
          .last;

      expect(requests, hasLength(1));
      expect(last.failures, isEmpty);
      expect(chunks.assemble(last.results), ['one', 'two']);
    });

    test('keeps a unit whose language cannot be told after the alignment '
        'is lost', () async {
      stub((request) {
        if (request.text.contains(BatchCodec.markerOpen)) {
          // Markers lost, nothing detected.
          final text = request.text.replaceAll(BatchCodec.markerPattern, '');
          return Stream.value(_result(text.toUpperCase()));
        }
        if (request.text.length < 20) {
          return Stream.error(const SourceLanguageRequiredException());
        }
        return Stream.value(_result(request.text.toUpperCase()));
      });
      final chunks = plan(['one', long]);
      final last = await translator()
          .translate(
            chunks,
            engine: offline,
            source: Language.auto,
            target: _de,
          )
          .last;

      expect(requests, hasLength(3));
      expect(chunks.assemble(last.results), ['one', long.toUpperCase()]);
    });

    test(
      'identifies on the device for translation-specialised models',
      () async {
        stubDetection((text) async => const DetectedLanguage(code: 'qaa'));
        final chunks = plan(['Hi', long], maxUnits: 1);
        final last = await translator()
            .translate(
              chunks,
              engine: gemma,
              source: Language.auto,
              target: _de,
            )
            .last;

        // Asked with the offline engine: the on-device identifier answers.
        expect(detections().single.$2, offline);
        // A language missing from the catalogue is used by its code.
        expect(requests.map((r) => (r.source.code, r.source.name)).toSet(), {
          ('qaa', 'qaa'),
        });
        expect(last.done, 2);
      },
    );

    test('engines that detect per request are not identified first', () async {
      stubDetection(english);
      stub();
      await translator()
          .translate(
            plan(['Hi']),
            engine: _mozhi,
            source: Language.auto,
            target: _de,
          )
          .drain<void>();

      verifyNever(
        () => repository.detectLanguage(any(), engine: any(named: 'engine')),
      );
      expect(requests.single.source, Language.auto);
    });

    test('nothing is identified without an on-device engine', () async {
      when(() => repository.hasOfflineEngine).thenReturn(false);
      stubDetection(english);
      final last = await translator()
          .translate(
            plan([long]),
            engine: offline,
            source: Language.auto,
            target: _de,
          )
          .last;

      verifyNever(
        () => repository.detectLanguage(any(), engine: any(named: 'engine')),
      );
      expect(requests.single.source, Language.auto);
      expect(last.done, 1);
    });

    test('a blank detection is ignored', () async {
      stubDetection((text) async => const DetectedLanguage(code: ' '));
      await translator()
          .translate(
            plan([long]),
            engine: offline,
            source: Language.auto,
            target: _de,
          )
          .drain<void>();

      expect(detections(), hasLength(1));
      expect(requests.single.source, Language.auto);
    });

    test('a document of placeholders only is not identified', () async {
      final chunks = plan(['⟨1⟩']);
      final last = await translator()
          .translate(
            chunks,
            engine: offline,
            source: Language.auto,
            target: _de,
          )
          .last;

      verifyNever(
        () => repository.detectLanguage(any(), engine: any(named: 'engine')),
      );
      expect(chunks.assemble(last.results), ['⟨1⟩']);
    });

    test('an explicit source is never identified and its errors still fail '
        'the chunk', () async {
      stubDetection(english);
      stub((request) => Stream.error(const SourceLanguageRequiredException()));
      final last = await translator()
          .translate(plan(['Hi']), engine: offline, source: _en, target: _de)
          .last;

      verifyNever(
        () => repository.detectLanguage(any(), engine: any(named: 'engine')),
      );
      expect(last.failures[0], isA<SourceLanguageRequiredException>());
      // Not retried: it cannot succeed.
      expect(requests, hasLength(1));
    });

    test('cancelling while the language is identified sends nothing', () async {
      final detection = Completer<DetectedLanguage>();
      stubDetection((text) => detection.future);
      final events = <DocumentProgress>[];
      final subscription = translator()
          .translate(
            plan(['Hi']),
            engine: offline,
            source: Language.auto,
            target: _de,
          )
          .listen(events.add);
      await pumpEventQueue();
      expect(detections(), hasLength(1));

      await subscription.cancel();
      detection.complete(const DetectedLanguage(code: 'en'));
      await pumpEventQueue();
      expect(requests, isEmpty);
      expect(events, hasLength(1));
    });

    test('the sample skips placeholders and is capped without splitting a '
        'surrogate pair', () async {
      stubDetection(english);
      final chunks = plan(['T ⟨1⟩  x', '😀' * 3000, 'More text']);
      await translator()
          .translate(
            chunks,
            engine: offline,
            source: Language.auto,
            target: _de,
          )
          .drain<void>();

      final sample = detections().single.$1;
      expect(sample, startsWith('T x\n\n😀'));
      expect(sample, isNot(contains('More')));
      expect(sample.length, DocumentTranslator.detectionSampleLength - 1);
      // Ends with a whole emoji.
      expect(
        sample.codeUnitAt(sample.length - 1),
        inInclusiveRange(0xDC00, 0xDFFF),
      );
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
      expect(retry(const SourceLanguageRequiredException()), isFalse);
      expect(retry(ArgumentError()), isFalse);
      expect(retry(StateError('x')), isFalse);
      expect(retry(UnsupportedError('x')), isFalse);
      expect(retry(TimeoutException('x')), isTrue);
      expect(retry(const EmptyTranslationException()), isTrue);
    });
  });
}
