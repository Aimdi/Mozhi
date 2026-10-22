import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:llama_engine/llama_engine.dart';
import 'package:mozhi/on_device_ai/data/on_device_models.dart';

/// A catalogue entry for tests.
LlamaCatalogModel catalogModel(
  String id, {
  String? displayName,
  int size = 0,
  LlamaModelRole role = LlamaModelRole.translation,
}) => LlamaCatalogModel(
  id: id,
  name: '$id.gguf',
  url: Uri.parse('https://example.org/$id.gguf'),
  size: size,
  sha256: '0' * 64,
  role: role,
  family: 'hunyuan-dense',
  promptProfile: 'hunyuanMt',
  displayName: displayName ?? id,
  license: 'Apache-2.0',
  licenseUrl: Uri.parse('https://example.org/license'),
  sourceUrl: Uri.parse('https://example.org'),
);

/// Hy-MT2 (1.1 GB) and Qwen3 (1.2 GB).
final List<LlamaCatalogModel> testCatalog = [
  catalogModel(
    'hy-mt2-1.8b-q4',
    displayName: 'Hy-MT2 1.8B',
    size: 1100 * 1024 * 1024,
  ),
  catalogModel(
    'qwen3-1.7b-q4',
    displayName: 'Qwen3 1.7B',
    size: 1200 * 1024 * 1024,
    role: LlamaModelRole.assistant,
  ),
];

/// [OnDeviceModels] with a fixed catalogue, fit and selection.
class FakeOnDeviceModels extends Fake implements OnDeviceModels {
  new(List<LlamaCatalogModel> models, {this.fits = const {}})
    : catalog = LlamaModelCatalog(models: models);

  @override
  final LlamaModelCatalog catalog;

  /// The fit of each model id (default [OnDeviceFit.ok]).
  Map<String, OnDeviceFit> fits;

  @override
  String? translationModel;

  @override
  String? assistantModel;

  final controller = StreamController<void>.broadcast();

  @override
  Stream<void> get changes => controller.stream;

  @override
  Future<void> get ready async {}

  @override
  OnDeviceFit fitOf(LlamaCatalogModel model) =>
      fits[model.id] ?? OnDeviceFit.ok;
}
