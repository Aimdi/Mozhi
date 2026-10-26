import 'dart:typed_data';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/router.dart';
import 'package:mozhi/image_translate/image_translate.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/live_camera/live_camera_entry.dart';
import 'package:mozhi/live_camera/view/live_camera_page.dart';

import '../app/mocks.dart';
import '../helpers/helpers.dart';

class _MockImageTranslateCubit extends MockCubit<ImageTranslateState>
    implements ImageTranslateCubit;

class _MockGoRouter extends Mock implements GoRouter;

/// Longer than any page transition.
const _transition = Duration(seconds: 1);

void main() {
  test('the live camera is offered in the Android app only', () {
    // Tests run on a desktop host.
    expect(liveCameraOffered, isFalse);
    debugLiveCameraOffered = true;
    addTearDown(() => debugLiveCameraOffered = null);
    expect(liveCameraOffered, isTrue);
    expect(AppRoutes.liveCamera, '/image/live');
  });

  group('image screen', () {
    late _MockImageTranslateCubit cubit;
    late _MockGoRouter router;

    setUpAll(
      () => registerFallbackValue(
        PickedImage(bytes: Uint8List(0), mimeType: 'image/jpeg'),
      ),
    );

    setUp(() {
      cubit = _MockImageTranslateCubit();
      when(() => cubit.state).thenReturn(
        const ImageTranslateState(methods: [ImageTranslateMethod.onDevice()]),
      );
      when(() => cubit.isClosed).thenReturn(false);
      when(
        () => cubit.setImage(any(), autoTranslate: any(named: 'autoTranslate')),
      ).thenAnswer((_) async {});
      router = _MockGoRouter();
    });

    tearDown(() => debugLiveCameraOffered = null);

    Future<void> pump(WidgetTester tester) => tester.pumpApp(
      InheritedGoRouter(
        goRouter: router,
        child: BlocProvider<ImageTranslateCubit>.value(
          value: cubit,
          child: const Scaffold(
            body: SingleChildScrollView(child: ImageTranslateEmptyState()),
          ),
        ),
      ),
    );

    testWidgets('has no Live camera button off Android', (tester) async {
      await pump(tester);
      expect(
        find.byKey(const Key('image_translate_live_camera_button')),
        findsNothing,
      );
    });

    testWidgets('Live camera opens it; a frozen still is shown', (
      tester,
    ) async {
      debugLiveCameraOffered = true;
      final still = PickedImage(
        bytes: Uint8List.fromList([0xFF, 0xD8, 0xFF]),
        mimeType: 'image/jpeg',
      );
      when(
        () => router.push<PickedImage>(
          LiveCameraRoutes.location,
          extra: LiveCameraLaunch.open,
        ),
      ).thenAnswer((_) async => still);
      await pump(tester);

      expect(find.text('Live camera'), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('image_translate_live_camera_button')),
      );
      await tester.pump();

      verify(() => cubit.setImage(still)).called(1);
    });

    testWidgets('closing the live camera leaves the screen as it is', (
      tester,
    ) async {
      debugLiveCameraOffered = true;
      when(
        () => router.push<PickedImage>(
          LiveCameraRoutes.location,
          extra: LiveCameraLaunch.open,
        ),
      ).thenAnswer((_) async => null);
      await pump(tester);
      await tester.tap(
        find.byKey(const Key('image_translate_live_camera_button')),
      );
      await tester.pump();

      verifyNever(
        () => cubit.setImage(any(), autoTranslate: any(named: 'autoTranslate')),
      );
    });
  });

  group('route', () {
    late TestEnvironment env;
    late GoRouter router;

    setUpAll(() async {
      registerAppFallbacks();
      await DeferredFeatures.liveCamera.load();
      await DeferredFeatures.image.load();
    });

    setUp(() {
      env = TestEnvironment();
      router = createAppRouter();
    });

    tearDown(() => router.dispose());

    Future<void> pumpRouter(WidgetTester tester) async {
      tester.view
        ..physicalSize = const Size(400, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        env.wrap(
          MaterialApp.router(
            routerConfig: router,
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await tester.pump();
    }

    String location() =>
        router.routerDelegate.currentConfiguration.uri.toString();

    testWidgets('a link opens the image screen, not the camera', (
      tester,
    ) async {
      await pumpRouter(tester);
      router.go(AppRoutes.liveCamera);
      await tester.pump();
      await tester.pump(_transition);

      expect(location(), AppRoutes.image);
      expect(find.byType(LiveCameraPage), findsNothing);
      expect(find.byType(ImageTranslatePage), findsOneWidget);
    });

    testWidgets('the image screen opens it above itself', (tester) async {
      await pumpRouter(tester);
      router.go(AppRoutes.image);
      await tester.pump();
      await tester.pump(_transition);

      final closed = router.push<PickedImage>(
        AppRoutes.liveCamera,
        extra: LiveCameraLaunch.open,
      );
      await tester.pump();
      await tester.pump(_transition);

      expect(find.byType(LiveCameraPage), findsOneWidget);
      // No camera on the test host.
      expect(find.text('Live camera needs the Android app'), findsOneWidget);

      await tester.tap(find.byTooltip('Close'));
      await tester.pump();
      await tester.pump(_transition);
      expect(await closed, isNull);
      expect(location(), AppRoutes.image);
    });
  });
}
