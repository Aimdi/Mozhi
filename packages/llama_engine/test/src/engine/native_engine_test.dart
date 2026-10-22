// The real engine (libmozhi_llama.so from tool/build_native_linux.sh, or
// LLAMA_LIBRARY_PATH) with the tiny models of tool/make_test_model.py:
// random llama-architecture weights with a predictable "script" (see the
// tool). After a ChatML/Qwen3 prompt the model writes the alphabet and 中
// (split into three byte tokens), then ends; after a Gemma 4 prompt it
// counts digits forever; with the JSON grammar it answers "{}". Skipped
// when the library or the models are missing.
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:llama_engine/llama_engine.dart';
import 'package:llama_engine/src/engine/ffi/bindings.dart';
import 'package:llama_engine/src/engine/ffi/isolate_engine.dart';
import 'package:llama_engine/src/engine/ffi/native_engine.dart';
import 'package:path/path.dart' as p;

import '../../helpers/native_library.dart';

const alphabet = 'abcdefghijklmnopqrstuvwxyz中';

const user = [LlamaChatMessage(LlamaRole.user, 'hello')];

// Two threads: the test machines are shared.
const threads = 2;

void main() {
  group('native engine', skip: nativeLibrarySkip(), () {
    late String library;
    late NativeLlamaEngine engine;

    setUpAll(() {
      library = nativeLibraryPath()!;
    });

    setUp(() {
      engine = NativeLlamaEngine.openFirst([library]);
    });

    tearDown(() => engine.dispose());

    List<String> pieces(LlamaGenerateRequest request) {
      engine.begin(request);
      try {
        return [for (String? piece; (piece = engine.next()) != null;) piece!];
      } finally {
        engine.end();
      }
    }

    test('reports its version and CPU variant', () {
      expect(engine.library, library);
      expect(engine.version, startsWith('llama.cpp 0.6.0 (ggml '));
      expect(engine.version, contains(', CPU '));
      expect(engine.cpuFeatures, contains(': '));
      expect(engine.engine, '${engine.version}; ${engine.cpuFeatures}');
    });

    test('falls back to the next library that opens', () {
      final fallback = NativeLlamaEngine.openFirst([
        '/no/such/libmozhi_llama_i8mm.so',
        library,
      ]);
      expect(fallback.library, library);
      fallback.dispose();
    });

    test('loads a model and describes it', () {
      final model = testModelPath()!;
      final info = engine.load(model, contextSize: 2048, threads: threads);
      expect(info.architecture, 'llama');
      expect(info.name, 'Mozhi test model');
      expect(info.description, 'llama ?B Q4_0');
      expect(info.contextLength, 4096);
      expect(info.contextSize, 2048);
      expect(info.parameters, greaterThan(4000000));
      expect(info.sizeBytes, greaterThan(2000000));
      expect(info.chatTemplate, isTrue);
      expect(info.chatTemplateName, 'chatml');
      expect(info.engine, engine.engine);
      expect(engine.loadedModelPath, model);
      // The same settings: nothing reloads.
      expect(
        identical(
          engine.load(model, contextSize: 2048, threads: threads),
          info,
        ),
        isTrue,
      );
      // The context is capped at the training context.
      final larger = engine.load(model, contextSize: 100000, threads: threads);
      expect(larger.contextSize, 4096);
      engine.unload();
      expect(engine.loadedModelPath, isNull);
      engine.unload();
    });

    test('reports load errors', () {
      expect(
        () => engine.load(
          '/no/such/model.gguf',
          contextSize: 2048,
          threads: threads,
        ),
        throwsA(
          isA<LlamaEngineException>().having(
            (error) => error.message,
            'message',
            allOf(
              startsWith('load: cannot load the model /no/such/model.gguf'),
              contains('failed to open'),
            ),
          ),
        ),
      );
      final notGguf = File(
        p.join(Directory.systemTemp.createTempSync('llama').path, 'x.gguf'),
      )..writeAsStringSync('not a model');
      expect(
        () => engine.load(notGguf.path, contextSize: 2048, threads: threads),
        throwsA(isA<LlamaEngineException>()),
      );
      notGguf.parent.deleteSync(recursive: true);
      expect(engine.loadedModelPath, isNull);
    });

    test('needs a loaded model', () {
      expect(
        () => engine.begin(const LlamaGenerateRequest(messages: user)),
        throwsA(isA<LlamaNotLoadedException>()),
      );
      expect(
        () => engine.countTokens(user),
        throwsA(isA<LlamaNotLoadedException>()),
      );
      expect(engine.next, throwsA(isA<LlamaNotLoadedException>()));
      engine.end();
    });

    test('formats chats with the template of each model family', () {
      const chat = [
        LlamaChatMessage(LlamaRole.system, 'S'),
        LlamaChatMessage(LlamaRole.user, 'U'),
      ];
      final expected = {
        'chatml':
            '<|im_start|>system\nS<|im_end|>\n<|im_start|>user\nU<|im_end|>\n'
            '<|im_start|>assistant\n',
        'qwen3':
            '<|im_start|>system\nS<|im_end|>\n<|im_start|>user\nU<|im_end|>\n'
            '<|im_start|>assistant\n<think>\n\n</think>\n\n',
        'gemma4':
            '<|turn>system\nS<turn|>\n<|turn>user\nU<turn|>\n'
            '<|turn>model\n<|channel>thought\n<channel|>',
        'hunyuan-dense':
            'S<｜hy_place▁holder▁no▁3｜><｜hy_User｜>U<｜hy_Assistant｜>',
      };
      for (final MapEntry(key: template, value: prompt) in expected.entries) {
        final info = engine.load(
          testModelPath(template)!,
          contextSize: 2048,
          threads: threads,
        );
        expect(info.chatTemplateName, template, reason: template);
        expect(info.chatTemplate, isTrue, reason: template);
        expect(engine.formatChat(chat), prompt, reason: template);
      }
      // Gemma 4: the answer's role is "model"; without addAssistant the
      // prompt ends after the last turn.
      engine.load(
        testModelPath('gemma4')!,
        contextSize: 2048,
        threads: threads,
      );
      expect(
        engine.formatChat(const [
          LlamaChatMessage(LlamaRole.user, ' U '),
          LlamaChatMessage(LlamaRole.assistant, 'A'),
        ], addAssistant: false),
        '<|turn>user\nU<turn|>\n<|turn>model\nA<turn|>\n',
      );
    });

    test('a model without a chat template cannot chat', () {
      final info = engine.load(
        testModelPath('none')!,
        contextSize: 2048,
        threads: threads,
      );
      expect(info.chatTemplate, isFalse);
      expect(info.chatTemplateName, isNull);
      expect(
        () => engine.begin(const LlamaGenerateRequest(messages: user)),
        throwsA(
          isA<LlamaEngineException>().having(
            (error) => error.message,
            'message',
            'chat template: the model has no supported chat template',
          ),
        ),
      );
    });

    test('counts the tokens of the formatted prompt', () {
      engine.load(testModelPath()!, contextSize: 2048, threads: threads);
      final count = engine.countTokens(user);
      expect(count, engine.tokenCount(engine.formatChat(user)));
      expect(count, greaterThan(10));
      expect(
        engine.countTokens(const [
          LlamaChatMessage(LlamaRole.user, 'hello hello hello hello'),
        ]),
        greaterThan(count),
      );
    });

    test('generates the script: whole characters, then the end', () {
      engine.load(testModelPath()!, contextSize: 2048, threads: threads);
      final result = pieces(const LlamaGenerateRequest(messages: user));
      expect(result.join(), alphabet);
      // 中 arrives as three byte tokens but leaves as one piece.
      expect(result.last, '中');
      expect(result, [...alphabet.split('')]);
      final stats = engine.stats();
      expect(stats.finishReason, LlamaFinishReason.stop);
      expect(stats.generatedTokens, 30); // 26 letters, 3 bytes, the end.
      expect(stats.promptTokens, engine.countTokens(user));
    });

    test('greedy sampling gives the same answer', () {
      engine.load(testModelPath()!, contextSize: 2048, threads: threads);
      expect(
        pieces(
          const LlamaGenerateRequest(
            messages: user,
            sampling: LlamaSampling.greedy,
          ),
        ).join(),
        alphabet,
      );
      expect(
        pieces(
          const LlamaGenerateRequest(
            messages: user,
            sampling: LlamaSampling(
              topK: 0,
              topP: 1,
              minP: 0.05,
              repeatPenalty: 1,
              seed: 1,
            ),
          ),
        ).join(),
        alphabet,
      );
    });

    test('stops after maxTokens', () {
      engine.load(testModelPath()!, contextSize: 2048, threads: threads);
      expect(
        pieces(const LlamaGenerateRequest(messages: user, maxTokens: 5)).join(),
        'abcde',
      );
      expect(engine.stats().finishReason, LlamaFinishReason.length);
      expect(engine.stats().generatedTokens, 5);
    });

    test('ends before a stop string, holding back what may start one', () {
      engine.load(testModelPath()!, contextSize: 2048, threads: threads);
      final result = pieces(
        const LlamaGenerateRequest(messages: user, stop: ['def']),
      );
      expect(result.join(), 'abc');
      expect(engine.stats().finishReason, LlamaFinishReason.stop);
      // A stop string that ends inside 中's bytes.
      expect(
        pieces(const LlamaGenerateRequest(messages: user, stop: ['xyz中']))
            .join(),
        'abcdefghijklmnopqrstuvw',
      );
      // Held back until the end ("中" could have started "中!"), and "q"
      // until "r" showed it was no "q?".
      final held = pieces(
        const LlamaGenerateRequest(messages: user, stop: ['中!', '', 'q?']),
      );
      expect(held.join(), alphabet);
      expect(held.last, '中');
      expect(held, contains('qr'));
    });

    test('answers JSON with the grammar', () {
      engine.load(testModelPath()!, contextSize: 2048, threads: threads);
      final answer = pieces(
        const LlamaGenerateRequest(messages: user, jsonOutput: true),
      ).join();
      expect(jsonDecode(answer), <String, Object?>{});
      expect(answer, '{}');
    });

    test('fails with a context error when the prompt does not fit', () {
      // llama.cpp rounds context sizes up to a multiple of 256.
      engine.load(testModelPath()!, contextSize: 200, threads: threads);
      final long = [LlamaChatMessage(LlamaRole.user, 'hello ' * 200)];
      expect(
        () => engine.begin(LlamaGenerateRequest(messages: long)),
        throwsA(
          isA<LlamaContextException>()
              .having(
                (error) => error.promptTokens,
                'promptTokens',
                engine.countTokens(long),
              )
              .having((error) => error.contextSize, 'contextSize', 256)
              .having(
                (error) => error.message,
                'message',
                contains('tokens; the context holds'),
              ),
        ),
      );
      // A short prompt, but no room for the answer.
      expect(
        () => engine.begin(
          const LlamaGenerateRequest(messages: user, maxTokens: 240),
        ),
        throwsA(isA<LlamaContextException>()),
      );
      // Without maxTokens the answer may fill the context.
      final endless = NativeLlamaEngine.openFirst([library])
        ..load(testModelPath('gemma4')!, contextSize: 256, threads: threads)
        ..begin(const LlamaGenerateRequest(messages: user, maxTokens: 0));
      final text = StringBuffer();
      for (String? piece; (piece = endless.next()) != null;) {
        text.write(piece);
      }
      final stats = endless.stats();
      endless.end();
      expect(stats.finishReason, LlamaFinishReason.length);
      expect(stats.promptTokens + stats.generatedTokens, 256);
      expect(text.toString(), startsWith('0123456789'));
      endless.dispose();
    });

    test('two generations in a row start from scratch', () {
      engine.load(testModelPath()!, contextSize: 2048, threads: threads);
      final first = pieces(const LlamaGenerateRequest(messages: user)).join();
      final second = pieces(const LlamaGenerateRequest(messages: user)).join();
      expect(first, alphabet);
      expect(second, alphabet);
      // A new begin ends an unfinished one.
      engine
        ..begin(const LlamaGenerateRequest(messages: user))
        ..next()
        ..begin(const LlamaGenerateRequest(messages: user, maxTokens: 2));
      expect(engine.next(), 'a');
      expect(engine.next(), 'b');
      expect(engine.next(), isNull);
      engine.end();
      expect(
        () => engine.next(),
        throwsA(
          isA<LlamaEngineException>().having(
            (error) => error.message,
            'message',
            'generate: no generation is running',
          ),
        ),
      );
    });

    test('unloads and loads another model', () {
      engine.load(testModelPath()!, contextSize: 2048, threads: threads);
      expect(
        pieces(const LlamaGenerateRequest(messages: user)).join(),
        alphabet,
      );
      engine
        ..unload()
        ..load(testModelPath('qwen3')!, contextSize: 2048, threads: threads);
      // Qwen3's prompt also ends with a newline.
      expect(
        pieces(const LlamaGenerateRequest(messages: user)).join(),
        alphabet,
      );
      engine.load(
        testModelPath('gemma4')!,
        contextSize: 2048,
        threads: threads,
      );
      expect(
        pieces(const LlamaGenerateRequest(messages: user, maxTokens: 12))
            .join(),
        '012345678901',
      );
    });

    test('the global cancel stops a generation in another isolate', () async {
      final libraryPath = library;
      final model = testModelPath('gemma4')!;
      var done = false;
      final outcome = Isolate.run(() {
        final native = NativeLlamaEngine.openFirst([libraryPath])
          ..load(model, contextSize: 4096, threads: threads)
          ..begin(const LlamaGenerateRequest(messages: user, maxTokens: 0));
        try {
          while (native.next() != null) {}
          return 'finished';
        } on LlamaCancelledException {
          return 'cancelled';
        } finally {
          native.dispose();
        }
      }).whenComplete(() => done = true);
      final bindings = LlamaBindings(LlamaBindings.open(library));
      while (!done) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        bindings.cancel();
      }
      expect(await outcome, 'cancelled');

      // A cancel before a generation does not affect it.
      bindings.cancel();
      engine.load(testModelPath()!, contextSize: 2048, threads: threads);
      expect(
        pieces(const LlamaGenerateRequest(messages: user)).join(),
        alphabet,
      );
    });
  });

  group('isolate engine', skip: nativeLibrarySkip(), () {
    late IsolateLlamaEngine engine;

    setUp(() {
      engine = IsolateLlamaEngine(libraries: [nativeLibraryPath()!]);
    });

    tearDown(() => engine.dispose());

    test('streams the answer and its statistics', () async {
      final info = await engine.load(
        testModelPath()!,
        contextSize: 2048,
        threads: threads,
      );
      expect(info.chatTemplateName, 'chatml');
      expect(engine.loadedModelPath, testModelPath());
      LlamaGenerateStats? stats;
      final result = await engine
          .generate(
            LlamaGenerateRequest(
              messages: user,
              onFinish: (value) => stats = value,
            ),
          )
          .toList();
      expect(result.join(), alphabet);
      expect(result.last, '中');
      expect(stats?.finishReason, LlamaFinishReason.stop);
      expect(stats?.generatedTokens, 30);
      expect(await engine.countTokens(user), stats?.promptTokens);
      final json = await engine
          .generate(
            const LlamaGenerateRequest(messages: user, jsonOutput: true),
          )
          .join();
      expect(jsonDecode(json), isEmpty);
    });

    test('cancelling the subscription stops an endless answer', () async {
      await engine.load(testModelPath('gemma4')!, threads: threads);
      final received = <String>[];
      final stopwatch = Stopwatch()..start();
      await for (final piece in engine.generate(
        const LlamaGenerateRequest(messages: user, maxTokens: 0),
      )) {
        received.add(piece);
        if (received.length == 5) break;
      }
      expect(received.join(), '01234');
      // The next answer starts at once: the endless one has stopped.
      final next = await engine
          .generate(const LlamaGenerateRequest(messages: user, maxTokens: 3))
          .join();
      expect(next, '012');
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 30)));
    });

    test('cancel() stops a running answer with an error', () async {
      await engine.load(testModelPath('gemma4')!, threads: threads);
      var count = 0;
      final failed = expectLater(
        engine
            .generate(const LlamaGenerateRequest(messages: user, maxTokens: 0))
            .map((piece) {
              if (++count == 3) unawaited(engine.cancel());
              return piece;
            }),
        emitsThrough(emitsError(isA<LlamaCancelledException>())),
      );
      await failed;
      expect(
        await engine
            .generate(const LlamaGenerateRequest(messages: user, maxTokens: 2))
            .join(),
        '01',
      );
    });

    test('a prompt that does not fit fails with a context error', () async {
      await engine.load(testModelPath()!, contextSize: 256, threads: threads);
      await expectLater(
        engine.generate(
          LlamaGenerateRequest(
            messages: [LlamaChatMessage(LlamaRole.user, 'hello ' * 400)],
            maxTokens: 16,
          ),
        ),
        emitsError(
          isA<LlamaContextException>()
              .having((error) => error.contextSize, 'contextSize', 256)
              .having(
                (error) => error.promptTokens,
                'promptTokens',
                greaterThan(240),
              ),
        ),
      );
      // The engine still works.
      expect(
        await engine
            .generate(const LlamaGenerateRequest(messages: user, maxTokens: 4))
            .join(),
        'abcd',
      );
    });

    test('unload and reload', () async {
      await engine.load(testModelPath()!, contextSize: 2048, threads: threads);
      await engine.unload();
      expect(engine.loadedModelPath, isNull);
      await expectLater(
        engine.generate(const LlamaGenerateRequest(messages: user)),
        emitsError(isA<LlamaNotLoadedException>()),
      );
      await engine.load(
        testModelPath('qwen3')!,
        contextSize: 2048,
        threads: threads,
      );
      expect(
        await engine
            .generate(const LlamaGenerateRequest(messages: user))
            .join(),
        alphabet,
      );
    });
  });
}
