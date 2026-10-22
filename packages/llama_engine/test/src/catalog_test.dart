import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llama_engine/llama_engine.dart';

import '../helpers/fake_llama_models.dart';

class _StringBundle extends CachingAssetBundle {
  new(this.values);

  final Map<String, String> values;

  @override
  Future<ByteData> load(String key) async {
    final value = values[key];
    if (value == null) throw StateError('Unable to load asset: $key');
    return ByteData.sublistView(utf8.encode(value));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, Object?> entry([Map<String, Object?> changes = const {}]) {
    final json = <String, Object?>{
      'id': 'hy-mt2-1.8b-q4',
      'name': 'Hy-MT2-1.8B-Q4_K_M.gguf',
      'url':
          'https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/resolve/'
          '${'c' * 40}/Hy-MT2-1.8B-Q4_K_M.gguf',
      'size': 1100,
      'sha256': 'a' * 64,
      'role': 'translation',
      'family': 'hunyuan-dense',
      'promptProfile': 'hunyuanMt',
      'displayName': 'Hy-MT2 1.8B',
      'parameters': '1.8B',
      'quantization': 'Q4_K_M',
      'contextSize': 4096,
      'minRamMb': 5000,
      'recommendedRamMb': 7000,
      'languages': ['zh-CN', 'en', 'zh-TW'],
      'license': 'Apache-2.0',
      'licenseUrl':
          'https://github.com/Tencent-Hunyuan/Hy-MT2/blob/main/LICENSE.txt',
      'sourceUrl': 'https://github.com/Tencent-Hunyuan/Hy-MT2',
      'sampling': {
        'temperature': 0.7,
        'topP': 0.6,
        'topK': 20,
        'repeatPenalty': 1.05,
      },
    };
    for (final MapEntry(:key, :value) in changes.entries) {
      if (value == null) {
        json.remove(key);
      } else {
        json[key] = value;
      }
    }
    return json;
  }

  String catalog(List<Object?> models, {Object schema = 1}) =>
      jsonEncode({'schemaVersion': schema, 'models': models});

  group(LlamaModelCatalog, () {
    final bundled = File('assets/models.json').readAsStringSync();

    test('the bundled catalog parses and pins every file to a commit', () {
      final parsed = LlamaModelCatalog.parse(bundled);
      final json = jsonDecode(bundled) as Map<String, Object?>;
      expect(json['_provenance'], isA<List<Object?>>());
      for (final model in parsed.models) {
        expect(model.url.host, 'huggingface.co', reason: model.id);
        expect(
          model.url.path,
          matches(RegExp('/resolve/[0-9a-f]{40}/')),
          reason: '${model.id} must be pinned to a commit',
        );
        expect(model.license, 'Apache-2.0', reason: model.id);
      }
      expect(
        parsed.models.map((m) => m.id),
        everyElement(
          isIn(['hy-mt2-1.8b-q4', 'gemma-4-e2b-q4', 'qwen3-1.7b-q4']),
        ),
      );
    });

    test(
      'the bundled catalog matches the sources of tool/llm_catalog.json',
      () {
        final sources = File('../../tool/llm_catalog.json');
        if (!sources.existsSync()) {
          markTestSkipped('not in the Mozhi repository');
          return;
        }
        final listed = {
          for (final source
              in (jsonDecode(sources.readAsStringSync())
                      as Map<String, Object?>)['models']!
                  as List<Object?>)
            (source! as Map<String, Object?>)['id']: source,
        };
        for (final model in LlamaModelCatalog.parse(bundled).models) {
          final source = listed[model.id]! as Map<String, Object?>;
          expect(model.role.name, source['role'], reason: model.id);
          expect(model.minRamMb, source['minRamMb'], reason: model.id);
          expect(model.languages, source['languages'] ?? <String>[]);
        }
      },
    );

    test('loads the bundled asset', () async {
      final loaded = await loadBundledLlamaCatalog(
        bundle: _StringBundle({LlamaModelCatalog.assetKey: bundled}),
      );
      expect(loaded.models, LlamaModelCatalog.parse(bundled).models);
      expect(LlamaModelCatalog.assetKey, contains('llama_engine'));
    });

    test('accepts an empty model list', () {
      final parsed = LlamaModelCatalog.parse(catalog([]));
      expect(parsed.isEmpty, isTrue);
      expect(parsed.model('x'), isNull);
      expect(const LlamaModelCatalog().models, isEmpty);
    });

    test('parses every field', () {
      final parsed = LlamaModelCatalog.parse(
        catalog([
          entry(),
          entry({
            'id': 'qwen3-1.7b-q4',
            'name': 'Qwen3-1.7B-Q4_K_M.gguf',
            'url':
                'https://huggingface.co/Qwen/Qwen3-1.7B-GGUF/resolve/'
                '${'d' * 40}/Qwen3-1.7B-Q4_K_M.gguf',
            'role': 'assistant',
            'family': 'qwen3',
            'promptProfile': 'general',
            'languages': null,
            'sampling': null,
          }),
        ]),
      );
      expect(parsed.isEmpty, isFalse);
      final hy = parsed.model('hy-mt2-1.8b-q4')!;
      expect(hy.name, 'Hy-MT2-1.8B-Q4_K_M.gguf');
      expect(hy.size, 1100);
      expect(hy.sha256, 'a' * 64);
      expect(hy.role, LlamaModelRole.translation);
      expect(hy.family, 'hunyuan-dense');
      expect(hy.promptProfile, 'hunyuanMt');
      expect(hy.displayName, 'Hy-MT2 1.8B');
      expect(hy.parameters, '1.8B');
      expect(hy.quantization, 'Q4_K_M');
      expect(hy.contextSize, 4096);
      expect(hy.minRamMb, 5000);
      expect(hy.recommendedRamMb, 7000);
      expect(hy.languages, ['zh-CN', 'en', 'zh-TW']);
      expect(hy.license, 'Apache-2.0');
      expect(hy.licenseUrl.host, 'github.com');
      expect(hy.sourceUrl.path, '/Tencent-Hunyuan/Hy-MT2');
      expect(
        hy.sampling,
        const LlamaCatalogSampling(
          temperature: 0.7,
          topP: 0.6,
          topK: 20,
          repeatPenalty: 1.05,
        ),
      );
      expect(hy.sampling.minP, isNull);
      expect(
        hy.toString(),
        'LlamaCatalogModel(hy-mt2-1.8b-q4, '
        'Hy-MT2-1.8B-Q4_K_M.gguf)',
      );

      final qwen = parsed.model('qwen3-1.7b-q4')!;
      expect(qwen.role, LlamaModelRole.assistant);
      expect(qwen.languages, isEmpty);
      expect(qwen.sampling, const LlamaCatalogSampling());
      expect(parsed.ofRole(LlamaModelRole.translation), [hy]);
      expect(parsed.ofRole(LlamaModelRole.assistant), [qwen]);
    });

    test('models are equal by value', () {
      LlamaCatalogModel parse(Map<String, Object?> json) =>
          LlamaModelCatalog.parse(catalog([json])).models.single;
      final a = parse(entry());
      final b = parse(entry());
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      for (final change in <Map<String, Object?>>[
        {'size': 1101},
        {
          'languages': ['en', 'zh-CN'],
        },
        {
          'languages': ['en'],
        },
        {
          'sampling': {'temperature': 0.5},
        },
        {'minRamMb': 5001},
        {'displayName': 'Other'},
      ]) {
        expect(a, isNot(parse(entry(change))), reason: '$change');
      }
      expect(a.sampling.hashCode, b.sampling.hashCode);
    });

    test('sampling round-trips through JSON', () {
      const sampling = LlamaCatalogSampling(
        temperature: 1,
        topP: 0.95,
        topK: 64,
        minP: 0.01,
        repeatPenalty: 1,
      );
      expect(LlamaCatalogSampling.fromJson(sampling.toJson()), sampling);
      expect(const LlamaCatalogSampling().toJson(), isEmpty);
    });

    test('the fake helper writes valid catalogs', () {
      final model = fakeLlamaModel('x', fakeModelBytes(10));
      expect(LlamaModelCatalog.parse(catalogJson([model])).models, [model]);
    });

    final invalid = <String, String>{
      'not an object': '[]',
      'unknown schema': catalog([entry()], schema: 2),
      'models not a list': jsonEncode({'schemaVersion': 1, 'models': 'x'}),
      'no models key': jsonEncode({'schemaVersion': 1}),
      'entry not an object': catalog(['x']),
      'missing id': catalog([
        entry({'id': null}),
      ]),
      'unsafe id': catalog([
        entry({'id': '../x'}),
      ]),
      'id with ..': catalog([
        entry({'id': 'a..b'}),
      ]),
      'long id': catalog([
        entry({'id': 'a' * 49}),
      ]),
      'unsafe name': catalog([
        entry({'name': '../x.gguf'}),
      ]),
      'hidden name': catalog([
        entry({'name': '.x.gguf'}),
      ]),
      'not a gguf': catalog([
        entry({'name': 'x.bin'}),
      ]),
      'http url': catalog([
        entry({'url': 'http://models.example/x.gguf'}),
      ]),
      'bad url': catalog([
        entry({'url': 'https://'}),
      ]),
      'url with credentials': catalog([
        entry({'url': 'https://u:p@models.example/Hy-MT2-1.8B-Q4_K_M.gguf'}),
      ]),
      'url with query': catalog([
        entry({'url': 'https://models.example/Hy-MT2-1.8B-Q4_K_M.gguf?x=1'}),
      ]),
      'url naming another file': catalog([
        entry({'url': 'https://models.example/other.gguf'}),
      ]),
      'url without a path': catalog([
        entry({'url': 'https://models.example'}),
      ]),
      'bad size': catalog([
        entry({'size': 0}),
      ]),
      'size not an int': catalog([
        entry({'size': '10'}),
      ]),
      'bad sha256': catalog([
        entry({'sha256': 'A' * 64}),
      ]),
      'short sha256': catalog([
        entry({'sha256': 'a' * 40}),
      ]),
      'unknown role': catalog([
        entry({'role': 'chat'}),
      ]),
      'unknown family': catalog([
        entry({'family': 'llama'}),
      ]),
      'unknown prompt profile': catalog([
        entry({'promptProfile': 'chatml'}),
      ]),
      'blank display name': catalog([
        entry({'displayName': ' '}),
      ]),
      'long display name': catalog([
        entry({'displayName': 'x' * 65}),
      ]),
      'display name with a newline': catalog([
        entry({'displayName': 'a\nb'}),
      ]),
      'missing parameters': catalog([
        entry({'parameters': null}),
      ]),
      'long parameters': catalog([
        entry({'parameters': 'x' * 33}),
      ]),
      'bad quantization': catalog([
        entry({'quantization': 'Q4 K M'}),
      ]),
      'small context': catalog([
        entry({'contextSize': 128}),
      ]),
      'context not an int': catalog([
        entry({'contextSize': '4096'}),
      ]),
      'bad minRamMb': catalog([
        entry({'minRamMb': 0}),
      ]),
      'recommended below minimum': catalog([
        entry({'recommendedRamMb': 4000}),
      ]),
      'languages not a list': catalog([
        entry({'languages': 'en'}),
      ]),
      'bad language code': catalog([
        entry({
          'languages': ['EN'],
        }),
      ]),
      'duplicate language': catalog([
        entry({
          'languages': ['en', 'en'],
        }),
      ]),
      'translation model without languages': catalog([
        entry({'languages': <String>[]}),
      ]),
      'bad license': catalog([
        entry({'license': 'Apache 2.0'}),
      ]),
      'http license url': catalog([
        entry({'licenseUrl': 'http://example.org/LICENSE'}),
      ]),
      'missing source url': catalog([
        entry({'sourceUrl': null}),
      ]),
      'sampling not an object': catalog([
        entry({'sampling': 1}),
      ]),
      'unknown sampling key': catalog([
        entry({
          'sampling': {'top_p': 0.5},
        }),
      ]),
      'temperature out of range': catalog([
        entry({
          'sampling': {'temperature': 3},
        }),
      ]),
      'topP out of range': catalog([
        entry({
          'sampling': {'topP': 1.5},
        }),
      ]),
      'topK not an int': catalog([
        entry({
          'sampling': {'topK': 2.5},
        }),
      ]),
      'repeat penalty out of range': catalog([
        entry({
          'sampling': {'repeatPenalty': 0.1},
        }),
      ]),
      'minP not a number': catalog([
        entry({
          'sampling': {'minP': 'x'},
        }),
      ]),
      'duplicate id': catalog([
        entry(),
        entry({
          'name': 'Other.gguf',
          'url': 'https://models.example/Other.gguf',
        }),
      ]),
      'duplicate name': catalog([
        entry(),
        entry({'id': 'other'}),
      ]),
    };
    for (final MapEntry(key: reason, value: source) in invalid.entries) {
      test('rejects $reason', () {
        expect(() => LlamaModelCatalog.parse(source), throwsFormatException);
      });
    }
  });

  group(LlamaModelRole, () {
    test('parses role names', () {
      expect(
        LlamaModelRole.tryParse('translation'),
        LlamaModelRole.translation,
      );
      expect(LlamaModelRole.tryParse('assistant'), LlamaModelRole.assistant);
      expect(LlamaModelRole.tryParse('other'), isNull);
      expect(LlamaModelRole.tryParse(null), isNull);
    });
  });

  test('isSafeId', () {
    expect(LlamaCatalogModel.isSafeId('gemma-4-e2b-q4'), isTrue);
    expect(LlamaCatalogModel.isSafeId('qwen3-1.7b-q4'), isTrue);
    expect(LlamaCatalogModel.isSafeId('a' * 48), isTrue);
    expect(LlamaCatalogModel.isSafeId('a' * 49), isFalse);
    expect(LlamaCatalogModel.isSafeId('.hidden'), isFalse);
    expect(LlamaCatalogModel.isSafeId('a/b'), isFalse);
    expect(LlamaCatalogModel.isSafeId('a..b'), isFalse);
  });
}
