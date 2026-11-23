import 'dart:async';

import 'package:llama_engine/src/engine/llama_engine.dart';
import 'package:llama_engine/src/engine/web/llama_worker.dart';

/// [LlamaEngine] backed by a WebAssembly worker (`web/llama/worker.js`) over
/// [LlamaWorkerChannel].
///
/// Pure Dart so it can be unit-tested on any platform against a fake channel.
final class WebLlamaEngine implements LlamaEngine {
  new(this._channel);

  final LlamaWorkerChannel _channel;
  String? _loadedModelPath;
  bool _disposed = false;

  @override
  String? get loadedModelPath => _loadedModelPath;

  /// Probes whether this browser and deployment support on-device WASM AI.
  Future<bool> isSupported() async {
    if (_disposed) return false;
    try {
      final result = await _channel.request('probe');
      return result is Map && result['supported'] == true;
    } on Object {
      return false;
    }
  }

  @override
  Future<LlamaModelInfo> load(
    String modelPath, {
    int contextSize = 4096,
    int threads = 0,
  }) async {
    _ensureOpen();
    final raw = await _run(
      () => _channel.request('load', {
        'path': modelPath,
        'threads': threads,
        'contextSize': contextSize,
      }),
    );
    _loadedModelPath = modelPath;
    final map = raw is Map ? raw : const <Object?, Object?>{};
    return LlamaModelInfo(
      architecture: '${map['architecture'] ?? ''}',
      name: '${map['name'] ?? modelPath}',
      contextLength: (map['contextLength'] as num?)?.toInt() ?? contextSize,
      contextSize: (map['contextSize'] as num?)?.toInt() ?? contextSize,
      parameters: (map['parameters'] as num?)?.toInt() ?? 0,
      sizeBytes: (map['sizeBytes'] as num?)?.toInt() ?? 0,
      chatTemplate: map['chatTemplate'] as bool? ?? true,
      chatTemplateName: map['chatTemplateName'] as String?,
      description: '${map['description'] ?? ''}',
      engine: '${map['engine'] ?? 'llama.cpp (WebAssembly)'}',
    );
  }

  @override
  Future<int> countTokens(List<LlamaChatMessage> messages) async {
    _ensureOpen();
    if (_loadedModelPath == null) throw const LlamaNotLoadedException();
    final raw = await _run(
      () => _channel.request('countTokens', {
        'messages': _encodeMessages(messages),
      }),
    );
    if (raw is num) return raw.toInt();
    throw const LlamaEngineException('Worker returned invalid token count');
  }

  @override
  Stream<String> generate(LlamaGenerateRequest request) {
    _ensureOpen();
    late final StreamController<String> controller;
    var cancelled = false;

    controller = StreamController<String>(
      onListen: () {
        if (_loadedModelPath == null) {
          controller.addError(const LlamaNotLoadedException());
          unawaited(controller.close());
          return;
        }
        unawaited(
          _run(
            () => _channel.request(
              'generate',
              {
                'messages': _encodeMessages(request.messages),
                'sampling': {
                  'temperature': request.sampling.temperature,
                  'topK': request.sampling.topK,
                  'topP': request.sampling.topP,
                  'minP': request.sampling.minP,
                  'repeatPenalty': request.sampling.repeatPenalty,
                  'repeatLastN': request.sampling.repeatLastN,
                  'seed': request.sampling.seed,
                },
                'maxTokens': request.maxTokens,
                'jsonOutput': request.jsonOutput,
                'stop': request.stop,
              },
              (delta) {
                if (!cancelled && !controller.isClosed) {
                  controller.add(delta);
                }
              },
            ),
          ).then(
            (raw) {
              if (!cancelled && raw is Map) {
                request.onFinish?.call(_parseStats(raw));
              }
              if (!controller.isClosed) unawaited(controller.close());
            },
            onError: (Object error, StackTrace stackTrace) {
              if (!controller.isClosed) {
                controller.addError(error, stackTrace);
                unawaited(controller.close());
              }
            },
          ),
        );
      },
      onCancel: () async {
        cancelled = true;
        await cancel();
      },
    );
    return controller.stream;
  }

  @override
  Future<void> cancel() async {
    if (_disposed) return;
    try {
      await _channel.request('cancel');
    } on Object {
      // Best-effort cancellation.
    }
  }

  @override
  Future<void> unload() async {
    if (_disposed) return;
    await _run(() => _channel.request('unload'));
    _loadedModelPath = null;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _loadedModelPath = null;
    _channel.terminate();
  }

  void _ensureOpen() {
    if (_disposed) throw const LlamaEngineException('engine is disposed');
  }

  Future<Object?> _run(Future<Object?> Function() action) async {
    try {
      return await action();
    } on LlamaWorkerException catch (error) {
      throw switch (error.kind) {
        LlamaWorkerErrorKind.notLoaded => const LlamaNotLoadedException(),
        LlamaWorkerErrorKind.cancelled => const LlamaCancelledException(),
        _ => LlamaEngineException(error.message),
      };
    }
  }

  static List<Map<String, String>> _encodeMessages(
    List<LlamaChatMessage> messages,
  ) => [
    for (final m in messages) {'role': m.role.name, 'content': m.content},
  ];

  static LlamaGenerateStats _parseStats(Map<Object?, Object?> raw) {
    final reason = raw['finishReason'] == 'length'
        ? LlamaFinishReason.length
        : LlamaFinishReason.stop;
    return LlamaGenerateStats(
      promptTokens: (raw['promptTokens'] as num?)?.toInt() ?? 0,
      generatedTokens: (raw['generatedTokens'] as num?)?.toInt() ?? 0,
      promptDuration: Duration(
        milliseconds: (raw['promptMs'] as num?)?.toInt() ?? 0,
      ),
      generateDuration: Duration(
        milliseconds: (raw['generateMs'] as num?)?.toInt() ?? 0,
      ),
      finishReason: reason,
    );
  }
}
