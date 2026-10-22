import 'dart:async';
import 'dart:math' as math;

import 'package:llama_engine/llama_engine.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/on_device_ai/data/on_device_models.dart';

/// A catalogue model for the tests.
LlamaCatalogModel catalogModel(
  String id, {
  LlamaModelRole role = LlamaModelRole.assistant,
  String? family,
  String? promptProfile,
  int contextSize = 4096,
  LlamaCatalogSampling sampling = const LlamaCatalogSampling(),
}) => LlamaCatalogModel(
  id: id,
  name: '$id.gguf',
  url: Uri.parse('https://models.example/repo/resolve/abc/$id.gguf'),
  size: 1,
  sha256: '0' * 64,
  role: role,
  family:
      family ??
      (role == LlamaModelRole.translation ? 'hunyuan-dense' : 'gemma4'),
  promptProfile:
      promptProfile ??
      (role == LlamaModelRole.translation ? 'hunyuanMt' : 'general'),
  displayName: 'Model $id',
  parameters: '1B',
  quantization: 'Q4_K_M',
  contextSize: contextSize,
  minRamMb: 4000,
  recommendedRamMb: 6000,
  languages: role == LlamaModelRole.translation ? const ['en', 'de'] : const [],
  license: 'Apache-2.0',
  licenseUrl: Uri.parse('https://www.apache.org/licenses/LICENSE-2.0'),
  sourceUrl: Uri.parse('https://models.example/repo'),
  sampling: sampling,
);

final LlamaCatalogModel hyMtModel = catalogModel(
  'hy-mt2',
  role: LlamaModelRole.translation,
  sampling: const LlamaCatalogSampling(
    temperature: 0.7,
    topP: 0.6,
    topK: 20,
    repeatPenalty: 1.05,
  ),
);

final LlamaCatalogModel gemmaModel = catalogModel(
  'gemma',
  sampling: const LlamaCatalogSampling(temperature: 1, topP: 0.95, topK: 64),
);

final LlamaCatalogModel qwenModel = catalogModel('qwen', family: 'qwen3');

/// The catalogue of the tests.
final testCatalog = LlamaModelCatalog(
  models: [hyMtModel, gemmaModel, qwenModel],
);

/// [OnDeviceModels] with the installed models in [paths] (id to path) and
/// the selections in [translationModel] and [assistantModel].
class FakeOnDeviceModels extends Fake implements OnDeviceModels {
  new({
    LlamaModelCatalog? catalog,
    Map<String, String>? paths,
    this.translationModel,
    this.assistantModel,
  }) : catalog = catalog ?? testCatalog,
       paths =
           paths ?? {for (final m in testCatalog.models) m.id: '/m/${m.id}'};

  @override
  final LlamaModelCatalog catalog;

  final Map<String, String> paths;

  @override
  String? translationModel;

  @override
  String? assistantModel;

  final _changes = StreamController<void>.broadcast();
  bool disposed = false;

  /// Fires [changes].
  void changed() => _changes.add(null);

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<String?> pathOf(String id) async => paths[id];

  @override
  Future<void> dispose() async {
    disposed = true;
    await _changes.close();
  }
}

/// A [LlamaEngine] that records what it is asked and answers [reply].
class FakeLlamaEngine implements LlamaEngine {
  /// (path, contextSize) of every load.
  final loads = <(String, int)>[];
  final requests = <LlamaGenerateRequest>[];
  final counted = <List<LlamaChatMessage>>[];
  int unloads = 0;
  int cancels = 0;
  int cancelledGenerations = 0;
  bool disposed = false;

  /// The context the model was trained with ([LlamaModelInfo]).
  int trainedContext = 32768;

  /// Whether [load] reports the context it loaded (else 0, unknown).
  bool reportsContext = true;

  /// Why every generation ends ([LlamaGenerateRequest.onFinish]).
  LlamaFinishReason finishReason = LlamaFinishReason.stop;

  /// Thrown by [load] when set.
  Exception? loadError;

  /// [load] waits for it when set.
  Completer<void>? loadGate;

  /// Tokens of a chat: its characters, unless set.
  int Function(List<LlamaChatMessage> messages)? tokens;

  /// The pieces of every generation (default: `Hi`), or an error.
  Stream<String> Function(LlamaGenerateRequest request) reply = (_) =>
      Stream.value('Hi');

  String? _loaded;

  @override
  String? get loadedModelPath => _loaded;

  @override
  Future<LlamaModelInfo> load(
    String modelPath, {
    int contextSize = 4096,
    int threads = 0,
  }) async {
    loads.add((modelPath, contextSize));
    await loadGate?.future;
    if (loadError case final error?) throw error;
    _loaded = modelPath;
    return LlamaModelInfo(
      architecture: 'test',
      name: 'Test',
      contextLength: trainedContext,
      parameters: 1,
      sizeBytes: 1,
      chatTemplate: true,
      contextSize: reportsContext ? math.min(contextSize, trainedContext) : 0,
    );
  }

  @override
  Stream<String> generate(LlamaGenerateRequest request) {
    requests.add(request);
    late final StreamController<String> controller;
    StreamSubscription<String>? source;
    controller = StreamController<String>(
      onListen: () {
        source = reply(request).listen(
          controller.add,
          onError: controller.addError,
          onDone: () {
            request.onFinish?.call(
              LlamaGenerateStats(
                promptTokens: 1,
                generatedTokens: 1,
                finishReason: finishReason,
              ),
            );
            unawaited(controller.close());
          },
        );
      },
      onCancel: () async {
        cancelledGenerations++;
        await source?.cancel();
      },
    );
    return controller.stream;
  }

  @override
  Future<int> countTokens(List<LlamaChatMessage> messages) async {
    counted.add(messages);
    return tokens?.call(messages) ??
        messages.fold<int>(0, (sum, m) => sum + m.content.length);
  }

  @override
  Future<void> cancel() async => cancels++;

  @override
  Future<void> unload() async {
    unloads++;
    _loaded = null;
  }

  @override
  Future<void> dispose() async => disposed = true;
}
