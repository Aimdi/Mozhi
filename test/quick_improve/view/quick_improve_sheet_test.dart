import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/quick_improve/quick_improve.dart';
import 'package:mozhi/quick_translate/quick_translate_host.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/usage/usage.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

class _MockGoRouter extends Mock implements GoRouter;

const _ready = TranslateState(
  enginesStatus: EnginesStatus.ready,
  engines: [google, claude, ollama],
  engine: google,
  assistEngine: ollama,
);

Finder _byKey(String key) => find.byKey(Key(key));

void main() {
  setUpAll(registerQuickImproveFallbacks);

  const channel = MethodChannel(QuickTranslateHost.channelName);
  late MockTranslationRepository repository;
  late MockTranslateCubit translate;
  late MockSettingsCubit settings;
  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    repository = MockTranslationRepository();
    translate = MockTranslateCubit();
    settings = MockSettingsCubit();
    when(() => settings.state).thenReturn(const AppSettings());
    when(() => repository.destinationOf(any()))
        .thenReturn(const SelfHostedDestination('localhost'));
    when(() => translate.loadEngines(refresh: any(named: 'refresh')))
        .thenAnswer((_) async {});
    stubProofread(repository);
  });

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  void stubTranslate(
    TranslateState state, {
    Stream<TranslateState> stream = const Stream.empty(),
  }) => whenListen(translate, stream, initialState: state);

  Future<void> open(
    WidgetTester tester, {
    QuickTranslateHost? window,
    GoRouter? router,
    ValueChanged<String>? onReplace,
    VoidCallback? onOpenInProofread,
    String text = sentence,
    Size size = const Size(400, 900),
    UsageTracker? usage,
    bool settle = true,
  }) async {
    Widget child = Builder(
      builder: (context) => Center(
        child: TextButton(
          onPressed: () => showQuickImprove(
            context,
            text: text,
            onReplace: onReplace,
            onOpenInProofread: onOpenInProofread,
            host: window ?? QuickTranslateHost(initialRoute: () => '/'),
          ),
          child: const Text('open'),
        ),
      ),
    );
    if (router != null) {
      child = InheritedGoRouter(goRouter: router, child: child);
    }
    Widget app = MultiBlocProvider(
      providers: [
        BlocProvider<TranslateCubit>.value(value: translate),
        BlocProvider<SettingsCubit>.value(value: settings),
      ],
      child: child,
    );
    if (usage != null) {
      app = RepositoryProvider<UsageTracker>.value(value: usage, child: app);
    }
    await tester.pumpImprove(
      RepositoryProvider<TranslationRepository>.value(
        value: repository,
        child: app,
      ),
      size: size,
    );
    await tester.tap(find.text('open'));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      // A progress indicator never settles.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }
  }

  testWidgets('proofreads the selection with the assist engine', (
    tester,
  ) async {
    stubTranslate(_ready);
    await open(tester);

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(_byKey('quick_improve_diff'), findsOneWidget);
    expect(_byKey('quick_improve_destination'), findsOneWidget);
    verify(
      () => repository.proofread(
        ollama,
        sentence,
        style: any(named: 'style', that: equals(WritingStyle.general)),
        level: any(named: 'level', that: equals(CorrectionLevel.standard)),
        uiLanguage: any(named: 'uiLanguage', that: equals('English')),
      ),
    ).called(1);
  });

  testWidgets('Replace returns the improved text and closes the sheet', (
    tester,
  ) async {
    final replaced = <String>[];
    stubTranslate(_ready);
    await open(tester, onReplace: replaced.add);

    await tester.tap(_byKey('quick_improve_replace'));
    await tester.pumpAndSettle();

    expect(replaced, ['I have a cat.']);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('a read-only selection has no Replace', (tester) async {
    stubTranslate(_ready);
    await open(tester, onOpenInProofread: () {});

    expect(_byKey('quick_improve_replace'), findsNothing);
    expect(_byKey('quick_improve_open_in_proofread'), findsOneWidget);
  });

  testWidgets('shows a dialog on wide windows', (tester) async {
    stubTranslate(_ready);
    await open(tester, size: const Size(900, 800));

    expect(find.byType(Dialog), findsOneWidget);
    await tester.tap(_byKey('quick_improve_close'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('shows nothing for blank text', (tester) async {
    stubTranslate(_ready);
    await open(tester, text: '  ');

    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('proofreads once the engines arrive', (tester) async {
    final states = StreamController<TranslateState>();
    addTearDown(states.close);
    stubTranslate(
      const TranslateState(enginesStatus: EnginesStatus.loading),
      stream: states.stream,
    );
    await open(tester, settle: false);
    expect(find.text('Loading engines…'), findsOneWidget);

    states.add(_ready);
    await tester.pumpAndSettle();

    expect(_byKey('quick_improve_diff'), findsOneWidget);
  });

  testWidgets('reloads engines that failed to load', (tester) async {
    final states = StreamController<TranslateState>();
    addTearDown(states.close);
    stubTranslate(
      const TranslateState(enginesStatus: EnginesStatus.failure),
      stream: states.stream,
    );
    await open(tester);

    await tester.tap(_byKey('quick_improve_reload_engines'));
    verify(() => translate.loadEngines(refresh: true)).called(1);

    // Only the status changes while the list loads again.
    states.add(const TranslateState(enginesStatus: EnginesStatus.loading));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Loading engines…'), findsOneWidget);

    states.add(_ready);
    await tester.pumpAndSettle();
    expect(_byKey('quick_improve_diff'), findsOneWidget);
  });

  testWidgets('uses the quick translate window of the app by default', (
    tester,
  ) async {
    stubTranslate(_ready);
    await tester.pumpImprove(
      RepositoryProvider<TranslationRepository>.value(
        value: repository,
        child: MultiBlocProvider(
          providers: [
            BlocProvider<TranslateCubit>.value(value: translate),
            BlocProvider<SettingsCubit>.value(value: settings),
          ],
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () => showQuickImprove(context, text: sentence),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(_byKey('quick_improve_close'));
    await tester.pumpAndSettle();

    // Not in the window (a test runs at `/`): nothing to close.
    expect(calls, isEmpty);
  });

  testWidgets('the sheet offers on-device AI where a model fits', (
    tester,
  ) async {
    final opened = <String>[];
    stubTranslate(const TranslateState(enginesStatus: EnginesStatus.ready));
    await tester.pumpImprove(
      RepositoryProvider<TranslationRepository>.value(
        value: repository,
        child: BlocProvider<TranslateCubit>.value(
          value: translate,
          child: QuickImproveSheet(
            text: sentence,
            offerOnDeviceAi: true,
            onOpenSettings: opened.add,
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(_byKey('quick_improve_set_up_on_device_ai'));
    await tester.tap(_byKey('quick_improve_add_provider'));

    expect(opened, [AppRoutes.onDeviceAi, AppRoutes.providers]);
  });

  testWidgets('counts the usage of a provider', (tester) async {
    final usage = MockUsageTracker();
    when(
      () => usage.recordText(
        any(),
        input: any(named: 'input'),
        output: any(named: 'output'),
      ),
    ).thenAnswer((_) async => UsageStats.zero);
    stubTranslate(
      const TranslateState(
        enginesStatus: EnginesStatus.ready,
        engines: [claude],
      ),
    );
    await open(tester, usage: usage);

    verify(
      () => usage.recordText(
        'claude',
        input: sentence,
        output: any(named: 'output'),
      ),
    ).called(1);
  });

  group('without an AI engine', () {
    const none = TranslateState(
      enginesStatus: EnginesStatus.ready,
      engines: [google],
      engine: google,
    );

    testWidgets('the AI providers open above the app', (tester) async {
      final router = _MockGoRouter();
      when(() => router.push<void>(any())).thenAnswer((_) async {});
      stubTranslate(none);
      await open(tester, router: router);

      expect(find.text('Proofreading needs an AI provider'), findsOneWidget);
      await tester.tap(_byKey('quick_improve_add_provider'));
      await tester.pumpAndSettle();

      verify(() => router.push<void>(AppRoutes.providers)).called(1);
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('no button without a router', (tester) async {
      stubTranslate(none);
      await open(tester);

      expect(_byKey('quick_improve_add_provider'), findsNothing);
    });

    testWidgets('in the quick translate window they open in the main one', (
      tester,
    ) async {
      final window = QuickTranslateHost(
        initialRoute: () => QuickTranslateHost.location,
      );
      stubTranslate(none);
      await open(tester, window: window);

      await tester.tap(_byKey('quick_improve_add_provider'));
      await tester.pumpAndSettle();

      expect(calls.map((call) => call.method), ['openInApp', 'close']);
      expect(calls.first.arguments, {'location': AppRoutes.providers});
    });
  });

  testWidgets('closing the sheet closes the quick translate window', (
    tester,
  ) async {
    final window = QuickTranslateHost(
      initialRoute: () => QuickTranslateHost.location,
    );
    stubTranslate(_ready);
    await open(tester, window: window);

    await tester.tap(_byKey('quick_improve_close'));
    await tester.pumpAndSettle();

    expect(calls.map((call) => call.method), ['close']);
  });

  test("sends the edits' explanations in the UI language", () {
    expect(quickImproveUiLanguage(const Locale('en', 'GB')), 'English');
    expect(quickImproveUiLanguage(const Locale('de')), 'German');
    expect(quickImproveUiLanguage(const Locale('xx')), 'English');
  });
}
