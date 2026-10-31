import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:tesseract_ocr/tesseract_ocr.dart';

import '../helpers/fake_tessdata.dart';

class _MockEngine extends Mock implements OcrEngine;

void main() {
  late Directory root;
  late FakeTessdata deu;
  late FakeTessdata eng;
  late FakeTessdataServer server;
  late _MockEngine engine;
  late TesseractOcr ocr;

  setUpAll(() {
    registerFallbackValue(OcrImage(Uint8List(4), width: 1, height: 1));
  });

  setUp(() {
    root = Directory.systemTemp.createTempSync('tesseract_ocr_');
    deu = FakeTessdata('deu');
    eng = FakeTessdata('eng', size: 5000, seed: 2);
    server = FakeTessdataServer([deu, eng]);
    engine = _MockEngine();
    when(
      () => engine.recognize(
        any(),
        dataPath: any(named: 'dataPath'),
        languages: any(named: 'languages'),
        layout: any(named: 'layout'),
      ),
    ).thenAnswer(
      (_) async => const OcrResult(text: 'Hallo', meanConfidence: 88),
    );
    when(() => engine.release()).thenAnswer((_) async {});
    when(() => engine.dispose()).thenAnswer((_) async {});
    ocr = TesseractOcr(
      catalog: fakeCatalog([deu, eng]),
      root: root,
      httpClient: server.client,
      engine: engine,
    );
  });

  tearDown(() => root.deleteSync(recursive: true));

  final pixels = Uint8List(4 * 4 * 2);

  test('is available with an injected engine, not on a desktop host', () {
    expect(ocr.isAvailable, isTrue);
    expect(
      TesseractOcr(catalog: fakeCatalog([deu]), root: root).isAvailable,
      isFalse,
    );
    expect(
      TesseractOcr(
        catalog: fakeCatalog([deu]),
        root: root,
        engine: engine,
        isAvailable: false,
      ).isAvailable,
      isFalse,
    );
  });

  test('downloads, lists, recognises with and deletes languages', () async {
    expect(await ocr.installedLanguages(), isEmpty);
    final progress = <double>[];
    final installed = await ocr.download(
      'deu',
      onProgress: (update) => progress.add(update.fraction),
    );
    expect(installed.code, 'deu');
    expect(progress.last, 1);
    verify(() => engine.release()).called(1);
    expect(await ocr.installedLanguages(), {'deu'});

    final result = await ocr.recognize(
      pixels,
      4,
      2,
      languages: const ['deu', 'deu'],
    );
    expect(result.text, 'Hallo');
    final captured = verify(
      () => engine.recognize(
        captureAny(),
        dataPath: p.join(root.path, 'tessdata'),
        languages: ['deu'],
      ),
    ).captured;
    final image = captured.single as OcrImage;
    expect((image.width, image.height, image.bytesPerPixel), (4, 2, 4));

    // The layout is asked for only when wanted.
    await ocr.recognize(pixels, 4, 2, languages: const ['deu'], layout: true);
    verify(
      () => engine.recognize(
        any(),
        dataPath: p.join(root.path, 'tessdata'),
        languages: ['deu'],
        layout: true,
      ),
    ).called(1);

    await ocr.delete('deu');
    verify(() => engine.release()).called(1);
    expect(await ocr.installedLanguages(), isEmpty);
  });

  test('refuses languages that are not installed', () async {
    await ocr.download('eng');
    await expectLater(
      ocr.recognize(pixels, 4, 2, languages: const ['deu', 'eng', 'fra']),
      throwsA(
        isA<TessdataMissingException>()
            .having((e) => e.missing, 'missing', ['deu', 'fra'])
            .having(
              (e) => e.toString(),
              'toString',
              'TessdataMissingException(deu, fra)',
            ),
      ),
    );
    verifyNever(
      () => engine.recognize(
        any(),
        dataPath: any(named: 'dataPath'),
        languages: any(named: 'languages'),
        layout: any(named: 'layout'),
      ),
    );
  });

  test('validates languages and the image', () async {
    expect(
      () => ocr.recognize(pixels, 4, 2, languages: const []),
      throwsArgumentError,
    );
    expect(
      () => ocr.recognize(pixels, 4, 2, languages: List.filled(9, 'eng')),
      throwsArgumentError,
    );
    expect(
      () => ocr.recognize(pixels, 4, 2, languages: const ['../eng']),
      throwsArgumentError,
    );
    expect(
      () => ocr.recognize(pixels, 40, 20, languages: const ['eng']),
      throwsArgumentError,
    );
  });

  test('fails when unavailable', () async {
    final unavailable = TesseractOcr(
      catalog: fakeCatalog([deu]),
      root: root,
      engine: engine,
      isAvailable: false,
    );
    await expectLater(
      unavailable.recognize(pixels, 4, 2, languages: const ['deu']),
      throwsUnsupportedError,
    );
  });

  test('cancelDownload stops a running download', () async {
    server.stallAfter = 1000;
    final download = ocr.download('deu');
    await server.stalled.future;
    await ocr.cancelDownload('deu');
    await expectLater(
      download,
      throwsA(isA<TessdataDownloadCancelledException>()),
    );
    expect(await ocr.installedLanguages(), isEmpty);
  });

  test('download refuses codes outside the catalog', () async {
    await expectLater(ocr.download('fra'), throwsArgumentError);
  });

  test('installedLanguages ignores data the catalog does not list', () async {
    await ocr.download('deu');
    final other = TesseractOcr(
      catalog: fakeCatalog([eng]),
      root: root,
      engine: engine,
    );
    expect(await other.installedLanguages(), isEmpty);
  });

  test('importFiles installs without the network and releases', () async {
    final file = File(p.join(root.path, 'deu.traineddata'))
      ..writeAsBytesSync(deu.bytes);
    final result = await ocr.importFiles([file]);
    expect(result.installed, [deu.language]);
    expect(server.requests, isEmpty);
    verify(() => engine.release()).called(1);

    final again = await ocr.importFiles([file]);
    expect(again.installed, isEmpty);
    verifyNever(() => engine.release());
  });

  test('ignores release failures', () async {
    when(() => engine.release()).thenThrow(StateError('gone'));
    await ocr.download('deu');
    await ocr.delete('deu');
  });

  test('dispose stops the engine', () async {
    await ocr.dispose();
    verify(() => engine.dispose()).called(1);
    await ocr.dispose();
    verifyNoMoreInteractions(engine);
  });
}
