import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/fallback_key_value_store.dart';
import 'package:mozhi/core/key_value_store.dart';

class _MockStore extends Mock implements KeyValueStore;

void main() {
  group('FallbackKeyValueStore', () {
    late _MockStore primary;
    late MemoryStore fallback;
    late FallbackKeyValueStore store;

    setUp(() {
      primary = _MockStore();
      fallback = MemoryStore();
      store = FallbackKeyValueStore(
        primary,
        fallback: fallback,
        retryDelay: Duration.zero,
      );
    });

    test('uses the primary store while it works', () async {
      when(() => primary.read(any())).thenAnswer((_) async => 'v');
      when(() => primary.write('k', 'v')).thenAnswer((_) async {});
      when(() => primary.delete('k')).thenAnswer((_) async {});

      await store.probe();
      expect(await store.read('k'), 'v');
      await store.write('k', 'v');
      await store.delete('k');

      expect(store.usingFallback, isFalse);
      verify(() => primary.write('k', 'v')).called(1);
      verify(() => primary.delete('k')).called(1);
      expect(fallback.values, isEmpty);
    });

    test('works without a probe', () async {
      when(() => primary.read('k')).thenAnswer((_) async => 'v');

      expect(await store.read('k'), 'v');
      expect(store.usingFallback, isFalse);
    });

    test('tries a failed operation once more', () async {
      var calls = 0;
      when(() => primary.write(any(), any())).thenAnswer((_) async {
        if (calls++ == 0) throw Exception('keystore busy');
      });

      await store.write('k', 'v');

      verify(() => primary.write('k', 'v')).called(2);
      expect(store.usingFallback, isFalse);
      expect(fallback.values, isEmpty);
    });

    test('throws when the retry fails too, and does not switch to the '
        'fallback', () async {
      when(() => primary.probeRead()).thenAnswer((_) async => null);
      when(() => primary.write(any(), any())).thenThrow(Exception('keyring'));
      when(() => primary.read('k')).thenAnswer((_) async => 'stored');

      await store.probe();
      await expectLater(store.write('k', 'v'), throwsException);

      verify(() => primary.write('k', 'v')).called(2);
      expect(store.usingFallback, isFalse);
      expect(fallback.values, isEmpty);
      expect(await store.read('k'), 'stored');
    });

    test('probe detects a failing store', () async {
      when(() => primary.read(any())).thenThrow(StateError('no keychain'));

      await store.probe();
      await store.probe();

      expect(store.usingFallback, isTrue);
      verify(() => primary.read(FallbackKeyValueStore.probeKey)).called(1);

      await store.write('k', 'v');
      expect(await store.read('k'), 'v');
      await store.delete('k');
      expect(fallback.values, isEmpty);
      verifyNever(() => primary.write(any(), any()));
      verifyNever(() => primary.delete(any()));
    });

    test('waits 1.5 s for the probe by default', () {
      expect(
        FallbackKeyValueStore.probeTimeout,
        const Duration(milliseconds: 1500),
      );
    });

    test('operations wait for a running probe', () async {
      final answer = Completer<String?>();
      when(() => primary.probeRead()).thenAnswer((_) => answer.future);
      when(() => primary.read('k')).thenAnswer((_) async => 'v');

      final probe = store.probe();
      final read = store.read('k');
      await pumpEventQueue();
      verifyNever(() => primary.read('k'));

      answer.complete(null);
      await probe;
      expect(await read, 'v');
    });

    group('after a probe that ran out of time', () {
      late Completer<String?> answer;

      setUp(() async {
        answer = Completer<String?>();
        when(() => primary.probeRead()).thenAnswer((_) => answer.future);
        when(() => primary.write(any(), any())).thenAnswer((_) async {});
        when(() => primary.delete(any())).thenAnswer((_) async {});
        when(() => primary.read('k')).thenAnswer((_) async => 'from primary');
        await store.probe(timeout: const Duration(milliseconds: 10));
      });

      test('uses the fallback', () async {
        expect(store.usingFallback, isTrue);
        expect(await store.read('k'), isNull);
        verifyNever(() => primary.read('k'));
      });

      test('switches back when the store answers, with what was written '
          'meanwhile', () async {
        await store.write('k', 'v');
        await store.write('gone', 'x');
        await store.delete('gone');

        answer.complete(null);
        await pumpEventQueue();

        expect(store.usingFallback, isFalse);
        verify(() => primary.write('k', 'v')).called(1);
        verify(() => primary.delete('gone')).called(1);
        expect(await store.read('k'), 'from primary');
      });

      test('operations during the switch wait for it', () async {
        await store.write('k', 'v');
        final copied = Completer<void>();
        when(() => primary.write('k', 'v')).thenAnswer((_) => copied.future);

        answer.complete(null);
        await pumpEventQueue();
        final read = store.read('k');
        await pumpEventQueue();
        verifyNever(() => primary.read('k'));

        copied.complete();
        expect(await read, 'from primary');
      });

      test('stays on the fallback when the late answer is an error', () async {
        answer.completeError(StateError('no keychain'));
        await pumpEventQueue();

        expect(store.usingFallback, isTrue);
        await store.write('k', 'v');
        expect(fallback.values, {'k': 'v'});
        verifyNever(() => primary.write(any(), any()));
      });

      test('stays on the fallback when copying fails', () async {
        when(() => primary.write(any(), any())).thenThrow(StateError('no'));
        await store.write('k', 'v');

        answer.complete(null);
        await pumpEventQueue();

        expect(store.usingFallback, isTrue);
        expect(await store.read('k'), 'v');
      });
    });

    test('defaults to an in-memory fallback', () async {
      final defaultStore = FallbackKeyValueStore(primary);
      when(() => primary.read(any())).thenThrow(Exception('nope'));

      await defaultStore.probe();

      expect(await defaultStore.read('k'), isNull);
      expect(defaultStore.fallback, isA<MemoryStore>());
      expect(defaultStore.retryDelay, const Duration(milliseconds: 100));
    });
  });
}

extension on _MockStore {
  Future<String?> probeRead() => read(FallbackKeyValueStore.probeKey);
}
