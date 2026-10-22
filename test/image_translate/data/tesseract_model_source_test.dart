import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mozhi/image_translate/data/tesseract_text_recognition_service.dart';
import 'package:mozhi/settings/models/model_source.dart';
import 'package:tesseract_ocr/tesseract_ocr.dart';

/// [TesseractTextRecognitionService.downloadOcrLanguage] with the
/// settings' model source (W3-B).
void main() {
  late Directory root;
  late Uint8List bytes;
  late List<Uri> requests;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tesseract_source_');
    bytes = Uint8List.fromList([for (var i = 0; i < 300; i++) i & 0xff]);
    requests = [];
  });
  tearDown(() {
    ModelSource.current = ModelSource.platformDefault;
    root.deleteSync(recursive: true);
  });

  TesseractTextRecognitionService build() => TesseractTextRecognitionService(
    open: () async => TesseractOcr(
      catalog: TessdataCatalog([
        TessdataLanguage(
          code: 'deu',
          name: 'German',
          languages: const ['de'],
          url: Uri.parse('https://data.example/deu.traineddata'),
          size: bytes.length,
          sha256: sha256.convert(bytes).toString(),
        ),
      ]),
      root: root,
      httpClient: MockClient((request) async {
        requests.add(request.url);
        return request.url.host == 'mirror.example'
            ? http.Response.bytes(bytes, 200)
            : http.Response('missing', 404);
      }),
      isAvailable: true,
    ),
    isSupported: true,
    isMeteredConnection: () async => false,
  );

  test('downloads from the mirror of the model source', () async {
    ModelSource.current = const ModelSource(
      kind: ModelSourceKind.custom,
      customUrl: 'https://mirror.example/models/',
    );
    await build().downloadOcrLanguage('deu', wifiOnly: false);
    expect(requests, [
      Uri.parse('https://mirror.example/models/tesseract/deu.traineddata'),
    ]);
  });

  test('falls back to the original publisher only when allowed', () async {
    ModelSource.current = const ModelSource(
      kind: ModelSourceKind.custom,
      customUrl: 'https://other.example/',
      fallbackToDefault: true,
    );
    await expectLater(
      build().downloadOcrLanguage('deu', wifiOnly: false),
      throwsA(isA<TessdataDownloadException>()),
    );
    expect(requests, [
      Uri.parse('https://other.example/tesseract/deu.traineddata'),
      Uri.parse('https://data.example/deu.traineddata'),
    ]);
  });
}
