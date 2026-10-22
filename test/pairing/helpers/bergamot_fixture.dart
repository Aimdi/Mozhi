import 'dart:convert';
import 'dart:io';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fake_packs.dart';

/// A translation engine that echoes.
class EchoEngine implements BergamotEngine {
  @override
  Future<String> translate(
    List<ModelPaths> chain,
    String text, {
    bool html = false,
  }) async => text;

  @override
  Future<void> release(String key) async {}

  @override
  Future<void> dispose() async {}
}

/// A tiny Bergamot catalog (three small files per direction) and the gzip
/// bodies its URLs serve.
class TinyCatalog {
  final models = <Map<String, Object?>>[];
  final bodies = <Uri, List<int>>{};

  void add(String source, String target, String version) {
    final pair = '$source-$target';
    final files = <String, Object?>{};
    for (final (index, kind) in [
      'model',
      'lexicalShortlist',
      'vocab',
    ].indexed) {
      final raw = utf8.encode('$pair $version $kind ' * (40 + index * 20));
      final gz = gzip.encode(raw);
      final url = Uri.parse('https://models.example/$pair/$version/$kind.gz');
      bodies[url] = gz;
      files[kind] = {
        'name': '$kind.$pair.bin',
        'url': '$url',
        'size': gz.length,
        'sha256': sha256Of(gz),
        'uncompressedSize': raw.length,
        'uncompressedSha256': sha256Of(raw),
      };
    }
    models
      ..removeWhere((m) => m['source'] == source && m['target'] == target)
      ..add({
        'source': source,
        'target': target,
        'version': version,
        'files': files,
      });
  }

  ModelCatalog build() =>
      ModelCatalog.fromJson({'schemaVersion': 1, 'models': models});

  http.Client client() => MockClient((request) async {
    final body = bodies[request.url];
    return body == null
        ? http.Response('not found', 404)
        : http.Response.bytes(body, 200);
  });

  BergamotTranslator translator(Directory root, {bool available = true}) =>
      BergamotTranslator(
        catalog: build(),
        root: root,
        isMeteredConnection: () async => false,
        httpClient: client(),
        engine: EchoEngine(),
        isAvailable: available,
      );
}
