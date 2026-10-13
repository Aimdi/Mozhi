import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/image_translate/image_translate.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

void main() {
  group('ImageTranslateState', () {
    test('has sensible defaults', () {
      const state = ImageTranslateState();
      expect(state.status, ImageTranslateStatus.initial);
      expect(state.source, Language.auto);
      expect(state.target.code, 'en');
      expect(state.hasImage, isFalse);
      expect(state.isWorking, isFalse);
      expect(state.canTranslate, isFalse);
      expect(state.canEditSourceText, isFalse);
    });

    test('canTranslate needs an image, a method and no running request', () {
      final state = ImageTranslateState(image: jpegImage, method: mozhiMethod);
      expect(state.canTranslate, isTrue);
      expect(
        state.copyWith(status: ImageTranslateStatus.working).canTranslate,
        isFalse,
      );
      expect(state.copyWith(method: () => null).canTranslate, isFalse);
    });

    test('recognised text is editable for on-device recognition', () {
      const state = ImageTranslateState(
        method: onDeviceMethod,
        result: ImageTranslation(sourceText: 'Hola'),
      );
      expect(state.canEditSourceText, isTrue);
      expect(
        state.copyWith(method: () => mozhiMethod).canEditSourceText,
        isFalse,
      );
      expect(
        state
            .copyWith(result: () => const ImageTranslation())
            .canEditSourceText,
        isFalse,
      );
    });

    test('copyWith replaces every field', () {
      const error = ImageTranslateException(ImageTranslateErrorKind.noText);
      final state = const ImageTranslateState().copyWith(
        status: ImageTranslateStatus.failure,
        phase: ImageTranslatePhase.recognizing,
        slow: true,
        image: () => pngImage,
        methods: const [onDeviceMethod],
        method: () => onDeviceMethod,
        source: japanese,
        target: german,
        translateEngine: () => deepl,
        options: const TranslationOptions(context: 'Menu'),
        canUseCamera: true,
        result: () => const ImageTranslation(sourceText: 'a'),
        error: () => error,
        pickError: () => error,
        showOriginal: true,
      );
      expect(state.status, ImageTranslateStatus.failure);
      expect(state.phase, ImageTranslatePhase.recognizing);
      expect(state.slow, isTrue);
      expect(state.image, same(pngImage));
      expect(state.methods, const [onDeviceMethod]);
      expect(state.method, onDeviceMethod);
      expect(state.source, japanese);
      expect(state.target, german);
      expect(state.translateEngine, deepl);
      expect(state.options, const TranslationOptions(context: 'Menu'));
      expect(state.canUseCamera, isTrue);
      expect(state.result, const ImageTranslation(sourceText: 'a'));
      expect(state.error, error);
      expect(state.pickError, error);
      expect(state.showOriginal, isTrue);
      expect(state.copyWith(), state);
      expect(state.props, hasLength(15));
    });
  });
}
