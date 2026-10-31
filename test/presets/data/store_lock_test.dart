import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/presets/data/store_lock.dart';

void main() {
  group(StoreLock, () {
    test(
      'runs the actions on one key of one store one at a time, in order',
      () async {
        final store = MemoryStore();
        final first = Completer<void>();
        final log = <String>[];
        final a = StoreLock.run(store, 'k', () async {
          log.add('a starts');
          await first.future;
          log.add('a ends');
          return 1;
        });
        final b = StoreLock.run(store, 'k', () async {
          log.add('b');
          return 2;
        });
        await pumpEventQueue();
        expect(log, ['a starts']);
        first.complete();
        expect(await a, 1);
        expect(await b, 2);
        expect(log, ['a starts', 'a ends', 'b']);
      },
    );

    test('other keys and other stores do not wait', () async {
      final store = MemoryStore();
      final held = Completer<void>();
      unawaited(StoreLock.run(store, 'k', () => held.future));
      expect(await StoreLock.run(store, 'other', () async => 'free'), 'free');
      expect(
        await StoreLock.run(MemoryStore(), 'k', () async => 'free'),
        'free',
      );
      held.complete();
    });

    test('a failed action does not block the next', () async {
      final store = MemoryStore();
      await expectLater(
        StoreLock.run<void>(store, 'k', () async => throw StateError('x')),
        throwsStateError,
      );
      expect(await StoreLock.run(store, 'k', () async => 'next'), 'next');
    });
  });
}
