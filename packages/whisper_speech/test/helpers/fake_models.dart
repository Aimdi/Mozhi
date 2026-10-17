import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:whisper_speech/whisper_speech.dart';

/// Deterministic bytes standing in for a model file.
Uint8List fakeModelBytes(int length, {int seed = 1}) => Uint8List.fromList([
  for (var i = 0; i < length; i++) (i * 31 + seed * 17) & 0xff,
]);

/// A catalog model whose size and SHA-1 are those of [bytes].
WhisperCatalogModel fakeModel(String id, Uint8List bytes, {String? name}) =>
    WhisperCatalogModel(
      id: id,
      name: name ?? 'ggml-$id.bin',
      url: Uri.parse('https://models.example/ggml-$id.bin'),
      size: bytes.length,
      sha1: sha1.convert(bytes).toString(),
    );

/// The JSON of [model] as in `models.json`.
Map<String, Object?> modelJson(WhisperCatalogModel model) => {
  'id': model.id,
  'name': model.name,
  'url': model.url.toString(),
  'size': model.size,
  'sha1': model.sha1,
  'multilingual': model.multilingual,
};

/// A `models.json` listing [models].
String catalogJson(List<WhisperCatalogModel> models) => jsonEncode({
  'schemaVersion': 1,
  'source': 'https://models.example',
  'models': [for (final model in models) modelJson(model)],
});
