import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mozhi/offline/data/bergamot_model_details.dart';
import 'package:mozhi/offline/data/offline_model_import.dart';
import 'package:mozhi/offline/data/picked_import_file.dart';

/// The worker's storage operations an import uses, in memory (no engine):
/// `list` from the manifests written by `commit`.
class _StorageWorker implements BergamotWorkerChannel {
  final Map<String, Uint8List> files = {};
  final List<String> ops = [];

  @override
  Future<Object?> request(
    String op, [
    Map<String, Object?> arguments = const {},
  ]) async {
    ops.add(op);
    final path = arguments['path'] as String?;
    switch (op) {
      case 'list':
        return [
          for (final MapEntry(:key, :value) in files.entries)
            if (key.endsWith('/manifest.json'))
              {
                'directory': key.substring(0, key.lastIndexOf('/')),
                'manifest': jsonDecode(utf8.decode(value)),
                'sizeBytes': 0,
              },
        ];
      case 'downloadOpen':
        files[path!] = Uint8List(0);
        return {'size': 0};
      case 'downloadWrite':
        files[path!] = Uint8List.fromList([
          ...files[path]!,
          ...arguments['bytes']! as Uint8List,
        ]);
        return null;
      case 'fingerprint':
        final bytes = files[path]!;
        return {'size': bytes.length, 'sha256': '${sha256.convert(bytes)}'};
      case 'install':
        final part = files.remove(arguments['part'])!;
        files[arguments['target']! as String] = arguments['compressed'] == false
            ? part
            : Uint8List.fromList(gzip.decode(part));
        return null;
      case 'commit':
        files['${arguments['directory']}/manifest.json'] = utf8.encode(
          jsonEncode(arguments['manifest']),
        );
        return null;
      case 'remove':
        files.removeWhere((key, _) => key == path || key.startsWith('$path/'));
        return null;
      default:
        return null;
    }
  }

  @override
  void terminate() {}
}

void main() {
  final raw = Uint8List.fromList(List.generate(900, (i) => i % 7));
  final gz = Uint8List.fromList(gzip.encode(raw));
  CatalogFile file(ModelFileKind kind, String name) => CatalogFile(
    kind: kind,
    name: name,
    url: Uri.parse('https://models.test/de-en/v1/$name.gz'),
    size: gz.length,
    sha256: '${sha256.convert(gz)}',
    uncompressedSize: raw.length,
    uncompressedSha256: '${sha256.convert(raw)}',
  );
  final model = CatalogModel(
    source: 'de',
    target: 'en',
    version: 'v1',
    architecture: 'tiny',
    releaseStatus: 'Release',
    files: {
      ModelFileKind.model: file(ModelFileKind.model, 'model.deen.bin'),
      ModelFileKind.lexicalShortlist: file(
        ModelFileKind.lexicalShortlist,
        'lex.deen.bin',
      ),
      ModelFileKind.vocab: file(ModelFileKind.vocab, 'vocab.deen.spm'),
    },
  );

  late _StorageWorker worker;
  late WebBergamotModelDetails details;

  setUp(() {
    worker = _StorageWorker();
    final translator = createWebBergamotTranslator(
      catalog: ModelCatalog([model]),
      channel: worker,
      httpClient: MockClient((_) async => http.Response('', 500)),
      isAvailable: true,
    );
    details = offlineModelDetailsOf(translator)! as WebBergamotModelDetails;
  });

  test('installs the models the picked files complete', () async {
    final report = await details.importContents([
      PickedImportFile.bytes('model.deen.bin.gz', gz, chunkSize: 100),
      PickedImportFile.bytes('lex.deen.bin', raw),
      PickedImportFile.bytes('vocab.deen.spm.gz', gz),
      PickedImportFile.bytes('notes.txt', Uint8List.fromList([1, 2])),
    ]);

    expect(report.models, [
      const OfflineImportedModel(
        source: 'de',
        target: 'en',
        status: OfflineImportStatus.installed,
      ),
    ]);
    expect(report.unmatchedFiles, ['notes.txt']);
    expect(worker.files['models/de-en/v1/lex.deen.bin'], raw);
    expect(worker.files['models/de-en/v1/model.deen.bin'], raw);
    expect(worker.ops, isNot(contains('translate')));
  });

  test('names the files still needed', () async {
    final report = await details.importContents([
      PickedImportFile.bytes('model.deen.bin.gz', gz),
    ]);

    expect(report.models.single.status, OfflineImportStatus.incomplete);
    expect(report.models.single.missingFiles, [
      'lex.deen.bin.gz',
      'vocab.deen.spm.gz',
    ]);
  });
}
