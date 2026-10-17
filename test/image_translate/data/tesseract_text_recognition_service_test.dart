import 'dart:io';
import 'dart:typed_data';

import 'package:bergamot_translator/bergamot_translator.dart'
    show MeteredConnectionException;
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/image_translate/image_translate.dart';
import 'package:path/path.dart' as p;
import 'package:tesseract_ocr/tesseract_ocr.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

class _MockEngine extends Mock implements OcrEngine;

class _FakeDecoder implements RgbaImageDecoder {
  Exception? error;
  final sides = <int>[];

  @override
  Future<RgbaImage> decode(
    Uint8List bytes, {
    int maxSide = defaultOcrMaxSide,
  }) async {
    sides.add(maxSide);
    final failure = error;
    if (failure != null) throw failure;
    return RgbaImage(pixels: Uint8List(4 * 3 * 2), width: 3, height: 2);
  }
}

TessdataLanguage _language(String code, List<String> languages, List<int> b) =>
    TessdataLanguage(
      code: code,
      name: code,
      languages: languages,
      url: Uri.parse('https://example.org/$code.traineddata'),
      size: b.length,
      sha256: sha256.convert(b).toString(),
    );

void main() {
  final deuBytes = List.generate(3000, (i) => i * 7 & 0xFF);
  final engBytes = List.generate(4000, (i) => i * 13 & 0xFF);
  final chiBytes = List.generate(2000, (i) => i * 3 & 0xFF);
  final catalog = TessdataCatalog([
    _language('chi_sim', const ['zh-CN', 'wuu'], chiBytes),
    _language('deu', const ['de'], deuBytes),
    _language('eng', const ['en'], engBytes),
  ]);

  late Directory root;
  late _MockEngine engine;
  late _FakeDecoder decoder;
  late List<http.BaseRequest> requests;
  late bool metered;
  late int opened;
  late TesseractTextRecognitionService service;

  setUpAll(() {
    registerFallbackValue(OcrImage(Uint8List(4), width: 1, height: 1));
  });

  setUp(() {
    root = Directory.systemTemp.createTempSync('ocr_service_');
    engine = _MockEngine();
    when(
      () => engine.recognize(
        any(),
        dataPath: any(named: 'dataPath'),
        languages: any(named: 'languages'),
      ),
    ).thenAnswer((_) async => const OcrResult(text: 'Ausgang links'));
    when(() => engine.release()).thenAnswer((_) async {});
    decoder = _FakeDecoder();
    requests = [];
    metered = false;
    opened = 0;
    final client = MockClient((request) async {
      requests.add(request);
      final name = request.url.pathSegments.last;
      final body = switch (name) {
        'deu.traineddata' => deuBytes,
        'eng.traineddata' => engBytes,
        'chi_sim.traineddata' => chiBytes,
        _ => null,
      };
      return body == null
          ? http.Response('', 404)
          : http.Response.bytes(body, 200);
    });
    service = TesseractTextRecognitionService(
      open: () async {
        opened++;
        return TesseractOcr(
          catalog: catalog,
          root: root,
          httpClient: client,
          engine: engine,
        );
      },
      isSupported: true,
      isMeteredConnection: () async => metered,
      decoder: decoder,
    );
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('lists the catalog languages with their app language', () async {
    final languages = await service.ocrLanguages();
    expect(
      [for (final language in languages) language.code],
      ['chi_sim', 'deu', 'eng'],
    );
    expect(languages[1].appCode, 'de');
    expect(languages[1].downloadSize, deuBytes.length);
    expect(languages[1].url, Uri.parse('https://example.org/deu.traineddata'));
    expect(await service.ocrLanguages(), same(languages));
    expect(opened, 1);
  });

  test('maps app languages to their data', () async {
    expect((await service.ocrLanguageFor('de'))?.code, 'deu');
    expect((await service.ocrLanguageFor('de-CH'))?.code, 'deu');
    expect((await service.ocrLanguageFor('zh'))?.code, 'chi_sim');
    expect((await service.ocrLanguageFor('zh_Hans'))?.code, 'chi_sim');
    expect(await service.ocrLanguageFor('auto'), isNull);
    expect(await service.ocrLanguageFor(''), isNull);
    expect(await service.ocrLanguageFor('fr'), isNull);
  });

  test('downloads, lists, recognises with and deletes data', () async {
    final changes = <void>[];
    final subscription = service.ocrLanguagesChanged.listen(changes.add);
    addTearDown(subscription.cancel);

    final progress = <double>[];
    await service.downloadOcrLanguage(
      'deu',
      wifiOnly: true,
      onProgress: progress.add,
    );
    expect(progress.last, 1);
    expect(await service.installedOcrLanguages(), {'deu': deuBytes.length});

    final text = await service.recognize(pngImage, source: german);
    expect(text, 'Ausgang links');
    verify(
      () => engine.recognize(
        any(),
        dataPath: p.join(root.path, 'tessdata'),
        languages: ['deu'],
      ),
    ).called(1);
    expect(decoder.sides, [defaultOcrMaxSide]);

    await service.deleteOcrLanguage('deu');
    expect(await service.installedOcrLanguages(), isEmpty);
    await pumpEventQueue();
    expect(changes, hasLength(2));
  });

  test('a Wi-Fi-only download stops on a metered network', () async {
    metered = true;
    await expectLater(
      service.downloadOcrLanguage('deu', wifiOnly: true),
      throwsA(isA<MeteredConnectionException>()),
    );
    expect(requests, isEmpty);
    await service.downloadOcrLanguage('deu', wifiOnly: false);
    expect(requests, hasLength(1));
  });

  group('recognize', () {
    test('offers the missing data of the source', () async {
      await expectLater(
        service.recognize(pngImage, source: german),
        throwsA(
          isA<OcrDataMissingException>()
              .having((e) => e.language.code, 'code', 'deu')
              .having((e) => e.guessed, 'guessed', isFalse),
        ),
      );
    });

    test('guesses English for Detect language without data', () async {
      await expectLater(
        service.recognize(pngImage, source: Language.auto),
        throwsA(
          isA<OcrDataMissingException>()
              .having((e) => e.language.code, 'code', 'eng')
              .having((e) => e.guessed, 'guessed', isTrue),
        ),
      );
    });

    test('reads Detect language with the installed data', () async {
      await service.downloadOcrLanguage('chi_sim', wifiOnly: false);
      await service.downloadOcrLanguage('eng', wifiOnly: false);
      await service.recognize(pngImage, source: Language.auto);
      verify(
        () => engine.recognize(
          any(),
          dataPath: any(named: 'dataPath'),
          languages: ['eng', 'chi_sim'],
        ),
      ).called(1);
    });

    test('reports languages without data', () async {
      await expectLater(
        service.recognize(pngImage, source: french),
        throwsA(
          const ImageTranslateException(
            ImageTranslateErrorKind.recognitionLanguageUnsupported,
          ),
        ),
      );
    });

    test('fails where the engine cannot run', () async {
      final unsupported = TesseractTextRecognitionService(
        open: () => throw StateError('not opened'),
        isSupported: false,
        isMeteredConnection: () async => false,
      );
      await expectLater(
        unsupported.recognize(pngImage, source: german),
        throwsA(
          const ImageTranslateException(
            ImageTranslateErrorKind.recognitionFailed,
          ),
        ),
      );
    });
  });

  group('recognizeWith', () {
    test('turns missing data into an offer', () async {
      await expectLater(
        service.recognizeWith(pngImage, const ['deu']),
        throwsA(
          isA<OcrDataMissingException>().having(
            (e) => e.language.code,
            'code',
            'deu',
          ),
        ),
      );
    });

    test('reports engine failures and undecodable images', () async {
      await service.downloadOcrLanguage('deu', wifiOnly: false);
      when(
        () => engine.recognize(
          any(),
          dataPath: any(named: 'dataPath'),
          languages: any(named: 'languages'),
        ),
      ).thenThrow(const TesseractEngineException('boom'));
      await expectLater(
        service.recognizeWith(pngImage, const ['deu']),
        throwsA(
          isA<ImageTranslateException>()
              .having(
                (e) => e.kind,
                'kind',
                ImageTranslateErrorKind.recognitionFailed,
              )
              .having((e) => e.cause, 'cause', isA<TesseractEngineException>()),
        ),
      );

      decoder.error = const ImageTranslateException(
        ImageTranslateErrorKind.invalidImage,
      );
      await expectLater(
        service.recognizeWith(pngImage, const ['deu']),
        throwsA(
          const ImageTranslateException(ImageTranslateErrorKind.invalidImage),
        ),
      );
    });
  });

  test('imports files without the network and reports them', () async {
    final picked = Directory(p.join(root.path, 'picked'))..createSync();
    File write(String name, List<int> bytes) =>
        File(p.join(picked.path, name))..writeAsBytesSync(bytes);
    final changes = <void>[];
    final subscription = service.ocrLanguagesChanged.listen(changes.add);
    addTearDown(subscription.cancel);

    final report = await service.importOcrFiles([
      write('deu.traineddata', deuBytes).path,
      write('eng.traineddata', [1, 2, 3]).path,
      write('photo.jpg', [1]).path,
    ]);
    expect(
      report,
      const OcrImportReport(
        installed: ['deu'],
        damaged: ['eng'],
        unmatchedFiles: ['photo.jpg'],
      ),
    );
    final again = await service.importOcrFiles([
      p.join(picked.path, 'deu.traineddata'),
    ]);
    expect(again.alreadyInstalled, ['deu']);
    expect(requests, isEmpty);
    await pumpEventQueue();
    expect(changes, hasLength(1));
  });

  test('retries opening after a failure', () async {
    var attempts = 0;
    final flaky = TesseractTextRecognitionService(
      open: () async {
        if (attempts++ == 0) throw StateError('no assets');
        return TesseractOcr(catalog: catalog, root: root, engine: engine);
      },
      isSupported: true,
      isMeteredConnection: () async => false,
    );
    await expectLater(flaky.ocrLanguages(), throwsStateError);
    expect(await flaky.ocrLanguages(), hasLength(3));
  });
}
