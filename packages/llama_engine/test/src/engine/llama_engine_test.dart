import 'package:flutter_test/flutter_test.dart';
import 'package:llama_engine/llama_engine.dart';
import 'package:llama_engine/src/engine/cpu_features.dart';
import 'package:llama_engine/src/engine/engine_factory_stub.dart' as stub;
import 'package:llama_engine/src/engine/ffi/bindings.dart';
import 'package:llama_engine/src/engine/ffi/isolate_engine.dart';
import 'package:llama_engine/src/engine/ffi/native_engine.dart';

void main() {
  group('exceptions', () {
    test('describe themselves', () {
      expect(
        const LlamaEngineException('x').toString(),
        'LlamaEngineException(x)',
      );
      expect(
        const LlamaNotLoadedException().toString(),
        'LlamaNotLoadedException()',
      );
      expect(const LlamaNotLoadedException().message, 'no model is loaded');
      expect(
        const LlamaCancelledException().toString(),
        'LlamaCancelledException()',
      );
      expect(const LlamaCancelledException().message, 'cancelled');
      const context = LlamaContextException(
        'too long',
        promptTokens: 5000,
        contextSize: 4096,
      );
      expect(context.message, 'too long');
      expect(
        context.toString(),
        'LlamaContextException(5000 tokens, '
        'context 4096)',
      );
      expect(context, isA<LlamaEngineException>());
    });
  });

  group('values', () {
    test('chat messages compare by value and hide their text', () {
      const message = LlamaChatMessage(LlamaRole.user, 'secret');
      expect(message, const LlamaChatMessage(LlamaRole.user, 'secret'));
      expect(
        message.hashCode,
        const LlamaChatMessage(LlamaRole.user, 'secret').hashCode,
      );
      expect(
        message,
        isNot(const LlamaChatMessage(LlamaRole.system, 'secret')),
      );
      expect(message.toString(), 'LlamaChatMessage(user, 6 chars)');
      expect(message.toString(), isNot(contains('secret')));
    });

    test('sampling defaults are Hy-MT2 settings', () {
      const sampling = LlamaSampling();
      expect(sampling.temperature, 0.7);
      expect(sampling.topK, 20);
      expect(sampling.topP, 0.6);
      expect(sampling.minP, 0.0);
      expect(sampling.repeatPenalty, 1.05);
      expect(sampling.repeatLastN, 64);
      expect(sampling.seed, isNull);
      expect(LlamaSampling.greedy.temperature, 0);
      final copy = sampling.copyWith(
        temperature: 0.2,
        topK: 40,
        topP: 0.9,
        minP: 0.05,
        repeatPenalty: 1.1,
        repeatLastN: 128,
        seed: 7,
      );
      expect(
        copy,
        const LlamaSampling(
          temperature: 0.2,
          topK: 40,
          topP: 0.9,
          minP: 0.05,
          repeatPenalty: 1.1,
          repeatLastN: 128,
          seed: 7,
        ),
      );
      expect(sampling.copyWith(), sampling);
      expect(sampling.copyWith().hashCode, sampling.hashCode);
      expect(copy, isNot(sampling));
      expect(copy.toString(), contains('temperature: 0.2'));
    });

    test('a request has the contract defaults', () {
      const request = LlamaGenerateRequest(
        messages: [LlamaChatMessage(LlamaRole.user, 'hi')],
      );
      expect(request.sampling, const LlamaSampling());
      expect(request.maxTokens, 1024);
      expect(request.jsonOutput, isFalse);
      expect(request.stop, isEmpty);
      expect(request.onFinish, isNull);
    });

    test('statistics', () {
      const stats = LlamaGenerateStats(
        promptTokens: 10,
        generatedTokens: 50,
        finishReason: LlamaFinishReason.length,
        promptDuration: Duration(milliseconds: 100),
        generateDuration: Duration(seconds: 2),
      );
      expect(stats.tokensPerSecond, 25);
      expect(
        const LlamaGenerateStats(
          promptTokens: 1,
          generatedTokens: 1,
          finishReason: LlamaFinishReason.stop,
        ).tokensPerSecond,
        0,
      );
      expect(
        stats,
        const LlamaGenerateStats(
          promptTokens: 10,
          generatedTokens: 50,
          finishReason: LlamaFinishReason.length,
          promptDuration: Duration(milliseconds: 100),
          generateDuration: Duration(seconds: 2),
        ),
      );
      expect(
        stats.hashCode,
        const LlamaGenerateStats(
          promptTokens: 10,
          generatedTokens: 50,
          finishReason: LlamaFinishReason.length,
          promptDuration: Duration(milliseconds: 100),
          generateDuration: Duration(seconds: 2),
        ).hashCode,
      );
      expect(stats.toString(), 'LlamaGenerateStats(10 + 50 tokens, length)');
    });
  });

  group('LlamaModelInfo.fromNative', () {
    test('reads mozhi_llama_model_info()', () {
      final info = LlamaModelInfo.fromNative(const {
        'architecture': 'hunyuan-dense',
        'name': 'Hy-MT2 1.8B',
        'description': 'hunyuan-dense 1.8B Q4_K - Medium',
        'n_ctx_train': 8192,
        'n_ctx': 4096,
        'n_params': 1791000000,
        'size': 1100000000.0,
        'n_vocab': 120818,
        'n_layer': 32,
        'n_embd': 2048,
        'chat_template': true,
        'chat_template_name': 'hunyuan-dense',
      }, engine: 'llama.cpp 0.6.0');
      expect(
        info,
        const LlamaModelInfo(
          architecture: 'hunyuan-dense',
          name: 'Hy-MT2 1.8B',
          contextLength: 8192,
          parameters: 1791000000,
          sizeBytes: 1100000000,
          chatTemplate: true,
          chatTemplateName: 'hunyuan-dense',
          contextSize: 4096,
          description: 'hunyuan-dense 1.8B Q4_K - Medium',
          engine: 'llama.cpp 0.6.0',
        ),
      );
      expect(
        info.hashCode,
        LlamaModelInfo.fromNative(const {
          'architecture': 'hunyuan-dense',
          'name': 'Hy-MT2 1.8B',
          'description': 'hunyuan-dense 1.8B Q4_K - Medium',
          'n_ctx_train': 8192,
          'n_ctx': 4096,
          'n_params': 1791000000,
          'size': 1100000000,
          'chat_template': true,
          'chat_template_name': 'hunyuan-dense',
        }, engine: 'llama.cpp 0.6.0').hashCode,
      );
      expect(info.toString(), contains('hunyuan-dense'));
    });

    test('tolerates missing and mistyped fields', () {
      final info = LlamaModelInfo.fromNative(const {
        'architecture': 3,
        'n_ctx_train': 'many',
        'chat_template': 'yes',
        'chat_template_name': null,
      });
      expect(info.architecture, '');
      expect(info.name, '');
      expect(info.contextLength, 0);
      expect(info.chatTemplate, isFalse);
      expect(info.chatTemplateName, isNull);
      expect(info.engine, '');
    });
  });

  group('library candidates', () {
    test('an explicit path or LLAMA_LIBRARY_PATH wins', () {
      expect(
        LlamaBindings.candidates(
          path: '/x/lib.so',
          features: const ArmCpuFeatures(dotprod: true, fp16: true, i8mm: true),
          environment: {'LLAMA_LIBRARY_PATH': '/env/lib.so'},
        ),
        ['/x/lib.so'],
      );
      expect(
        LlamaBindings.candidates(
          environment: {'LLAMA_LIBRARY_PATH': '/env/lib.so'},
        ),
        ['/env/lib.so'],
      );
      expect(
        LlamaBindings.candidates(environment: {'LLAMA_LIBRARY_PATH': ''}),
        [LlamaBindings.libraryName],
      );
      expect(LlamaBindings.candidates(environment: {}), [
        LlamaBindings.libraryName,
      ]);
    });

    test('the native engine reports every library it could not open', () {
      expect(
        () => NativeLlamaEngine.openFirst(['/no/a.so', '/no/b.so']),
        throwsA(
          isA<LlamaEngineException>().having(
            (error) => error.message,
            'message',
            allOf(
              startsWith('Cannot load the native engine: /no/a.so: '),
              contains('/no/b.so: '),
            ),
          ),
        ),
      );
      expect(
        () => NativeLlamaEngine.open(libraryPath: '/no/such/lib.so'),
        throwsA(isA<LlamaEngineException>()),
      );
    });
  });

  group('engine factory', () {
    test('the native engine only runs on Android', () {
      expect(llamaPlatformSupported, isFalse);
      final engine = createLlamaEngine(libraryPath: '/x/lib.so');
      expect(engine, isA<IsolateLlamaEngine>());
      expect((engine as IsolateLlamaEngine).libraries, ['/x/lib.so']);
      expect(engine.loadedModelPath, isNull);
    });

    test('the web stub is unsupported', () async {
      expect(stub.llamaPlatformSupported, isFalse);
      final engine = stub.createLlamaEngine();
      expect(engine.loadedModelPath, isNull);
      await expectLater(
        engine.load('model.gguf'),
        throwsA(isA<UnsupportedError>()),
      );
      await expectLater(
        engine.generate(const LlamaGenerateRequest(messages: [])),
        emitsError(isA<UnsupportedError>()),
      );
      await expectLater(
        engine.countTokens(const []),
        throwsA(isA<UnsupportedError>()),
      );
      await engine.cancel();
      await engine.unload();
      await engine.dispose();
    });
  });
}
