import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/fallback_key_value_store.dart';
import 'package:mozhi/core/key_value_store.dart';

class _MockStore extends Mock implements KeyValueStore {}

void main() {
  group('FallbackKeyValueStore', () {
    late _MockStore primary;
    late MemoryStore fallback;
    late FallbackKeyValueStore store;

    setUp(() {
      primary = _MockStore();
      fallback = MemoryStore();
      store = FallbackKeyValueStore(primary, fallback: fallback);
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

    test('switches to the fallback after a failure', () async {
      when(() => primary.write(any(), any())).thenThrow(Exception('keyring'));

      await store.write('k', 'v');

      expect(store.usingFallback, isTrue);
      expect(await store.read('k'), 'v');
      await store.delete('k');
      expect(fallback.values, isEmpty);
      verifyNever(() => primary.read(any()));
      verifyNever(() => primary.delete(any()));
    });

    test('probe detects a failing store', () async {
      when(() => primary.read(any())).thenThrow(StateError('no keychain'));

      await store.probe();
      await store.probe();

      expect(store.usingFallback, isTrue);
      verify(() => primary.read(any())).called(1);
    });

    test('probe detects a hanging store', () async {
      final never = Completer<String?>();
      when(() => primary.read(any())).thenAnswer((_) => never.future);

      await store.probe(timeout: const Duration(milliseconds: 10));

      expect(store.usingFallback, isTrue);
      expect(await store.read('k'), isNull);
    });

    test('defaults to an in-memory fallback', () async {
      final defaultStore = FallbackKeyValueStore(primary);
      when(() => primary.read(any())).thenThrow(Exception('nope'));

      expect(await defaultStore.read('k'), isNull);
      expect(defaultStore.fallback, isA<MemoryStore>());
    });
  });
}
