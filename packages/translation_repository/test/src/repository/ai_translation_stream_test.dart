import 'dart:async';

import 'package:test/test.dart';
import 'package:translation_repository/src/repository/ai_translation_stream.dart';
import 'package:translation_repository/translation_repository.dart';

import 'test_helpers.dart';

void main() {
  group('aiTranslationStream', () {
    final engine = aiEngine(claudeConfig);
    const autoRequest = TranslationRequest(
      text: 'Hello',
      source: Language.auto,
      target: german,
    );
    const englishRequest = TranslationRequest(
      text: 'Hello',
      source: english,
      target: german,
    );

    Stream<TranslationResult> build(
      Stream<String> deltas, {
      TranslationRequest request = autoRequest,
      Duration interval = Duration.zero,
      bool parseMarker = true,
      String? detectedSource,
    }) => aiTranslationStream(
      open: () => deltas,
      engine: engine,
      request: request,
      snapshotInterval: interval,
      parseMarker: parseMarker,
      detectedSource: detectedSource,
    );

    test('never shows a trailing marker while it streams in', () async {
      final results = await build(
        Stream.fromIterable(['Hallo', '\n[[lang:', 'en]]']),
      ).toList();
      expect(results.map((r) => r.text), everyElement('Hallo'));
      expect(results.last.isComplete, isTrue);
      expect(results.last.detectedSource, 'en');
      for (final result in results) {
        expect(result.text, isNot(contains('[')));
      }
    });

    test('holds back a partial marker at the end of a line', () async {
      final results = await build(
        Stream.fromIterable(['Hallo [[la', 'ng: de', '-AT ]]']),
        request: englishRequest,
      ).toList();
      expect(results.map((r) => r.text), everyElement('Hallo'));
    });

    test('shows brackets that cannot become a marker', () async {
      final results = await build(
        Stream.fromIterable(['Array [1]', ' and [[x]]']),
        request: englishRequest,
      ).toList();
      expect(results.map((r) => r.text), [
        'Array [1]',
        'Array [1] and [[x]]',
        'Array [1] and [[x]]',
      ]);
    });

    group('with parseMarker: false', () {
      test('passes markers through and reports the given language', () async {
        final results = await build(
          Stream.fromIterable(['[[lang:fr]]', ' Hallo']),
          parseMarker: false,
          detectedSource: 'en',
        ).toList();
        expect(results.first.text, '[[lang:fr]]');
        expect(results.last.text, '[[lang:fr]] Hallo');
        expect(results.map((r) => r.detectedSource), everyElement('en'));
      });

      test('emits from the first delta', () async {
        final results = await build(
          Stream.fromIterable(['[', 'x]']),
          parseMarker: false,
          request: englishRequest,
        ).toList();
        expect(results.map((r) => r.text), ['[', '[x]', '[x]']);
        expect(results.map((r) => r.detectedSource), everyElement(isNull));
      });
    });

    test('hides a split language marker and reports the language', () async {
      final results = await build(
        Stream.fromIterable(['[[la', 'ng:de]]\nHal', 'lo']),
      ).toList();
      expect(results.map((r) => r.text), ['Hal', 'Hallo', 'Hallo']);
      expect(results.map((r) => r.isComplete), [false, false, true]);
      expect(results.map((r) => r.detectedSource), everyElement('de'));
      for (final result in results) {
        expect(result.text, isNot(contains('[')));
        expect(result.engineId, engine.id);
        expect(result.engineName, engine.name);
        expect(result.elapsed, isNotNull);
      }
    });

    test('emits nothing while the marker is pending', () async {
      final deltas = ControlledDeltas();
      final results = <TranslationResult>[];
      final subscription = build(deltas.stream).listen(results.add);
      deltas.controller.add('[');
      await pumpEventQueue();
      deltas.controller.add('[lang:');
      await pumpEventQueue();
      expect(results, isEmpty);
      deltas.controller.add('fr]] Bon');
      await pumpEventQueue();
      expect(results.single.text, isNot(contains('lang')));
      expect(results.single.text, endsWith('Bon'));
      expect(results.single.detectedSource, 'fr');
      await subscription.cancel();
    });

    test('streams plain text without a marker', () async {
      final results = await build(
        Stream.fromIterable(['Hal', 'lo', ' Welt']),
        request: englishRequest,
      ).toList();
      expect(results.map((r) => r.text), [
        'Hal',
        'Hallo',
        'Hallo Welt',
        'Hallo Welt',
      ]);
      expect(results.last.isComplete, isTrue);
      expect(results.map((r) => r.detectedSource), everyElement(isNull));
    });

    test('ignores markers for explicit sources but still hides them', () async {
      final results = await build(
        Stream.fromIterable(['[[lang:en]]\n', 'Hallo']),
        request: englishRequest,
      ).toList();
      expect(results.last.text, 'Hallo');
      expect(results.map((r) => r.detectedSource), everyElement(isNull));
      expect(results.map((r) => r.text), everyElement(isNot(contains('['))));
    });

    test('normalises the detected language', () async {
      final results = await build(
        Stream.fromIterable(['[[lang:iw]]\n', 'שלום']),
      ).toList();
      expect(results.last.detectedSource, 'he');
    });

    test('cleans the final translation', () async {
      final results = await build(
        Stream.fromIterable(['"Hal', 'lo"']),
        request: englishRequest,
      ).toList();
      expect(results.last.isComplete, isTrue);
      expect(
        results.last.text,
        ResponseParsers.cleanTranslation('"Hallo"', source: 'Hello'),
      );
      expect(results.last.text, 'Hallo');
    });

    test('drops identical consecutive snapshots', () async {
      final results = await build(
        Stream.fromIterable(['Hallo', '', '']),
        request: englishRequest,
      ).toList();
      expect(results.map((r) => r.isComplete), [false, true]);
    });

    test('emits only a final result for empty output', () async {
      final results = await build(const Stream.empty()).toList();
      expect(results, hasLength(1));
      expect(results.single.isComplete, isTrue);
      expect(results.single.text, isEmpty);
      expect(results.single.detectedSource, isNull);
    });

    test('a marker that never completes is resolved on done', () async {
      final results = await build(Stream.fromIterable(['[[lang:'])).toList();
      expect(results.single.isComplete, isTrue);
    });

    group('throttling', () {
      test('emits the first snapshot and the exact final result', () async {
        final results = await build(
          Stream.fromIterable(['a', 'b', 'c', 'd']),
          request: englishRequest,
          interval: const Duration(hours: 1),
        ).toList();
        expect(results.map((r) => r.text), ['a', 'abcd']);
        expect(results.map((r) => r.isComplete), [false, true]);
      });

      test('delivers the latest snapshot when the interval elapses', () async {
        final deltas = ControlledDeltas();
        final results = <TranslationResult>[];
        final done = Completer<void>();
        build(
          deltas.stream,
          request: englishRequest,
          interval: const Duration(milliseconds: 250),
        ).listen(results.add, onDone: done.complete);
        deltas.controller.add('a');
        await pumpEventQueue();
        expect(results.map((r) => r.text), ['a']);
        deltas.controller
          ..add('b')
          ..add('c');
        await pumpEventQueue();
        expect(results, hasLength(1));
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(results.map((r) => r.text), ['a', 'abc']);
        await deltas.controller.close();
        await done.future;
        expect(results.map((r) => r.text), ['a', 'abc', 'abc']);
        expect(results.last.isComplete, isTrue);
      });
    });

    group('errors', () {
      test('forwards stream errors after partial snapshots', () async {
        final deltas = ControlledDeltas();
        final events = <Object>[];
        final done = Completer<void>();
        build(
          deltas.stream,
          request: englishRequest,
        ).listen(events.add, onError: events.add, onDone: done.complete);
        deltas.controller.add('Hal');
        await pumpEventQueue();
        deltas.controller.addError(
          const LlmRefusalException('no', category: 'cyber'),
        );
        await done.future;
        expect(events, hasLength(2));
        expect(events.first, isA<TranslationResult>());
        expect(events.last, isA<LlmRefusalException>());
        expect(deltas.cancelled, isTrue);
      });

      test('drops a pending throttled snapshot on error', () async {
        final deltas = ControlledDeltas();
        final events = <Object>[];
        final done = Completer<void>();
        build(
          deltas.stream,
          request: englishRequest,
          interval: const Duration(hours: 1),
        ).listen(events.add, onError: events.add, onDone: done.complete);
        deltas.controller
          ..add('a')
          ..add('b')
          ..addError(const LlmApiException('lost'));
        await done.future;
        expect(events, hasLength(2));
        expect((events.first as TranslationResult).text, 'a');
        expect(events.last, isA<LlmApiException>());
      });

      test('reports errors thrown when opening the request', () async {
        final stream = aiTranslationStream(
          open: () => throw ArgumentError('no provider'),
          engine: engine,
          request: autoRequest,
        );
        await expectLater(
          stream,
          emitsInOrder(<Object>[emitsError(isArgumentError), emitsDone]),
        );
      });

      test('is lazy: nothing is opened before listening', () async {
        var opened = 0;
        final stream = aiTranslationStream(
          open: () {
            opened++;
            return const Stream.empty();
          },
          engine: engine,
          request: autoRequest,
        );
        await pumpEventQueue();
        expect(opened, 0);
        await stream.drain<void>();
        expect(opened, 1);
      });
    });

    group('subscription control', () {
      test('cancelling cancels the delta subscription', () async {
        final deltas = ControlledDeltas();
        final results = <TranslationResult>[];
        final subscription = build(
          deltas.stream,
          request: englishRequest,
        ).listen(results.add);
        deltas.controller.add('Hal');
        await pumpEventQueue();
        await subscription.cancel();
        expect(deltas.cancelled, isTrue);
        expect(results, hasLength(1));
      });

      test('cancelling during a pending throttle emits nothing more', () async {
        final deltas = ControlledDeltas();
        final results = <TranslationResult>[];
        final subscription = build(
          deltas.stream,
          request: englishRequest,
          interval: const Duration(milliseconds: 250),
        ).listen(results.add);
        deltas.controller
          ..add('a')
          ..add('b');
        await pumpEventQueue();
        await subscription.cancel();
        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(results.map((r) => r.text), ['a']);
      });

      test('pausing pauses the delta subscription', () async {
        final deltas = ControlledDeltas();
        final subscription = build(
          deltas.stream,
          request: englishRequest,
        ).listen((_) {});
        await pumpEventQueue();
        subscription.pause();
        await pumpEventQueue();
        expect(deltas.controller.isPaused, isTrue);
        subscription.resume();
        await pumpEventQueue();
        expect(deltas.controller.isPaused, isFalse);
        await subscription.cancel();
      });
    });
  });
}
