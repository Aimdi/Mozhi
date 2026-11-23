import 'package:flutter_test/flutter_test.dart';
import 'package:llama_engine/llama_engine.dart';

final class _FakeLlamaWorkerChannel implements LlamaWorkerChannel {
  final List<(String op, Map<String, Object?> args)> calls = [];
  bool terminated = false;
  Map<String, Object?> probeResult = const {'supported': true};
  List<String> deltas = const ['Bon', 'jour'];
  Exception? nextError;

  @override
  Future<Object?> request(
    String op, [
    Map<String, Object?> arguments = const {},
    void Function(String delta)? onDelta,
  ]) async {
    calls.add((op, arguments));
    if (nextError case final error?) {
      nextError = null;
      throw error;
    }
    return switch (op) {
      'probe' => probeResult,
      'load' => {
        'architecture': 'gemma4',
        'name': 'Gemma 4 E2B',
        'contextLength': 8192,
        'contextSize': arguments['contextSize'] ?? 4096,
        'parameters': 2000000000,
        'sizeBytes': 123456,
        'chatTemplate': true,
        'chatTemplateName': 'gemma4',
      },
      'countTokens' => 14,
      'generate' => () {
        if (onDelta != null) {
          deltas.forEach(onDelta);
        }
        return {
          'promptTokens': 14,
          'generatedTokens': 2,
          'promptMs': 40,
          'generateMs': 80,
          'finishReason': 'stop',
        };
      }(),
      'cancel' || 'unload' => null,
      _ => throw LlamaWorkerException(
        LlamaWorkerErrorKind.protocol,
        'Unknown op $op',
      ),
    };
  }

  @override
  void terminate() {
    terminated = true;
  }
}

void main() {
  group('WebLlamaEngine', () {
    late _FakeLlamaWorkerChannel channel;
    late WebLlamaEngine engine;

    setUp(() {
      channel = _FakeLlamaWorkerChannel();
      engine = WebLlamaEngine(channel);
    });

    tearDown(() => engine.dispose());

    test('probes support, loads model, counts tokens and streams', () async {
      expect(await engine.isSupported(), isTrue);

      final info = await engine.load('gemma-4.gguf', contextSize: 2048);
      expect(engine.loadedModelPath, 'gemma-4.gguf');
      expect(info.architecture, 'gemma4');
      expect(info.contextSize, 2048);

      final tokens = await engine.countTokens(const [
        LlamaChatMessage(LlamaRole.user, 'Hello'),
      ]);
      expect(tokens, 14);

      LlamaGenerateStats? stats;
      final pieces = await engine
          .generate(
            LlamaGenerateRequest(
              messages: const [LlamaChatMessage(LlamaRole.user, 'Hello')],
              onFinish: (value) => stats = value,
            ),
          )
          .toList();
      expect(pieces, ['Bon', 'jour']);
      expect(stats?.generatedTokens, 2);
      expect(stats?.finishReason, LlamaFinishReason.stop);

      await engine.unload();
      expect(engine.loadedModelPath, isNull);
    });

    test('throws LlamaNotLoadedException before load', () async {
      await expectLater(
        engine.countTokens(const [LlamaChatMessage(LlamaRole.user, 'Hi')]),
        throwsA(isA<LlamaNotLoadedException>()),
      );
      await expectLater(
        engine
            .generate(
              const LlamaGenerateRequest(
                messages: [LlamaChatMessage(LlamaRole.user, 'Hi')],
              ),
            )
            .toList(),
        throwsA(isA<LlamaNotLoadedException>()),
      );
    });

    test('maps worker errors and terminates channel on dispose', () async {
      await engine.load('model.gguf');
      channel.nextError = const LlamaWorkerException(
        LlamaWorkerErrorKind.cancelled,
        'cancelled',
      );
      await expectLater(
        engine
            .generate(
              const LlamaGenerateRequest(
                messages: [LlamaChatMessage(LlamaRole.user, 'Hi')],
              ),
            )
            .toList(),
        throwsA(isA<LlamaCancelledException>()),
      );
      await engine.dispose();
      expect(channel.terminated, isTrue);
    });
  });

  group('LlamaCatalogModel mmproj vision projector', () {
    test('parses optional mmproj and exposes supportsVision/totalSize', () {
      final sha = 'a' * 64;
      final projSha = 'b' * 64;
      final model = LlamaCatalogModel.fromJson({
        'id': 'gemma-4-e2b-vision',
        'name': 'gemma-4-e2b-q4.gguf',
        'url': 'https://example.org/models/gemma-4-e2b-q4.gguf',
        'size': 2000000,
        'sha256': sha,
        'role': 'assistant',
        'family': 'gemma4',
        'promptProfile': 'general',
        'displayName': 'Gemma 4 E2B',
        'parameters': '2B',
        'quantization': 'Q4_K_M',
        'contextSize': 4096,
        'minRamMb': 6000,
        'recommendedRamMb': 8000,
        'license': 'Apache-2.0',
        'licenseUrl': 'https://example.org/license',
        'sourceUrl': 'https://example.org/model',
        'mmproj': {
          'name': 'mmproj-gemma-4-f16.gguf',
          'url': 'https://example.org/models/mmproj-gemma-4-f16.gguf',
          'size': 400000,
          'sha256': projSha,
        },
      });
      expect(model.supportsVision, isTrue);
      expect(model.mmproj?.name, 'mmproj-gemma-4-f16.gguf');
      expect(model.totalSize, 2400000);
    });
  });
}
