@Tags(['golden', 'skip_very_good_optimization'])
library;

// TEMPORARY: screenshots of the app chrome for review; deleted afterwards.

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/router.dart';
import 'package:mozhi/app/view/top_level_actions.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/voice/speech_input_service.dart';
import 'package:translation_repository/translation_repository.dart';

import '../app/mocks.dart';
import 'helpers/golden_helpers.dart';

const _out =
    '/tmp/claude-0/-home-user-Mozhi/071da89e-592f-547c-b32a-54fb03071e39/'
    'scratchpad/mix/chrome';

const _claude = TranslationEngine(
  id: 'ai:claude',
  kind: EngineKind.ai,
  name: 'Claude',
  subtitle: 'claude-opus-5-5',
  providerId: 'claude',
);

const _english = Language(code: 'en', name: 'English');
const _spanish = Language(code: 'es', name: 'Spanish');

void main() {
  setUpAll(() async {
    registerAppFallbacks();
    await Future.wait(DeferredFeatures.all.map((library) => library.load()));
  });

  Future<GoRouter> pumpApp(
    WidgetTester tester, {
    required Size size,
    required Brightness brightness,
    double textScale = 1,
  }) async {
    final env = TestEnvironment();
    when(() => env.translateCubit.state).thenReturn(
      TranslateState(
        enginesStatus: EnginesStatus.ready,
        engines: [testEngines.first, _claude],
        engine: _claude,
        assistEngine: _claude,
        source: _english,
        target: _spanish,
        sourceLanguages: const [Language.auto, _english, _spanish],
        targetLanguages: const [_english, _spanish],
      ),
    );
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final router = createAppRouter();
    addTearDown(router.dispose);
    final speech = SpeechInputService(
      store: MemoryStore(),
      platformSupported: true,
    );
    await tester.pumpWidget(
      env.wrap(
        RepositoryProvider<SpeechInputService>.value(
          value: speech,
          child: MaterialApp.router(
            debugShowCheckedModeBanner: false,
            routerConfig: router,
            theme: goldenTheme(brightness),
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      ),
    );
    await tester.pump();
    return router;
  }

  Future<void> shot(WidgetTester tester, String name) async {
    await tester.pump(const Duration(seconds: 1));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(Uri.file('$_out/$name.png')),
    );
  }

  goldenGroup('chrome', () {
    for (final brightness in Brightness.values) {
      testWidgets('phone ${brightness.name}', (tester) async {
        final router = await pumpApp(
          tester,
          size: GoldenDevice.phone.size,
          brightness: brightness,
        );
        for (final tab in ['translate', 'dictionary', 'proofread']) {
          router.go('/$tab');
          await tester.pump();
          await shot(tester, '${tab}_phone_${brightness.name}');
        }
        router.go('/conversation');
        await tester.pump();
        await shot(tester, 'conversation_phone_${brightness.name}');
        await tester.tap(find.byKey(TopLevelActions.settingsKey));
        await tester.pump();
        await shot(tester, 'settings_pushed_phone_${brightness.name}');
      });
    }

    testWidgets('320 dp at 200 %', (tester) async {
      final router = await pumpApp(
        tester,
        size: const Size(320, 640),
        brightness: Brightness.light,
        textScale: 2,
      );
      for (final tab in [
        'translate',
        'dictionary',
        'proofread',
        'conversation',
      ]) {
        router.go('/$tab');
        await tester.pump();
        await shot(tester, '${tab}_320_text200');
        expect(tester.takeException(), isNull, reason: tab);
      }
    });

    testWidgets('tablet', (tester) async {
      final router = await pumpApp(
        tester,
        size: GoldenDevice.tablet.size,
        brightness: Brightness.light,
      );
      for (final tab in ['dictionary', 'conversation']) {
        router.go('/$tab');
        await tester.pump();
        await shot(tester, '${tab}_tablet_light');
      }
      await tester.tap(find.byKey(const Key('conversation_layout_toggle')));
      await tester.pump();
      await shot(tester, 'conversation_face_to_face_tablet_light');
    });
  });
}
