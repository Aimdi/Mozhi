import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper_speech/whisper_speech.dart';

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

  Map<String, Object?> entry({
    Object? id = 'tiny',
    Object? name = 'ggml-tiny.bin',
    Object? url = 'https://models.example/ggml-tiny.bin',
    Object? size = 10,
    Object? sha = 'aa',
    Object? sha256,
    Object? multilingual,
    Object? parameters,
  }) => {
    'id': ?id,
    'name': ?name,
    'url': ?url,
    'size': ?size,
    'sha1': sha == 'aa' ? 'a' * 40 : sha,
    'sha256': ?sha256,
    'multilingual': ?multilingual,
    'parameters': ?parameters,
  };

  String catalog(List<Object?> models, {Object schema = 1}) =>
      jsonEncode({'schemaVersion': schema, 'models': models});

  group(WhisperModelCatalog, () {
    test('the bundled catalog lists tiny and base with the published '
        'checksums', () {
      final parsed = WhisperModelCatalog.parse(
        File('assets/models.json').readAsStringSync(),
      );
      expect(parsed.models.map((m) => m.id), ['tiny', 'base']);
      final tiny = parsed.model('tiny')!;
      final base = parsed.model('base')!;
      // whisper.cpp v1.9.5 models/README.md.
      expect(tiny.sha1, 'bd577a113a864445d4c299885e0cb97d4ba92b5f');
      expect(base.sha1, '465707469ff3a37a2b9b8d8f89f2f99de7299dac');
      expect(tiny.size, 77691713);
      expect(base.size, 147951465);
      // Hugging Face's SHA-256, checked too (a mirror can't swap files).
      expect(
        tiny.sha256,
        'be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21',
      );
      expect(
        base.sha256,
        '60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe',
      );
      expect(
        tiny.url,
        Uri.parse(
          'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/'
          'ggml-tiny.bin',
        ),
      );
      expect(base.url.host, 'huggingface.co');
      expect(tiny.multilingual && base.multilingual, isTrue);
      expect(tiny.parameters, lessThan(base.parameters!));
      expect(parsed.source, 'https://huggingface.co/ggerganov/whisper.cpp');
      expect(parsed.license, contains('MIT'));
      expect(parsed.model('large'), isNull);
    });

    test('the checksums match the copy of the whisper.cpp README', () {
      final readme = File('native/third_party/whisper.cpp/models/README.md');
      if (!readme.existsSync()) {
        markTestSkipped('whisper.cpp is not checked out');
        return;
      }
      final text = readme.readAsStringSync();
      final parsed = WhisperModelCatalog.parse(
        File('assets/models.json').readAsStringSync(),
      );
      for (final model in parsed.models) {
        expect(
          RegExp(
            '^\\| ${model.id} +\\| [^|]+\\| `${model.sha1}` \\|',
            multiLine: true,
          ).hasMatch(text),
          isTrue,
          reason: model.id,
        );
      }
    });

    test('loads the bundled asset', () async {
      final source = File('assets/models.json').readAsStringSync();
      final loaded = await loadBundledWhisperCatalog(
        bundle: _StringBundle({WhisperModelCatalog.assetKey: source}),
      );
      expect(loaded.models, hasLength(2));
    });

    test('parses optional fields', () {
      final parsed = WhisperModelCatalog.parse(
        catalog([entry(multilingual: false, parameters: 5)]),
      );
      final model = parsed.models.single;
      expect(model.multilingual, isFalse);
      expect(model.parameters, 5);
      expect(model.toString(), 'WhisperCatalogModel(tiny, ggml-tiny.bin)');
      expect(parsed.source, isNull);
      expect(parsed.license, isNull);
    });

    test('models are equal by value', () {
      final a = WhisperModelCatalog.parse(catalog([entry()])).models.single;
      final b = WhisperModelCatalog.parse(catalog([entry()])).models.single;
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(
        a,
        isNot(WhisperModelCatalog.parse(catalog([entry(size: 11)])).models[0]),
      );
    });

    test('reads an optional SHA-256', () {
      final parsed = WhisperModelCatalog.parse(
        catalog([
          entry(sha256: 'b' * 64),
          entry(id: 'base', name: 'ggml-base.bin'),
        ]),
      );
      expect(parsed.model('tiny')!.sha256, 'b' * 64);
      expect(parsed.model('base')!.sha256, isNull);
      expect(parsed.model('tiny'), isNot(parsed.model('base')));
    });

    final invalid = <String, String>{
      'not an object': '[]',
      'unknown schema': catalog([entry()], schema: 2),
      'no models': jsonEncode({'schemaVersion': 1, 'models': <Object>[]}),
      'models not a list': jsonEncode({'schemaVersion': 1, 'models': 'x'}),
      'entry not an object': catalog(['x']),
      'missing id': catalog([entry(id: null)]),
      'unsafe id': catalog([entry(id: '../x')]),
      'unsafe name': catalog([entry(name: '../ggml.bin')]),
      'hidden name': catalog([entry(name: '.ggml.bin')]),
      'http url': catalog([entry(url: 'http://models.example/x.bin')]),
      'bad url': catalog([entry(url: 'https://')]),
      'bad sha1': catalog([entry(sha: 'ABC')]),
      'bad sha256': catalog([entry(sha256: 'B' * 64)]),
      'sha256 not a string': catalog([entry(sha256: 1)]),
      'bad size': catalog([entry(size: 0)]),
      'size not an int': catalog([entry(size: '10')]),
      'bad multilingual': catalog([entry(multilingual: 'yes')]),
      'bad parameters': catalog([entry(parameters: -1)]),
      'duplicate id': catalog([entry(), entry(name: 'other.bin')]),
      'duplicate name': catalog([entry(), entry(id: 'other')]),
    };
    for (final MapEntry(key: reason, value: source) in invalid.entries) {
      test('rejects $reason', () {
        expect(() => WhisperModelCatalog.parse(source), throwsFormatException);
      });
    }
  });
}
