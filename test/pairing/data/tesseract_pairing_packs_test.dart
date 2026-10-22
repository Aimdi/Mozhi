import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/image_translate/data/text_recognition_service.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:mozhi/pairing/data/tesseract_pairing_packs.dart';
import 'package:mozhi/pairing/models/pairing_item.dart';
import 'package:tesseract_ocr/tesseract_ocr.dart';

import '../helpers/fake_packs.dart';

/// Recognition data in [directory], imported with a size and SHA-256
/// check against [catalog] like the real recognizer.
class _FakeData implements TextRecognitionLanguageData {
  new(this.directory, this.catalog, {this.isSupported = true});

  final Directory directory;
  final TessdataCatalog catalog;
  OcrImportReport? report;
  final imported = <List<String>>[];

  @override
  final bool isSupported;

  @override
  Future<Map<String, int>> installedOcrLanguages() async => {
    if (directory.existsSync())
      for (final file in directory.listSync().whereType<File>())
        file.uri.pathSegments.last.split('.').first: file.lengthSync(),
  };

  @override
  Future<OcrImportReport> importOcrFiles(List<String> paths) async {
    imported.add(paths);
    if (report case final report?) return report;
    final installed = <String>[];
    final damaged = <String>[];
    for (final path in paths) {
      final file = File(path);
      final code = file.uri.pathSegments.last.split('.').first;
      final language = catalog.byCode(code)!;
      final bytes = file.readAsBytesSync();
      if (bytes.length == language.size && sha256Of(bytes) == language.sha256) {
        directory.createSync(recursive: true);
        file.copySync('${directory.path}/${language.fileName}');
        installed.add(code);
      } else {
        damaged.add(code);
      }
    }
    return OcrImportReport(installed: installed, damaged: damaged);
  }

  @override
  Stream<void> get ocrLanguagesChanged => const Stream.empty();

  @override
  Future<List<OcrLanguage>> ocrLanguages() => throw UnimplementedError();

  @override
  Future<OcrLanguage?> ocrLanguageFor(String code) =>
      throw UnimplementedError();

  @override
  Future<String> recognizeWith(PickedImage image, List<String> codes) =>
      throw UnimplementedError();

  @override
  Future<void> downloadOcrLanguage(
    String code, {
    required bool wifiOnly,
    void Function(double fraction)? onProgress,
  }) => throw UnimplementedError();

  @override
  Future<void> deleteOcrLanguage(String code) => throw UnimplementedError();
}

void main() {
  late Directory temp;
  late TessdataCatalog catalog;
  final deu = bytesOf(400, 3);
  final fra = bytesOf(200, 5);

  TessdataLanguage language(String code, String app, List<int> bytes) =>
      TessdataLanguage(
        code: code,
        name: code,
        languages: [app],
        url: Uri.parse('https://data.example/$code.traineddata'),
        size: bytes.length,
        sha256: sha256Of(bytes),
      );

  setUp(() {
    temp = Directory.systemTemp.createTempSync('mozhi_pairing_ocr_');
    catalog = TessdataCatalog([
      language('deu', 'de', deu),
      language('fra', 'fr', fra),
    ]);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  _FakeData data(String folder, {bool isSupported = true}) => _FakeData(
    Directory('${temp.path}/$folder/tessdata'),
    catalog,
    isSupported: isSupported,
  );

  TesseractPairingPacks packs(_FakeData data) => TesseractPairingPacks(
    data: data,
    catalog: () async => catalog,
    dataDirectory: () async => data.directory,
  );

  void install(_FakeData data, String code, List<int> bytes) =>
      File('${data.directory.path}/$code.traineddata')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes);

  Future<List<File>> copy(PairingItem item, List<int> bytes) async => [
    File('${temp.path}/in/${item.files.single.name}')
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes),
  ];

  group('TesseractPairingPacks', () {
    test('offers the installed languages of the catalogue', () async {
      final sender = data('sender');
      install(sender, 'deu', deu);
      install(sender, 'fra', bytesOf(150, 5));
      install(sender, 'xyz', bytesOf(10));
      final outgoing = await packs(sender).outgoing();
      expect(packs(sender).kind, PairingItemKind.ocr);
      expect([for (final o in outgoing) o.item.key], ['deu', 'fra']);
      expect(outgoing.first.item.files.single.sha256, sha256Of(deu));
      // An older version: no SHA-256 to offer.
      expect(outgoing.last.item.files.single.sha256, isNull);
      expect(
        await outgoing.first.readers['deu.traineddata']!()
            .expand((chunk) => chunk)
            .toList(),
        deu,
      );
    });

    test('offers nothing where recognition does not run', () async {
      final sender = data('sender', isSupported: false);
      install(sender, 'deu', deu);
      expect(await packs(sender).outgoing(), isEmpty);
    });

    test('skips a language whose file is missing', () async {
      final sender = _FakeData(Directory('${temp.path}/elsewhere'), catalog);
      install(sender, 'deu', deu);
      final packs = TesseractPairingPacks(
        data: sender,
        catalog: () async => catalog,
        dataDirectory: () async => Directory('${temp.path}/empty'),
      );
      expect(await packs.outgoing(), isEmpty);
    });

    test('a phone without the language takes and installs it', () async {
      final sender = data('sender');
      install(sender, 'deu', deu);
      final item = (await packs(sender).outgoing()).single.item;
      final receiver = data('receiver');
      final plan = await packs(receiver).plan(item);
      expect(plan.status, PairingItemStatus.available);
      expect(
        await packs(receiver).install(item, await copy(item, deu)),
        PairingItemOutcome.installed,
      );
      expect(
        await packs(receiver).plan(item),
        const PairingPlan.installed(language: 'de'),
      );
    });

    test('reports damaged and failed imports', () async {
      const item = PairingItem(
        kind: PairingItemKind.ocr,
        key: 'deu',
        files: [PairingFile(name: 'deu.traineddata', size: 400)],
      );
      final receiver = data('receiver');
      expect(
        await packs(receiver).install(item, await copy(item, bytesOf(400))),
        PairingItemOutcome.damaged,
      );
      receiver.report = const OcrImportReport(failed: ['deu']);
      expect(
        await packs(receiver).install(item, await copy(item, deu)),
        PairingItemOutcome.failed,
      );
      receiver.report = const OcrImportReport(alreadyInstalled: ['deu']);
      expect(
        await packs(receiver).install(item, await copy(item, deu)),
        PairingItemOutcome.installed,
      );
    });

    test('takes nothing it does not know or cannot run', () async {
      const unknown = PairingItem(
        kind: PairingItemKind.ocr,
        key: 'xyz',
        files: [PairingFile(name: 'xyz.traineddata', size: 1)],
      );
      expect(
        await packs(data('receiver')).plan(unknown),
        const PairingPlan.incompatible(),
      );
      const other = PairingItem(
        kind: PairingItemKind.ocr,
        key: 'deu',
        files: [PairingFile(name: 'deu.traineddata', size: 399)],
      );
      expect(
        await packs(data('receiver')).plan(other),
        const PairingPlan.incompatible(),
      );
      const right = PairingItem(
        kind: PairingItemKind.ocr,
        key: 'deu',
        files: [PairingFile(name: 'deu.traineddata', size: 400)],
      );
      expect(
        await packs(data('off', isSupported: false)).plan(right),
        const PairingPlan.incompatible(),
      );
    });
  });
}
