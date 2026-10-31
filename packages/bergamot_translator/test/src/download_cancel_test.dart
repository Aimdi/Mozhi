import 'dart:async';

import 'package:bergamot_translator/src/download_cancel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:translation_repository/translation_repository.dart'
    show OfflineDownloadCancelledException;

final Matcher _cancelled = throwsA(isA<OfflineDownloadCancelledException>());

void main() {
  group('DownloadCancel', () {
    test('check throws once cancelled', () {
      final cancel = DownloadCancel();
      expect(cancel.isCancelled, isFalse);
      cancel
        ..check()
        ..cancel()
        ..cancel();
      expect(cancel.isCancelled, isTrue);
      expect(cancel.check, _cancelled);
      expect(cancel.future, completes);
    });

    group('guard', () {
      test('passes events through until cancelled', () async {
        final cancel = DownloadCancel();
        final source = StreamController<int>();
        final events = <int>[];
        final done = expectLater(
          cancel.guard(source.stream).forEach(events.add),
          _cancelled,
        );
        source.add(1);
        await pumpEventQueue();
        expect(events, [1]);
        cancel.cancel();
        await done;
        expect(source.hasListener, isFalse);
      });

      test('ends with the source and passes its errors', () async {
        final cancel = DownloadCancel();
        final source = StreamController<int>();
        final events = <Object>[];
        final done = Completer<void>();
        cancel
            .guard(source.stream)
            .listen(events.add, onError: events.add, onDone: done.complete);
        source
          ..add(1)
          ..addError(StateError('x'));
        await source.close();
        await done.future;
        expect(events, [1, isA<StateError>()]);
        cancel.cancel();
      });

      test('pauses and resumes the source', () async {
        final cancel = DownloadCancel();
        final source = StreamController<int>();
        final subscription = cancel.guard(source.stream).listen((_) {});
        await pumpEventQueue();
        subscription.pause();
        expect(source.isPaused, isTrue);
        subscription.resume();
        expect(source.isPaused, isFalse);
        await subscription.cancel();
        expect(source.hasListener, isFalse);
      });

      test('closes a source read after the cancel unread', () async {
        final cancel = DownloadCancel()..cancel();
        var listened = false;
        final source = StreamController<int>()
          ..onListen = () => listened = true;
        await expectLater(cancel.guard(source.stream).toList(), _cancelled);
        await pumpEventQueue();
        expect(listened, isTrue);
        expect(source.hasListener, isFalse);
      });
    });

    group('race', () {
      test('is the work when it comes first', () async {
        final cancel = DownloadCancel();
        expect(await cancel.race(Future.value(1)), 1);
        await expectLater(
          cancel.race(Future<int>.error(StateError('x'))),
          throwsStateError,
        );
        cancel.cancel();
      });

      test(
        'fails at once when cancelled; a late result goes to onLate',
        () async {
          final cancel = DownloadCancel();
          final work = Completer<int>();
          final late = <int>[];
          final raced = cancel.race(work.future, onLate: late.add);
          cancel.cancel();
          await expectLater(raced, _cancelled);
          work.complete(3);
          await pumpEventQueue();
          expect(late, [3]);
        },
      );

      test('a late result without onLate is dropped', () async {
        final cancel = DownloadCancel();
        final work = Completer<int>();
        final raced = cancel.race(work.future);
        cancel.cancel();
        await expectLater(raced, _cancelled);
        work.complete(3);
        await pumpEventQueue();
      });
    });
  });

  group('SharedInstalls', () {
    test('shares one run per key and forgets it when done', () async {
      final installs = SharedInstalls<int>();
      var runs = 0;
      final gate = Completer<int>();
      Future<int> start(DownloadCancel _) {
        runs++;
        return gate.future;
      }

      final one = installs.run('a', start);
      final two = installs.run('a', start, abort: Completer<void>().future);
      expect(installs.running('a'), isNotNull);
      expect(runs, 1);
      gate.complete(5);
      expect(await one, 5);
      expect(await two, 5);
      await pumpEventQueue();
      expect(installs.running('a'), isNull);
    });

    test('passes errors to callers with an abort', () async {
      final installs = SharedInstalls<int>();
      await expectLater(
        installs.run(
          'a',
          (_) => Future.error(StateError('x')),
          abort: Completer<void>().future,
        ),
        throwsStateError,
      );
    });

    test('an abort after the result changes nothing', () async {
      final installs = SharedInstalls<int>();
      final abort = Completer<void>();
      expect(await installs.run('a', (_) async => 1, abort: abort.future), 1);
      abort.complete();
      await pumpEventQueue();
    });

    test('an abort that fails is ignored', () async {
      final installs = SharedInstalls<int>();
      final gate = Completer<int>();
      final abort = Completer<void>();
      final run = installs.run('a', (_) => gate.future, abort: abort.future);
      abort.completeError(StateError('x'));
      await pumpEventQueue();
      gate.complete(2);
      expect(await run, 2);
    });

    test('the last abort cancels the work and waits for it to stop; a new '
        'call starts it again after that', () async {
      final installs = SharedInstalls<int>();
      final stopped = Completer<void>();
      final starts = <DownloadCancel>[];
      Future<int> start(DownloadCancel cancel) async {
        starts.add(cancel);
        if (starts.length == 1) {
          await cancel.future;
          await stopped.future;
          cancel.check();
        }
        return starts.length;
      }

      final abort = Completer<void>();
      final first = installs.run('a', start, abort: abort.future);
      var failed = false;
      unawaited(first.then<void>((_) {}, onError: (Object _) => failed = true));
      abort.complete();
      await pumpEventQueue();
      expect(starts.single.isCancelled, isTrue);
      expect(failed, isFalse, reason: 'waits for the work to stop');

      final again = installs.run('a', start);
      await pumpEventQueue();
      expect(starts, hasLength(1), reason: 'starts after the cancelled one');
      stopped.complete();
      await expectLater(first, _cancelled);
      expect(await again, 2);
    });

    test('a cancelled install that fails otherwise is cancelled', () async {
      final installs = SharedInstalls<int>();
      final abort = Completer<void>();
      final run = installs.run('a', (cancel) async {
        await cancel.future;
        throw StateError('socket closed');
      }, abort: abort.future);
      abort.complete();
      await expectLater(run, _cancelled);
    });

    test('ends with the result when the work finished first', () async {
      final installs = SharedInstalls<int>();
      final abort = Completer<void>();
      final run = installs.run('a', (cancel) async {
        await cancel.future;
        return 7;
      }, abort: abort.future);
      abort.complete();
      expect(await run, 7);
    });
  });

  group('resumesAt', () {
    http.StreamedResponse response(String? range, {int? length}) =>
        http.StreamedResponse(
          const Stream.empty(),
          206,
          contentLength: length,
          headers: {'content-range': ?range},
        );

    test('accepts the rest of the same file', () {
      expect(resumesAt(response('bytes 10-99/100'), 10, 100), isTrue);
      expect(resumesAt(response('BYTES 10-99/*'), 10, 100), isTrue);
      expect(
        resumesAt(response('bytes 10-99/100', length: 90), 10, 100),
        isTrue,
      );
    });

    test('rejects anything else', () {
      expect(resumesAt(response(null), 10, 100), isFalse);
      expect(resumesAt(response('bytes 0-99/100'), 10, 100), isFalse);
      expect(resumesAt(response('bytes 10-98/100'), 10, 100), isFalse);
      expect(resumesAt(response('bytes 10-99/200'), 10, 100), isFalse);
      expect(resumesAt(response('bytes */100'), 10, 100), isFalse);
      expect(
        resumesAt(response('bytes 10-99/100', length: 50), 10, 100),
        isFalse,
      );
    });

    test('rejects numbers too large for an int without throwing', () {
      const huge = '99999999999999999999';
      expect(resumesAt(response('bytes $huge-99/100'), 10, 100), isFalse);
      expect(resumesAt(response('bytes 10-$huge/100'), 10, 100), isFalse);
      expect(resumesAt(response('bytes 10-99/$huge'), 10, 100), isFalse);
    });
  });
}
