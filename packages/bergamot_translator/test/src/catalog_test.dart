import 'dart:convert';
import 'dart:io';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, Object?> fileJson({
    String name = 'model.ende.intgemm.alphas.bin',
    String url = 'https://storage.example/model.ende.intgemm.alphas.bin.gz',
    Object size = 10,
    Object sha = 'aa',
  }) => {
    'name': name,
    'url': url,
    'size': size,
    'sha256': sha == 'aa' ? 'a' * 64 : sha,
    'uncompressedSize': 20,
    'uncompressedSha256': 'b' * 64,
  };

  Map<String, Object?> modelJson({
    String source = 'en',
    String target = 'de',
    String version = 'run_1',
    Map<String, Object?>? files,
  }) => {
    'source': source,
    'target': target,
    'version': version,
    'architecture': 'base-memory',
    'releaseStatus': 'Release',
    'files':
        files ??
        {
          'model': fileJson(),
          'lexicalShortlist': fileJson(
            name: 'lex.50.50.ende.s2t.bin',
            url: 'https://storage.example/lex.gz',
          ),
          'vocab': fileJson(
            name: 'vocab.ende.spm',
            url: 'https://storage.example/vocab.gz',
          ),
        },
  };

  String catalogJson(List<Object?> models, {Object schema = 1}) =>
      jsonEncode({'schemaVersion': schema, 'models': models});

  group('ModelCatalog', () {
    test('parses models and their files', () {
      final catalog = ModelCatalog.parse(catalogJson([modelJson()]));
      final model = catalog.model('en', 'de')!;
      expect(model.pair, 'en-de');
      expect(model.version, 'run_1');
      expect(model.architecture, 'base-memory');
      expect(model.releaseStatus, 'Release');
      expect(model.files.keys, {
        ModelFileKind.model,
        ModelFileKind.lexicalShortlist,
        ModelFileKind.vocab,
      });
      expect(model.downloadSize, 30);
      expect(model.installedSize, 60);
      final file = model.files[ModelFileKind.model]!;
      expect(file.url.host, 'storage.example');
      expect(file.sha256, 'a' * 64);
      expect(catalog.model('de', 'en'), isNull);
      expect(model.toString(), 'CatalogModel(en-de, run_1)');
    });

    test('round-trips through toJson', () {
      final catalog = ModelCatalog.parse(catalogJson([modelJson()]));
      final again = ModelCatalog.fromJson(
        jsonDecode(jsonEncode(catalog.toJson())) as Map<String, Object?>,
      );
      final model = again.model('en', 'de')!;
      expect(model, catalog.model('en', 'de'));
      expect(model.hashCode, catalog.model('en', 'de').hashCode);
      expect(model.files, catalog.model('en', 'de')!.files);
      expect(
        model.files[ModelFileKind.vocab].hashCode,
        catalog.model('en', 'de')!.files[ModelFileKind.vocab].hashCode,
      );
    });

    test('accepts split vocabularies', () {
      final catalog = ModelCatalog.parse(
        catalogJson([
          modelJson(
            target: 'zh',
            files: {
              'model': fileJson(),
              'lexicalShortlist': fileJson(name: 'lex.bin'),
              'srcVocab': fileJson(name: 'srcvocab.enzh.spm'),
              'trgVocab': fileJson(name: 'trgvocab.enzh.spm'),
            },
          ),
        ]),
      );
      expect(catalog.model('en', 'zh')!.files, hasLength(4));
    });

    final invalid = <String, Object?>{
      'not an object': '[]',
      'an unknown schema': catalogJson([], schema: 2),
      'no model list': jsonEncode({'schemaVersion': 1}),
      'a model that is not an object': catalogJson(['x']),
      'duplicate pairs': catalogJson([modelJson(), modelJson()]),
      'an invalid language code': catalogJson([modelJson(source: 'EN')]),
      'equal source and target': catalogJson([modelJson(target: 'en')]),
      'an unsafe version': catalogJson([modelJson(version: '../x')]),
      'a hidden version': catalogJson([modelJson(version: '.x')]),
      'missing files': catalogJson([
        {...modelJson()}..remove('files'),
      ]),
      'an unknown file kind': catalogJson([
        modelJson(files: {'weights': fileJson()}),
      ]),
      'a file that is not an object': catalogJson([
        modelJson(files: {'model': 'x'}),
      ]),
      'no shortlist': catalogJson([
        modelJson(
          files: {
            'model': fileJson(),
            'vocab': fileJson(name: 'v.spm'),
          },
        ),
      ]),
      'only a source vocabulary': catalogJson([
        modelJson(
          files: {
            'model': fileJson(),
            'lexicalShortlist': fileJson(name: 'lex.bin'),
            'srcVocab': fileJson(name: 'v.spm'),
          },
        ),
      ]),
      'duplicate file names': catalogJson([
        modelJson(
          files: {
            'model': fileJson(),
            'lexicalShortlist': fileJson(),
            'vocab': fileJson(name: 'v.spm'),
          },
        ),
      ]),
      'a path in a file name': catalogJson([
        modelJson(
          files: {
            'model': fileJson(name: '../../evil.bin'),
            'lexicalShortlist': fileJson(name: 'lex.bin'),
            'vocab': fileJson(name: 'v.spm'),
          },
        ),
      ]),
      'a hidden file name': catalogJson([
        modelJson(
          files: {
            'model': fileJson(name: '.model'),
            'lexicalShortlist': fileJson(name: 'lex.bin'),
            'vocab': fileJson(name: 'v.spm'),
          },
        ),
      ]),
      'a plain http URL': catalogJson([
        modelJson(
          files: {
            'model': fileJson(url: 'http://example.com/m.gz'),
            'lexicalShortlist': fileJson(name: 'lex.bin'),
            'vocab': fileJson(name: 'v.spm'),
          },
        ),
      ]),
      'a zero size': catalogJson([
        modelJson(
          files: {
            'model': fileJson(size: 0),
            'lexicalShortlist': fileJson(name: 'lex.bin'),
            'vocab': fileJson(name: 'v.spm'),
          },
        ),
      ]),
      'an invalid SHA-256': catalogJson([
        modelJson(
          files: {
            'model': fileJson(sha: 'A' * 64),
            'lexicalShortlist': fileJson(name: 'lex.bin'),
            'vocab': fileJson(name: 'v.spm'),
          },
        ),
      ]),
      'a missing name': catalogJson([
        modelJson(
          files: {
            'model': {...fileJson()}..remove('name'),
            'lexicalShortlist': fileJson(name: 'lex.bin'),
            'vocab': fileJson(name: 'v.spm'),
          },
        ),
      ]),
    };
    for (final MapEntry(:key, :value) in invalid.entries) {
      test('rejects $key', () {
        expect(
          () => ModelCatalog.parse(value! as String),
          throwsFormatException,
        );
      });
    }
  });

  group('bundled catalog', () {
    late ModelCatalog catalog;

    setUpAll(() {
      catalog = ModelCatalog.parse(
        File('assets/catalog.json').readAsStringSync(),
      );
    });

    test('has released models to and from English', () {
      expect(catalog.models.length, greaterThan(100));
      for (final pair in ['en-de', 'de-en', 'es-en', 'en-es', 'en-zh']) {
        final parts = pair.split('-');
        expect(catalog.model(parts[0], parts[1]), isNotNull, reason: pair);
      }
      for (final model in catalog.models) {
        expect(
          model.source == 'en' || model.target == 'en',
          isTrue,
          reason: model.pair,
        );
        expect(model.releaseStatus, startsWith('Release'));
        for (final file in model.files.values) {
          expect(file.url.host, 'storage.googleapis.com');
          expect(file.url.path, endsWith('${file.name}.gz'));
        }
      }
    });

    test('loads from the asset bundle', () async {
      final bundle = _FileBundle();
      final loaded = await loadBundledCatalog(bundle: bundle);
      expect(loaded.models.length, catalog.models.length);
      expect(bundle.keys, [ModelCatalog.assetKey]);
    });
  });

  test('CatalogFile equality covers every field', () {
    final file = FakeModel('en', 'de').files.first.entry;
    final other = CatalogFile(
      kind: file.kind,
      name: file.name,
      url: file.url,
      size: file.size + 1,
      sha256: file.sha256,
      uncompressedSize: file.uncompressedSize,
      uncompressedSha256: file.uncompressedSha256,
    );
    expect(file == other, isFalse);
    expect(ModelFileKind.fromKey('nope'), isNull);
  });
}

class _FileBundle extends CachingAssetBundle {
  final keys = <String>[];

  @override
  Future<ByteData> load(String key) async {
    keys.add(key);
    final bytes = File('assets/catalog.json').readAsBytesSync();
    return ByteData.sublistView(bytes);
  }
}
