import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:llama_engine/llama_engine.dart';

/// Deterministic bytes standing in for a model file.
Uint8List fakeModelBytes(int length, {int seed = 1}) => Uint8List.fromList([
  for (var i = 0; i < length; i++) (i * 31 + seed * 17) & 0xff,
]);

/// A catalog model whose size and SHA-256 are those of [bytes].
LlamaCatalogModel fakeLlamaModel(
  String id,
  Uint8List bytes, {
  String? name,
  LlamaModelRole role = LlamaModelRole.assistant,
  int minRamMb = 4000,
  int recommendedRamMb = 6000,
}) {
  final file = name ?? '$id.gguf';
  return LlamaCatalogModel(
    id: id,
    name: file,
    url: Uri.parse('https://models.example/repo/resolve/abc/$file'),
    size: bytes.length,
    sha256: sha256.convert(bytes).toString(),
    role: role,
    family: role == LlamaModelRole.translation ? 'hunyuan-dense' : 'qwen3',
    promptProfile: role == LlamaModelRole.translation ? 'hunyuanMt' : 'general',
    displayName: 'Model $id',
    parameters: '1B',
    quantization: 'Q4_K_M',
    minRamMb: minRamMb,
    recommendedRamMb: recommendedRamMb,
    languages: role == LlamaModelRole.translation
        ? const ['en', 'de']
        : const [],
    license: 'Apache-2.0',
    licenseUrl: Uri.parse('https://www.apache.org/licenses/LICENSE-2.0'),
    sourceUrl: Uri.parse('https://models.example/repo'),
  );
}

/// The JSON of [model] as in `models.json`.
Map<String, Object?> modelJson(LlamaCatalogModel model) => {
  'id': model.id,
  'name': model.name,
  'url': model.url.toString(),
  'size': model.size,
  'sha256': model.sha256,
  'role': model.role.name,
  'family': model.family,
  'promptProfile': model.promptProfile,
  'displayName': model.displayName,
  'parameters': model.parameters,
  'quantization': model.quantization,
  'contextSize': model.contextSize,
  'minRamMb': model.minRamMb,
  'recommendedRamMb': model.recommendedRamMb,
  'languages': model.languages,
  'license': model.license,
  'licenseUrl': model.licenseUrl.toString(),
  'sourceUrl': model.sourceUrl.toString(),
  'sampling': model.sampling.toJson(),
};

/// A `models.json` listing [models].
String catalogJson(List<LlamaCatalogModel> models) => jsonEncode({
  'schemaVersion': 1,
  'models': [for (final model in models) modelJson(model)],
});
