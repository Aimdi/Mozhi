import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/image_translate/image_translate.dart';
import 'package:mozhi/platform/text_recognition.dart';
import 'package:mozhi/platform/text_recognition_io.dart' as io;
import 'package:mozhi/platform/text_recognition_web.dart' as web;
import 'package:path/path.dart' as p;
import 'package:tesseract_ocr/tesseract_ocr.dart';

class _MockEngine extends Mock implements OcrEngine;

/// Serves the package's real catalog from disk.
class _CatalogBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    expect(key, TessdataCatalog.assetKey);
    return ByteData.sublistView(
      File('packages/tesseract_ocr/assets/catalog.json').readAsBytesSync(),
    );
  }
}

void main() {
  late Directory support;

  setUp(() => support = Directory.systemTemp.createTempSync('ocr_support_'));
  tearDown(() => support.deleteSync(recursive: true));

  test('loads the bundled catalog lazily into <support>/tesseract', () async {
    var asked = 0;
    final service = io.createTesseractTextRecognitionService(
      bundle: _CatalogBundle(),
      supportDirectory: () async {
        asked++;
        return support;
      },
      isAvailable: true,
      engine: _MockEngine(),
      isMeteredConnection: () async => false,
    );
    expect(asked, 0);
    expect(service.isSupported, isTrue);

    final languages = await service.ocrLanguages();
    expect(languages, hasLength(110));
    expect((await service.ocrLanguageFor('de'))?.downloadSize, 1525436);
    expect(asked, 1);

    // Data goes to <support>/tesseract/tessdata.
    final picked = File(p.join(support.path, 'photo.jpg'))
      ..writeAsBytesSync(Uint8List(3));
    final report = await service.importOcrFiles([picked.path]);
    expect(report.unmatchedFiles, ['photo.jpg']);
    expect(io.textRecognitionFolder, 'tesseract');
    expect(await service.installedOcrLanguages(), isEmpty);
  });

  test('is not supported on a desktop host by default', () {
    final service = io.createTesseractTextRecognitionService(
      supportDirectory: () async => support,
    );
    expect(service.isSupported, isFalse);
  });

  test('the app shares one recognizer', () {
    final recognizer = defaultTextRecognitionService();
    expect(recognizer, isA<TesseractTextRecognitionService>());
    expect(defaultTextRecognitionService(), same(recognizer));
  });

  test('the web has no recognizer', () {
    final recognizer = web.defaultTextRecognitionService();
    expect(recognizer, isA<UnavailableTextRecognitionService>());
    expect(recognizer.isSupported, isFalse);
    expect(textRecognitionLanguageDataOf(recognizer), isNull);
  });
}
