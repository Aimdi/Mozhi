import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/live_captions/cubit/live_captions_cubit.dart';
import 'package:mozhi/live_captions/view/live_captions_page.dart';
import 'package:mozhi/platform/device_conditions.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers.dart';

class _MockTranslateCubit extends MockCubit<TranslateState>
    implements TranslateCubit;

class _MockSettingsCubit extends MockCubit<AppSettings>
    implements SettingsCubit;

void main() {
  late FakeCaptionsHost host;
  late FakeCaptionRecognizer recognizer;
  late MockDeviceConditions conditions;
  late _MockTranslateCubit translate;
  late _MockSettingsCubit settings;
  late GoRouter router;
  late MockTranslationRepository repository;

  setUpAll(() => registerFallbackValue(deepl));

  setUp(() {
    repository = MockTranslationRepository();
    when(() => repository.destinationOf(any()))
        .thenReturn(const OnDeviceDestination());
    host = FakeCaptionsHost();
    recognizer = FakeCaptionRecognizer();
    conditions = MockDeviceConditions();
    translate = _MockTranslateCubit();
    settings = _MockSettingsCubit();
    when(() => conditions.latest).thenReturn(DeviceConditionsSnapshot.unknown);
    when(() => conditions.changes).thenAnswer((_) => const Stream.empty());
    when(() => translate.state).thenReturn(
      TranslateState(
        engines: [offlineEngine, deepl],
        engine: deepl,
        targetLanguages: const [english, spanish],
      ),
    );
    when(() => settings.state).thenReturn(const AppSettings());
    router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: Text('Home')),
        ),
        GoRoute(
          path: '/transcribe/captions',
          builder: (context, state) => LiveCaptionsPage(
            host: () async => host,
            recognizer: recognizer,
            overlay: FakeOverlayControls(),
            conditions: conditions,
          ),
        ),
      ],
    );
  });

  tearDown(() async {
    router.dispose();
    await host.dispose();
  });

  Future<void> pumpRouter(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(420, 900)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepositoryProvider<TranslationRepository>.value(
        value: repository,
        child: MultiBlocProvider(
          providers: [
            BlocProvider<TranslateCubit>.value(value: translate),
            BlocProvider<SettingsCubit>.value(value: settings),
            BlocProvider<HistoryCubit>.value(value: MockHistoryCubit()),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> go(WidgetTester tester, String location) async {
    router.go(location);
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
  }

  LiveCaptionsCubit cubitOf(WidgetTester tester) =>
      tester.element(find.byType(LiveCaptionsView)).read<LiveCaptionsCubit>();

  testWidgets('a start request starts the captions once per token', (
    tester,
  ) async {
    host.startTokens.addAll(['tile-1', 'tile-2']);
    await pumpRouter(tester);
    await go(tester, '/transcribe/captions?start=tile-1');

    expect(find.byType(LiveCaptionsView), findsOneWidget);
    expect(host.starts, 1);
    expect(cubitOf(tester).state.status, LiveCaptionsStatus.running);

    unawaited(cubitOf(tester).stop());
    await tester.pump();
    await tester.pump();
    expect(cubitOf(tester).state.status, LiveCaptionsStatus.idle);
    // The same location again (built anew): not started again.
    await go(tester, '/');
    await go(tester, '/transcribe/captions?start=tile-1');
    expect(host.starts, 1);

    // A new tap of the tile: a new token.
    await go(tester, '/transcribe/captions?start=tile-2');
    expect(host.starts, 2);
  });

  testWidgets('a token the tile did not make only opens the screen', (
    tester,
  ) async {
    host.startTokens.add('tile-1');
    await pumpRouter(tester);
    // Another app's link (MainActivity is exported): a guessed token.
    await go(tester, '/transcribe/captions?start=1');

    expect(find.byType(LiveCaptionsView), findsOneWidget);
    expect(host.consumedTokens, ['1']);
    expect(host.starts, 0);
    expect(cubitOf(tester).state.status, LiveCaptionsStatus.idle);
  });

  testWidgets('a used-up token does not start again in a new process', (
    tester,
  ) async {
    // The platform says no (used already): nothing starts, though this
    // page has not seen the token yet.
    await pumpRouter(tester);
    await go(tester, '/transcribe/captions?start=used-token');

    expect(host.consumedTokens, ['used-token']);
    expect(host.starts, 0);
  });

  testWidgets('opened without one, nothing starts', (tester) async {
    await pumpRouter(tester);
    await go(tester, '/transcribe/captions');

    expect(find.byType(LiveCaptionsView), findsOneWidget);
    expect(host.starts, 0);
    expect(cubitOf(tester).state.status, LiveCaptionsStatus.idle);
  });

  testWidgets('an empty token starts nothing', (tester) async {
    await pumpRouter(tester);
    await go(tester, '/transcribe/captions?start=');

    expect(host.starts, 0);
    expect(host.consumedTokens, isEmpty);
  });
}
