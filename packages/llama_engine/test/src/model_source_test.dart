import 'package:flutter_test/flutter_test.dart';
import 'package:llama_engine/llama_engine.dart';

import '../helpers/fake_llama_models.dart';

void main() {
  final model = fakeLlamaModel(
    'hy-mt2-1.8b-q4',
    fakeModelBytes(10),
    name: 'Hy-MT2-1.8B-Q4_K_M.gguf',
    role: LlamaModelRole.translation,
  );

  group(llamaMirrorUrl, () {
    test('puts the file under llm/ with its published name', () {
      for (final base in [
        'https://example.org/models/',
        'https://example.org/models',
      ]) {
        expect(
          llamaMirrorUrl(Uri.parse(base), model).toString(),
          'https://example.org/models/llm/Hy-MT2-1.8B-Q4_K_M.gguf',
          reason: base,
        );
      }
      expect(
        llamaMirrorUrl(Uri.parse('http://[::1]:8080'), model).toString(),
        'http://[::1]:8080/llm/Hy-MT2-1.8B-Q4_K_M.gguf',
      );
    });

    test('rejects what is not an http(s) base URL', () {
      for (final base in [
        'file:///models/',
        'models/',
        'https://example.org/?x=1',
        'https://example.org/#x',
      ]) {
        expect(
          () => llamaMirrorUrl(Uri.parse(base), model),
          throwsArgumentError,
          reason: base,
        );
      }
    });

    test('rejects an unsafe file name', () {
      final unsafe = LlamaCatalogModel(
        id: 'x',
        name: '..',
        url: model.url,
        size: 1,
        sha256: 'a' * 64,
        role: LlamaModelRole.assistant,
        family: 'qwen3',
        promptProfile: 'general',
        displayName: 'X',
        license: 'MIT',
        licenseUrl: model.licenseUrl,
        sourceUrl: model.sourceUrl,
      );
      expect(
        () => llamaMirrorUrl(Uri.parse('https://m.example/'), unsafe),
        throwsArgumentError,
      );
    });
  });

  group(llamaDownloadUrls, () {
    final mirror = Uri.parse('https://mirror.example/');
    final copy = llamaMirrorUrl(mirror, model);

    test('is the catalog URL without a mirror', () {
      expect(llamaDownloadUrls(model), [model.url]);
      expect(llamaDownloadUrls(model, fallbackToDefault: true), [model.url]);
    });

    test('is the mirror copy, then the catalog URL with the fallback', () {
      expect(llamaDownloadUrls(model, mirror: mirror), [copy]);
      expect(
        llamaDownloadUrls(model, mirror: mirror, fallbackToDefault: true),
        [copy, model.url],
      );
    });
  });

  test('the mirror folder', () => expect(llamaMirrorFolder, 'llm'));
}
