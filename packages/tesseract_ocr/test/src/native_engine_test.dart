// Tests against the real native library (tool/build_native_linux.sh) and
// tessdata_fast's eng.traineddata; skipped when either is missing (see the
// README, "Building and testing").
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tesseract_ocr/src/engine/ffi/bindings.dart';
import 'package:tesseract_ocr/src/engine/ffi/isolate_engine.dart';
import 'package:tesseract_ocr/src/engine/ffi/native_engine.dart';
import 'package:tesseract_ocr/tesseract_ocr.dart';

import '../helpers/native_library.dart';

void main() {
  final fixture = readPgm('opening_hours.pgm');

  group('IsolateTesseractEngine', () {
    test('reports a library that cannot be loaded, and retries', () async {
      final engine = IsolateTesseractEngine(
        libraryPath: '/nonexistent/libmozhi_tesseract.so',
      );
      for (var i = 0; i < 2; i++) {
        await expectLater(
          engine.recognize(
            OcrImage(Uint8List(4), width: 1, height: 1),
            dataPath: '/nonexistent',
            languages: const ['eng'],
          ),
          throwsA(
            isA<TesseractEngineException>().having(
              (e) => e.message,
              'message',
              contains('Cannot load the native engine'),
            ),
          ),
        );
      }
      await engine.release();
      await engine.dispose();
    });

    test('release and dispose before the first call do nothing', () async {
      final engine = IsolateTesseractEngine();
      await engine.release();
      await engine.dispose();
    });

    test('reads English text, in gray and in RGBA', () async {
      final engine = IsolateTesseractEngine(libraryPath: nativeLibraryPath());
      addTearDown(engine.dispose);
      final dataPath = englishTessdataPath()!;
      final gray = await engine.recognize(
        OcrImage(
          fixture.pixels,
          width: fixture.width,
          height: fixture.height,
          bytesPerPixel: 1,
        ),
        dataPath: dataPath,
        languages: const ['eng'],
      );
      expect(gray.text, 'Opening hours\nMonday to Friday');
      expect(gray.meanConfidence, greaterThan(80));

      final rgba = await engine.recognize(
        OcrImage(
          grayToRgba(fixture.pixels),
          width: fixture.width,
          height: fixture.height,
        ),
        dataPath: dataPath,
        languages: const ['eng'],
      );
      expect(rgba.text, gray.text);

      // Released engines load again on the next call.
      await engine.release();
      final again = await engine.recognize(
        OcrImage(
          fixture.pixels,
          width: fixture.width,
          height: fixture.height,
          bytesPerPixel: 1,
        ),
        dataPath: dataPath,
        languages: const ['eng'],
      );
      expect(again, gray);
    }, skip: realEngineSkip());

    test('reports missing language data and keeps working', () async {
      final engine = IsolateTesseractEngine(libraryPath: nativeLibraryPath());
      addTearDown(engine.dispose);
      final empty = Directory.systemTemp.createTempSync('tessdata_empty_');
      addTearDown(() => empty.deleteSync(recursive: true));
      await expectLater(
        engine.recognize(
          OcrImage(Uint8List(4), width: 1, height: 1),
          dataPath: empty.path,
          languages: const ['deu'],
        ),
        throwsA(
          isA<TesseractEngineException>().having(
            (e) => e.message,
            'message',
            allOf(contains('load deu'), contains('no language data')),
          ),
        ),
      );
    }, skip: nativeLibrarySkip());

    test('a stopped engine starts again', () async {
      final engine = IsolateTesseractEngine(libraryPath: nativeLibraryPath());
      final image = OcrImage(
        fixture.pixels,
        width: fixture.width,
        height: fixture.height,
        bytesPerPixel: 1,
      );
      final dataPath = englishTessdataPath()!;
      await engine.recognize(
        image,
        dataPath: dataPath,
        languages: const ['eng'],
      );
      await engine.dispose();
      final result = await engine.recognize(
        image,
        dataPath: dataPath,
        languages: const ['eng'],
      );
      expect(result.text, contains('Monday'));
      await engine.dispose();
    }, skip: realEngineSkip());
  });

  group('NativeTesseractEngine', () {
    test('rejects a library with another ABI', () {
      expect(
        () => NativeTesseractEngine.open(libraryPath: '/nonexistent.so'),
        throwsA(isA<TesseractEngineException>()),
      );
    });

    test('reports its version and keeps at most maxLoaded engines', () {
      final engine = NativeTesseractEngine.open(
        libraryPath: nativeLibraryPath(),
        maxLoaded: 1,
      );
      addTearDown(engine.release);
      expect(engine.version, 'tesseract 5.5.3, leptonica-1.87.0');
      final dataPath = englishTessdataPath()!;
      final blank = Uint8List(64 * 32)..fillRange(0, 64 * 32, 255);
      final result = engine.recognize(
        blank,
        width: 64,
        height: 32,
        bytesPerPixel: 1,
        bytesPerLine: 64,
        dataPath: dataPath,
        languages: const ['eng'],
      );
      expect(result.text, isEmpty);
      expect(engine.loaded, ['$dataPath|eng']);
      // A second language set replaces the first (maxLoaded: 1).
      engine.recognize(
        blank,
        width: 64,
        height: 32,
        bytesPerPixel: 1,
        bytesPerLine: 64,
        dataPath: dataPath,
        languages: const ['eng', 'eng'],
      );
      expect(engine.loaded, ['$dataPath|eng+eng']);
      expect(
        () => engine.recognize(
          blank,
          width: 64,
          height: 32,
          bytesPerPixel: 1,
          bytesPerLine: 64,
          dataPath: dataPath,
          languages: const [],
        ),
        throwsArgumentError,
      );
      engine.release();
      expect(engine.loaded, isEmpty);
    }, skip: realEngineSkip());
  });

  group('C API', () {
    late TesseractBindings bindings;

    setUp(() {
      if (nativeLibraryPath() == null) return;
      bindings = TesseractBindings(TesseractBindings.open(nativeLibraryPath()));
    });

    String? lastError() {
      final error = bindings.lastError();
      return error == nullptr ? null : error.toDartString();
    }

    test('validates its arguments', () {
      expect(bindings.abiVersion(), TesseractBindings.expectedAbiVersion);
      using((arena) {
        Pointer<Utf8> utf8(String value) =>
            value.toNativeUtf8(allocator: arena);
        final dataPath = englishTessdataPath() ?? '/nonexistent';
        for (final languages in [
          '',
          '../eng',
          'eng+',
          'ENG',
          'chi_simplified',
        ]) {
          expect(
            bindings.create(utf8(dataPath), utf8(languages)),
            nullptr,
            reason: languages,
          );
          expect(lastError(), isNotNull, reason: languages);
        }
        expect(
          bindings.create(
            utf8(dataPath),
            utf8(List.filled(9, 'eng').join('+')),
          ),
          nullptr,
        );
        expect(lastError(), contains('more than 8'));
        expect(bindings.create(nullptr, utf8('eng')), nullptr);
        expect(lastError(), contains('required'));

        final pixels = arena<Uint8>(16);
        final confidence = arena<Int32>();
        expect(
          bindings.recognize(nullptr, pixels, 2, 2, 4, 8, confidence),
          nullptr,
        );
        expect(lastError(), contains('required'));
        bindings.destroy(nullptr);
        bindings.freeString(nullptr);
        expect(lastError(), isNull);
      });
    }, skip: nativeLibrarySkip());

    test('rejects invalid images and recognises a valid one', () {
      using((arena) {
        final engine = bindings.create(
          englishTessdataPath()!.toNativeUtf8(allocator: arena),
          'eng'.toNativeUtf8(allocator: arena),
        );
        expect(engine, isNot(nullptr));
        final pixels = arena<Uint8>(fixture.pixels.length)
          ..asTypedList(fixture.pixels.length).setAll(0, fixture.pixels);
        final confidence = arena<Int32>();
        for (final (width, height, bpp, bpl, error) in [
          (0, 10, 1, 10, 'invalid image size'),
          (20000, 10, 1, 20000, 'invalid image size'),
          (10, 10, 2, 20, 'bytes_per_pixel'),
          (10, 10, 4, 39, 'shorter than a row'),
        ]) {
          expect(
            bindings.recognize(
              engine,
              pixels,
              width,
              height,
              bpp,
              bpl,
              confidence,
            ),
            nullptr,
          );
          expect(lastError(), contains(error));
        }
        final rgb = arena<Uint8>(fixture.pixels.length * 3);
        final view = rgb.asTypedList(fixture.pixels.length * 3);
        for (var i = 0; i < fixture.pixels.length; i++) {
          view.fillRange(i * 3, i * 3 + 3, fixture.pixels[i]);
        }
        final text = bindings.recognize(
          engine,
          rgb,
          fixture.width,
          fixture.height,
          3,
          fixture.width * 3,
          confidence,
        );
        expect(text, isNot(nullptr));
        expect(text.toDartString(), contains('Opening hours'));
        expect(confidence.value, greaterThan(80));
        expect(lastError(), isNull);
        bindings
          ..freeString(text)
          ..destroy(engine);
      });
    }, skip: realEngineSkip());
  });

  test('TesseractOcr reads text with installed data end to end', () async {
    final root = Directory.systemTemp.createTempSync('tesseract_e2e_');
    addTearDown(() => root.deleteSync(recursive: true));
    final catalog = TessdataCatalog.parse(
      File('assets/catalog.json').readAsStringSync(),
    );
    final ocr = TesseractOcr(
      catalog: catalog,
      root: root,
      engine: IsolateTesseractEngine(libraryPath: nativeLibraryPath()),
    );
    addTearDown(ocr.dispose);
    final imported = await ocr.importFiles([
      File(p.join(englishTessdataPath()!, 'eng.traineddata')),
    ]);
    expect(imported.installed, [catalog.byCode('eng')]);
    final result = await ocr.recognize(
      grayToRgba(fixture.pixels),
      fixture.width,
      fixture.height,
      languages: const ['eng'],
    );
    expect(result.text, 'Opening hours\nMonday to Friday');
  }, skip: realEngineSkip());
}
