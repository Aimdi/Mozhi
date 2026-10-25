import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/app.dart';
import 'package:mozhi/app_lock/app_lock.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/history/view/history_page.dart';
import 'package:mozhi/platform/shared_text_service.dart';
import 'package:mozhi/quick_translate/quick_translate_host.dart';
import 'package:mozhi/quick_translate/view/quick_translate_sheet.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/view/translate_page.dart';
import 'package:translation_repository/translation_repository.dart';

import '../app/mocks.dart';
import 'helpers/fake_app_lock_platform.dart';

/// The app lock in the whole app: the gate above the router, the setting
/// applied to the lock, and text selected in another app waiting for the
/// unlock.
void main() {
  setUpAll(() {
    registerAppFallbacks();
    registerFallbackValue(const AppSettings());
    registerFallbackValue(
      HistoryEntry(
        id: 'h',
        text: '',
        translation: '',
        source: Language.auto,
        target: Language.auto,
        engineId: '',
        engineName: '',
        createdAt: DateTime(2026),
      ),
    );
  });

  late TestEnvironment env;
  late FakeAppLockPlatform platform;
  late StreamController<SharedText> sharedTexts;

  setUp(() {
    env = TestEnvironment();
    platform = FakeAppLockPlatform();
    sharedTexts = StreamController<SharedText>.broadcast();
    when(() => env.sharedTextService.texts)
        .thenAnswer((_) => sharedTexts.stream);
    when(() => env.settingsRepository.save(any())).thenAnswer((_) async {});
    when(env.historyRepository.load).thenAnswer((_) async => const []);
    when(
      () => env.translationRepository.updateConfiguration(
        instances: any(named: 'instances'),
        providers: any(named: 'providers'),
      ),
    ).thenReturn(null);
    when(() => env.translationRepository.translate(any(), any())).thenAnswer(
      (_) => Stream.value(
        const TranslationResult(
          engineId: 'mozhi:google',
          engineName: 'Google',
          text: 'hello',
        ),
      ),
    );
  });

  tearDown(() => sharedTexts.close());

  Future<AppLockController> pumpApp(
    WidgetTester tester, {
    AppLockTimeout timeout = AppLockTimeout.immediately,
  }) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = AppSettings(
      instances: const [testInstance],
      onboardingComplete: true,
      appLock: timeout,
    );
    final lock = AppLockController(platform: platform, timeout: timeout);
    await tester.pumpWidget(
      App(
        dependencies: AppDependencies(
          translationRepository: env.translationRepository,
          settingsRepository: env.settingsRepository,
          historyRepository: env.historyRepository,
          speechService: env.speechService,
          sharedTextService: env.sharedTextService,
          settings: settings,
          preferences: env.preferences,
          secrets: env.secrets,
          speechInputService: env.speechInputService,
          offlineTranslator: env.offlineTranslator,
          usageTracker: env.usageTracker,
          appLock: lock,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    return lock;
  }

  testWidgets('shows only the lock screen until unlocked', (tester) async {
    platform.holdPrompt = Completer();
    await pumpApp(tester);

    expect(find.byType(AppLockScreen), findsOneWidget);
    expect(find.byType(AppShell), findsNothing);
    expect(find.byType(TranslatePage), findsNothing);
    expect(platform.prompts, hasLength(1), reason: 'prompts by itself');

    platform.holdPrompt!.complete(AppLockPromptResult.success);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(AppLockScreen), findsNothing);
    expect(find.byType(TranslatePage), findsOneWidget);
  });

  testWidgets('provides the lock to the app', (tester) async {
    final lock = await pumpApp(tester, timeout: AppLockTimeout.off);

    final context = tester.element(find.byType(TranslatePage));
    expect(context.read<AppLock>(), same(lock));
    expect(maybeAppLock(context), same(lock));
  });

  testWidgets('applies the setting to the lock', (tester) async {
    final lock = await pumpApp(tester, timeout: AppLockTimeout.off);
    final context = tester.element(find.byType(TranslatePage));

    context.read<SettingsCubit>().setAppLock(AppLockTimeout.after5Minutes);
    await tester.pump();

    expect(lock.timeout, AppLockTimeout.after5Minutes);
    expect(lock.isLocked, isFalse, reason: 'the user is here');
    expect(platform.protections, [true]);
  });

  testWidgets('waits for the unlock before it shows text selected in '
      'another app', (tester) async {
    platform.promptResult = AppLockPromptResult.cancelled;
    await pumpApp(tester);
    await tester.pump();

    sharedTexts.add(
      const SharedText('hola', readOnly: false, isProcessText: true),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(QuickTranslateSheet), findsNothing);
    expect(find.byType(AppLockScreen), findsOneWidget);
    verifyNever(() => env.translationRepository.translate(any(), any()));

    platform.promptResult = AppLockPromptResult.success;
    await tester.tap(find.byKey(AppLockScreen.unlockKey));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(QuickTranslateSheet), findsOneWidget);
    expect(find.text('hello'), findsOneWidget);
  });

  TranslateCubit translateCubit(WidgetTester tester) => tester
      .element(find.byType(TranslatePage, skipOffstage: false))
      .read<TranslateCubit>();

  Future<void> goTo(WidgetTester tester, List<AppLifecycleState> states) async {
    for (final state in states) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
    }
  }

  /// Leaves the app (it locks at once) and comes back to the lock screen.
  Future<void> lockAgain(WidgetTester tester) async {
    platform
      ..leave(Duration.zero)
      ..promptResult = AppLockPromptResult.cancelled;
    await goTo(tester, const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]);
    await tester.pump(Duration.zero);
    platform.comeBack();
    await goTo(tester, const [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]);
    await tester.pump();
    expect(find.byType(AppLockScreen), findsOneWidget);
  }

  Future<void> unlock(WidgetTester tester) async {
    platform.promptResult = AppLockPromptResult.success;
    await tester.tap(find.byKey(AppLockScreen.unlockKey));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('shared text waits for the unlock: nothing is filled in, '
      'translated or saved before', (tester) async {
    platform.promptResult = AppLockPromptResult.cancelled;
    await pumpApp(tester);
    await tester.pump();

    sharedTexts.add(const SharedText('bonjour'));
    await tester.pump(const Duration(seconds: 2));

    verifyNever(() => env.translationRepository.translate(any(), any()));
    verifyNever(() => env.historyRepository.add(any()));

    await unlock(tester);

    expect(translateCubit(tester).state.input, 'bonjour');
    verify(() => env.translationRepository.translate(any(), any())).called(1);
  });

  testWidgets('keeps the translator alive behind the lock', (tester) async {
    await pumpApp(tester);
    expect(find.byType(TranslatePage), findsOneWidget);
    translateCubit(tester).setInput('half typed');

    await lockAgain(tester);
    expect(find.byType(TranslatePage), findsNothing);
    expect(
      find.byType(TranslatePage, skipOffstage: false),
      findsOneWidget,
      reason: 'hidden, not closed',
    );

    await unlock(tester);
    expect(find.byType(TranslatePage), findsOneWidget);
    expect(translateCubit(tester).state.input, 'half typed');
  });

  testWidgets('a link that arrives while locked opens once unlocked', (
    tester,
  ) async {
    await pumpApp(tester);
    await lockAgain(tester);

    await tester.binding.handlePushRoute('/translate?text=hola');
    await tester.pump(const Duration(seconds: 2));
    expect(translateCubit(tester).state.input, isEmpty);
    verifyNever(() => env.translationRepository.translate(any(), any()));

    await unlock(tester);

    expect(translateCubit(tester).state.input, 'hola');
  });

  testWidgets('a screen asked for while locked opens once unlocked', (
    tester,
  ) async {
    await pumpApp(tester);
    await lockAgain(tester);

    await tester.binding.handlePushRoute('/history');
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(HistoryPage, skipOffstage: false), findsNothing);

    await unlock(tester);

    expect(find.byType(HistoryPage), findsOneWidget);
  });

  testWidgets('the quick translate window shows the lock card, whose '
      'Close closes the window', (tester) async {
    const channel = MethodChannel('test/quick_translate_lock');
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call.method);
      return null;
    });
    final previous = QuickTranslateHost.instance;
    QuickTranslateHost.instance = QuickTranslateHost(
      channel: channel,
      initialRoute: () => QuickTranslateHost.location,
    );
    addTearDown(() {
      QuickTranslateHost.instance = previous;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    });
    platform.promptResult = AppLockPromptResult.cancelled;
    await pumpApp(tester);
    await tester.pump();

    expect(find.byType(AppLockCompactScreen), findsOneWidget);
    await tester.tap(find.byKey(AppLockCompactScreen.closeKey));
    await tester.pump();

    expect(calls, contains('close'));
  });
}
