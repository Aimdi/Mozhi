// Play variant only: tool/play_prepare.sh copies this test to
// test/image_translate/data/ with the ML Kit text recognition service.
import 'dart:io';

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
}
