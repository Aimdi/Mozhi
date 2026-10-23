// The isolate protocol of IsolateLlamaEngine with a fake native layer
// (test/helpers/fake_llama_native.dart) running in the real background
// isolate: no library needed.
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:llama_engine/llama_engine.dart';
import 'package:llama_engine/src/engine/ffi/isolate_engine.dart';
import 'package:llama_engine/src/engine/ffi/native_engine.dart';

import '../../helpers/fake_llama_native.dart';

IsolateLlamaEngine fakeEngine([FakeScript script = const FakeScript()]) =>
    IsolateLlamaEngine(
      libraries: const ['fake'],
      opener: (libraries) => FakeLlamaNative(script),
    );

LlamaNative failingOpener(List<String> libraries) =>
    throw LlamaEngineException('no library in $libraries');

LlamaNative crashingOpener(List<String> libraries) => throw StateError('boom');

const hello = LlamaGenerateRequest(
  messages: [LlamaChatMessage(LlamaRole.user, 'hello')],
);

void main() {
  group('IsolateLlamaEngine', () {
    test('loads, counts, generates and unloads in the isolate', () async {
      final engine = fakeEngine();
      expect(engine.loadedModelPath, isNull);
      final info = await engine.load('a.gguf', contextSize: 2048, threads: 3);
      expect(info.name, 'a.gguf');
      expect(info.contextSize, 2048);
      expect(info.parameters, 3);
      expect(engine.loadedModelPath, 'a.gguf');

      expect(
        await engine.countTokens(const [
          LlamaChatMessage(LlamaRole.system, 'abc'),
          LlamaChatMessage(LlamaRole.user, 'de'),
        ]),
        5,
      );

      LlamaGenerateStats? stats;
      final pieces = await engine
          .generate(
            LlamaGenerateRequest(
              messages: const [LlamaChatMessage(LlamaRole.user, 'hello')],
              onFinish: (value) => stats = value,
            ),
          )
          .toList();
      expect(pieces, ['Hel', 'lo']);
      expect(stats, isNotNull);
      expect(stats!.finishReason, LlamaFinishReason.stop);
      expect(stats!.promptTokens, 1);

      await engine.unload();
      expect(engine.loadedModelPath, isNull);
      await expectLater(
        engine.generate(hello),
        emitsError(isA<LlamaNotLoadedException>()),
      );
      await expectLater(
        engine.countTokens(const []),
        throwsA(isA<LlamaNotLoadedException>()),
      );
      await engine.dispose();
    });

    test('the request reaches the isolate intact', () async {
      final engine = fakeEngine(const FakeScript(echoRequest: true));
      await engine.load('a.gguf');
      final pieces = await engine
          .generate(
            const LlamaGenerateRequest(
              messages: [
                LlamaChatMessage(LlamaRole.system, 's'),
                LlamaChatMessage(LlamaRole.user, 'u'),
              ],
              sampling: LlamaSampling(temperature: 0.3, seed: 42),
              maxTokens: 77,
              jsonOutput: true,
              stop: ['</s>', '\n\n'],
            ),
          )
          .toList();
      expect(
        pieces.first,
        'messages=system,user max=77 json=true stop=</s>|\n\n '
        'temperature=0.3 seed=42 flag=true',
      );
      expect(pieces.skip(1), ['Hel', 'lo']);
      await engine.dispose();
    });

    test('reports the finish reason (length: cut short)', () async {
      final engine = fakeEngine(
        const FakeScript(finishReason: LlamaFinishReason.length),
      );
      await engine.load('a.gguf');
      final finished = Completer<LlamaGenerateStats>();
      await engine
          .generate(
            LlamaGenerateRequest(
              messages: hello.messages,
              onFinish: finished.complete,
            ),
          )
          .drain<void>();
      expect((await finished.future).finishReason, LlamaFinishReason.length);
      await engine.dispose();
    });

    test('an onFinish error ends the stream with that error', () async {
      final engine = fakeEngine();
      await engine.load('a.gguf');
      await expectLater(
        engine.generate(
          LlamaGenerateRequest(
            messages: hello.messages,
            onFinish: (_) => throw StateError('listener failed'),
          ),
        ),
        emitsInOrder(['Hel', 'lo', emitsError(isA<StateError>()), emitsDone]),
      );
      await engine.dispose();
    });

    test('engine errors keep their type', () async {
      const context = LlamaContextException(
        'the prompt has 9000 tokens',
        promptTokens: 9000,
        contextSize: 4096,
      );
      final engine = fakeEngine(const FakeScript(beginError: context));
      await engine.load('a.gguf');
      await expectLater(
        engine.generate(hello),
        emitsError(
          isA<LlamaContextException>()
              .having((error) => error.promptTokens, 'promptTokens', 9000)
              .having((error) => error.contextSize, 'contextSize', 4096),
        ),
      );
      await engine.dispose();

      final failing = fakeEngine(
        const FakeScript(nextError: LlamaEngineException('decode failed')),
      );
      await failing.load('a.gguf');
      await expectLater(
        failing.generate(hello),
        emitsError(
          isA<LlamaEngineException>().having(
            (error) => error.message,
            'message',
            'decode failed',
          ),
        ),
      );
      await failing.dispose();

      final crashing = fakeEngine(const FakeScript(crashOnNext: true));
      await crashing.load('a.gguf');
      await expectLater(
        crashing.generate(hello),
        emitsError(
          isA<LlamaEngineException>().having(
            (error) => error.message,
            'message',
            contains('generate: Bad state: boom'),
          ),
        ),
      );
      // Load errors that are not engine errors are wrapped too.
      await expectLater(
        crashing.load('crash'),
        throwsA(
          isA<LlamaEngineException>().having(
            (error) => error.message,
            'message',
            contains('bad path'),
          ),
        ),
      );
      await crashing.dispose();
    });

    test('a load error leaves the previous state alone', () async {
      final engine = fakeEngine(
        const FakeScript(loadError: LlamaEngineException('load: bad file')),
      );
      await expectLater(
        engine.load('a.gguf'),
        throwsA(isA<LlamaEngineException>()),
      );
      expect(engine.loadedModelPath, isNull);
      await engine.dispose();
    });

    test('generations run one at a time, in order', () async {
      final engine = fakeEngine(
        const FakeScript(
          pieces: ['1', '2', '3'],
          pieceDelay: Duration(milliseconds: 20),
        ),
      );
      await engine.load('a.gguf');
      final events = <String>[];
      final first = engine.generate(hello).map((piece) => 'a$piece');
      final second = engine.generate(hello).map((piece) => 'b$piece');
      await Future.wait([
        first.forEach(events.add),
        second.forEach(events.add),
      ]);
      expect(events, ['a1', 'a2', 'a3', 'b1', 'b2', 'b3']);
      await engine.dispose();
    });

    test('cancelling a subscription stops that generation only', () async {
      final engine = fakeEngine(
        const FakeScript(
          pieces: ['x'],
          endless: true,
          pieceDelay: Duration(milliseconds: 10),
        ),
      );
      await engine.load('a.gguf');
      final pieces = <String>[];
      final running = Completer<void>();
      late final StreamSubscription<String> subscription;
      subscription = engine.generate(hello).listen((piece) {
        pieces.add(piece);
        if (pieces.length == 3 && !running.isCompleted) running.complete();
      });
      // Waits behind the endless one.
      final waiting = engine
          .generate(
            LlamaGenerateRequest(
              messages: hello.messages,
              maxTokens: 3,
              onFinish: (_) {},
            ),
          )
          .take(2)
          .toList();
      await running.future;
      final stopwatch = Stopwatch()..start();
      await subscription.cancel();
      // The worker stopped the endless generation within a piece or two.
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(await waiting, ['x', 'x']);
      await engine.dispose();
    });

    test('a subscription cancelled before it starts never runs', () async {
      final engine = fakeEngine(
        const FakeScript(
          pieces: ['x'],
          endless: true,
          pieceDelay: Duration(milliseconds: 10),
        ),
      );
      await engine.load('a.gguf');
      final subscription = engine.generate(hello).listen((_) {});
      await subscription.cancel();
      // The engine is free at once for the next one.
      expect(await engine.generate(hello).take(1).toList(), ['x']);
      await engine.dispose();
    });

    test('cancel() fails running and waiting generations at once', () async {
      final engine = fakeEngine(
        const FakeScript(
          pieces: ['x'],
          endless: true,
          pieceDelay: Duration(milliseconds: 10),
        ),
      );
      await engine.load('a.gguf');
      final started = Completer<void>();
      final running = engine.generate(hello);
      final runningDone = expectLater(
        running.map((piece) {
          if (!started.isCompleted) started.complete();
          return piece;
        }),
        emitsThrough(emitsError(isA<LlamaCancelledException>())),
      );
      final waiting = expectLater(
        engine.generate(hello),
        emitsError(isA<LlamaCancelledException>()),
      );
      await started.future;
      await engine.cancel();
      await runningDone;
      await waiting;
      // Later generations are not affected.
      expect(await engine.generate(hello).take(2).toList(), ['x', 'x']);
      await engine.cancel();
      await engine.dispose();
    });

    test('dispose stops generations; the engine starts again', () async {
      final engine = fakeEngine(
        const FakeScript(
          pieces: ['x'],
          endless: true,
          pieceDelay: Duration(milliseconds: 10),
        ),
      );
      await engine.load('a.gguf');
      final started = Completer<void>();
      final running = expectLater(
        engine.generate(hello).map((piece) {
          if (!started.isCompleted) started.complete();
          return piece;
        }),
        emitsThrough(emitsError(isA<LlamaCancelledException>())),
      );
      await started.future;
      await engine.dispose();
      await running;
      expect(engine.loadedModelPath, isNull);
      // A new isolate, without a model.
      await expectLater(
        engine.generate(hello),
        emitsError(isA<LlamaNotLoadedException>()),
      );
      await engine.load('b.gguf');
      expect(await engine.generate(hello).take(1).toList(), ['x']);
      await engine.dispose();
      await engine.dispose();
    });

    test('nothing to cancel, unload or stop before the first use', () async {
      final engine = fakeEngine();
      await engine.cancel();
      await engine.unload();
      await engine.dispose();
    });

    test('a library that cannot be opened fails, and is retried', () async {
      final engine = IsolateLlamaEngine(
        libraries: const ['a.so', 'b.so'],
        opener: failingOpener,
      );
      await expectLater(
        engine.load('a.gguf'),
        throwsA(
          isA<LlamaEngineException>().having(
            (error) => error.message,
            'message',
            'no library in [a.so, b.so]',
          ),
        ),
      );
      await expectLater(
        engine.generate(hello),
        emitsError(isA<LlamaEngineException>()),
      );
      await expectLater(
        engine.countTokens(const []),
        throwsA(isA<LlamaEngineException>()),
      );
      await engine.cancel();
      await engine.unload();
      await engine.dispose();

      final crashing = IsolateLlamaEngine(opener: crashingOpener);
      await expectLater(
        crashing.load('a.gguf'),
        throwsA(
          isA<LlamaEngineException>().having(
            (error) => error.message,
            'message',
            'Cannot load the native engine: Bad state: boom',
          ),
        ),
      );
      await crashing.dispose();
    });

    test('the native library is opened inside the isolate', () async {
      final engine = IsolateLlamaEngine(libraryPath: '/no/such/lib.so');
      expect(engine.libraries, ['/no/such/lib.so']);
      await expectLater(
        engine.load('a.gguf'),
        throwsA(
          isA<LlamaEngineException>().having(
            (error) => error.message,
            'message',
            startsWith('Cannot load the native engine: /no/such/lib.so'),
          ),
        ),
      );
      await engine.dispose();
    });

    test(
      'a dying isolate fails its generation; the next call respawns',
      () async {
        final engine = fakeEngine(const FakeScript(dieOnNext: true));
        await engine.load('a.gguf');
        await expectLater(
          engine.generate(hello),
          emitsError(
            isA<LlamaEngineException>().having(
              (error) => error.message,
              'message',
              'The engine isolate stopped',
            ),
          ),
        );
        expect(engine.loadedModelPath, isNull);
        // A fresh isolate (the fake dies on every next(), but loads fine).
        await engine.load('b.gguf');
        expect(engine.loadedModelPath, 'b.gguf');
        // A request the isolate dies on fails too.
        await expectLater(
          engine.load('die'),
          throwsA(
            isA<LlamaEngineException>().having(
              (error) => error.message,
              'message',
              'The engine isolate stopped',
            ),
          ),
        );
        expect(engine.loadedModelPath, isNull);
        await engine.dispose();
      },
    );

    test('cancel and dispose while the isolate fails to start', () async {
      final engine = IsolateLlamaEngine(opener: failingOpener);
      final loading = expectLater(
        engine.load('a.gguf'),
        throwsA(isA<LlamaEngineException>()),
      );
      await engine.cancel();
      await loading;
      final again = expectLater(
        engine.load('a.gguf'),
        throwsA(isA<LlamaEngineException>()),
      );
      await engine.dispose();
      await again;
    });
  });
}
