// Play variant only: tool/play_prepare.sh copies this test to
// test/image_translate/data/ with the ML Kit text recognition service.
import 'dart:io';
import 'dart:math' show Point;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/image_translate/data/mlkit_text_recognition_service.dart';
import 'package:mozhi/image_translate/image_translate.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

class MockTextRecognizer extends Mock implements TextRecognizer;

class _FakeDecoder implements RgbaImageDecoder {
  new(this.image);

  final RgbaImage? image;

  @override
  Future<RgbaImage> decode(
    Uint8List bytes, {
    int maxSide = defaultOcrMaxSide,
  }) async {
    final result = image;
    if (result == null) {
      throw const ImageTranslateException(ImageTranslateErrorKind.invalidImage);
    }
    return result;
  }
}

/// Builds a [width] x [height] RGBA buffer filled with [bg], painting [fg]
/// inside [textRect].
RgbaImage _sampleRgba({
  required int width,
  required int height,
  required Color bg,
  Rect? textRect,
  Color? fg,
}) {
  final pixels = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final useFg =
          textRect != null &&
          fg != null &&
          x >= textRect.left &&
          x < textRect.right &&
          y >= textRect.top &&
          y < textRect.bottom;
      final c = useFg ? fg : bg;
      final o = (y * width + x) * 4;
      pixels[o] = (c.r * 255).round();
      pixels[o + 1] = (c.g * 255).round();
      pixels[o + 2] = (c.b * 255).round();
      pixels[o + 3] = 255;
    }
  }
  return RgbaImage(pixels: pixels, width: width, height: height);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => registerFallbackValue(InputImage.fromFilePath('/x')));

  group('scriptFor', () {
    TextRecognitionScript script(String code) =>
        MlKitTextRecognitionService.scriptFor(Language(code: code, name: code));

    test('maps scripts by primary subtag', () {
      expect(script('zh-CN'), TextRecognitionScript.chinese);
      expect(script('zh_TW'), TextRecognitionScript.chinese);
      expect(script('yue'), TextRecognitionScript.chinese);
      expect(script('ja'), TextRecognitionScript.japanese);
      expect(script('KO'), TextRecognitionScript.korean);
      for (final code in ['hi', 'mr', 'ne', 'sa', 'mai', 'bho', 'kok']) {
        expect(script(code), TextRecognitionScript.devanagiri, reason: code);
      }
      expect(script('en'), TextRecognitionScript.latin);
      expect(script('ru'), TextRecognitionScript.latin);
      expect(
        MlKitTextRecognitionService.scriptFor(Language.auto),
        TextRecognitionScript.latin,
      );
    });
  });

  group('isSupported', () {
    test('only on Android and iOS', () {
      for (final platform in TargetPlatform.values) {
        expect(
          MlKitTextRecognitionService(
            platform: platform,
            isWeb: false,
          ).isSupported,
          platform == TargetPlatform.android || platform == TargetPlatform.iOS,
          reason: platform.name,
        );
      }
    });

    test('never on web', () {
      expect(
        MlKitTextRecognitionService(
          platform: TargetPlatform.android,
          isWeb: true,
        ).isSupported,
        isFalse,
      );
    });

    test('defaults to the current platform', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      expect(MlKitTextRecognitionService(isWeb: false).isSupported, isTrue);
    });
  });

  group('recognize', () {
    late MockTextRecognizer recognizer;
    late List<TextRecognitionScript> scripts;
    late MlKitTextRecognitionService service;

    setUp(() {
      recognizer = MockTextRecognizer();
      scripts = [];
      service = MlKitTextRecognitionService(
        platform: TargetPlatform.android,
        isWeb: false,
        recognizerFactory: (script) {
          scripts.add(script);
          return recognizer;
        },
      );
      when(() => recognizer.close()).thenAnswer((_) async {});
    });

    test('returns the trimmed text and closes the recognizer', () async {
      when(() => recognizer.processImage(any())).thenAnswer(
        (_) async => RecognizedText(text: '  こんにちは \n', blocks: const []),
      );
      expect(await service.recognize(pngImage, source: japanese), 'こんにちは');
      expect(scripts, [TextRecognitionScript.japanese]);
      final input =
          verify(() => recognizer.processImage(captureAny())).captured.single
              as InputImage;
      expect(input.filePath, '/tmp/shot.png');
      verify(() => recognizer.close()).called(1);
    });

    test('maps failures and still closes', () async {
      when(() => recognizer.processImage(any()))
          .thenThrow(PlatformException(code: 'failed'));
      when(() => recognizer.close()).thenThrow(StateError('closed'));
      await expectLater(
        service.recognize(pngImage, source: english),
        throwsA(
          const ImageTranslateException(
            ImageTranslateErrorKind.recognitionFailed,
          ),
        ),
      );
      verify(() => recognizer.close()).called(1);
    });

    test('reads an image without a file path from a temporary copy and '
        'deletes it', () async {
      final directory = Directory.systemTemp.createTempSync('mlkit_test');
      addTearDown(() => directory.deleteSync(recursive: true));
      final written = <Uint8List>[];
      service = MlKitTextRecognitionService(
        platform: TargetPlatform.android,
        isWeb: false,
        recognizerFactory: (script) {
          scripts.add(script);
          return recognizer;
        },
        temporaryImageWriter: (bytes) async {
          written.add(bytes);
          final file = File('${directory.path}/still.img')
            ..writeAsBytesSync(bytes);
          return file.path;
        },
      );
      when(
        () => recognizer.processImage(any()),
      ).thenAnswer((_) async => RecognizedText(text: 'Exit', blocks: const []));
      final image = PickedImage(bytes: pngBytes, mimeType: 'image/png');

      expect(await service.recognize(image, source: english), 'Exit');

      expect(written, [pngBytes]);
      final input =
          verify(() => recognizer.processImage(captureAny())).captured.single
              as InputImage;
      expect(input.filePath, '${directory.path}/still.img');
      expect(File('${directory.path}/still.img').existsSync(), isFalse);
    });

    test('deletes the temporary copy when reading fails', () async {
      final directory = Directory.systemTemp.createTempSync('mlkit_test');
      addTearDown(() => directory.deleteSync(recursive: true));
      service = MlKitTextRecognitionService(
        platform: TargetPlatform.android,
        isWeb: false,
        recognizerFactory: (_) => recognizer,
        temporaryImageWriter: (bytes) async {
          final file = File('${directory.path}/still.img')
            ..writeAsBytesSync(bytes);
          return file.path;
        },
      );
      when(() => recognizer.processImage(any()))
          .thenThrow(PlatformException(code: 'failed'));

      await expectLater(
        service.recognize(
          PickedImage(bytes: pngBytes, mimeType: 'image/png'),
          source: english,
        ),
        throwsA(isA<ImageTranslateException>()),
      );
      expect(File('${directory.path}/still.img').existsSync(), isFalse);
    });

    test('fails when the temporary copy cannot be written', () async {
      service = MlKitTextRecognitionService(
        platform: TargetPlatform.android,
        isWeb: false,
        recognizerFactory: (script) {
          scripts.add(script);
          return recognizer;
        },
        temporaryImageWriter: (_) async =>
            throw const FileSystemException('full'),
      );
      await expectLater(
        service.recognize(
          PickedImage(bytes: pngBytes, mimeType: 'image/png'),
          source: english,
        ),
        throwsA(
          const ImageTranslateException(
            ImageTranslateErrorKind.recognitionFailed,
          ),
        ),
      );
      expect(scripts, isEmpty);
    });

    test('fails on unsupported platforms', () async {
      service = MlKitTextRecognitionService(
        platform: TargetPlatform.linux,
        isWeb: false,
      );
      await expectLater(
        service.recognize(pngImage, source: english),
        throwsA(isA<ImageTranslateException>()),
      );
    });

    test('uses ML Kit by default', () async {
      const channel = MethodChannel('google_mlkit_text_recognizer');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'vision#startTextRecognizer') {
              return {'text': 'Hello', 'blocks': <Object>[]};
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      service = MlKitTextRecognitionService(
        platform: TargetPlatform.android,
        isWeb: false,
      );
      expect(await service.recognize(pngImage, source: german), 'Hello');
      expect(calls.map((call) => call.method), [
        'vision#startTextRecognizer',
        'vision#closeTextRecognizer',
      ]);
      expect(
        (calls.first.arguments as Map)['script'],
        TextRecognitionScript.latin.index,
      );
    });
  });

  group('recognizeLayout', () {
    late MockTextRecognizer recognizer;

    setUp(() {
      recognizer = MockTextRecognizer();
      when(() => recognizer.close()).thenAnswer((_) async {});
    });

    TextLine line(
      String text,
      Rect box, {
      double? confidence = 0.9,
      double? angle = 0,
    }) => TextLine(
      text: text,
      elements: const [],
      boundingBox: box,
      recognizedLanguages: const [],
      cornerPoints: const [],
      confidence: confidence,
      angle: angle,
    );

    test('builds TextLayout with joined lines, tilt angle, alignment and '
        'sampled colours', () async {
      const yellow = Color(0xFFFFDC00);
      const navy = Color(0xFF001480);
      final sample = _sampleRgba(
        width: 200,
        height: 100,
        bg: yellow,
        textRect: const Rect.fromLTWH(25, 25, 110, 30),
        fg: navy,
      );
      final service = MlKitTextRecognitionService(
        platform: TargetPlatform.android,
        isWeb: false,
        recognizerFactory: (_) => recognizer,
        decoder: _FakeDecoder(sample),
      );
      when(() => recognizer.processImage(any())).thenAnswer(
        (_) async => RecognizedText(
          text: 'Open\nhours\n---\nمرحبا',
          blocks: [
            TextBlock(
              text: 'Open\nhours',
              boundingBox: const Rect.fromLTWH(20, 20, 120, 40),
              recognizedLanguages: const ['en'],
              cornerPoints: const [
                Point(20, 20),
                Point(140, 20),
                Point(140, 60),
                Point(20, 60),
              ],
              lines: [
                line(
                  'Open',
                  const Rect.fromLTWH(20, 20, 70, 18),
                  confidence: 0.92,
                  angle: 12,
                ),
                line(
                  'hours',
                  const Rect.fromLTWH(20, 40, 90, 18),
                  confidence: 0.88,
                  angle: 14,
                ),
              ],
            ),
            // Punctuation-only speck block is filtered out.
            TextBlock(
              text: '---',
              boundingBox: const Rect.fromLTWH(5, 5, 10, 5),
              recognizedLanguages: const [],
              cornerPoints: const [],
              lines: [line('---', const Rect.fromLTWH(5, 5, 10, 5))],
            ),
            // RTL block with corner-point tilt fallback (iOS null angle).
            TextBlock(
              text: 'مرحبا',
              boundingBox: const Rect.fromLTWH(20, 70, 100, 20),
              recognizedLanguages: const ['ar'],
              cornerPoints: const [
                Point(20, 70),
                Point(120, 90),
                Point(120, 100),
                Point(20, 80),
              ],
              lines: [
                line(
                  'مرحبا',
                  const Rect.fromLTWH(20, 70, 100, 20),
                  confidence: null,
                  angle: null,
                ),
              ],
            ),
          ],
        ),
      );

      final result = await service.recognizeLayout(pngImage, source: english);

      expect(result.confidence, 90);
      expect(result.text, 'Open hours\n\nمرحبا');
      final layout = result.layout!;
      expect((layout.width, layout.height), (200, 100));
      expect(layout.paragraphs, hasLength(2));

      final first = layout.paragraphs[0];
      expect(first.text, 'Open hours');
      expect(first.lineCount, 2);
      expect(first.alignment, TextParagraphAlignment.left);
      expect(first.isRightToLeft, isFalse);
      expect(first.angle, 13);
      expect(first.confidence, 90);
      expect(first.background, yellow);
      expect(first.foreground, navy);

      final second = layout.paragraphs[1];
      expect(second.text, 'مرحبا');
      expect(second.isRightToLeft, isTrue);
      expect(second.angle, closeTo(11.31, 0.05));
    });

    test('falls back to plain text when image decoding fails', () async {
      final service = MlKitTextRecognitionService(
        platform: TargetPlatform.android,
        isWeb: false,
        recognizerFactory: (_) => recognizer,
        decoder: _FakeDecoder(null),
      );
      when(() => recognizer.processImage(any())).thenAnswer(
        (_) async => RecognizedText(
          text: '  Exit  ',
          blocks: [
            TextBlock(
              text: 'Exit',
              boundingBox: const Rect.fromLTWH(0, 0, 40, 20),
              recognizedLanguages: const [],
              cornerPoints: const [],
              lines: [line('Exit', const Rect.fromLTWH(0, 0, 40, 20))],
            ),
          ],
        ),
      );

      final result = await service.recognizeLayout(pngImage, source: english);
      expect(result.text, 'Exit');
      expect(result.layout, isNull);
      expect(result.confidence, 90);
    });
  });
}
