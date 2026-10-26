import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app_lock/data/app_lock.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/image_translate/image_translate.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/live_camera/cubit/live_camera_cubit.dart';
import 'package:mozhi/live_camera/data/live_camera_controller.dart';
import 'package:mozhi/live_camera/view/live_camera_page.dart';
import 'package:mozhi/live_camera/widgets/live_overlay.dart';
import 'package:mozhi/platform/device_conditions.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/live_camera_fakes.dart';

class _MockSettingsCubit extends MockCubit<AppSettings>
    implements SettingsCubit;

class _MockTranslateCubit extends MockCubit<TranslateState>
    implements TranslateCubit;

/// [testWidgets] that unmounts the page at the end, so the camera stops
/// and its waiting frame (and the frame timeout) ends.
void testLive(String description, WidgetTesterCallback body) {
  testWidgets(description, (tester) async {
    await body(tester);
    await tester.pumpWidget(const SizedBox());
    // The wait between two frames ends too.
    await tester.pump(const Duration(seconds: 1));
  });
}

void main() {
  setUpAll(registerLiveCameraFallbacks);

  late FakeLiveCamera camera;
  late FakeLiveRecognizer recognizer;
  late MockTranslationRepository repository;
  late MockDeviceConditions conditions;
  late _MockSettingsCubit settings;
  late _MockTranslateCubit translate;

  setUp(() {
    camera = FakeLiveCamera();
    recognizer = FakeLiveRecognizer();
    repository = MockTranslationRepository();
    when(() => repository.translate(any(), any()))
        .thenAnswer(bracketTranslation);
    conditions = MockDeviceConditions();
    when(() => conditions.latest).thenReturn(DeviceConditionsSnapshot.unknown);
    when(() => conditions.changes).thenAnswer((_) => const Stream.empty());
    settings = _MockSettingsCubit();
    when(() => settings.state).thenReturn(const AppSettings());
    translate = _MockTranslateCubit();
    when(() => translate.state).thenReturn(
      TranslateState(
        engines: [TranslationEngine.offline(), googleEngine],
        sourceLanguages: const [Language.auto, english, german],
        targetLanguages: const [english, german, french],
        source: english,
        target: german,
      ),
    );
  });

  Widget app({ThemeData? theme, Widget? home, AppLock? lock}) =>
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<TranslationRepository>.value(value: repository),
          if (lock != null) RepositoryProvider<AppLock>.value(value: lock),
        ],
        child: RepositoryProvider<KeyValueStore>.value(
          value: MemoryStore(),
          child: MultiBlocProvider(
            providers: [
              BlocProvider<SettingsCubit>.value(value: settings),
              BlocProvider<TranslateCubit>.value(value: translate),
            ],
            child: MaterialApp(
              theme: theme,
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home:
                  home ??
                  LiveCameraPage(
                    camera: camera,
                    recognizer: recognizer,
                    conditions: conditions,
                  ),
            ),
          ),
        ),
      );

  Future<void> pumpPage(
    WidgetTester tester, {
    ThemeData? theme,
    AppLock? lock,
  }) async {
    // A phone held upright.
    tester.view
      ..physicalSize = const Size(400, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(theme: theme, lock: lock));
    await tester.pump();
    await tester.pump();
  }

  LiveCameraCubit cubitOf(WidgetTester tester) =>
      tester.element(find.byType(LiveCameraView)).read<LiveCameraCubit>();

  /// Lets the camera hand out a frame reading [paragraphs].
  Future<void> show(WidgetTester tester, List<TextParagraph> paragraphs) async {
    recognizer.answers.add(layoutOf(paragraphs));
    // As a back camera delivers it: turned 90° from upright (360 x 640).
    camera.push(testFrame(rotation: 90, width: 640, height: 360));
    await tester.pump();
    // Past the wait before the next frame.
    await tester.pump(const Duration(milliseconds: 400));
  }

  testLive('shows the preview with its controls', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpPage(tester);

    expect(find.byType(Texture), findsOneWidget);
    expect(find.byTooltip('Close'), findsOneWidget);
    expect(find.byTooltip('Turn on the flashlight'), findsOneWidget);
    expect(find.text('1×'), findsOneWidget);
    expect(find.bySemanticsLabel('Freeze'), findsOneWidget);
    expect(find.bySemanticsLabel('Zoom 1×'), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        'Translate live with Offline (on-device). Change the engine',
      ),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Live camera'), findsOneWidget);
    expect(find.text('Point the camera at some text'), findsOneWidget);
    final status = find.byKey(const Key('live_camera_status'));
    expect(
      tester.widget<Text>(status).data,
      'Translating live with Offline (on-device)',
    );
    final region = tester.widget<Semantics>(
      find.ancestor(of: status, matching: find.byType(Semantics)).first,
    );
    expect(region.properties.liveRegion, isTrue);
    semantics.dispose();
  });

  testLive('draws the translations over the preview', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpPage(tester);
    final status = tester
        .widget<Text>(find.byKey(const Key('live_camera_status')))
        .data;

    await show(tester, [paragraph('Hello world')]);

    final overlay = tester.widget<CustomPaint>(
      find.byKey(const Key('live_camera_overlay')),
    );
    final painter = overlay.painter! as LiveOverlayPainter;
    expect(painter.labels.single.translation, '<Hello world>de');
    expect(find.semantics.byLabel('<Hello world>de'), findsOne);
    expect(find.text('Point the camera at some text'), findsNothing);
    // The status line stays the same: nothing is announced per frame.
    expect(
      tester.widget<Text>(find.byKey(const Key('live_camera_status'))).data,
      status,
    );

    // A block still being read is an outline only.
    await show(tester, [
      paragraph('Hello world'),
      paragraph(
        'Second one',
        box: const Rect.fromLTWH(10, 200, 100, 20),
        confidence: 60,
      ),
    ]);
    final next =
        tester
                .widget<CustomPaint>(
                  find.byKey(const Key('live_camera_overlay')),
                )
                .painter!
            as LiveOverlayPainter;
    expect(next.reading, hasLength(1));
    expect(next.labels, hasLength(1));
    semantics.dispose();
  });

  testLive('torch and zoom', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byTooltip('Turn on the flashlight'));
    await tester.pump();
    expect(camera.torch, [true]);
    expect(find.byTooltip('Turn off the flashlight'), findsOneWidget);

    await tester.tap(find.byKey(const Key('live_camera_zoom')));
    await tester.pump();
    expect(camera.zooms, [2]);
    expect(find.text('2×'), findsOneWidget);
  });

  testLive('pinch to zoom', (tester) async {
    await pumpPage(tester);
    final center = tester.getCenter(
      find.byKey(const Key('live_camera_preview')),
    );
    final first = await tester.startGesture(center - const Offset(20, 0));
    final second = await tester.startGesture(
      center + const Offset(20, 0),
      pointer: 2,
    );
    await tester.pump();
    await first.moveBy(const Offset(-40, 0));
    await second.moveBy(const Offset(40, 0));
    await tester.pump();
    await first.up();
    await second.up();
    await tester.pump();
    expect(camera.zooms, isNotEmpty);
    expect(cubitOf(tester).state.zoom, greaterThan(1));
  });

  testLive('no torch and no zoom where the camera has none', (tester) async {
    camera.preview = const LivePreview(
      textureId: 1,
      previewSize: Size(640, 480),
      rotation: 90,
    );
    await pumpPage(tester);
    expect(find.byKey(const Key('live_camera_torch')), findsNothing);
    expect(find.byKey(const Key('live_camera_zoom')), findsNothing);
  });

  testLive('Freeze pops the still for the photo page', (tester) async {
    final still = PickedImage(
      bytes: Uint8List.fromList([0xFF, 0xD8, 0xFF]),
      mimeType: 'image/jpeg',
    );
    camera.picture = still;
    PickedImage? result;
    await tester.pumpWidget(
      app(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await Navigator.of(context).push<PickedImage>(
                MaterialPageRoute(
                  builder: (_) => LiveCameraPage(
                    camera: camera,
                    recognizer: recognizer,
                    conditions: conditions,
                  ),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('live_camera_freeze')));
    await tester.pumpAndSettle();

    expect(result, same(still));
    expect(find.byType(LiveCameraView), findsNothing);
    expect(camera.stops, greaterThanOrEqualTo(1));
  });

  group('with the router', () {
    late GoRouter router;

    GoRouter routerFor(String initialLocation, List<PickedImage?> results) =>
        GoRouter(
          initialLocation: initialLocation,
          routes: [
            GoRoute(
              path: '/image',
              builder: (context, state) => TextButton(
                onPressed: () async =>
                    results.add(await context.push<PickedImage>('/image/live')),
                child: const Text('open'),
              ),
            ),
            GoRoute(
              path: '/image/live',
              builder: (context, state) => LiveCameraPage(
                camera: camera,
                recognizer: recognizer,
                conditions: conditions,
              ),
            ),
          ],
        );

    Future<void> pumpRouter(WidgetTester tester) async {
      addTearDown(router.dispose);
      await tester.pumpWidget(
        RepositoryProvider<TranslationRepository>.value(
          value: repository,
          child: MultiBlocProvider(
            providers: [
              BlocProvider<SettingsCubit>.value(value: settings),
              BlocProvider<TranslateCubit>.value(value: translate),
            ],
            child: MaterialApp.router(
              routerConfig: router,
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testLive('Freeze pops the still to the image screen', (tester) async {
      final still = PickedImage(
        bytes: Uint8List.fromList([0xFF, 0xD8, 0xFF]),
        mimeType: 'image/jpeg',
      );
      camera.picture = still;
      final results = <PickedImage?>[];
      router = routerFor('/image', results);
      await pumpRouter(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('live_camera_freeze')));
      await tester.pumpAndSettle();

      expect(results.single, same(still));
    });

    testLive('opened on its own, Freeze and Close go to the image screen', (
      tester,
    ) async {
      camera.picture = PickedImage(
        bytes: Uint8List.fromList([0xFF, 0xD8, 0xFF]),
        mimeType: 'image/jpeg',
      );
      router = routerFor('/image/live', []);
      await pumpRouter(tester);
      await tester.tap(find.byKey(const Key('live_camera_freeze')));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/image');

      router.go('/image/live');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/image');
    });
  });

  testLive('a failed freeze says so and reads on', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const Key('live_camera_freeze')));
    await tester.pump();
    await tester.pump();
    expect(find.text('Couldn’t take the photo. Try again.'), findsOneWidget);
    expect(cubitOf(tester).state.status, LiveCameraStatus.running);
  });

  testLive('Close goes back', (tester) async {
    await tester.pumpWidget(
      app(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => LiveCameraPage(
                  camera: camera,
                  recognizer: recognizer,
                  conditions: conditions,
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(LiveCameraView), findsNothing);
    expect(camera.stops, 1);
  });

  testLive('asks again after the camera was refused', (tester) async {
    camera.access = [CameraAccess.denied, CameraAccess.granted];
    await pumpPage(tester);

    expect(find.byKey(const Key('live_camera_denied')), findsOneWidget);
    expect(find.text('Allow the camera'), findsOneWidget);
    await tester.tap(find.byKey(const Key('live_camera_allow')));
    await tester.pump();
    await tester.pump();

    expect(camera.accessRequests, 2);
    expect(find.byKey(const Key('live_camera_denied')), findsNothing);
    expect(find.byType(Texture), findsOneWidget);
  });

  testLive('blocked: offers the settings', (tester) async {
    camera.access = [CameraAccess.blocked];
    await pumpPage(tester);

    expect(find.byKey(const Key('live_camera_blocked')), findsOneWidget);
    await tester.tap(find.byKey(const Key('live_camera_open_settings')));
    await tester.pump();
    expect(camera.settingsOpened, 1);
    await tester.tap(find.byKey(const Key('live_camera_ask_again')));
    await tester.pump();
    expect(camera.accessRequests, 2);
  });

  testLive('says where there is no live camera', (tester) async {
    camera.isSupported = false;
    await pumpPage(tester);
    expect(find.byKey(const Key('live_camera_unsupported')), findsOneWidget);
    expect(find.byKey(const Key('live_camera_no_preview')), findsOneWidget);
  });

  testLive('a camera failure offers Retry', (tester) async {
    camera.startErrors.add(
      const LiveCameraException(LiveCameraErrorKind.inUse),
    );
    await pumpPage(tester);
    expect(
      find.text('Another app is using the camera. Close it and try again.'),
      findsWidgets,
    );
    await tester.tap(find.byKey(const Key('live_camera_retry')));
    await tester.pump();
    await tester.pump();
    expect(find.byType(Texture), findsOneWidget);
  });

  testLive('offers missing recognition data and the language', (tester) async {
    when(() => translate.state).thenReturn(
      TranslateState(
        engines: [TranslationEngine.offline()],
        source: french,
        target: german,
      ),
    );
    await pumpPage(tester);

    expect(find.byKey(const Key('image_translate_ocr_offer')), findsOneWidget);
    await tester.tap(find.byKey(const Key('live_camera_choose_source')));
    await tester.pumpAndSettle();
    // The catalogue (the translator has no source languages).
    await tester.enterText(
      find.byKey(const Key('image_language_search')),
      'German',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('image_language_de')));
    await tester.pumpAndSettle();

    expect(cubitOf(tester).state.source.code, 'de');
    expect(find.byKey(const Key('image_translate_ocr_offer')), findsNothing);
  });

  testLive('a language no data reads', (tester) async {
    when(() => translate.state).thenReturn(
      const TranslateState(
        source: Language(code: 'xh', name: 'Xhosa'),
        target: german,
      ),
    );
    await pumpPage(tester);
    expect(
      find.byKey(const Key('live_camera_ocr_unsupported')),
      findsOneWidget,
    );
  });

  testLive('the source from the language bar', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const Key('live_camera_source_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('image_language_de')));
    await tester.pumpAndSettle();
    expect(cubitOf(tester).state.source, german);
  });

  testLive('reads on once the missing data is downloaded', (tester) async {
    when(() => translate.state).thenReturn(
      TranslateState(
        engines: [TranslationEngine.offline()],
        source: french,
        target: german,
      ),
    );
    await pumpPage(tester);
    await tester.tap(find.byKey(const Key('image_translate_ocr_download')));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(recognizer.installed, contains('fra'));
    expect(find.byKey(const Key('image_translate_ocr_offer')), findsNothing);
    expect(camera.waitingForFrame, isTrue);
  });

  testLive('the target from the language bar', (tester) async {
    await pumpPage(tester);
    await show(tester, [paragraph('Hello world')]);
    await tester.tap(find.byKey(const Key('live_camera_target_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('image_language_fr')));
    await tester.pumpAndSettle();

    expect(cubitOf(tester).state.target, french);
    expect(cubitOf(tester).state.blocks.single.translation, '<Hello world>fr');
  });

  testLive('the engine chip opens the engine picker', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const Key('live_camera_engine_chip')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('live_engine_picker')), findsOneWidget);
  });

  testLive('follows the live engine of the settings', (tester) async {
    whenListen(
      settings,
      Stream.value(const AppSettings(liveEngineId: 'mozhi:google')),
      initialState: const AppSettings(),
    );
    await pumpPage(tester);
    await tester.pump();
    expect(cubitOf(tester).state.engine.id, 'mozhi:google');
  });

  testLive('follows the engines of the translator', (tester) async {
    when(() => settings.state)
        .thenReturn(const AppSettings(liveEngineId: 'ai:gemma'));
    whenListen(
      translate,
      Stream.value(
        TranslateState(
          engines: [TranslationEngine.offline(), onDeviceAiEngine],
          source: english,
          target: german,
        ),
      ),
      initialState: TranslateState(
        engines: [TranslationEngine.offline()],
        source: english,
        target: german,
      ),
    );
    await pumpPage(tester);
    await tester.pump();
    expect(cubitOf(tester).state.engine.id, 'ai:gemma');
  });

  testLive('shows the consent the engine needs', (tester) async {
    when(() => repository.translate(any(), any())).thenAnswer(
      (_) => Stream.error(
        const ConsentRequiredException(
          kind: ConsentKind.offlineOnly,
          destination: CloudProviderDestination('Claude'),
          engineId: 'ai:claude',
        ),
      ),
    );
    await pumpPage(tester);
    await show(tester, [paragraph('Hello world')]);
    expect(
      find.text('Offline only is on, and this engine needs the network.'),
      findsOneWidget,
    );
  });

  testLive('an engine failure offers another engine', (tester) async {
    when(() => repository.translate(any(), any()))
        .thenAnswer((_) => Stream.error(StateError('down')));
    await pumpPage(tester);
    await show(tester, [paragraph('Hello world')]);
    expect(
      find.byKey(const Key('live_camera_translation_error')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('live_camera_choose_engine')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('live_engine_picker')), findsOneWidget);
  });

  testLive('recognition failures are reported', (tester) async {
    await pumpPage(tester);
    recognizer.error = const ImageTranslateException(
      ImageTranslateErrorKind.recognitionFailed,
    );
    for (var i = 0; i < 3; i++) {
      camera.push(testFrame());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(
      find.byKey(const Key('live_camera_recognition_failed')),
      findsOneWidget,
    );
  });

  testLive('pauses in the background and goes on in front', (tester) async {
    await pumpPage(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(cubitOf(tester).state.status, LiveCameraStatus.running);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(cubitOf(tester).state.status, LiveCameraStatus.paused);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(cubitOf(tester).state.status, LiveCameraStatus.running);
    expect(camera.starts, 2);
  });

  testLive('turns the preview with the display', (tester) async {
    await pumpPage(tester);
    camera.rotation = 90;
    tester.view.physicalSize = const Size(2400, 1080);
    addTearDown(tester.view.reset);
    await tester.pump();
    await tester.pump();
    expect(cubitOf(tester).state.displayRotation, 90);
    final box = tester.widget<RotatedBox>(find.byType(RotatedBox));
    expect(box.quarterTurns, 3);
  });

  testLive('says when it is paused while locked', (tester) async {
    final lock = FakeAppLock(isLocked: true);
    await pumpPage(tester, lock: lock);
    expect(find.text('Paused while Mozhi is locked'), findsOneWidget);
    expect(find.byType(Texture), findsNothing);
    expect(camera.accessRequests, 0);

    lock.unlockNow();
    await tester.pump();
    await tester.pump();
    expect(find.byType(Texture), findsOneWidget);
  });

  testLive('says it reads less often while the phone is hot', (tester) async {
    when(
      () => conditions.latest,
    ).thenReturn(const DeviceConditionsSnapshot(thermal: ThermalStatus.severe));
    await pumpPage(tester, theme: ThemeData.dark());
    expect(
      find.text('Reading less often while the phone is hot'),
      findsOneWidget,
    );
  });

  testLive('light status bar icons over the camera', (tester) async {
    await pumpPage(tester);
    final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
      find.byType(AnnotatedRegion<SystemUiOverlayStyle>).first,
    );
    expect(region.value.statusBarIconBrightness, Brightness.light);
  });
}
