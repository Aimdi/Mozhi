import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/image_translate/image_translate.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/usage/usage.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

/// Taps Translate: methods that upload the image wait for it.
Future<void> translateNow(WidgetTester tester) async {
  final button = find.byKey(const Key('image_translate_translate_button'));
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(registerImageTranslateFallbacks);

  late ImageTranslateHarness harness;

  setUp(() => harness = ImageTranslateHarness());

  void stubImage(Future<ImageTranslationResult> Function() answer) => when(
    () => harness.repository.translateImage(
      any(),
      any(),
      mimeType: any(named: 'mimeType'),
      source: any(named: 'source'),
      target: any(named: 'target'),
      options: any(named: 'options'),
    ),
  ).thenAnswer((_) => answer());

  ImageTranslationResult lensResult({String notes = ''}) =>
      ImageTranslationResult(
        translatedImage: pngBytes,
        sourceText: 'Hola mundo',
        translatedText: 'Bonjour le monde',
        notes: notes,
      );

  group('empty state', () {
    testWidgets('explains the methods and offers the pickers', (tester) async {
      await harness.pumpPage(tester);
      expect(find.text('Translate image'), findsOneWidget);
      expect(find.byKey(const Key('image_translate_empty_state')), findsOne);
      expect(find.text('Translate text in photos'), findsOneWidget);
      expect(find.text('Choose image'), findsOneWidget);
      expect(find.text('Take photo'), findsOneWidget);
      // Chip + method list entry.
      expect(find.text('Mozhi (Google Lens)'), findsNWidgets(2));
      expect(find.text('AI vision · Claude'), findsNWidgets(2));
      expect(find.text('On-device text recognition'), findsNothing);
      expect(find.text('Detect language'), findsOneWidget);
      expect(find.text('French'), findsOneWidget);
    });

    testWidgets('hides the camera when unsupported', (tester) async {
      harness.picker.supportsCamera = false;
      await harness.pumpPage(tester);
      expect(find.text('Take photo'), findsNothing);
    });

    testWidgets('points to settings when no method is available', (
      tester,
    ) async {
      harness = ImageTranslateHarness(
        translate: translateState(engines: const [deepl]),
        settings: const AppSettings(),
      );
      await harness.pumpPage(tester);
      expect(find.byKey(const Key('image_translate_no_methods')), findsOne);
      final gallery = tester.widget<FilledButton>(
        find.byKey(const Key('image_translate_gallery_button')),
      );
      expect(gallery.onPressed, isNull);

      await tester.tap(
        find.byKey(const Key('image_translate_providers_button')),
      );
      verify(() => harness.router.go('/settings/providers')).called(1);
      await tester.tap(
        find.byKey(const Key('image_translate_instances_button')),
      );
      verify(() => harness.router.go('/settings/instances')).called(1);
    });

    testWidgets('lists on-device recognition when supported', (tester) async {
      harness.recognizer.isSupported = true;
      await harness.pumpPage(tester);
      expect(find.text('On-device text recognition'), findsNWidgets(2));
    });
  });

  group('translating', () {
    testWidgets('picks and shows the translated image and text', (
      tester,
    ) async {
      harness.picker.image = jpegImage;
      stubImage(() async => lensResult(notes: 'A shop sign'));
      await harness.pumpPage(tester);

      await tester.tap(find.byKey(const Key('image_translate_gallery_button')));
      await tester.pumpAndSettle();
      await translateNow(tester);

      expect(harness.picker.picks, [ImagePickSource.gallery]);
      expect(find.byKey(const Key('image_translate_toggle')), findsOneWidget);
      expect(find.bySemanticsLabel('Translated image'), findsOneWidget);
      expect(find.text('Hola mundo'), findsOneWidget);
      expect(find.text('Bonjour le monde'), findsOneWidget);
      expect(find.text('A shop sign'), findsOneWidget);
      expect(find.byKey(const Key('image_translate_copy_button')), findsOne);
      expect(find.byKey(const Key('image_translate_share_button')), findsOne);
      expect(find.byKey(const Key('image_translate_open_button')), findsOne);

      await tester.ensureVisible(find.text('Original'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Original'));
      await tester.pump();
      expect(find.bySemanticsLabel('Selected image'), findsOneWidget);
      await tester.tap(find.text('Translated'));
      await tester.pump();
      expect(find.bySemanticsLabel('Translated image'), findsOneWidget);
    });

    testWidgets("counts AI requests with the app's usage tracker", (
      tester,
    ) async {
      final tracker = MockUsageTracker();
      when(
        () => tracker.recordText(
          any(),
          input: any(named: 'input'),
          output: any(named: 'output'),
        ),
      ).thenAnswer((_) async => const UsageStats(requests: 1));
      harness = ImageTranslateHarness(translate: translateState(engine: claude))
        ..usageTracker = tracker;
      harness.picker.image = jpegImage;
      stubImage(
        () async => const ImageTranslationResult(
          sourceText: 'Hola',
          translatedText: 'Salut',
        ),
      );
      await harness.pumpPage(tester);

      await tester.tap(find.byKey(const Key('image_translate_gallery_button')));
      await tester.pumpAndSettle();
      await translateNow(tester);

      expect(find.text('Salut'), findsOneWidget);
      verify(() => tracker.recordText('claude', input: 'Hola', output: 'Salut'))
          .called(1);
    });

    testWidgets('opens the picker on arrival', (tester) async {
      harness.picker.image = pngImage;
      stubImage(() async => lensResult());
      await harness.pumpPage(tester, initialSource: ImagePickSource.camera);
      await tester.pumpAndSettle();
      await translateNow(tester);
      expect(harness.picker.picks, [ImagePickSource.camera]);
      expect(find.text('Bonjour le monde'), findsOneWidget);
    });

    testWidgets('reports picker failures in a snackbar', (tester) async {
      harness.picker.error = const ImageTranslateException(
        ImageTranslateErrorKind.permissionDenied,
      );
      await harness.pumpPage(tester);
      await tester.tap(find.byKey(const Key('image_translate_camera_button')));
      await tester.pump();
      expect(find.textContaining('Access to the camera'), findsOneWidget);
    });

    testWidgets('shows progress and can be cancelled', (tester) async {
      final pending = Completer<ImageTranslationResult>();
      harness.picker.image = jpegImage;
      stubImage(() => pending.future);
      await harness.pumpPage(tester);

      await tester.tap(find.byKey(const Key('image_translate_gallery_button')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('image_translate_translate_button')),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('image_translate_progress')), findsOne);
      expect(find.textContaining('Google Lens via Mozhi'), findsOneWidget);

      await tester.tap(find.byKey(const Key('image_translate_cancel_button')));
      await tester.pump();
      expect(find.byKey(const Key('image_translate_progress')), findsNothing);
      expect(
        find.byKey(const Key('image_translate_translate_button')),
        findsOneWidget,
      );

      stubImage(() async => lensResult());
      await tester.tap(
        find.byKey(const Key('image_translate_translate_button')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Bonjour le monde'), findsOneWidget);
    });

    testWidgets('shows errors with retry', (tester) async {
      harness.picker.image = jpegImage;
      stubImage(
        () async => throw const MozhiApiException('big', statusCode: 413),
      );
      await harness.pumpPage(tester);
      await tester.tap(find.byKey(const Key('image_translate_gallery_button')));
      await tester.pumpAndSettle();
      await translateNow(tester);
      expect(find.textContaining('too large'), findsOneWidget);

      stubImage(() async => lensResult());
      await tester.tap(find.byKey(const Key('image_translate_retry_button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('image_translate_error')), findsNothing);
      expect(find.text('Bonjour le monde'), findsOneWidget);
    });

    testWidgets('app bar actions replace and remove the image', (tester) async {
      harness.picker.image = jpegImage;
      stubImage(() async => lensResult());
      await harness.pumpPage(tester);
      await tester.tap(find.byKey(const Key('image_translate_gallery_button')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('image_translate_appbar_camera')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('image_translate_appbar_gallery')));
      await tester.pumpAndSettle();
      expect(harness.picker.picks, [
        ImagePickSource.gallery,
        ImagePickSource.camera,
        ImagePickSource.gallery,
      ]);

      await tester.tap(find.byKey(const Key('image_translate_appbar_clear')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('image_translate_empty_state')), findsOne);
    });
  });

  group('options', () {
    testWidgets('changing the target waits for Translate', (tester) async {
      harness.picker.image = jpegImage;
      stubImage(() async => lensResult());
      await harness.pumpPage(tester);
      await tester.tap(find.byKey(const Key('image_translate_gallery_button')));
      await tester.pumpAndSettle();
      await translateNow(tester);

      await tester.tap(find.byKey(const Key('image_translate_target_button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('image_language_search')),
        'deut',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('image_language_en')), findsNothing);
      await tester.tap(find.byKey(const Key('image_language_de')));
      await tester.pumpAndSettle();

      expect(find.text('German'), findsOneWidget);
      await translateNow(tester);
      verify(
        () => harness.repository.translateImage(
          google,
          any(),
          mimeType: 'image/png',
          source: Language.auto,
          target: german,
        ),
      ).called(1);
    });

    testWidgets('the source can be changed', (tester) async {
      await harness.pumpPage(tester);
      await tester.tap(find.byKey(const Key('image_translate_source_button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('image_language_auto')), findsOneWidget);
      await tester.tap(find.byKey(const Key('image_language_ja')));
      await tester.pumpAndSettle();
      expect(find.text('Japanese'), findsOneWidget);
    });

    testWidgets('selecting a method switches to it', (tester) async {
      harness.picker.image = jpegImage;
      stubImage(
        () async => const ImageTranslationResult(translatedText: 'Salut'),
      );
      await harness.pumpPage(tester);
      await tester.tap(
        find.byKey(Key('image_translate_method_${claudeMethod.id}')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(
              find.byKey(Key('image_translate_method_${claudeMethod.id}')),
            )
            .selected,
        isTrue,
      );

      await tester.tap(find.byKey(const Key('image_translate_gallery_button')));
      await tester.pumpAndSettle();
      await translateNow(tester);
      expect(find.text('Salut'), findsOneWidget);
      expect(find.byKey(const Key('image_translate_toggle')), findsNothing);
      verify(
        () => harness.repository.translateImage(
          claude,
          encodedPng,
          mimeType: 'image/png',
          source: any(named: 'source'),
          target: any(named: 'target'),
          options: any(named: 'options'),
        ),
      ).called(1);
    });

    testWidgets('follows engine and provider changes', (tester) async {
      final translateController = StreamController<TranslateState>();
      final settingsController = StreamController<AppSettings>();
      addTearDown(translateController.close);
      addTearDown(settingsController.close);
      whenListen(
        harness.translate,
        translateController.stream,
        initialState: translateState(),
      );
      whenListen(
        harness.settings,
        settingsController.stream,
        initialState: const AppSettings(providers: allProviders),
      );
      await harness.pumpPage(tester);
      expect(find.text('AI vision · Claude'), findsNWidgets(2));

      settingsController.add(const AppSettings(providers: [ollamaProvider]));
      await tester.pumpAndSettle();
      expect(find.text('AI vision · Claude'), findsNothing);

      final onClaude = translateState(engine: claude);
      translateController
        ..add(onClaude)
        ..add(
          onClaude.copyWith(options: const TranslationOptions(context: 'Menu')),
        );
      await tester.pumpAndSettle();
      expect(find.text('Mozhi (Google Lens)'), findsNWidgets(2));

      translateController.add(translateState(engines: const [deepl]));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('image_translate_no_methods')), findsOne);
    });
  });

  group('on-device recognition', () {
    testWidgets('recognised text can be edited and translated again', (
      tester,
    ) async {
      harness = ImageTranslateHarness(
        translate: translateState(engines: const [deepl]),
        settings: const AppSettings(),
      );
      harness.recognizer
        ..isSupported = true
        ..text = 'Hola';
      harness.picker.image = pngImage;
      when(() => harness.repository.translate(any(), any())).thenAnswer((
        invocation,
      ) {
        final request = invocation.positionalArguments[1] as TranslationRequest;
        return Stream.value(
          TranslationResult(
            engineId: deepl.id,
            engineName: deepl.name,
            text: '${request.text}!',
          ),
        );
      });
      await harness.pumpPage(tester);
      await tester.tap(find.byKey(const Key('image_translate_gallery_button')));
      await tester.pumpAndSettle();

      expect(find.text('Hola!'), findsOneWidget);
      final field = find.byKey(const Key('image_translate_source_field'));
      expect(field, findsOneWidget);
      await tester.enterText(field, 'Adiós');
      await tester.tap(
        find.byKey(const Key('image_translate_retranslate_button')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Adiós!'), findsOneWidget);
    });
  });

  group('layout', () {
    testWidgets('uses two panes on wide screens', (tester) async {
      harness.picker.image = jpegImage;
      stubImage(() async => lensResult());
      await harness.pumpPage(tester, size: const Size(1280, 800));
      expect(find.byKey(const Key('image_translate_wide')), findsOneWidget);
      await tester.tap(find.byKey(const Key('image_translate_gallery_button')));
      await tester.pumpAndSettle();
      await translateNow(tester);
      expect(find.text('Bonjour le monde'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders in dark mode on a small phone', (tester) async {
      harness.picker.image = jpegImage;
      stubImage(() async => lensResult());
      await harness.pumpPage(
        tester,
        size: const Size(360, 640),
        themeMode: ThemeMode.dark,
      );
      expect(find.byKey(const Key('image_translate_narrow')), findsOneWidget);
      final gallery = find.byKey(const Key('image_translate_gallery_button'));
      await tester.ensureVisible(gallery);
      await tester.pumpAndSettle();
      await tester.tap(gallery);
      await tester.pumpAndSettle();
      await translateNow(tester);
      expect(harness.picker.picks, [ImagePickSource.gallery]);
      expect(find.byKey(const Key('image_translate_toggle')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('meets tap target guidelines', (tester) async {
      final handle = tester.ensureSemantics();
      await harness.pumpPage(tester);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    });
  });

  group('routing', () {
    test('locations', () {
      expect(ImageTranslatePage.location, '/translate/image');
      expect(ImageTranslatePage.locationFor(), '/translate/image');
      expect(
        ImageTranslatePage.locationFor(source: ImagePickSource.camera),
        '/translate/image?source=camera',
      );
    });

    Future<void> pumpRouter(WidgetTester tester, String location) async {
      final router = GoRouter(
        initialLocation: location,
        routes: [
          GoRoute(
            path: '/translate',
            builder: (context, state) => const SizedBox(),
            routes: [ImageTranslatePage.route()],
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        RepositoryProvider<TranslationRepository>.value(
          value: harness.repository,
          child: MultiBlocProvider(
            providers: [
              BlocProvider<TranslateCubit>.value(value: harness.translate),
              BlocProvider<SettingsCubit>.value(value: harness.settings),
            ],
            child: MaterialApp.router(
              routerConfig: router,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('route builds the page', (tester) async {
      await pumpRouter(tester, '/translate/image?source=scanner');
      final view = tester.widget<ImageTranslateView>(
        find.byType(ImageTranslateView),
      );
      expect(view.initialSource, isNull);
    });

    testWidgets('route opens the requested picker', (tester) async {
      const channel = MethodChannel('plugins.flutter.io/image_picker');
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call.method);
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await pumpRouter(tester, '/translate/image?source=gallery');
      final view = tester.widget<ImageTranslateView>(
        find.byType(ImageTranslateView),
      );
      expect(view.initialSource, ImagePickSource.gallery);
      expect(calls, contains('pickImage'));
      expect(find.byKey(const Key('image_translate_empty_state')), findsOne);
    });
  });
}
