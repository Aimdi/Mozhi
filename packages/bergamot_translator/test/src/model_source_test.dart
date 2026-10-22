import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final file = CatalogFile(
    kind: ModelFileKind.model,
    name: 'model.ende.intgemm.alphas.bin',
    url: Uri.parse(
      'https://storage.googleapis.com/bucket/models/en-de/run1/exported/'
      'model.ende.intgemm.alphas.bin.gz',
    ),
    size: 10,
    sha256: 'a' * 64,
    uncompressedSize: 20,
    uncompressedSha256: 'b' * 64,
  );
  final model = CatalogModel(
    source: 'en',
    target: 'de',
    version: 'run1',
    files: {ModelFileKind.model: file},
  );

  group(bergamotMirrorUrl, () {
    test('puts the published file under bergamot/<pair>/<version>/', () {
      const expected =
          'https://example.org/models/bergamot/en-de/run1/'
          'model.ende.intgemm.alphas.bin.gz';
      for (final base in [
        'https://example.org/models/',
        'https://example.org/models',
        'https://example.org//models//',
      ]) {
        expect(
          bergamotMirrorUrl(Uri.parse(base), model, file).toString(),
          expected,
          reason: base,
        );
      }
    });

    test('keeps the port and works at the root of a server', () {
      expect(
        bergamotMirrorUrl(
          Uri.parse('http://192.168.1.10:8080'),
          model,
          file,
        ).toString(),
        'http://192.168.1.10:8080/bergamot/en-de/run1/'
        'model.ende.intgemm.alphas.bin.gz',
      );
    });

    test('rejects what is not an http(s) base URL', () {
      for (final base in [
        'ftp://example.org/models/',
        '/models/',
        'https://example.org/models/?key=1',
        'https://example.org/models/#top',
      ]) {
        expect(
          () => bergamotMirrorUrl(Uri.parse(base), model, file),
          throwsArgumentError,
          reason: base,
        );
      }
    });

    test('rejects a catalog URL without a file name', () {
      final unnamed = CatalogFile(
        kind: ModelFileKind.model,
        name: file.name,
        url: Uri.parse('https://models.test/dir/'),
        size: 1,
        sha256: 'a' * 64,
        uncompressedSize: 1,
        uncompressedSha256: 'b' * 64,
      );
      expect(
        () => bergamotMirrorUrl(Uri.parse('https://m.test/'), model, unnamed),
        throwsArgumentError,
      );
    });
  });

  group(bergamotDownloadUrls, () {
    final mirror = Uri.parse('https://mirror.test/');
    final copy = bergamotMirrorUrl(mirror, model, file);

    test('is the catalog URL without a mirror', () {
      expect(bergamotDownloadUrls(model, file), [file.url]);
      expect(bergamotDownloadUrls(model, file, fallbackToDefault: true), [
        file.url,
      ]);
    });

    test('is only the mirror copy with a mirror', () {
      expect(bergamotDownloadUrls(model, file, mirror: mirror), [copy]);
    });

    test('tries the catalog URL after the mirror with the fallback', () {
      expect(
        bergamotDownloadUrls(
          model,
          file,
          mirror: mirror,
          fallbackToDefault: true,
        ),
        [copy, file.url],
      );
    });
  });

  test('the mirror folder', () {
    expect(bergamotMirrorFolder, 'bergamot');
  });
}
