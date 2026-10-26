import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/image_translate/image_translate.dart';
import 'package:tesseract_ocr/tesseract_ocr.dart';

import '../helpers/live_camera_fakes.dart';

class _MockEngine extends Mock implements OcrEngine;

void main() {
  final engBytes = List.generate(1000, (i) => i * 13 & 0xFF);
  final catalog = TessdataCatalog([
    TessdataLanguage(
      code: 'eng',
      name: 'eng',
      languages: const ['en'],
      url: Uri.parse('https://example.org/eng.traineddata'),
      size: engBytes.length,
      sha256: sha256.convert(engBytes).toString(),
    ),
  ]);

  late Directory root;
  late _MockEngine engine;
  late TesseractTextRecognitionService service;

  setUpAll(() {
    registerFallbackValue(OcrImage(Uint8List(4), width: 1, height: 1));
  });

  setUp(() {
    root = Directory.systemTemp.createTempSync('ocr_pixels_');
    engine = _MockEngine();
    when(
      () => engine.recognize(
        any(),
        dataPath: any(named: 'dataPath'),
        languages: any(named: 'languages'),
        layout: any(named: 'layout'),
      ),
    ).thenAnswer(
      (_) async => const OcrResult(
        text: 'Exit',
        meanConfidence: 88,
        layout: OcrLayout(
          width: 6,
          height: 2,
          blocks: [
            OcrBlock(
              box: OcrBox(0, 0, 6, 2),
              paragraphs: [
                OcrParagraph(
                  box: OcrBox(0, 0, 6, 2),
                  confidence: 88,
                  lines: [
                    OcrLine(
                      text: 'Exit',
                      box: OcrBox(0, 0, 6, 2),
                      confidence: 88,
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
    when(() => engine.release()).thenAnswer((_) async {});
    service = TesseractTextRecognitionService(
      open: () async => TesseractOcr(
        catalog: catalog,
        root: root,
        httpClient: MockClient((_) async => http.Response.bytes(engBytes, 200)),
        engine: engine,
      ),
      isSupported: true,
      isMeteredConnection: () async => false,
    );
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('the Tesseract service reads raw pixels', () {
    expect(textRecognitionPixelsOf(service), same(service));
    expect(textRecognitionPixelsOf(FilesOnlyRecognizer()), isNull);
  });

  test('reads grey pixels with their row length and the layout', () async {
    await service.downloadOcrLanguage('eng', wifiOnly: false);

    final read = await service.recognizePixels(
      Uint8List(16),
      width: 6,
      height: 2,
      codes: const ['eng'],
      bytesPerPixel: 1,
      bytesPerLine: 8,
    );

    expect(read.text, 'Exit');
    expect(read.confidence, 88);
    expect(read.layout!.paragraphs.single.text, 'Exit');
    final image =
        verify(
              () => engine.recognize(
                captureAny(),
                dataPath: any(named: 'dataPath'),
                languages: ['eng'],
                layout: true,
              ),
            ).captured.single
            as OcrImage;
    expect(
      (image.width, image.height, image.bytesPerPixel, image.bytesPerLine),
      (6, 2, 1, 8),
    );
  });

  test('missing data is offered', () async {
    await expectLater(
      service.recognizePixels(
        Uint8List(12),
        width: 6,
        height: 2,
        codes: const ['eng'],
        bytesPerPixel: 1,
      ),
      throwsA(
        isA<OcrDataMissingException>().having(
          (error) => error.language.code,
          'code',
          'eng',
        ),
      ),
    );
  });

  test('pixels that do not fit fail as a recognition failure', () async {
    await service.downloadOcrLanguage('eng', wifiOnly: false);
    await expectLater(
      service.recognizePixels(
        Uint8List(3),
        width: 6,
        height: 2,
        codes: const ['eng'],
        bytesPerPixel: 1,
      ),
      throwsA(
        const ImageTranslateException(
          ImageTranslateErrorKind.recognitionFailed,
        ),
      ),
    );
  });
}
