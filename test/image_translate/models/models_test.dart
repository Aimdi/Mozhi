import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

void main() {
  group('ImagePickSource.tryParse', () {
    test('parses known values', () {
      expect(ImagePickSource.tryParse('gallery'), ImagePickSource.gallery);
      expect(ImagePickSource.tryParse('camera'), ImagePickSource.camera);
    });

    test('returns null for unknown values', () {
      expect(ImagePickSource.tryParse(null), isNull);
      expect(ImagePickSource.tryParse('scanner'), isNull);
    });
  });

  group('detectImageMimeType', () {
    Uint8List bytes(List<int> values) => Uint8List.fromList(values);

    test('sniffs common signatures', () {
      expect(detectImageMimeType(pngBytes), 'image/png');
      expect(detectImageMimeType(jpegBytes), 'image/jpeg');
      expect(detectImageMimeType(bytes('GIF89a'.codeUnits)), 'image/gif');
      expect(
        detectImageMimeType(
          bytes([...'RIFF'.codeUnits, 0, 0, 0, 0, ...'WEBP'.codeUnits]),
        ),
        'image/webp',
      );
      expect(detectImageMimeType(bytes([0x42, 0x4D, 0, 0])), 'image/bmp');
      expect(detectImageMimeType(heicBytes), 'image/heic');
      expect(
        detectImageMimeType(bytes([0, 0, 0, 0, ...'ftypavif'.codeUnits])),
        'image/avif',
      );
      expect(
        detectImageMimeType(bytes([0, 0, 0, 0, ...'ftyp'.codeUnits])),
        'image/heic',
      );
    });

    test('falls back to the reported type', () {
      expect(
        detectImageMimeType(bytes([1, 2]), reported: ' Image/WebP '),
        'image/webp',
      );
      expect(
        detectImageMimeType(bytes([1, 2]), reported: 'application/pdf'),
        'image/jpeg',
      );
    });

    test('falls back to the extension, then JPEG', () {
      String byName(String name) => detectImageMimeType(bytes([1]), name: name);
      expect(byName('a.PNG'), 'image/png');
      expect(byName('a.gif'), 'image/gif');
      expect(byName('a.webp'), 'image/webp');
      expect(byName('a.bmp'), 'image/bmp');
      expect(byName('a.heif'), 'image/heic');
      expect(byName('a.heic'), 'image/heic');
      expect(byName('a.avif'), 'image/avif');
      expect(byName('a.jpeg'), 'image/jpeg');
      expect(byName('noextension'), 'image/jpeg');
      expect(detectImageMimeType(Uint8List(0)), 'image/jpeg');
    });
  });

  group('PickedImage', () {
    test('toString describes the image', () {
      expect(jpegImage.toString(), contains('photo.jpg'));
      expect(jpegImage.toString(), contains('image/jpeg'));
    });
  });

  group('ImageTranslateMethod', () {
    test('ids and flags', () {
      expect(mozhiMethod.id, 'mozhiLens:mozhi:google');
      expect(claudeMethod.id, 'aiVision:ai:claude');
      expect(onDeviceMethod.id, 'onDevice');
      expect(mozhiMethod.rendersImage, isTrue);
      expect(claudeMethod.rendersImage, isFalse);
      expect(onDeviceMethod.engine, isNull);
      expect(
        claudeMethod.toString(),
        'ImageTranslateMethod(aiVision:ai:claude)',
      );
    });

    test('supports value equality', () {
      expect(
        const ImageTranslateMethod.aiVision(claude),
        const ImageTranslateMethod.aiVision(claude),
      );
      expect(
        const ImageTranslateMethod.aiVision(claude),
        isNot(const ImageTranslateMethod.aiVision(ollama)),
      );
    });

    group('available', () {
      test('lists on-device recognition, vision engines, then Mozhi', () {
        expect(
          ImageTranslateMethod.available(
            engines: allEngines,
            providers: allProviders,
            onDeviceSupported: true,
            translateEngine: deepl,
          ),
          [onDeviceMethod, claudeMethod, mozhiMethod],
        );
      });

      test('orders the kinds the same way (recommended first)', () {
        expect(ImageTranslateMethodKind.values, [
          ImageTranslateMethodKind.onDevice,
          ImageTranslateMethodKind.aiVision,
          ImageTranslateMethodKind.mozhiLens,
        ]);
      });

      test('requires mozhi:google for Mozhi', () {
        expect(
          ImageTranslateMethod.available(
            engines: const [deepl],
            providers: allProviders,
            onDeviceSupported: false,
          ),
          isEmpty,
        );
      });

      test('requires a translate engine for on-device recognition', () {
        expect(
          ImageTranslateMethod.available(
            engines: const [],
            providers: const [],
            onDeviceSupported: true,
          ),
          isEmpty,
        );
      });

      test('matches providers by id when providerId is missing', () {
        const legacy = TranslationEngine(
          id: 'ai:claude',
          kind: EngineKind.ai,
          name: 'Claude',
        );
        const bare = TranslationEngine(
          id: 'claude',
          kind: EngineKind.ai,
          name: 'Claude',
        );
        expect(
          ImageTranslateMethod.available(
            engines: const [legacy, bare],
            providers: allProviders,
            onDeviceSupported: false,
          ),
          const [
            ImageTranslateMethod.aiVision(legacy),
            ImageTranslateMethod.aiVision(bare),
          ],
        );
      });
    });

    group('preferred', () {
      const methods = [onDeviceMethod, claudeMethod, mozhiMethod];

      test('prefers on-device recognition (the photo stays here)', () {
        expect(
          ImageTranslateMethod.preferred(methods, translateEngine: claude),
          onDeviceMethod,
        );
      });

      test('then the vision method of the translate engine', () {
        expect(
          ImageTranslateMethod.preferred(const [
            mozhiMethod,
            claudeMethod,
          ], translateEngine: claude),
          claudeMethod,
        );
      });

      test('then another vision method, before Mozhi', () {
        expect(
          ImageTranslateMethod.preferred(const [
            mozhiMethod,
            claudeMethod,
          ], translateEngine: deepl),
          claudeMethod,
        );
      });

      test('then Mozhi', () {
        expect(
          ImageTranslateMethod.preferred(const [mozhiMethod]),
          mozhiMethod,
        );
      });

      test('then the first method', () {
        expect(
          ImageTranslateMethod.preferred(const [claudeMethod]),
          claudeMethod,
        );
        expect(ImageTranslateMethod.preferred(const []), isNull);
      });

      test('only on-device recognition keeps the photo here', () {
        expect(onDeviceMethod.uploadsImage, isFalse);
        expect(mozhiMethod.uploadsImage, isTrue);
        expect(claudeMethod.uploadsImage, isTrue);
      });
    });
  });

  group('ImageTranslateMethod.withId', () {
    test('finds a method by its id', () {
      const methods = [onDeviceMethod, claudeMethod, mozhiMethod];
      expect(
        ImageTranslateMethod.withId(methods, 'aiVision:ai:claude'),
        claudeMethod,
      );
      expect(ImageTranslateMethod.withId(methods, 'onDevice'), onDeviceMethod);
      expect(ImageTranslateMethod.withId(methods, 'aiVision:ai:x'), isNull);
      expect(ImageTranslateMethod.withId(methods, null), isNull);
    });
  });

  group('ImageTranslation', () {
    test('keeps and compares the recognition confidence', () {
      const read = ImageTranslation(
        sourceText: 'Hola',
        recognitionConfidence: 42,
      );
      expect(read, isNot(const ImageTranslation(sourceText: 'Hola')));
      expect(read.copyWith(translatedText: 'Hi').recognitionConfidence, 42);
      expect(
        read.hashCode,
        isNot(const ImageTranslation(sourceText: 'Hola').hashCode),
      );
    });

    test('compares destinations', () {
      const sent = ImageTranslation(
        translatedText: 'a',
        destination: OnDeviceDestination(),
      );
      expect(sent, isNot(const ImageTranslation(translatedText: 'a')));
      expect(
        const ImageTranslation(translatedText: 'a')
            .copyWith(destination: const OnDeviceDestination()),
        sent,
      );
      expect(sent.hashCode, isNot(const ImageTranslation().hashCode));
    });

    test('compares images by identity', () {
      final image = Uint8List.fromList([1, 2]);
      expect(
        ImageTranslation(translatedImage: image, translatedText: 'a'),
        ImageTranslation(translatedImage: image, translatedText: 'a'),
      );
      expect(
        ImageTranslation(translatedImage: image).hashCode,
        ImageTranslation(translatedImage: image).hashCode,
      );
      expect(
        ImageTranslation(translatedImage: image),
        isNot(ImageTranslation(translatedImage: Uint8List.fromList([1, 2]))),
      );
    });

    test('copyWith keeps unchanged fields', () {
      final image = Uint8List.fromList([1]);
      final translation = ImageTranslation(
        translatedImage: image,
        sourceText: 'Hola',
        translatedText: 'Hi',
        notes: 'A sign',
        detectedSource: 'es',
        isComplete: false,
      );
      final copy = translation.copyWith();
      expect(copy, translation);
      final changed = translation.copyWith(
        sourceText: 'Adiós',
        translatedText: 'Bye',
        detectedSource: 'ca',
        isComplete: true,
      );
      expect(changed.translatedImage, same(image));
      expect(changed.notes, 'A sign');
      expect(changed.sourceText, 'Adiós');
      expect(changed.translatedText, 'Bye');
      expect(changed.detectedSource, 'ca');
      expect(changed.isComplete, isTrue);
      expect(changed.hasImage, isTrue);
      expect(const ImageTranslation().hasImage, isFalse);
      expect(changed.toString(), contains('Bye'));
    });
  });

  group('ImageTranslateException', () {
    test('compares by kind', () {
      expect(
        const ImageTranslateException(
          ImageTranslateErrorKind.noText,
          cause: 'a',
        ),
        const ImageTranslateException(ImageTranslateErrorKind.noText),
      );
      expect(
        const ImageTranslateException(ImageTranslateErrorKind.noText).hashCode,
        ImageTranslateErrorKind.noText.hashCode,
      );
    });

    test('toString includes the cause', () {
      expect(
        const ImageTranslateException(ImageTranslateErrorKind.timeout)
            .toString(),
        'ImageTranslateException(timeout)',
      );
      expect(
        const ImageTranslateException(
          ImageTranslateErrorKind.timeout,
          cause: 'slow',
        ).toString(),
        'ImageTranslateException(timeout: slow)',
      );
    });
  });
}
