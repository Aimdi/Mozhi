import 'dart:async';
import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/image_translate/image_translate.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

void main() {
  setUpAll(registerImageTranslateFallbacks);

  late ImageTranslateHarness harness;
  late AppLocalizations l10n;

  setUp(() {
    harness = ImageTranslateHarness();
    l10n = lookupAppLocalizations(const Locale('en'));
  });

  const working = ImageTranslateState(
    status: ImageTranslateStatus.working,
    methods: [mozhiMethod, claudeMethod],
    method: mozhiMethod,
    target: french,
  );

  ImageTranslateState successState({
    ImageTranslation result = const ImageTranslation(
      sourceText: 'Hola',
      translatedText: 'Bonjour',
    ),
    ImageTranslateMethod method = mozhiMethod,
  }) => ImageTranslateState(
    status: ImageTranslateStatus.success,
    image: jpegImage,
    methods: const [mozhiMethod, claudeMethod, onDeviceMethod],
    method: method,
    source: japanese,
    target: german,
    result: result,
  );

  group('labels', () {
    test('describe every image error', () {
      for (final kind in ImageTranslateErrorKind.values) {
        final info = describeImageTranslateError(
          l10n,
          ImageTranslateException(kind),
        );
        expect(info.message, isNotEmpty, reason: kind.name);
      }
      expect(
        describeImageTranslateError(
          l10n,
          const ImageTranslateException(ImageTranslateErrorKind.timeout),
        ).message,
        l10n.imageTranslateErrorTimeout,
      );
      expect(
        describeImageTranslateError(l10n, StateError('x')).message,
        l10n.translateErrorGeneric,
      );
    });

    test('describe each phase', () {
      String message(ImageTranslatePhase phase, ImageTranslateMethod method) =>
          imagePhaseMessage(
            l10n,
            working.copyWith(phase: phase, method: () => method),
          );
      expect(
        message(ImageTranslatePhase.preparing, mozhiMethod),
        l10n.imageTranslatePhasePreparing,
      );
      expect(
        message(ImageTranslatePhase.uploading, mozhiMethod),
        l10n.imageTranslatePhaseMozhi,
      );
      expect(
        message(ImageTranslatePhase.uploading, claudeMethod),
        l10n.imageTranslatePhaseAi('Claude'),
      );
      expect(
        message(ImageTranslatePhase.recognizing, onDeviceMethod),
        l10n.imageTranslatePhaseRecognizing,
      );
      expect(
        message(ImageTranslatePhase.translatingText, onDeviceMethod),
        l10n.imageTranslatePhaseTranslatingText,
      );
    });

    test('name methods and languages', () {
      expect(
        imageMethodLabel(l10n, onDeviceMethod),
        'On-device text recognition',
      );
      expect(
        imageMethodDescription(l10n, ImageTranslateMethodKind.onDevice),
        l10n.imageTranslateMethodOnDeviceDescription,
      );
      expect(imageLanguageLabel(l10n, Language.auto), 'Detect language');
      expect(imageLanguageLabel(l10n, french), 'French');
      expect(imageLanguageNameFor('fr', languages), 'French');
      expect(imageLanguageNameFor('es', languages), 'Spanish');
      expect(imageLanguageNameFor('xx-unknown', languages), 'xx-unknown');
    });
  });

  group('ImageTranslateProgress', () {
    testWidgets('shows the phase, the slow note and cancels', (tester) async {
      final cubit = mockImageCubit(
        working.copyWith(phase: ImageTranslatePhase.uploading, slow: true),
      );
      await harness.pumpWithCubit(
        tester,
        cubit,
        child: const ImageTranslateProgress(),
      );
      expect(find.text(l10n.imageTranslatePhaseMozhi), findsOneWidget);
      expect(find.byKey(const Key('image_translate_slow')), findsOneWidget);
      await tester.tap(find.byKey(const Key('image_translate_cancel_button')));
      verify(cubit.cancel).called(1);
    });
  });

  group('ImageTranslatePreview', () {
    testWidgets('renders nothing without an image', (tester) async {
      await harness.pumpWithCubit(
        tester,
        mockImageCubit(working),
        child: const ImageTranslatePreview(),
      );
      expect(find.byType(InteractiveViewer), findsNothing);
    });

    testWidgets('shows the original when requested', (tester) async {
      final cubit = mockImageCubit(
        successState(result: ImageTranslation(translatedImage: pngBytes))
            .copyWith(showOriginal: true),
      );
      await harness.pumpWithCubit(
        tester,
        cubit,
        child: const ImageTranslatePreview(),
      );
      expect(find.bySemanticsLabel('Selected image'), findsOneWidget);
      await tester.tap(find.text('Translated'));
      verify(() => cubit.setShowOriginal(showOriginal: false)).called(1);
    });

    testWidgets('shows a placeholder for undecodable images', (tester) async {
      final cubit = mockImageCubit(
        const ImageTranslateState(status: ImageTranslateStatus.ready)
            .copyWith(image: () => jpegImage),
      );
      await harness.pumpWithCubit(
        tester,
        cubit,
        child: const ImageTranslatePreview(),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump();
      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    });
  });

  group('ImageTranslateResultSection', () {
    Future<MockImageTranslateCubit> pump(
      WidgetTester tester,
      ImageTranslateState state,
    ) async {
      final cubit = mockImageCubit(state);
      await harness.pumpWithCubit(
        tester,
        cubit,
        child: const ImageTranslateResultSection(),
      );
      return cubit;
    }

    testWidgets('renders nothing without a result', (tester) async {
      await pump(tester, working);
      expect(find.byType(Card), findsNothing);
    });

    testWidgets('streams without actions', (tester) async {
      await pump(
        tester,
        working.copyWith(
          image: () => pngImage,
          method: () => onDeviceMethod,
          result: () => const ImageTranslation(
            sourceText: 'Hola',
            translatedText: 'Bon',
            isComplete: false,
          ),
        ),
      );
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('Bon'), findsOneWidget);
      expect(
        find.byKey(const Key('image_translate_copy_button')),
        findsNothing,
      );
      final retranslate = tester.widget<FilledButton>(
        find.byKey(const Key('image_translate_retranslate_button')),
      );
      expect(retranslate.onPressed, isNull);
    });

    testWidgets('copies the translation', (tester) async {
      final clipboard = FakeClipboard(tester);
      await pump(tester, successState());
      await tester.tap(find.byKey(const Key('image_translate_copy_button')));
      await tester.pump();
      expect(clipboard.copied, 'Bonjour');
      expect(find.text(l10n.commonCopied), findsOneWidget);
    });

    testWidgets('shares the translation', (tester) async {
      const channel = MethodChannel('dev.fluttercommunity.plus/share');
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return 'dev.fluttercommunity.plus/share/success';
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await pump(tester, successState());
      await tester.tap(find.byKey(const Key('image_translate_share_button')));
      await tester.pump();
      expect(calls.single.method, 'share');
      final arguments = calls.single.arguments as Map;
      expect(arguments['text'], 'Bonjour');
      expect(arguments.containsKey('paths'), isFalse);
    });

    testWidgets('shares a translated image', (tester) async {
      final temp = Directory.systemTemp.createTempSync('image_translate');
      addTearDown(() => temp.deleteSync(recursive: true));
      const share = MethodChannel('dev.fluttercommunity.plus/share');
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      final calls = <MethodCall>[];
      final messenger = tester.binding.defaultBinaryMessenger
        ..setMockMethodCallHandler(share, (call) async {
          calls.add(call);
          return 'dev.fluttercommunity.plus/share/success';
        })
        ..setMockMethodCallHandler(paths, (call) async => temp.path);
      addTearDown(() {
        messenger
          ..setMockMethodCallHandler(share, null)
          ..setMockMethodCallHandler(paths, null);
      });
      await pump(
        tester,
        successState(result: ImageTranslation(translatedImage: pngBytes)),
      );
      expect(
        find.byKey(const Key('image_translate_copy_button')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('image_translate_open_button')),
        findsNothing,
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('image_translate_share_button')));
        for (var i = 0; i < 20 && calls.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      });
      final arguments = calls.single.arguments as Map;
      expect(arguments.containsKey('text'), isFalse);
      expect(arguments['paths'], hasLength(1));
      expect(arguments['mimeTypes'], ['image/png']);
    });

    testWidgets('opens the source text in the translator', (tester) async {
      await pump(tester, successState());
      await tester.tap(find.byKey(const Key('image_translate_open_button')));
      verify(() => harness.translate.setSource(japanese)).called(1);
      verify(() => harness.translate.setTarget(german)).called(1);
      verify(() => harness.translate.setInputAndTranslate('Hola')).called(1);
      verify(() => harness.router.go('/translate')).called(1);
    });

    testWidgets('keeps matching translator languages', (tester) async {
      harness = ImageTranslateHarness(
        translate: translateState(source: japanese, target: german),
      );
      await pump(tester, successState());
      await tester.tap(find.byKey(const Key('image_translate_open_button')));
      verifyNever(() => harness.translate.setSource(any()));
      verifyNever(() => harness.translate.setTarget(any()));
      verify(() => harness.translate.setInputAndTranslate('Hola')).called(1);
    });

    testWidgets('editable text follows new recognitions', (tester) async {
      final first = successState(
        method: onDeviceMethod,
        result: const ImageTranslation(
          sourceText: 'Hola',
          translatedText: 'Hi',
        ),
      );
      final controller = StreamController<ImageTranslateState>();
      addTearDown(controller.close);
      final cubit = mockImageCubit(first);
      whenListen(cubit, controller.stream, initialState: first);
      await harness.pumpWithCubit(
        tester,
        cubit,
        child: const ImageTranslateResultSection(),
      );
      final field = find.byKey(const Key('image_translate_source_field'));
      expect(tester.widget<TextField>(field).controller!.text, 'Hola');

      controller.add(
        first.copyWith(
          result: () => const ImageTranslation(
            sourceText: 'Adiós',
            translatedText: 'Bye',
          ),
        ),
      );
      await tester.pump();
      expect(tester.widget<TextField>(field).controller!.text, 'Adiós');

      await tester.enterText(field, 'Adiós amigo');
      await tester.tap(
        find.byKey(const Key('image_translate_retranslate_button')),
      );
      verify(() => cubit.translateText('Adiós amigo')).called(1);
    });
  });

  group('ImageTranslateErrorView', () {
    testWidgets('links to AI providers for provider errors', (tester) async {
      var retried = 0;
      await harness.pump(
        tester,
        Scaffold(
          body: ImageTranslateErrorView(
            error: const LlmApiException('denied', statusCode: 401),
            onRetry: () => retried++,
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('image_translate_retry_button')));
      expect(retried, 1);
      await tester.tap(find.text(l10n.translateProvidersAction));
      verify(() => harness.router.go('/settings/providers')).called(1);
    });

    testWidgets('links to instances for unreachable instances', (tester) async {
      await harness.pump(
        tester,
        const Scaffold(
          body: ImageTranslateErrorView(error: MozhiApiException('offline')),
        ),
      );
      expect(
        find.byKey(const Key('image_translate_retry_button')),
        findsNothing,
      );
      await tester.tap(find.text(l10n.translateManageInstances));
      verify(() => harness.router.go('/settings/instances')).called(1);
    });

    testWidgets('shows image errors without a shortcut', (tester) async {
      await harness.pump(
        tester,
        const Scaffold(
          body: ImageTranslateErrorView(
            error: ImageTranslateException(ImageTranslateErrorKind.noText),
          ),
        ),
      );
      expect(find.text(l10n.imageTranslateErrorNoText), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
    });
  });

  group('ImageLanguageBar', () {
    testWidgets('shows the detected source language', (tester) async {
      await harness.pumpWithCubit(
        tester,
        mockImageCubit(
          successState(
            result: const ImageTranslation(
              translatedText: 'Hi',
              detectedSource: 'ja',
            ),
          ).copyWith(source: Language.auto),
        ),
        child: const ImageLanguageBar(),
      );
      expect(find.text('Detected: Japanese'), findsOneWidget);
    });

    testWidgets('falls back to the catalogue', (tester) async {
      harness = ImageTranslateHarness(
        translate: const TranslateState(sourceLanguages: [Language.auto]),
      );
      final cubit = mockImageCubit(working);
      await harness.pumpWithCubit(
        tester,
        cubit,
        child: const ImageLanguageBar(),
      );
      await tester.tap(find.byKey(const Key('image_translate_target_button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('image_language_search')),
        'zzz',
      );
      await tester.pump();
      expect(find.text(l10n.imageTranslateNoLanguages), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('image_language_search')),
        'es',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('image_language_es')));
      await tester.pumpAndSettle();
      verify(() => cubit.setTarget(LanguageCatalog.byCode('es')!)).called(1);

      await tester.tap(find.byKey(const Key('image_translate_source_button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('image_language_auto')), findsOneWidget);
      // Dismissing the picker changes nothing.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      verifyNever(() => cubit.setSource(any()));
    });
  });

  group('ImageMethodSelector', () {
    testWidgets('is hidden without methods', (tester) async {
      await harness.pumpWithCubit(
        tester,
        mockImageCubit(const ImageTranslateState()),
        child: const ImageMethodSelector(),
      );
      expect(find.byType(ChoiceChip), findsNothing);
    });
  });

  group('ImageTranslateButton', () {
    testWidgets('pushes the image page', (tester) async {
      await harness.pump(tester, const Scaffold(body: ImageTranslateButton()));
      expect(find.byTooltip(l10n.imageTranslateButtonTooltip), findsOneWidget);
      await tester.tap(find.byType(IconButton));
      verify(() => harness.router.push<Object?>('/translate/image')).called(1);
    });

    testWidgets('can open the camera right away', (tester) async {
      await harness.pump(
        tester,
        const Scaffold(
          body: ImageTranslateButton(source: ImagePickSource.camera),
        ),
      );
      await tester.tap(find.byType(IconButton));
      verify(
        () => harness.router.push<Object?>('/translate/image?source=camera'),
      ).called(1);
    });

    testWidgets('uses a custom callback', (tester) async {
      var pressed = 0;
      await harness.pump(
        tester,
        Scaffold(body: ImageTranslateButton(onPressed: () => pressed++)),
      );
      await tester.tap(find.byType(IconButton));
      expect(pressed, 1);
      verifyNever(() => harness.router.push<Object?>(any()));
    });
  });
}
