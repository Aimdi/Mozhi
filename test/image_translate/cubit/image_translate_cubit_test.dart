import 'dart:async';
import 'dart:typed_data';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/image_translate/image_translate.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

void main() {
  late MockTranslationRepository repository;
  late FakeImagePickerService picker;
  late FakeImageEncoder encoder;
  late FakeTextRecognitionService recognizer;

  final translatedPng = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 7]);
  const methods = [mozhiMethod, claudeMethod, onDeviceMethod];
  const base = ImageTranslateState(
    methods: methods,
    method: mozhiMethod,
    translateEngine: deepl,
    target: french,
    canUseCamera: true,
  );

  setUpAll(registerImageTranslateFallbacks);

  setUp(() {
    repository = MockTranslationRepository();
    picker = FakeImagePickerService();
    encoder = FakeImageEncoder();
    recognizer = FakeTextRecognitionService(text: ' Hola ');
  });

  ImageTranslateCubit build({
    List<TranslationEngine> engines = allEngines,
    List<AiProviderConfig> providers = allProviders,
    TranslationEngine? translateEngine = deepl,
    Language source = Language.auto,
    Language target = french,
    TranslationOptions options = const TranslationOptions(),
    Duration slowThreshold = const Duration(minutes: 1),
  }) => ImageTranslateCubit(
    repository: repository,
    picker: picker,
    encoder: encoder,
    recognizer: recognizer,
    engines: engines,
    providers: providers,
    translateEngine: translateEngine,
    source: source,
    target: target,
    options: options,
    slowThreshold: slowThreshold,
  );

  void stubImage(Future<ImageTranslationResult> Function() answer) => when(
    () => repository.translateImage(
      any(),
      any(),
      mimeType: any(named: 'mimeType'),
      source: any(named: 'source'),
      target: any(named: 'target'),
      options: any(named: 'options'),
    ),
  ).thenAnswer((_) => answer());

  void stubText(Stream<TranslationResult> Function() answer) =>
      when(() => repository.translate(any(), any()))
          .thenAnswer((_) => answer());

  TranslationResult text(
    String value, {
    bool complete = true,
    String? detected,
  }) => TranslationResult(
    engineId: deepl.id,
    engineName: deepl.name,
    text: value,
    isComplete: complete,
    detectedSource: detected,
  );

  ImageTranslationResult lensResult() => ImageTranslationResult(
    translatedImage: translatedPng,
    sourceText: ' Hola ',
    translatedText: ' Hello ',
  );

  group('initial state', () {
    test('lists methods and prefers Mozhi', () {
      expect(build().state, base);
    });

    test("prefers the translator's vision engine", () {
      final state = build(translateEngine: claude).state;
      expect(state.method, claudeMethod);
      expect(state.translateEngine, claude);
    });

    test('never starts from a custom source', () {
      expect(
        build(source: const Language.custom('Pirate')).state.source,
        Language.auto,
      );
    });

    test('reflects platform support', () {
      picker.supportsCamera = false;
      recognizer.isSupported = false;
      final state = build(engines: const [deepl], providers: const []).state;
      expect(state.canUseCamera, isFalse);
      expect(state.methods, isEmpty);
      expect(state.method, isNull);
    });
  });

  group('updateContext', () {
    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'keeps the selected method when still available',
      build: build,
      seed: () => base.copyWith(method: () => claudeMethod),
      act: (cubit) => cubit.updateContext(
        engines: const [claude],
        providers: allProviders,
        translateEngine: claude,
        options: const TranslationOptions(context: 'Menu'),
      ),
      expect: () => [
        base.copyWith(
          methods: [claudeMethod, onDeviceMethod],
          method: () => claudeMethod,
          translateEngine: () => claude,
          options: const TranslationOptions(context: 'Menu'),
        ),
      ],
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'falls back to the preferred method',
      build: build,
      act: (cubit) => cubit.updateContext(
        engines: const [deepl, claude],
        providers: allProviders,
      ),
      expect: () => [
        base.copyWith(
          methods: [claudeMethod],
          method: () => claudeMethod,
          translateEngine: () => null,
        ),
      ],
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'clears the method when nothing is available',
      build: build,
      act: (cubit) =>
          cubit.updateContext(engines: const [], providers: const []),
      expect: () => [
        base.copyWith(
          methods: const [],
          method: () => null,
          translateEngine: () => null,
        ),
      ],
    );
  });

  group('pickImage', () {
    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'translates the picked image with Mozhi (Google Lens)',
      setUp: () {
        picker.image = jpegImage;
        stubImage(() async => lensResult());
      },
      build: build,
      act: (cubit) => cubit.pickImage(ImagePickSource.gallery),
      expect: () {
        final ready = base.copyWith(
          status: ImageTranslateStatus.ready,
          image: () => jpegImage,
        );
        return [
          ready,
          ready.copyWith(status: ImageTranslateStatus.working),
          ready.copyWith(
            status: ImageTranslateStatus.working,
            phase: ImageTranslatePhase.uploading,
          ),
          ready.copyWith(
            status: ImageTranslateStatus.success,
            phase: ImageTranslatePhase.uploading,
            result: () => ImageTranslation(
              translatedImage: translatedPng,
              sourceText: 'Hola',
              translatedText: 'Hello',
            ),
          ),
        ];
      },
      verify: (_) {
        expect(picker.picks, [ImagePickSource.gallery]);
        expect(encoder.inputs, [jpegBytes]);
        verify(
          () => repository.translateImage(
            google,
            encodedPng,
            mimeType: 'image/png',
            source: Language.auto,
            target: french,
          ),
        ).called(1);
      },
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'does nothing when dismissed',
      build: build,
      act: (cubit) => cubit.pickImage(ImagePickSource.camera),
      expect: () => const <ImageTranslateState>[],
      verify: (_) => expect(picker.picks, [ImagePickSource.camera]),
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'ignores the camera when unsupported',
      setUp: () => picker.supportsCamera = false,
      build: build,
      act: (cubit) => cubit.pickImage(ImagePickSource.camera),
      expect: () => const <ImageTranslateState>[],
      verify: (_) => expect(picker.picks, isEmpty),
    );

    const denied = ImageTranslateException(
      ImageTranslateErrorKind.permissionDenied,
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'reports picker failures',
      setUp: () => picker.error = denied,
      build: build,
      act: (cubit) => cubit.pickImage(ImagePickSource.camera),
      expect: () => [base.copyWith(pickError: () => denied)],
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'clears the previous picker failure',
      build: build,
      seed: () => base.copyWith(pickError: () => denied),
      act: (cubit) => cubit.pickImage(ImagePickSource.gallery),
      expect: () => [base],
    );
  });

  group('Mozhi (Google Lens)', () {
    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'copies list results and keeps text-only results',
      setUp: () => stubImage(
        () async => const ImageTranslationResult(
          translatedImage: [1, 2, 3],
          notes: ' note ',
        ),
      ),
      build: build,
      act: (cubit) => cubit.setImage(jpegImage),
      verify: (cubit) {
        final result = cubit.state.result!;
        expect(cubit.state.status, ImageTranslateStatus.success);
        expect(result.translatedImage, Uint8List.fromList([1, 2, 3]));
        expect(result.notes, 'note');
      },
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'accepts text without an image',
      setUp: () => stubImage(
        () async => const ImageTranslationResult(
          translatedImage: [],
          translatedText: 'Hello',
        ),
      ),
      build: build,
      act: (cubit) => cubit.setImage(jpegImage),
      verify: (cubit) {
        expect(cubit.state.status, ImageTranslateStatus.success);
        expect(cubit.state.result!.hasImage, isFalse);
        expect(cubit.state.result!.translatedText, 'Hello');
      },
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'fails when nothing was translated',
      setUp: () => stubImage(() async => const ImageTranslationResult()),
      build: build,
      act: (cubit) => cubit.setImage(jpegImage),
      verify: (cubit) {
        expect(cubit.state.status, ImageTranslateStatus.failure);
        expect(
          cubit.state.error,
          const ImageTranslateException(ImageTranslateErrorKind.noText),
        );
        expect(cubit.state.result, isNull);
      },
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'maps HTTP 413 to "too large"',
      setUp: () => stubImage(
        () async => throw const MozhiApiException('big', statusCode: 413),
      ),
      build: build,
      act: (cubit) => cubit.setImage(jpegImage),
      verify: (cubit) => expect(
        cubit.state.error,
        const ImageTranslateException(ImageTranslateErrorKind.tooLarge),
      ),
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'reports undecodable images',
      setUp: () => encoder.error = const ImageTranslateException(
        ImageTranslateErrorKind.invalidImage,
      ),
      build: build,
      act: (cubit) => cubit.setImage(jpegImage),
      expect: () {
        final ready = base.copyWith(
          status: ImageTranslateStatus.ready,
          image: () => jpegImage,
        );
        return [
          ready,
          ready.copyWith(status: ImageTranslateStatus.working),
          ready.copyWith(
            status: ImageTranslateStatus.failure,
            error: () => const ImageTranslateException(
              ImageTranslateErrorKind.invalidImage,
            ),
          ),
        ];
      },
      verify: (_) => verifyNever(
        () => repository.translateImage(
          any(),
          any(),
          mimeType: any(named: 'mimeType'),
          source: any(named: 'source'),
          target: any(named: 'target'),
          options: any(named: 'options'),
        ),
      ),
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'flags slow requests',
      setUp: () {
        final pending = Completer<ImageTranslationResult>();
        stubImage(() => pending.future);
      },
      build: () => build(slowThreshold: const Duration(milliseconds: 10)),
      act: (cubit) => unawaited(cubit.setImage(jpegImage)),
      wait: const Duration(milliseconds: 60),
      verify: (cubit) {
        expect(cubit.state.isWorking, isTrue);
        expect(cubit.state.slow, isTrue);
      },
    );
  });

  group('AI vision', () {
    blocTest<ImageTranslateCubit, ImageTranslateState>(
      're-encodes the image (dropping EXIF metadata) and sends the options',
      setUp: () => stubImage(
        () async => const ImageTranslationResult(
          translatedText: ' Hello ',
          notes: ' A street sign ',
        ),
      ),
      build: () => build(
        translateEngine: claude,
        options: const TranslationOptions(context: 'Menu'),
      ),
      act: (cubit) => cubit.setImage(jpegImage),
      expect: () {
        final ready = base.copyWith(
          status: ImageTranslateStatus.ready,
          image: () => jpegImage,
          method: () => claudeMethod,
          translateEngine: () => claude,
          options: const TranslationOptions(context: 'Menu'),
        );
        return [
          ready,
          ready.copyWith(status: ImageTranslateStatus.working),
          ready.copyWith(
            status: ImageTranslateStatus.working,
            phase: ImageTranslatePhase.uploading,
          ),
          ready.copyWith(
            status: ImageTranslateStatus.success,
            phase: ImageTranslatePhase.uploading,
            result: () => const ImageTranslation(
              translatedText: 'Hello',
              notes: 'A street sign',
            ),
          ),
        ];
      },
      verify: (_) {
        expect(encoder.inputs, [jpegBytes]);
        verify(
          () => repository.translateImage(
            claude,
            encodedPng,
            mimeType: 'image/png',
            source: Language.auto,
            target: french,
            options: const TranslationOptions(context: 'Menu'),
          ),
        ).called(1);
      },
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'converts formats vision APIs do not accept',
      setUp: () => stubImage(
        () async => const ImageTranslationResult(translatedText: 'Hello'),
      ),
      build: () => build(translateEngine: claude),
      act: (cubit) => cubit.setImage(heicImage),
      verify: (cubit) {
        expect(cubit.state.status, ImageTranslateStatus.success);
        expect(encoder.inputs, [heicBytes]);
        verify(
          () => repository.translateImage(
            claude,
            encodedPng,
            mimeType: 'image/png',
            source: any(named: 'source'),
            target: any(named: 'target'),
            options: any(named: 'options'),
          ),
        ).called(1);
      },
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'fails on an empty translation',
      setUp: () => stubImage(
        () async => const ImageTranslationResult(translatedText: '  '),
      ),
      build: () => build(translateEngine: claude),
      act: (cubit) => cubit.setImage(pngImage),
      verify: (cubit) => expect(
        cubit.state.error,
        const ImageTranslateException(ImageTranslateErrorKind.noText),
      ),
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'reports provider errors as they are',
      setUp: () => stubImage(
        () async => throw const LlmApiException('nope', statusCode: 401),
      ),
      build: () => build(translateEngine: claude),
      act: (cubit) => cubit.setImage(pngImage),
      verify: (cubit) => expect(cubit.state.error, isA<LlmApiException>()),
    );
  });

  group('on-device recognition', () {
    final ready = base.copyWith(
      status: ImageTranslateStatus.ready,
      image: () => pngImage,
      method: () => onDeviceMethod,
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'recognises and streams the translation',
      setUp: () => stubText(
        () => Stream.fromIterable([
          text('Hel', complete: false),
          text('Hello', detected: 'es'),
        ]),
      ),
      build: build,
      seed: () => ready,
      act: (cubit) => cubit.translate(),
      expect: () {
        final working = ready.copyWith(
          status: ImageTranslateStatus.working,
          phase: ImageTranslatePhase.recognizing,
        );
        final translating = working.copyWith(
          phase: ImageTranslatePhase.translatingText,
          result: () =>
              const ImageTranslation(sourceText: 'Hola', isComplete: false),
        );
        return [
          working,
          translating,
          translating.copyWith(
            result: () => const ImageTranslation(
              sourceText: 'Hola',
              translatedText: 'Hel',
              isComplete: false,
            ),
          ),
          translating.copyWith(
            result: () => const ImageTranslation(
              sourceText: 'Hola',
              translatedText: 'Hello',
              detectedSource: 'es',
              isComplete: false,
            ),
          ),
          translating.copyWith(
            status: ImageTranslateStatus.success,
            result: () => const ImageTranslation(
              sourceText: 'Hola',
              translatedText: 'Hello',
              detectedSource: 'es',
            ),
          ),
        ];
      },
      verify: (_) {
        expect(recognizer.sources, [Language.auto]);
        verify(
          () => repository.translate(
            deepl,
            const TranslationRequest(
              text: 'Hola',
              source: Language.auto,
              target: french,
            ),
          ),
        ).called(1);
      },
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'fails when no text is found',
      setUp: () => recognizer.text = ' ',
      build: build,
      seed: () => ready,
      act: (cubit) => cubit.translate(),
      verify: (cubit) {
        expect(
          cubit.state.error,
          const ImageTranslateException(ImageTranslateErrorKind.noText),
        );
        verifyNever(() => repository.translate(any(), any()));
      },
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'keeps the recognised text when the translation fails',
      setUp: () => stubText(
        () => Stream.error(const MozhiApiException('down', statusCode: 500)),
      ),
      build: build,
      seed: () => ready,
      act: (cubit) => cubit.translate(),
      verify: (cubit) {
        expect(cubit.state.status, ImageTranslateStatus.failure);
        expect(cubit.state.error, isA<MozhiApiException>());
        expect(cubit.state.result, const ImageTranslation(sourceText: 'Hola'));
        expect(cubit.state.canEditSourceText, isTrue);
      },
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'maps custom languages Mozhi cannot handle',
      setUp: () =>
          stubText(() => Stream.error(ArgumentError.value('Pirate', 'target'))),
      build: build,
      seed: () => ready,
      act: (cubit) => cubit.translate(),
      verify: (cubit) => expect(
        cubit.state.error,
        const ImageTranslateException(
          ImageTranslateErrorKind.unsupportedLanguage,
        ),
      ),
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'translateText translates edited text without recognising again',
      setUp: () => stubText(() => Stream.value(text('Good morning'))),
      build: build,
      seed: () => ready.copyWith(
        status: ImageTranslateStatus.success,
        result: () =>
            const ImageTranslation(sourceText: 'Hola', translatedText: 'Hi'),
      ),
      act: (cubit) => cubit.translateText(' Buenos días '),
      expect: () {
        final translating = ready.copyWith(
          status: ImageTranslateStatus.working,
          phase: ImageTranslatePhase.translatingText,
          result: () =>
              const ImageTranslation(sourceText: 'Hola', translatedText: 'Hi'),
        );
        return [
          translating,
          translating.copyWith(
            result: () => const ImageTranslation(
              sourceText: 'Buenos días',
              isComplete: false,
            ),
          ),
          translating.copyWith(
            result: () => const ImageTranslation(
              sourceText: 'Buenos días',
              translatedText: 'Good morning',
              isComplete: false,
            ),
          ),
          translating.copyWith(
            status: ImageTranslateStatus.success,
            result: () => const ImageTranslation(
              sourceText: 'Buenos días',
              translatedText: 'Good morning',
            ),
          ),
        ];
      },
      verify: (_) => expect(recognizer.sources, isEmpty),
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'translateText needs an image',
      build: build,
      act: (cubit) => cubit.translateText('Hola'),
      expect: () => const <ImageTranslateState>[],
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'translateText ignores empty text',
      build: build,
      seed: () => ready,
      act: (cubit) => cubit.translateText('  '),
      expect: () => const <ImageTranslateState>[],
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'translateText fails without a translate engine',
      build: build,
      seed: () => ready.copyWith(translateEngine: () => null),
      act: (cubit) => cubit.translateText('Hola'),
      verify: (cubit) {
        expect(
          cubit.state.error,
          const ImageTranslateException(ImageTranslateErrorKind.noEngine),
        );
        expect(cubit.state.result, const ImageTranslation(sourceText: 'Hola'));
      },
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'a new target only re-translates the recognised text',
      setUp: () => stubText(() => Stream.value(text('Hallo'))),
      build: build,
      seed: () => ready.copyWith(
        status: ImageTranslateStatus.success,
        result: () =>
            const ImageTranslation(sourceText: 'Hola', translatedText: 'Hi'),
      ),
      act: (cubit) => cubit.setTarget(german),
      verify: (cubit) {
        expect(cubit.state.target, german);
        expect(cubit.state.result?.translatedText, 'Hallo');
        expect(recognizer.sources, isEmpty);
      },
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'cancel keeps the recognised text',
      setUp: () => stubText(() => const Stream<TranslationResult>.empty()),
      build: build,
      seed: () => ready,
      act: (cubit) async {
        final controller = StreamController<TranslationResult>();
        stubText(() => controller.stream);
        unawaited(cubit.translate());
        await Future<void>.delayed(Duration.zero);
        controller.add(text('Hel', complete: false));
        await Future<void>.delayed(Duration.zero);
        cubit.cancel();
        controller.add(text('Hello'));
        await controller.close();
      },
      verify: (cubit) {
        expect(cubit.state.status, ImageTranslateStatus.ready);
        expect(cubit.state.result, const ImageTranslation(sourceText: 'Hola'));
      },
    );
  });

  group('options', () {
    final success = base.copyWith(
      status: ImageTranslateStatus.success,
      image: () => jpegImage,
      result: () => const ImageTranslation(translatedText: 'Hello'),
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'selectMethod re-runs with the new method',
      setUp: () => stubImage(
        () async => const ImageTranslationResult(translatedText: 'Hi'),
      ),
      build: build,
      seed: () => success,
      act: (cubit) => cubit.selectMethod(claudeMethod),
      expect: () {
        final ready = success.copyWith(
          status: ImageTranslateStatus.ready,
          method: () => claudeMethod,
          result: () => null,
        );
        return [
          ready,
          ready.copyWith(status: ImageTranslateStatus.working),
          ready.copyWith(
            status: ImageTranslateStatus.working,
            phase: ImageTranslatePhase.uploading,
          ),
          ready.copyWith(
            status: ImageTranslateStatus.success,
            phase: ImageTranslatePhase.uploading,
            result: () => const ImageTranslation(translatedText: 'Hi'),
          ),
        ];
      },
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'selectMethod without an image only selects',
      build: build,
      act: (cubit) => cubit.selectMethod(onDeviceMethod),
      expect: () => [base.copyWith(method: () => onDeviceMethod)],
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'selectMethod ignores the current and unknown methods',
      build: build,
      act: (cubit) async {
        await cubit.selectMethod(mozhiMethod);
        await cubit.selectMethod(const ImageTranslateMethod.aiVision(ollama));
      },
      expect: () => const <ImageTranslateState>[],
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'setTarget re-runs the translation',
      setUp: () => stubImage(
        () async => const ImageTranslationResult(translatedText: 'Hallo'),
      ),
      build: build,
      seed: () => success,
      act: (cubit) => cubit.setTarget(german),
      verify: (cubit) {
        expect(cubit.state.target, german);
        expect(cubit.state.result?.translatedText, 'Hallo');
        verify(
          () => repository.translateImage(
            google,
            any(),
            mimeType: any(named: 'mimeType'),
            source: Language.auto,
            target: german,
          ),
        ).called(1);
      },
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'setTarget ignores auto and the current target',
      build: build,
      act: (cubit) async {
        await cubit.setTarget(Language.auto);
        await cubit.setTarget(french);
      },
      expect: () => const <ImageTranslateState>[],
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'setTarget without an image only updates the language',
      build: build,
      act: (cubit) => cubit.setTarget(german),
      expect: () => [base.copyWith(target: german)],
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'setSource re-runs the translation',
      setUp: () => stubImage(
        () async => const ImageTranslationResult(translatedText: 'Hello'),
      ),
      build: build,
      seed: () => success,
      act: (cubit) => cubit.setSource(japanese),
      verify: (cubit) {
        expect(cubit.state.source, japanese);
        verify(
          () => repository.translateImage(
            google,
            any(),
            mimeType: any(named: 'mimeType'),
            source: japanese,
            target: french,
          ),
        ).called(1);
      },
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'setSource ignores custom and current languages',
      build: build,
      act: (cubit) async {
        await cubit.setSource(const Language.custom('Pirate'));
        await cubit.setSource(Language.auto);
      },
      expect: () => const <ImageTranslateState>[],
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'setShowOriginal toggles the image',
      build: build,
      act: (cubit) => cubit
        ..setShowOriginal(showOriginal: true)
        ..setShowOriginal(showOriginal: false),
      expect: () => [base.copyWith(showOriginal: true), base],
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'clearImage returns to the empty state',
      build: build,
      seed: () => success.copyWith(showOriginal: true),
      act: (cubit) => cubit.clearImage(),
      expect: () => [base],
    );
  });

  group('cancel', () {
    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'drops the in-flight request',
      build: build,
      act: (cubit) async {
        final pending = Completer<ImageTranslationResult>();
        stubImage(() => pending.future);
        unawaited(cubit.setImage(jpegImage));
        await Future<void>.delayed(Duration.zero);
        cubit.cancel();
        pending.complete(lensResult());
        await Future<void>.delayed(Duration.zero);
      },
      expect: () {
        final ready = base.copyWith(
          status: ImageTranslateStatus.ready,
          image: () => jpegImage,
        );
        return [
          ready,
          ready.copyWith(status: ImageTranslateStatus.working),
          ready.copyWith(
            status: ImageTranslateStatus.working,
            phase: ImageTranslatePhase.uploading,
          ),
          ready.copyWith(phase: ImageTranslatePhase.uploading),
        ];
      },
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'drops a stale encoder result',
      build: build,
      act: (cubit) async {
        unawaited(cubit.setImage(jpegImage));
        cubit.cancel();
        await Future<void>.delayed(Duration.zero);
      },
      verify: (cubit) {
        expect(cubit.state.status, ImageTranslateStatus.ready);
        verifyNever(
          () => repository.translateImage(
            any(),
            any(),
            mimeType: any(named: 'mimeType'),
            source: any(named: 'source'),
            target: any(named: 'target'),
            options: any(named: 'options'),
          ),
        );
      },
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'drops stale vision results, conversions and recognitions',
      build: () => build(translateEngine: claude),
      act: (cubit) async {
        final pending = Completer<ImageTranslationResult>();
        stubImage(() => pending.future);
        unawaited(cubit.setImage(pngImage));
        await Future<void>.delayed(Duration.zero);
        cubit.cancel();
        pending.complete(const ImageTranslationResult(translatedText: 'late'));
        await Future<void>.delayed(Duration.zero);

        unawaited(cubit.setImage(heicImage));
        cubit.cancel();
        await Future<void>.delayed(Duration.zero);

        recognizer.gate = Completer<void>();
        unawaited(cubit.selectMethod(onDeviceMethod));
        await Future<void>.delayed(Duration.zero);
        cubit.cancel();
        recognizer.gate!.complete();
        await Future<void>.delayed(Duration.zero);
      },
      verify: (cubit) {
        expect(cubit.state.status, ImageTranslateStatus.ready);
        expect(cubit.state.result, isNull);
        verifyNever(() => repository.translate(any(), any()));
      },
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'is a no-op when idle',
      build: build,
      act: (cubit) => cubit.cancel(),
      expect: () => const <ImageTranslateState>[],
    );

    test('closing during a request emits nothing more', () async {
      final pending = Completer<ImageTranslationResult>();
      stubImage(() => pending.future);
      final cubit = build(slowThreshold: Duration.zero);
      unawaited(cubit.setImage(jpegImage));
      await Future<void>.delayed(Duration.zero);
      await cubit.close();
      pending.complete(lensResult());
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(cubit.state.isWorking, isTrue);
    });
  });

  group('translate', () {
    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'needs an image',
      build: build,
      act: (cubit) => cubit.translate(),
      expect: () => const <ImageTranslateState>[],
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'needs a method',
      build: build,
      seed: () => base.copyWith(image: () => jpegImage, method: () => null),
      act: (cubit) => cubit.translate(),
      expect: () => const <ImageTranslateState>[],
    );
  });

  group('mapError', () {
    Object map(Object error, [ImageTranslateMethodKind? method]) =>
        ImageTranslateCubit.mapError(error, method: method);

    ImageTranslateException kind(ImageTranslateErrorKind kind) =>
        ImageTranslateException(kind);

    test('maps upload and server errors', () {
      expect(
        map(const LlmApiException('big', statusCode: 413)),
        kind(ImageTranslateErrorKind.tooLarge),
      );
      for (final status in [400, 415, 422]) {
        expect(
          map(MozhiApiException('bad', statusCode: status)),
          kind(ImageTranslateErrorKind.unsupported),
        );
      }
      expect(
        map(const MozhiApiException('gateway', statusCode: 504)),
        kind(ImageTranslateErrorKind.timeout),
      );
      expect(
        map(TimeoutException('slow')),
        kind(ImageTranslateErrorKind.timeout),
      );
      expect(
        map(ArgumentError.value('x', 'source')),
        kind(ImageTranslateErrorKind.unsupportedLanguage),
      );
    });

    test('maps Mozhi client timeouts for Google Lens only', () {
      const timeout = MozhiApiException('No response within 30000 ms');
      expect(
        map(timeout, ImageTranslateMethodKind.mozhiLens),
        kind(ImageTranslateErrorKind.timeout),
      );
      expect(map(timeout, ImageTranslateMethodKind.onDevice), same(timeout));
      const offline = MozhiApiException('Connection refused');
      expect(map(offline, ImageTranslateMethodKind.mozhiLens), same(offline));
    });

    test('passes other errors through', () {
      final error = ArgumentError.value('x', 'engine');
      expect(map(error), same(error));
      const exception = ImageTranslateException(ImageTranslateErrorKind.noText);
      expect(map(exception), same(exception));
    });
  });
}
