import 'dart:async';

import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

const claude = TranslationEngine(
  id: 'ai:claude',
  kind: EngineKind.ai,
  name: 'Claude',
  subtitle: 'claude-opus-5-5',
  providerId: 'claude',
);

const google = TranslationEngine(
  id: 'mozhi:google',
  kind: EngineKind.mozhi,
  name: 'Google',
  mozhiEngine: 'google',
);

const german = Language(code: 'de', name: 'German');
const english = Language(code: 'en', name: 'English');

const request = TranslationRequest(
  text: 'Hello world',
  source: Language.auto,
  target: german,
);

TranslationResult result(
  String text, {
  bool isComplete = true,
  String engineId = 'ai:claude',
}) => TranslationResult(
  engineId: engineId,
  engineName: 'Claude',
  text: text,
  isComplete: isComplete,
  detectedSource: 'en',
  elapsed: const Duration(milliseconds: 420),
);

/// [result] as `cachedTranslate` serves it from the cache.
TranslationResult hit(String text) => result(text).copyWith(fromCache: true);

void main() {
  group(TranslationCache, () {
    late DateTime now;
    late TranslationCache cache;

    setUp(() {
      now = DateTime.utc(2026, 10, 13, 12);
      cache = TranslationCache(clock: () => now);
    });

    group('constructor', () {
      test('defaults to 200 entries for 24 hours', () {
        final cache = TranslationCache();
        expect(cache.maxEntries, 200);
        expect(cache.maxEntries, TranslationCache.defaultMaxEntries);
        expect(cache.ttl, const Duration(hours: 24));
        expect(cache.ttl, TranslationCache.defaultTtl);
        expect(cache.isEmpty, isTrue);
        expect(cache.length, 0);
      });

      test('uses the wall clock by default', () {
        final cache = TranslationCache();
        expect(cache.store(claude, request, result('Hallo Welt')), isTrue);
        expect(cache.lookup(claude, request), result('Hallo Welt'));
      });

      test('rejects a negative maxEntries', () {
        expect(() => TranslationCache(maxEntries: -1), throwsRangeError);
      });
    });

    group('store and lookup', () {
      test('returns null on a miss', () {
        expect(cache.lookup(claude, request), isNull);
      });

      test('returns the stored complete result', () {
        final stored = result('Hallo Welt');
        expect(cache.store(claude, request, stored), isTrue);
        expect(cache.lookup(claude, request), same(stored));
        expect(cache.length, 1);
        expect(cache.isEmpty, isFalse);
      });

      test('ignores partial results', () {
        expect(
          cache.store(claude, request, result('Hal', isComplete: false)),
          isFalse,
        );
        expect(cache.lookup(claude, request), isNull);
        expect(cache.isEmpty, isTrue);
      });

      test('ignores blank results', () {
        expect(cache.store(claude, request, result('')), isFalse);
        expect(cache.store(claude, request, result(' \n ')), isFalse);
        expect(cache.isEmpty, isTrue);
      });

      test('stores nothing when maxEntries is 0', () {
        final cache = TranslationCache(maxEntries: 0, clock: () => now);
        expect(cache.store(claude, request, result('Hallo Welt')), isFalse);
        expect(cache.lookup(claude, request), isNull);
        expect(cache.isEmpty, isTrue);
      });

      test('replaces an existing entry for the same key', () {
        cache
          ..store(claude, request, result('Hallo Welt'))
          ..store(claude, request, result('Hallo, Welt'));
        expect(cache.lookup(claude, request), result('Hallo, Welt'));
        expect(cache.length, 1);
      });

      test('keys by engine id, not by engine name or subtitle', () {
        cache.store(claude, request, result('Hallo Welt'));
        const renamed = TranslationEngine(
          id: 'ai:claude',
          kind: EngineKind.ai,
          name: 'My Claude',
          subtitle: 'other-model',
        );
        expect(cache.lookup(renamed, request), result('Hallo Welt'));
        expect(cache.lookup(google, request), isNull);
      });

      test('keys by source language', () {
        cache.store(claude, request, result('Hallo Welt'));
        expect(cache.lookup(claude, request.copyWith(source: english)), isNull);
        expect(
          cache.lookup(
            claude,
            request.copyWith(
              source: const Language(
                code: 'auto',
                name: 'Auto',
                isCustom: true,
              ),
            ),
          ),
          isNull,
        );
        expect(
          cache.lookup(
            claude,
            request.copyWith(
              source: const Language(code: 'auto', name: 'Other name'),
            ),
          ),
          result('Hallo Welt'),
        );
      });

      test('keys by target language code and isCustom', () {
        cache.store(claude, request, result('Hallo Welt'));
        expect(cache.lookup(claude, request.copyWith(target: english)), isNull);
        expect(
          cache.lookup(
            claude,
            request.copyWith(target: const Language.custom('de')),
          ),
          isNull,
        );
        final pirate = request.copyWith(
          target: const Language.custom('Pirate speak'),
        );
        cache.store(claude, pirate, result('Ahoy world'));
        expect(cache.lookup(claude, pirate), result('Ahoy world'));
        expect(
          cache.lookup(
            claude,
            request.copyWith(
              target: const Language(code: 'Pirate speak', name: 'Pirate'),
            ),
          ),
          isNull,
        );
      });

      test('keys by the exact text', () {
        cache.store(claude, request, result('Hallo Welt'));
        expect(
          cache.lookup(claude, request.copyWith(text: 'hello world')),
          isNull,
        );
        expect(
          cache.lookup(claude, request.copyWith(text: 'Hello world ')),
          isNull,
        );
        expect(
          cache.lookup(claude, request.copyWith(text: 'Hello world')),
          result('Hallo Welt'),
        );
      });

      test('keys by every option, including one-off instructions', () {
        cache.store(claude, request, result('Hallo Welt'));
        const variants = [
          TranslationOptions(style: TranslationStyle.literal),
          TranslationOptions(formality: Formality.more),
          TranslationOptions(readingLevel: ReadingLevel.a2),
          TranslationOptions(speakerGender: Gender.feminine),
          TranslationOptions(addresseeGender: Gender.masculine),
          TranslationOptions(context: 'A text message to my landlord'),
          TranslationOptions(preserveFormatting: false),
          TranslationOptions(glossary: {'world': 'Erde'}),
          TranslationOptions(instructions: 'Make it shorter'),
        ];
        for (final options in variants) {
          expect(
            cache.lookup(claude, request.copyWith(options: options)),
            isNull,
            reason: '$options',
          );
        }
        expect(
          cache.lookup(
            claude,
            request.copyWith(options: const TranslationOptions()),
          ),
          result('Hallo Welt'),
        );
      });

      test('matches equal glossaries held in different maps', () {
        final options = TranslationOptions(
          glossary: Map.of(const {'world': 'Erde'}),
        );
        cache.store(
          claude,
          request.copyWith(options: options),
          result('Hallo Erde'),
        );
        expect(
          cache.lookup(
            claude,
            request.copyWith(
              options: TranslationOptions(
                glossary: Map.of(const {'world': 'Erde'}),
              ),
            ),
          ),
          result('Hallo Erde'),
        );
      });

      test('is not affected by later changes to the glossary map', () {
        final glossary = {'world': 'Erde'};
        cache.store(
          claude,
          request.copyWith(options: TranslationOptions(glossary: glossary)),
          result('Hallo Erde'),
        );
        glossary['world'] = 'Welt';
        expect(
          cache.lookup(
            claude,
            request.copyWith(options: TranslationOptions(glossary: glossary)),
          ),
          isNull,
        );
        expect(
          cache.lookup(
            claude,
            request.copyWith(
              options: const TranslationOptions(glossary: {'world': 'Erde'}),
            ),
          ),
          result('Hallo Erde'),
        );
      });
    });

    group('LRU eviction', () {
      late TranslationCache small;
      final a = request.copyWith(text: 'a');
      final b = request.copyWith(text: 'b');
      final c = request.copyWith(text: 'c');

      setUp(() {
        small = TranslationCache(maxEntries: 2, clock: () => now);
      });

      test('evicts the least recently stored entry', () {
        small
          ..store(claude, a, result('A'))
          ..store(claude, b, result('B'))
          ..store(claude, c, result('C'));
        expect(small.length, 2);
        expect(small.lookup(claude, a), isNull);
        expect(small.lookup(claude, b), result('B'));
        expect(small.lookup(claude, c), result('C'));
      });

      test('a lookup makes the entry the most recently used', () {
        small
          ..store(claude, a, result('A'))
          ..store(claude, b, result('B'));
        expect(small.lookup(claude, a), result('A'));
        small.store(claude, c, result('C'));
        expect(small.lookup(claude, b), isNull);
        expect(small.lookup(claude, a), result('A'));
        expect(small.lookup(claude, c), result('C'));
      });

      test('storing again makes the entry the most recently used', () {
        small
          ..store(claude, a, result('A'))
          ..store(claude, b, result('B'))
          ..store(claude, a, result('A2'))
          ..store(claude, c, result('C'));
        expect(small.lookup(claude, b), isNull);
        expect(small.lookup(claude, a), result('A2'));
      });

      test('contains does not change recency', () {
        small
          ..store(claude, a, result('A'))
          ..store(claude, b, result('B'));
        expect(small.contains(claude, a), isTrue);
        small.store(claude, c, result('C'));
        expect(small.contains(claude, a), isFalse);
        expect(small.contains(claude, b), isTrue);
      });

      test('holds 200 entries by default', () {
        for (var i = 0; i <= 200; i++) {
          cache.store(claude, request.copyWith(text: '$i'), result('#$i'));
        }
        expect(cache.length, 200);
        expect(cache.lookup(claude, request.copyWith(text: '0')), isNull);
        expect(cache.lookup(claude, request.copyWith(text: '1')), result('#1'));
        expect(
          cache.lookup(claude, request.copyWith(text: '200')),
          result('#200'),
        );
      });
    });

    group('expiry', () {
      test('keeps entries until the ttl has elapsed', () {
        cache.store(claude, request, result('Hallo Welt'));
        now = now.add(const Duration(hours: 24) - const Duration(seconds: 1));
        expect(cache.lookup(claude, request), result('Hallo Welt'));
        now = now.add(const Duration(seconds: 1));
        expect(cache.lookup(claude, request), isNull);
        expect(cache.isEmpty, isTrue);
      });

      test('a lookup does not extend the lifetime', () {
        cache.store(claude, request, result('Hallo Welt'));
        now = now.add(const Duration(hours: 23));
        expect(cache.lookup(claude, request), result('Hallo Welt'));
        now = now.add(const Duration(hours: 1));
        expect(cache.lookup(claude, request), isNull);
      });

      test('storing again restarts the lifetime', () {
        cache.store(claude, request, result('Hallo Welt'));
        now = now.add(const Duration(hours: 23));
        cache.store(claude, request, result('Hallo Welt'));
        now = now.add(const Duration(hours: 23));
        expect(cache.lookup(claude, request), result('Hallo Welt'));
      });

      test('honours a custom ttl', () {
        final cache = TranslationCache(
          ttl: const Duration(minutes: 5),
          clock: () => now,
        )..store(claude, request, result('Hallo Welt'));
        now = now.add(const Duration(minutes: 5));
        expect(cache.lookup(claude, request), isNull);
      });

      test('treats entries as expired when the clock moved backwards', () {
        cache.store(claude, request, result('Hallo Welt'));
        now = now.subtract(const Duration(minutes: 1));
        expect(cache.lookup(claude, request), isNull);
      });

      test('contains reports and drops expired entries', () {
        expect(cache.contains(claude, request), isFalse);
        cache.store(claude, request, result('Hallo Welt'));
        expect(cache.contains(claude, request), isTrue);
        now = now.add(const Duration(days: 1));
        expect(cache.length, 1);
        expect(cache.contains(claude, request), isFalse);
        expect(cache.length, 0);
      });
    });

    group('remove', () {
      test('removes one entry and reports whether it existed', () {
        final other = request.copyWith(text: 'Bye');
        cache
          ..store(claude, request, result('Hallo Welt'))
          ..store(claude, other, result('Tschüss'));
        expect(cache.remove(claude, request), isTrue);
        expect(cache.remove(claude, request), isFalse);
        expect(cache.lookup(claude, request), isNull);
        expect(cache.lookup(claude, other), result('Tschüss'));
      });
    });

    group('invalidateEngine', () {
      test('removes only the entries of that engine', () {
        cache
          ..store(claude, request, result('Hallo Welt'))
          ..store(claude, request.copyWith(text: 'Bye'), result('Tschüss'))
          ..store(
            google,
            request,
            result('Hallo Welt', engineId: 'mozhi:google'),
          );
        expect(cache.invalidateEngine('ai:claude'), 2);
        expect(cache.lookup(claude, request), isNull);
        expect(
          cache.lookup(google, request),
          result('Hallo Welt', engineId: 'mozhi:google'),
        );
        expect(cache.invalidateEngine('ai:unknown'), 0);
        expect(cache.length, 1);
      });
    });

    group('clear', () {
      test('removes every entry', () {
        cache
          ..store(claude, request, result('Hallo Welt'))
          ..store(google, request, result('Hallo Welt'))
          ..clear();
        expect(cache.isEmpty, isTrue);
        expect(cache.lookup(claude, request), isNull);
      });
    });

    group('cachedTranslate', () {
      late int fetches;
      late StreamController<TranslationResult> source;

      Stream<TranslationResult> fetch() {
        fetches++;
        return source.stream;
      }

      setUp(() {
        fetches = 0;
        source = StreamController<TranslationResult>();
      });

      // `close` only completes once a listener received the done event.
      tearDown(() => unawaited(source.close()));

      test('emits the cached result without fetching', () async {
        cache.store(claude, request, result('Hallo Welt'));
        await expectLater(
          cache.cachedTranslate(claude, request, fetch),
          emitsInOrder([hit('Hallo Welt'), emitsDone]),
        );
        expect(fetches, 0);
      });

      test('marks cache hits with fromCache', () async {
        cache.store(claude, request, result('Hallo Welt'));
        final served = await cache
            .cachedTranslate(claude, request, fetch)
            .single;
        expect(served.fromCache, isTrue);
        expect(served.copyWith(fromCache: false), result('Hallo Welt'));
        // The stored entry itself is unchanged.
        expect(cache.lookup(claude, request)?.fromCache, isFalse);
      });

      test('keeps a stored fromCache result as it is', () async {
        final stored = hit('Hallo Welt');
        cache.store(claude, request, stored);
        expect(
          await cache.cachedTranslate(claude, request, fetch).single,
          same(stored),
        );
      });

      test('does not mark fetched results', () async {
        final stream = cache.cachedTranslate(claude, request, fetch);
        source
          ..add(result('Hal', isComplete: false))
          ..add(result('Hallo Welt'));
        unawaited(source.close());
        final results = await stream.toList();
        expect(results.map((r) => r.fromCache), [false, false]);
      });

      test('looks the cache up when listened to', () async {
        final stream = cache.cachedTranslate(claude, request, fetch);
        cache.store(claude, request, result('Hallo Welt'));
        await expectLater(stream, emitsInOrder([hit('Hallo Welt'), emitsDone]));
        expect(fetches, 0);
      });

      test('forwards a fetched stream and stores its final result', () async {
        final events = [
          result('Hal', isComplete: false),
          result('Hallo We', isComplete: false),
          result('Hallo Welt'),
        ];
        final stream = cache.cachedTranslate(claude, request, fetch);
        events.forEach(source.add);
        unawaited(source.close());
        await expectLater(stream, emitsInOrder([...events, emitsDone]));
        expect(fetches, 1);
        expect(cache.lookup(claude, request), result('Hallo Welt'));
        expect(cache.length, 1);

        await expectLater(
          cache.cachedTranslate(claude, request, fetch),
          emitsInOrder([hit('Hallo Welt'), emitsDone]),
        );
        expect(fetches, 1);
      });

      test('keeps a final result when the listener cancels early', () async {
        final stream = cache.cachedTranslate(claude, request, fetch);
        source
          ..add(result('Hal', isComplete: false))
          ..add(result('Hallo Welt'));
        final first = await stream.firstWhere((r) => r.isComplete);
        expect(first, result('Hallo Welt'));
        expect(cache.lookup(claude, request), result('Hallo Welt'));
      });

      test('does not store partial results', () async {
        final stream = cache.cachedTranslate(claude, request, fetch);
        source.add(result('Hal', isComplete: false));
        unawaited(source.close());
        await expectLater(
          stream,
          emitsInOrder([result('Hal', isComplete: false), emitsDone]),
        );
        expect(cache.isEmpty, isTrue);
      });

      test('does not store blank results', () async {
        final stream = cache.cachedTranslate(claude, request, fetch);
        source.add(result(' '));
        unawaited(source.close());
        await expectLater(stream, emitsInOrder([result(' '), emitsDone]));
        expect(cache.isEmpty, isTrue);
      });

      test('forwards errors without caching anything', () async {
        final error = StateError('offline');
        final stream = cache.cachedTranslate(claude, request, fetch);
        source
          ..add(result('Hal', isComplete: false))
          ..addError(error);
        unawaited(source.close());
        await expectLater(
          stream,
          emitsInOrder([
            result('Hal', isComplete: false),
            emitsError(same(error)),
            emitsDone,
          ]),
        );
        expect(cache.isEmpty, isTrue);
      });

      test('drops a final result that is followed by an error', () async {
        final error = StateError('broken');
        final stream = cache.cachedTranslate(claude, request, fetch);
        source
          ..add(result('Hallo Welt'))
          ..addError(error)
          ..add(result('Hallo, Welt'));
        unawaited(source.close());
        await expectLater(
          stream,
          emitsInOrder([
            result('Hallo Welt'),
            emitsError(same(error)),
            result('Hallo, Welt'),
            emitsDone,
          ]),
        );
        expect(cache.isEmpty, isTrue);
      });

      test('keeps a newer entry stored by someone else on error', () async {
        final stream = cache.cachedTranslate(claude, request, fetch);
        final events = <Object>[];
        final done = Completer<void>();
        stream.listen(
          events.add,
          onError: (Object error) => events.add('error'),
          onDone: done.complete,
        );
        source.add(result('Hallo Welt'));
        await pumpEventQueue();
        expect(cache.lookup(claude, request), result('Hallo Welt'));
        cache.store(claude, request, result('Servus Welt'));
        source.addError(StateError('broken'));
        unawaited(source.close());
        await done.future;
        expect(events, [result('Hallo Welt'), 'error']);
        expect(cache.lookup(claude, request), result('Servus Welt'));
      });

      test('emits synchronous fetch errors as stream errors', () async {
        final error = ArgumentError('custom target on Mozhi');
        await expectLater(
          cache.cachedTranslate(claude, request, () => throw error),
          emitsInOrder([emitsError(same(error)), emitsDone]),
        );
        expect(cache.isEmpty, isTrue);
      });

      test('always fetches when caching is disabled', () async {
        final cache = TranslationCache(maxEntries: 0, clock: () => now);
        Stream<TranslationResult> fetch() {
          fetches++;
          return Stream.value(result('Hallo Welt'));
        }

        for (var i = 0; i < 2; i++) {
          await expectLater(
            cache.cachedTranslate(claude, request, fetch),
            emitsInOrder([result('Hallo Welt'), emitsDone]),
          );
        }
        expect(fetches, 2);
        expect(cache.isEmpty, isTrue);
      });

      test('fetches again once the entry expired', () async {
        cache.store(claude, request, result('Hallo Welt'));
        now = now.add(const Duration(days: 2));
        final stream = cache.cachedTranslate(claude, request, fetch);
        source.add(result('Hallo, Welt'));
        unawaited(source.close());
        await expectLater(
          stream,
          emitsInOrder([result('Hallo, Welt'), emitsDone]),
        );
        expect(fetches, 1);
        expect(cache.lookup(claude, request), result('Hallo, Welt'));
      });

      test('forwards pause, resume and cancel to the fetched stream', () async {
        final calls = <String>[];
        source = StreamController<TranslationResult>(
          onPause: () => calls.add('pause'),
          onResume: () => calls.add('resume'),
          onCancel: () => calls.add('cancel'),
        );
        final subscription = cache
            .cachedTranslate(claude, request, fetch)
            .listen((_) {});
        await pumpEventQueue();
        expect(fetches, 1);
        subscription.pause();
        await pumpEventQueue();
        subscription.resume();
        await pumpEventQueue();
        await subscription.cancel();
        expect(calls, ['pause', 'resume', 'cancel']);
        expect(cache.isEmpty, isTrue);
      });

      test('pause, resume and cancel are safe on a cache hit', () async {
        cache.store(claude, request, result('Hallo Welt'));
        final received = <TranslationResult>[];
        final subscription =
            cache.cachedTranslate(claude, request, fetch).listen(received.add)
              ..pause()
              ..resume();
        await pumpEventQueue();
        await subscription.cancel();
        expect(received, [hit('Hallo Welt')]);
        expect(fetches, 0);
      });

      test('is a single-subscription stream', () {
        final stream = cache.cachedTranslate(claude, request, fetch);
        expect(stream.isBroadcast, isFalse);
      });
    });
  });
}
