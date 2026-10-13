import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/onboarding/onboarding.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';

import '../helpers.dart';

void main() {
  setUpAll(registerOnboardingFallbacks);

  late MockTranslationRepository repository;
  late SettingsCubit settings;
  late MockGoRouter router;

  setUp(() {
    repository = MockTranslationRepository();
    settings = createSettings();
    router = MockGoRouter();
    when(() => repository.pingInstance(any()))
        .thenAnswer((_) async => const Duration(milliseconds: 100));
  });

  tearDown(() => settings.close());

  Future<void> pumpPage(
    WidgetTester tester, {
    Widget? page,
    Size size = const Size(420, 900),
  }) async {
    tester.setScreenSize(size);
    await tester.pumpOnboarding(
      page ?? const OnboardingPage(),
      settings: settings,
      repository: repository,
      router: router,
      scaffold: false,
    );
  }

  Future<void> tapNext(WidgetTester tester) async {
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
  }

  group('OnboardingPage', () {
    testWidgets('starts with the welcome step', (tester) async {
      await pumpPage(tester);
      expect(find.byType(WelcomeStep), findsOneWidget);
      expect(find.text('Skip'), findsOneWidget);
      expect(find.text('Back'), findsNothing);
    });

    testWidgets('walks through all steps', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpPage(tester);

      await tapNext(tester);
      expect(find.byType(ServiceStep), findsOneWidget);
      expect(find.bySemanticsLabel('Step 2 of 4'), findsOneWidget);

      await tapNext(tester);
      expect(find.byType(AiStep), findsOneWidget);

      await tapNext(tester);
      expect(find.byType(DoneStep), findsOneWidget);
      expect(find.text('Skip'), findsNothing);
      expect(find.text('Next'), findsNothing);

      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      expect(find.byType(AiStep), findsOneWidget);
      handle.dispose();
    });

    testWidgets('Start translating completes onboarding', (tester) async {
      await pumpPage(tester);
      for (var i = 0; i < 3; i++) {
        await tapNext(tester);
      }
      await tester.tap(find.text('Start translating'));
      expect(settings.state.onboardingComplete, isTrue);
      verify(() => router.go('/translate')).called(1);
    });

    testWidgets('Skip completes onboarding right away', (tester) async {
      await pumpPage(tester, page: const OnboardingPage(finishLocation: '/x'));
      await tester.tap(find.text('Skip'));
      expect(settings.state.onboardingComplete, isTrue);
      verify(() => router.go('/x')).called(1);
    });

    testWidgets('system back returns to the previous step', (tester) async {
      await pumpPage(tester);
      await tapNext(tester);
      await tapNext(tester);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ServiceStep), findsOneWidget);
    });

    testWidgets('finds the fastest instance end to end', (tester) async {
      when(() => repository.pingInstance(instanceC))
          .thenAnswer((_) async => const Duration(milliseconds: 20));
      await pumpPage(tester);
      await tapNext(tester);

      await tester.tap(find.text('Find the fastest public instance'));
      await tester.pumpAndSettle();

      expect(find.text('Fastest'), findsOneWidget);
      expect(urlsOf(settings).first, instanceC.url);
    });

    testWidgets('keeps form input when moving between steps', (tester) async {
      await pumpPage(tester, size: const Size(420, 2400));
      await tapNext(tester);
      await tester.enterText(find.byType(TextField), 'my.instance');
      await tapNext(tester);
      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      expect(find.text('my.instance'), findsOneWidget);
    });

    testWidgets('jumps between steps when animations are disabled', (
      tester,
    ) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await pumpPage(tester);

      await tester.tap(find.text('Next'));
      await tester.pump();
      expect(find.byType(ServiceStep), findsOneWidget);
      expect(find.byType(WelcomeStep), findsNothing);
    });

    testWidgets('saves an AI provider from the AI step', (tester) async {
      when(() => repository.testProvider(any()))
          .thenAnswer((_) async => 'Bonjour !');
      await pumpPage(tester, size: const Size(420, 1600));
      await tapNext(tester);
      await tapNext(tester);

      await tester.tap(find.text('Ollama'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Test'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Test'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Bonjour !'), findsOneWidget);

      await tester.ensureVisible(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(settings.state.providers.single.presetId, 'ollama');

      await tapNext(tester);
      expect(find.textContaining('Ollama · gemma3'), findsOneWidget);
    });
  });
}
