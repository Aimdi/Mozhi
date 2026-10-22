import 'dart:async';

import 'package:llm_api/llm_api.dart';
import 'package:test/test.dart';
import 'package:translation_repository/src/chunking/chunked_translation.dart';
import 'package:translation_repository/src/chunking/paragraph_chunker.dart';
import 'package:translation_repository/src/models/models.dart';

const engine = TranslationEngine(
  id: 'ai:claude',
  kind: EngineKind.ai,
  name: 'Claude',
);

const english = Language(code: 'en', name: 'English');
const german = Language(code: 'de', name: 'German');

const chunks = [
  TextChunk(text: 'Anna lives in Zurich.', separator: '\n\n'),
  TextChunk(text: 'She works for Mozhi.', separator: '\n\n'),
  TextChunk(text: 'Anna likes Zurich.'),
];

/// Retries at once, so that the tests do not wait.
const immediate = LlmRetryPolicy(baseDelay: Duration.zero);

const overloaded = LlmApiException('Overloaded', statusCode: 529);

/// One chunk request and the controller that answers it.
class Call {
  new(this.request, this.context);

  final TranslationRequest request;
  final ChunkContext context;
  bool cancelled = false;
  bool paused = false;
  late final controller = StreamController<TranslationResult>(
    onCancel: () => cancelled = true,
    onPause: () => paused = true,
    onResume: () => paused = false,
  );

  void snapshot(String text) => controller.add(
    TranslationResult(
      engineId: engine.id,
      engineName: engine.name,
      text: text,
      isComplete: false,
    ),
  );

  Future<void> finish(String text, {String? detected}) async {
    controller.add(
      TranslationResult(
        engineId: engine.id,
        engineName: engine.name,
        text: text,
        detectedSource: detected,
      ),
    );
    await controller.close();
  }

  Future<void> fail(Object error) async {
    controller.addError(error);
    await controller.close();
  }
}

void main() {
  late List<Call> calls;

  Stream<TranslationResult> translate(
    TranslationRequest request,
    ChunkContext context,
  ) {
    final call = Call(request, context);
    calls.add(call);
    return call.controller.stream;
  }

  final request = TranslationRequest(
    text: chunks.map((c) => '${c.text}${c.separator}').join(),
    source: english,
    target: german,
  );

  Stream<TranslationResult> chunked({
    TranslationRequest? text,
    List<TextChunk> parts = chunks,
    int concurrency = 2,
    int contextChars = 400,
    int maxTerms = 30,
    LlmRetryPolicy retryPolicy = immediate,
    ChunkCache? cache,
    bool refresh = false,
  }) => chunkedTranslation(
    engine: engine,
    request: text ?? request,
    chunks: parts,
    translateInContext: translate,
    languageFor: (code) => Language(code: code, name: code),
    concurrency: concurrency,
    contextChars: contextChars,
    maxTerms: maxTerms,
    retryPolicy: retryPolicy,
    cache: cache,
    refresh: refresh,
  );

  /// Calls for the chunk with [text], in order.
  List<Call> callsFor(String text) =>
      calls.where((call) => call.request.text == text).toList();

  setUp(() => calls = []);

  group('chunkedTranslation context', () {
    test('needs exactly one translate callback', () {
      expect(
        () => chunkedTranslation(
          engine: engine,
          request: request,
          chunks: chunks,
          languageFor: (code) => english,
        ),
        throwsArgumentError,
      );
      expect(
        () => chunkedTranslation(
          engine: engine,
          request: request,
          chunks: chunks,
          languageFor: (code) => english,
          translate: (_, _) => const Stream.empty(),
          translateInContext: translate,
        ),
        throwsArgumentError,
      );
    });

    test('gives each chunk the preceding text, the latest finished '
        'translation and the running term map', () async {
      final done = Completer<void>();
      chunked().listen((_) {}, onDone: done.complete);
      await pumpEventQueue();
      expect(calls, hasLength(2));
      expect(calls[0].context, const ChunkContext(count: 3));
      // The second chunk starts with the first: nothing finished yet.
      expect(
        calls[1].context,
        const ChunkContext(
          index: 1,
          count: 3,
          precedingText: 'Anna lives in Zurich.',
        ),
      );

      await calls[0].finish('Anna wohnt in Zürich.');
      await pumpEventQueue();
      expect(calls, hasLength(3));
      expect(
        calls[2].context,
        const ChunkContext(
          index: 2,
          count: 3,
          precedingText: 'She works for Mozhi.',
          precedingTranslation: 'Anna wohnt in Zürich.',
          terms: {'Zurich': 'Zürich'},
        ),
      );
      await calls[1].finish('Sie arbeitet für Mozhi.');
      await calls[2].finish('Anna mag Zürich.');
      await done.future;
    });

    test('the preceding translation is the latest finished chunk before '
        'it, shortened', () async {
      chunked(concurrency: 1, contextChars: 12).listen((_) {});
      await pumpEventQueue();
      await calls[0].finish('Anna wohnt seit Jahren in Zürich.');
      await pumpEventQueue();
      expect(
        calls[1].context.precedingTranslation,
        precedingTextTail('Anna wohnt seit Jahren in Zürich.', maxChars: 12),
      );
      await calls[1].finish('Sie arbeitet für Mozhi.');
      await pumpEventQueue();
      expect(
        calls[2].context.precedingTranslation,
        precedingTextTail('Sie arbeitet für Mozhi.', maxChars: 12),
      );
    });

    test(
      'glossary terms of finished chunks come first in the term map',
      () async {
        chunked(
          concurrency: 1,
          text: request.copyWith(
            options: const TranslationOptions(glossary: {'works': 'arbeitet'}),
          ),
        ).listen((_) {});
        await pumpEventQueue();
        await calls[0].finish('Anna wohnt in Zürich.');
        await pumpEventQueue();
        await calls[1].finish('Sie arbeitet für Mozhi.');
        await pumpEventQueue();
        expect(calls[2].context.terms, {
          'works': 'arbeitet',
          'Zurich': 'Zürich',
          'Mozhi': 'Mozhi',
        });
      },
    );

    test('caps the term map', () async {
      chunked(concurrency: 1, maxTerms: 1).listen((_) {});
      await pumpEventQueue();
      await calls[0].finish('Anna wohnt in Zürich.');
      await pumpEventQueue();
      await calls[1].finish('Sie arbeitet für Mozhi.');
      await pumpEventQueue();
      expect(calls[2].context.terms, {'Zurich': 'Zürich'});
    });

    test('the older translate callback gets the preceding text', () async {
      final preceding = <String>[];
      chunkedTranslation(
        engine: engine,
        request: request,
        chunks: chunks,
        languageFor: (code) => english,
        translate: (chunk, text) {
          preceding.add(text);
          return const Stream.empty();
        },
      ).listen((_) {});
      await pumpEventQueue();
      expect(preceding, ['', 'Anna lives in Zurich.', 'She works for Mozhi.']);
    });
  });

  group('chunkedTranslation retries', () {
    test(
      'a chunk that failed with a transient error, keeping the others',
      () async {
        final results = <TranslationResult>[];
        final done = Completer<void>();
        chunked().listen(results.add, onDone: done.complete);
        await pumpEventQueue();
        await calls[0].finish('Eins.');
        await calls[1].fail(overloaded);
        await pumpEventQueue();
        final second = callsFor('She works for Mozhi.');
        expect(second, hasLength(2));
        // The retry has the newer context.
        expect(second.last.context.precedingTranslation, 'Eins.');
        // The third chunk started after the first finished; the retry counts
        // towards the concurrency.
        expect(calls, hasLength(4));
        await second.last.finish('Zwei.');
        await callsFor('Anna likes Zurich.').single.finish('Drei.');
        await done.future;
        expect(results.last.text, 'Eins.\n\nZwei.\n\nDrei.');
        expect(results.last.isComplete, isTrue);
        expect(callsFor('Anna lives in Zurich.'), hasLength(1));
      },
    );

    test('a chunk whose request threw a transient error', () async {
      var thrown = false;
      final results = <TranslationResult>[];
      final done = Completer<void>();
      chunkedTranslation(
        engine: engine,
        request: request,
        chunks: chunks.sublist(0, 1),
        languageFor: (code) => english,
        retryPolicy: immediate,
        translateInContext: (chunk, context) {
          if (!thrown) {
            thrown = true;
            throw overloaded;
          }
          return Stream.value(
            TranslationResult(
              engineId: engine.id,
              engineName: engine.name,
              text: 'Eins.',
            ),
          );
        },
      ).listen(results.add, onDone: done.complete);
      await done.future;
      expect(results.last.text, 'Eins.');
      expect(results.last.isComplete, isTrue);
      expect(thrown, isTrue);
    });

    test('after the wait of the policy, which counts as running', () async {
      chunked(
        concurrency: 1,
        retryPolicy: const LlmRetryPolicy(
          baseDelay: Duration(milliseconds: 40),
        ),
      ).listen((_) {});
      await pumpEventQueue();
      await calls[0].fail(overloaded);
      await pumpEventQueue();
      expect(calls, hasLength(1), reason: 'waiting, nothing else started');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(calls, hasLength(2));
      expect(calls[1].request.text, chunks[0].text);
    });

    test(
      'when a chunk still fails: a partial result, then the error',
      () async {
        final events = <Object>[];
        final done = Completer<void>();
        chunked().listen(
          events.add,
          onError: events.add,
          onDone: done.complete,
        );
        await pumpEventQueue();
        await calls[0].finish('Eins.');
        await pumpEventQueue();
        callsFor('Anna likes Zurich.').single.snapshot('Dr');
        await calls[1].fail(overloaded);
        await pumpEventQueue();
        await callsFor('She works for Mozhi.').last.fail(overloaded);
        await done.future;

        final results = events.whereType<TranslationResult>().toList();
        // The partial result keeps the finished first chunk only.
        expect(results.last.text, 'Eins.');
        expect(results.last.isComplete, isFalse);
        expect(events.last, same(overloaded));
        expect(callsFor('Anna likes Zurich.').single.cancelled, isTrue);
      },
    );

    test('no partial result when nothing finished', () async {
      final events = <Object>[];
      final done = Completer<void>();
      chunked(retryPolicy: LlmRetryPolicy.none)
          .listen(events.add, onError: events.add, onDone: done.complete);
      await pumpEventQueue();
      calls[0].snapshot('Ei');
      await pumpEventQueue();
      await calls[1].fail(overloaded);
      await done.future;
      expect(events, hasLength(2));
      expect((events.first as TranslationResult).text, 'Ei');
      expect(events.last, same(overloaded));
      expect(calls, hasLength(2), reason: 'not retried');
    });

    test('no partial result that repeats the last snapshot', () async {
      final events = <Object>[];
      final done = Completer<void>();
      chunked(concurrency: 1)
          .listen(events.add, onError: events.add, onDone: done.complete);
      await pumpEventQueue();
      await calls[0].finish('Eins.');
      await pumpEventQueue();
      await calls[1].fail(
        const LlmApiException('Bad request', statusCode: 400),
      );
      await done.future;
      expect(events.whereType<TranslationResult>().map((r) => r.text), [
        'Eins.',
      ]);
      expect(calls, hasLength(2), reason: 'a 400 is not retried');
    });

    test('other errors are not retried', () async {
      final done = Completer<void>();
      Object? error;
      chunked().listen(
        (_) {},
        onError: (Object e) => error = e,
        onDone: done.complete,
      );
      await pumpEventQueue();
      await calls[0].fail(StateError('boom'));
      await done.future;
      expect(error, isA<StateError>());
      expect(calls, hasLength(2));
    });

    test('cancelling during the wait stops the retry', () async {
      final subscription = chunked(
        retryPolicy: const LlmRetryPolicy(baseDelay: Duration(minutes: 5)),
      ).listen((_) {});
      await pumpEventQueue();
      await calls[0].fail(overloaded);
      await pumpEventQueue();
      await subscription.cancel();
      expect(calls[1].cancelled, isTrue);
      expect(calls, hasLength(2));
    });

    test('a chunk stopped during the wait is not retried', () async {
      final done = Completer<void>();
      chunked(
        retryPolicy: const LlmRetryPolicy(baseDelay: Duration(minutes: 5)),
      ).listen((_) {}, onError: (_) {}, onDone: done.complete);
      await pumpEventQueue();
      await calls[0].fail(overloaded);
      await calls[1].fail(StateError('boom'));
      await done.future;
      expect(calls, hasLength(2));
    });

    test('a retry started while paused starts paused', () async {
      final subscription = chunked(
        concurrency: 1,
        retryPolicy: const LlmRetryPolicy(
          baseDelay: Duration(milliseconds: 30),
        ),
      ).listen((_) {});
      await pumpEventQueue();
      await calls[0].fail(overloaded);
      subscription.pause();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(calls, hasLength(2));
      expect(calls[1].paused, isTrue);
      subscription.resume();
      expect(calls[1].paused, isFalse);
      await subscription.cancel();
    });
  });

  group('chunkedTranslation cache', () {
    Future<List<TranslationResult>> run(
      ChunkCache cache, {
      TranslationRequest? text,
      List<TextChunk> parts = chunks,
      bool refresh = false,
      Map<String, String> answers = const {},
    }) async {
      final results = <TranslationResult>[];
      final done = Completer<void>();
      chunked(
        text: text,
        parts: parts,
        cache: cache,
        refresh: refresh,
        concurrency: 3,
      ).listen(results.add, onDone: done.complete);
      // Answer every call as it comes.
      var answered = 0;
      for (var round = 0; round < 50 && !done.isCompleted; round++) {
        await pumpEventQueue();
        for (final call in calls.sublist(answered)) {
          answered++;
          await call.finish(
            answers[call.request.text] ?? call.request.text.toUpperCase(),
          );
        }
      }
      expect(done.isCompleted, isTrue);
      return results;
    }

    test('reuses finished chunks, sending only what changed', () async {
      final cache = MemoryChunkCache();
      final first = await run(cache);
      expect(first.last.fromCache, isFalse);
      expect(calls, hasLength(3));
      expect(cache.length, 3);

      calls.clear();
      final again = await run(cache);
      expect(calls, isEmpty);
      expect(again.last.text, first.last.text);
      expect(again.last.fromCache, isTrue);
      expect(again.last.isComplete, isTrue);

      // Change the last part: only it is sent again.
      calls.clear();
      final edited = [
        chunks[0],
        chunks[1],
        const TextChunk(text: 'Anna loves Zurich.'),
      ];
      final changed = await run(cache, parts: edited);
      expect(calls.map((c) => c.request.text), ['Anna loves Zurich.']);
      expect(changed.last.fromCache, isFalse);
      expect(changed.last.text, endsWith('ANNA LOVES ZURICH.'));
    });

    test(
      'a changed chunk also resends the next one (its preceding text)',
      () async {
        final cache = MemoryChunkCache();
        await run(cache);
        calls.clear();
        await run(
          cache,
          parts: [
            const TextChunk(text: 'Anna lived in Zurich.', separator: '\n\n'),
            chunks[1],
            chunks[2],
          ],
        );
        expect(calls.map((c) => c.request.text), [
          'Anna lived in Zurich.',
          'She works for Mozhi.',
        ]);
      },
    );

    test('is keyed by engine, languages and options', () async {
      final cache = MemoryChunkCache();
      await run(cache);
      calls.clear();
      await run(
        cache,
        text: request.copyWith(
          options: const TranslationOptions(formality: Formality.more),
        ),
      );
      expect(calls, hasLength(3));
    });

    test('refresh sends every chunk and stores the new translations', () async {
      final cache = MemoryChunkCache();
      await run(cache);
      calls.clear();
      await run(cache, refresh: true, answers: {chunks[0].text: 'Neu.'});
      expect(calls, hasLength(3));
      calls.clear();
      final results = await run(cache);
      expect(calls, isEmpty);
      expect(results.last.text, startsWith('Neu.'));
    });

    test('pins the source from a cached first chunk', () async {
      final cache = MemoryChunkCache();
      final auto = request.copyWith(source: Language.auto);
      final results = <TranslationResult>[];
      final done = Completer<void>();
      chunked(
        text: auto,
        cache: cache,
      ).listen(results.add, onDone: done.complete);
      await pumpEventQueue();
      await calls[0].finish('Eins.', detected: 'en');
      await pumpEventQueue();
      expect(calls[1].request.source.code, 'en');
      await calls[1].finish('Zwei.');
      await calls[2].finish('Drei.');
      await done.future;

      calls.clear();
      final again = await run(cache, text: auto);
      expect(calls, isEmpty);
      expect(again.last.detectedSource, 'en');
    });

    test('does not store chunks that ended without a final result', () async {
      final cache = MemoryChunkCache();
      final done = Completer<void>();
      chunked(
        parts: chunks.sublist(0, 1),
        cache: cache,
      ).listen((_) {}, onDone: done.complete);
      await pumpEventQueue();
      calls[0].snapshot('Ei');
      await calls[0].controller.close();
      await done.future;
      expect(cache.length, 0);
    });
  });

  group(MemoryChunkCache, () {
    ChunkCacheKey key(String text) => ChunkCacheKey(
      engineId: engine.id,
      request: request.copyWith(text: text),
      precedingHash: ChunkCacheKey.hashPreceding(''),
    );

    TranslationResult result(String text, {bool complete = true}) =>
        TranslationResult(
          engineId: engine.id,
          engineName: engine.name,
          text: text,
          isComplete: complete,
        );

    test('stores complete, non-blank results only', () {
      final cache = MemoryChunkCache()
        ..store(key('a'), result('A'))
        ..store(key('b'), result('B', complete: false))
        ..store(key('c'), result('  '));
      expect(cache.lookup(key('a'))?.text, 'A');
      expect(cache.lookup(key('b')), isNull);
      expect(cache.lookup(key('c')), isNull);
      expect(cache.length, 1);
    });

    test('evicts the least recently used entry', () {
      final cache = MemoryChunkCache(maxEntries: 2)
        ..store(key('a'), result('A'))
        ..store(key('b'), result('B'));
      expect(cache.lookup(key('a')), isNotNull);
      cache.store(key('c'), result('C'));
      expect(cache.lookup(key('b')), isNull);
      expect(cache.lookup(key('a')), isNotNull);
      expect(cache.lookup(key('c')), isNotNull);
      cache.store(key('c'), result('C2'));
      expect(cache.length, 2);
      expect(cache.lookup(key('c'))?.text, 'C2');
    });

    test('expires entries after the ttl', () {
      var now = DateTime(2026);
      final cache = MemoryChunkCache(
        ttl: const Duration(minutes: 1),
        clock: () => now,
      )..store(key('a'), result('A'));
      now = now.add(const Duration(seconds: 59));
      expect(cache.lookup(key('a')), isNotNull);
      now = now.add(const Duration(seconds: 2));
      expect(cache.lookup(key('a')), isNull);
      expect(cache.length, 0);
    });

    test('is off with no entries, and can be cleared', () {
      final off = MemoryChunkCache(maxEntries: 0)..store(key('a'), result('A'));
      expect(off.length, 0);
      final cache = MemoryChunkCache()
        ..store(key('a'), result('A'))
        ..clear();
      expect(cache.length, 0);
      expect(MemoryChunkCache.defaultMaxEntries, 500);
      expect(MemoryChunkCache.defaultTtl, const Duration(hours: 24));
      expect(() => MemoryChunkCache(maxEntries: -1), throwsRangeError);
    });

    test('keys compare by engine, request and preceding hash', () {
      expect(key('a'), key('a'));
      expect(key('a').hashCode, key('a').hashCode);
      expect(key('a'), isNot(key('b')));
      expect(
        key('a'),
        isNot(
          ChunkCacheKey(
            engineId: 'ai:other',
            request: request.copyWith(text: 'a'),
            precedingHash: ChunkCacheKey.hashPreceding(''),
          ),
        ),
      );
      expect(
        key('a'),
        isNot(
          ChunkCacheKey(
            engineId: engine.id,
            request: request.copyWith(text: 'a'),
            precedingHash: ChunkCacheKey.hashPreceding('x'),
          ),
        ),
      );
    });
  });

  group(ChunkContext, () {
    test('compares by value and describes itself without the text', () {
      const a = ChunkContext(
        index: 1,
        count: 2,
        precedingText: 'secret',
        precedingTranslation: 'geheim',
        terms: {'A': 'B'},
      );
      const b = ChunkContext(
        index: 1,
        count: 2,
        precedingText: 'secret',
        precedingTranslation: 'geheim',
        terms: {'A': 'B'},
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const ChunkContext(index: 1, count: 2)));
      expect(a.toString(), isNot(contains('secret')));
      expect(a.toString(), contains('2/2'));
    });
  });

  group(ChunkTermMap, () {
    test('keeps glossary terms first, then names, each once', () {
      final map =
          ChunkTermMap(
              maxTerms: 3,
              glossary: const {'server': 'Server', 'cloud': 'Wolke'},
            )
            ..addPart(
              'Yesterday Anna fixed the server.',
              'Gestern reparierte Anna den Server.',
            )
            ..addPart(
              'Then Boris moved the cloud.',
              'Dann zog Boris die Wolke um.',
            );
      expect(map.terms, {'server': 'Server', 'cloud': 'Wolke', 'Anna': 'Anna'});
      expect(() => map.terms['x'] = 'y', throwsUnsupportedError);
    });

    test('a name already in the glossary is not added again', () {
      final map = ChunkTermMap(glossary: const {'mozhi': 'Mozhi'})
        ..addPart('I use Mozhi.', 'Ich nutze Mozhi.');
      expect(map.terms, {'mozhi': 'Mozhi'});
    });

    test('keeps nothing with maxTerms 0', () {
      final map = ChunkTermMap(maxTerms: 0)
        ..addPart('I use Mozhi.', 'Ich nutze Mozhi.');
      expect(map.terms, isEmpty);
    });

    test('stops looking for names once full', () {
      final map = ChunkTermMap(maxTerms: 1)
        ..addPart('I met Anna.', 'Ich traf Anna.')
        ..addPart('I met Boris.', 'Ich traf Boris.');
      expect(map.terms, {'Anna': 'Anna'});
    });
  });

  group('nameRenderings', () {
    test('finds names kept as they are', () {
      expect(
        nameRenderings(
          'Yesterday Anna and Boris visited Mozhi in Berlin.',
          'Gestern besuchten Anna und Boris Mozhi in Berlin.',
        ),
        {
          'Anna': 'Anna',
          'Boris': 'Boris',
          'Mozhi': 'Mozhi',
          'Berlin': 'Berlin',
        },
      );
    });

    test('finds names spelt with accents or inflected', () {
      expect(
        nameRenderings(
          'We met Mr Kowalski in Zurich and Krakow.',
          'Spotkaliśmy pana Kowalskiego w Zürichu i Krakowie.',
        ),
        {'Kowalski': 'Kowalskiego', 'Zurich': 'Zürichu', 'Krakow': 'Krakowie'},
      );
    });

    test('finds runs of names', () {
      expect(
        nameRenderings(
          'She flew to New York with Anna Smith.',
          'Sie flog mit Anna Smith nach New York.',
        ),
        {'New York': 'New York', 'Anna Smith': 'Anna Smith'},
      );
      // A run that is not found is tried word by word.
      expect(nameRenderings('I saw Anna Smith.', 'Ich sah Frau Smith.'), {
        'Smith': 'Smith',
      });
    });

    test('skips words that only start a sentence or are common words', () {
      expect(
        nameRenderings(
          'The cat sleeps. Then it eats. The end.',
          'The cat sleeps. Then it eats. The end.',
        ),
        isEmpty,
      );
      expect(
        nameRenderings('Will you call Will? I will.', 'Will you call Will?'),
        isEmpty,
      );
      // A sentence start counts when the word also occurs mid-sentence.
      expect(nameRenderings('Anna sleeps. I like Anna.', 'Anna schläft.'), {
        'Anna': 'Anna',
      });
    });

    test('needs a capitalised rendering', () {
      // German nouns are capitalised but not names.
      expect(
        nameRenderings(
          'Das alte Haus und der neue Computer.',
          'The old house and the new computer.',
        ),
        isEmpty,
      );
    });

    test('finds nothing across scripts or without capitals', () {
      expect(
        nameRenderings('I met Anna in Moscow.', 'Я встретил Анну.'),
        isEmpty,
      );
      expect(nameRenderings('我在北京见到了安娜。', 'I met Anna in Beijing.'), isEmpty);
      expect(nameRenderings('', 'Anna'), isEmpty);
      expect(nameRenderings('I met Anna.', ''), isEmpty);
    });

    test('keeps at most max names', () {
      expect(
        nameRenderings(
          'I met Anna, Boris and Clara.',
          'Ich traf Anna, Boris und Clara.',
          max: 2,
        ),
        {'Anna': 'Anna', 'Boris': 'Boris'},
      );
      expect(nameRenderings('I met Anna.', 'Ich traf Anna.', max: 0), isEmpty);
    });
  });
}
