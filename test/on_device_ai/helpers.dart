import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:llama_engine/llama_engine.dart';

/// Deterministic bytes standing in for a GGUF file.
Uint8List ggufBytes(int length, {int seed = 1}) => Uint8List.fromList([
  for (var i = 0; i < length; i++) (i * 31 + seed * 17) & 0xff,
]);

/// A catalogue model whose size and SHA-256 are those of [bytes].
LlamaCatalogModel fakeOnDeviceModel(
  String id,
  Uint8List bytes, {
  LlamaModelRole role = LlamaModelRole.assistant,
  int minRamMb = 4000,
  int recommendedRamMb = 6000,
  String? displayName,
}) => LlamaCatalogModel(
  id: id,
  name: '$id.gguf',
  url: Uri.parse('https://models.example/repo/resolve/abc/$id.gguf'),
  size: bytes.length,
  sha256: sha256.convert(bytes).toString(),
  role: role,
  family: role == LlamaModelRole.translation ? 'hunyuan-dense' : 'qwen3',
  promptProfile: role == LlamaModelRole.translation ? 'hunyuanMt' : 'general',
  displayName: displayName ?? 'Model $id',
  parameters: '1B',
  quantization: 'Q4_K_M',
  minRamMb: minRamMb,
  recommendedRamMb: recommendedRamMb,
  languages: role == LlamaModelRole.translation
      ? const ['en', 'de', 'zh-CN']
      : const [],
  license: 'Apache-2.0',
  licenseUrl: Uri.parse('https://www.apache.org/licenses/LICENSE-2.0'),
  sourceUrl: Uri.parse('https://models.example/repo'),
);

/// Serves [contents] by file name (the last segment of the URL path);
/// [requests] records every request.
MockClient modelServer(
  Map<String, Uint8List> contents, {
  List<http.BaseRequest>? requests,
  int status = 200,
}) => MockClient((request) async {
  requests?.add(request);
  final name = request.url.pathSegments.last;
  final body = contents[name];
  if (status != 200 || body == null) {
    return http.Response('missing', status == 200 ? 404 : status);
  }
  return http.Response.bytes(body, 200);
});
