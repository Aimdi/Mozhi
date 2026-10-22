import 'dart:io';

import 'package:mozhi/image_translate/data/text_recognition_service.dart';
import 'package:mozhi/pairing/data/pairing_packs.dart';
import 'package:mozhi/pairing/models/pairing_item.dart';
import 'package:tesseract_ocr/tesseract_ocr.dart';

/// The text recognition data (Tesseract, [TextRecognitionLanguageData]) as
/// pairing items: one per installed language, keyed by its Tesseract code
/// (`deu`), its file `<code>.traineddata` read from `dataDirectory` (the
/// folder Tesseract reads, see `TessdataManager.dataDirectory`).
///
/// A phone takes a language its bundled `catalog` lists with the same
/// size and SHA-256 and installs it with
/// [TextRecognitionLanguageData.importOcrFiles], which checks it again.
class TesseractPairingPacks implements PairingPacks {
  new({
    required this.data,
    required this._catalog,
    required this._dataDirectory,
  });

  final TextRecognitionLanguageData data;
  final Future<TessdataCatalog> Function() _catalog;
  final Future<Directory> Function() _dataDirectory;
  Future<TessdataCatalog>? _loaded;

  @override
  PairingItemKind get kind => PairingItemKind.ocr;

  Future<TessdataCatalog> get _languages => _loaded ??= _catalog();

  @override
  Future<List<PairingOutgoingItem>> outgoing() async {
    if (!data.isSupported) return const [];
    final installed = await data.installedOcrLanguages();
    final catalog = await _languages;
    final directory = await _dataDirectory();
    final items = <PairingOutgoingItem>[];
    for (final code in installed.keys.toList()..sort()) {
      final language = catalog.byCode(code);
      if (language == null) continue;
      final file = File('${directory.path}/${language.fileName}');
      if (!file.existsSync()) continue;
      final size = await file.length();
      items.add(
        PairingOutgoingItem(
          PairingItem(
            kind: kind,
            key: code,
            files: [
              PairingFile(
                name: language.fileName,
                size: size,
                sha256: size == language.size ? language.sha256 : null,
              ),
            ],
          ),
          {language.fileName: file.openRead},
          language: language.languages.first,
        ),
      );
    }
    return items;
  }

  @override
  Future<PairingPlan> plan(PairingItem item) async {
    final language = (await _languages).byCode(item.key);
    if (!data.isSupported || language == null) {
      return const PairingPlan.incompatible();
    }
    final installed = await data.installedOcrLanguages();
    final app = language.languages.first;
    if (installed[language.code] == language.size) {
      return PairingPlan.installed(language: app);
    }
    final expected = PairingFile(
      name: language.fileName,
      size: language.size,
      sha256: language.sha256,
    );
    return matchesOffer(item, expected)
        ? PairingPlan.available([expected], language: app)
        : const PairingPlan.incompatible();
  }

  @override
  Future<PairingItemOutcome> install(PairingItem item, List<File> files) async {
    final report = await data.importOcrFiles([
      for (final file in files) file.path,
    ]);
    if (report.installed.contains(item.key) ||
        report.alreadyInstalled.contains(item.key)) {
      return PairingItemOutcome.installed;
    }
    if (report.failed.contains(item.key) || report.error != null) {
      return pairingOutcomeOf(report.error ?? 'failed');
    }
    return PairingItemOutcome.damaged;
  }
}
