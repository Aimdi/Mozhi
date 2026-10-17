import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/offline/widgets/offline_language_tile.dart';
import 'package:mozhi/onboarding/onboarding.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers.dart';

class _MockTranslateCubit extends MockCubit<TranslateState>
    implements TranslateCubit;

const _french = Language(code: 'fr', name: 'French', nativeName: 'Français');

void main() {
  setUpAll(registerOnboardingFallbacks);

  late MockTranslationRepository repository;
  late SettingsCubit settings;
  late MockGoRouter router;
  late FakeOfflineTranslator offline;

  setUp(() {
    repository = MockTranslationRepository();
    settings = createSettings();
    router = MockGoRouter();
    offline = FakeOfflineTranslator();
    when(() => repository.pingInstance(any()))
        .thenAnswer((_) async => const Duration(milliseconds: 100));
  });

  tearDown(() => settings.close());

  Future<void> pumpPage(
    WidgetTester tester, {
    Widget? page,
    Size size = const Size(420, 900),
    double textScale = 1,
    ThemeData? theme,
    Widget Function(Widget page)? wrap,
  }) async {
    tester.setScreenSize(size);
    final onboarding =
        page ??
        OnboardingPage(
          translator: offline,
          store: MemoryStore(),
          details: FakeModelDetails(offline),
        );
    await tester.pumpOnboarding(
      wrap?.call(onboarding) ?? onboarding,
      settings: settings,
      repository: repository,
      router: router,
      scaffold: false,
      textScale: textScale,
      theme: theme,
    );
  }

  Finder scrollableOf(Type step) => find
      .descendant(of: find.byType(step), matching: find.byType(Scrollable))
      .first;

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
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

    testWidgets('has at most three steps after the welcome', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpPage(tester);
      expect(OnboardingStep.values, hasLength(4));

      await tapNext(tester);
      expect(find.byType(PrivacyStep), findsOneWidget);
      expect(find.bySemanticsLabel('Step 2 of 4'), findsOneWidget);

      await tapNext(tester);
      expect(find.byType(LanguagesStep), findsOneWidget);
      expect(find.bySemanticsLabel('Step 3 of 4'), findsOneWidget);

      await tapNext(tester);
      expect(find.byType(ServiceStep), findsOneWidget);
      expect(find.bySemanticsLabel('Step 4 of 4'), findsOneWidget);
      // The last step: no Skip or Next, and no AI provider step.
      expect(find.text('Skip'), findsNothing);
      expect(find.text('Next'), findsNothing);
      expect(find.text('Start translating'), findsOneWidget);

      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      expect(find.byType(LanguagesStep), findsOneWidget);
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

    testWidgets('asks how private translations should be', (tester) async {
      await pumpPage(tester);
      await tapNext(tester);
      expect(find.text('How private should translations be?'), findsOneWidget);
      expect(find.text('Offline first (recommended)'), findsOneWidget);
      expect(settings.state.privacyMode, PrivacyMode.offlineFirst);

      await tapVisible(tester, find.text('Online'));
      expect(settings.state.privacyMode, PrivacyMode.online);
      await tapVisible(tester, find.text('Offline only'));
      expect(settings.state.privacyMode, PrivacyMode.offlineOnly);
    });

    testWidgets('Skip completes onboarding right away', (tester) async {
      await pumpPage(tester, page: const OnboardingPage(finishLocation: '/x'));
      await tester.tap(find.text('Skip'));
      expect(settings.state.onboardingComplete, isTrue);
      verify(() => router.go('/x')).called(1);
    });

    testWidgets('Skip works from the languages step', (tester) async {
      await pumpPage(tester);
      await tapNext(tester);
      await tapNext(tester);
      await tester.tap(find.text('Skip'));
      expect(settings.state.onboardingComplete, isTrue);
      verify(() => router.go('/translate')).called(1);
    });

    testWidgets('system back returns to the previous step', (tester) async {
      await pumpPage(tester);
      await tapNext(tester);
      await tapNext(tester);
      await tapNext(tester);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(LanguagesStep), findsOneWidget);
    });

    testWidgets('picks the default languages', (tester) async {
      await pumpPage(tester, size: const Size(420, 1400));
      await tapNext(tester);
      await tapNext(tester);

      await tester.tap(find.byKey(const Key('onboarding_target_language')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('onboarding_language_search')),
        'franç',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('French'));
      await tester.pumpAndSettle();
      expect(settings.state.target.code, 'fr');

      await tester.tap(find.byKey(const Key('onboarding_source_language')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('onboarding_language_search')),
        'germ',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('German'));
      await tester.pumpAndSettle();
      expect(settings.state.source.code, 'de');

      // Both can be downloaded for offline use.
      expect(
        find.byKey(const ValueKey('onboarding_offline_de')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('onboarding_offline_fr')),
        findsOneWidget,
      );
    });

    testWidgets('sends the languages through the translator when there is '
        'one', (tester) async {
      final translate = _MockTranslateCubit();
      when(() => translate.state).thenReturn(const TranslateState());
      await pumpPage(
        tester,
        size: const Size(420, 1400),
        wrap: (page) =>
            BlocProvider<TranslateCubit>.value(value: translate, child: page),
      );
      await tapNext(tester);
      await tapNext(tester);

      await tester.tap(find.byKey(const Key('onboarding_target_language')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('onboarding_language_search')),
        'fren',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('French'));
      await tester.pumpAndSettle();
      verify(
        () => translate.setTarget(
          any(that: isA<Language>().having((l) => l.code, 'code', 'fr')),
        ),
      ).called(1);

      await tester.tap(find.byKey(const Key('onboarding_source_language')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('onboarding_language_search')),
        'span',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Spanish'));
      await tester.pumpAndSettle();
      verify(
        () => translate.setSource(
          any(that: isA<Language>().having((l) => l.code, 'code', 'es')),
        ),
      ).called(1);
    });

    testWidgets('downloads a picked language with its size', (tester) async {
      settings.setLanguages(target: _french);
      await pumpPage(tester, size: const Size(420, 1400));
      await tapNext(tester);
      await tapNext(tester);

      final tile = find.byKey(const ValueKey('onboarding_offline_fr'));
      expect(
        find.descendant(
          of: tile,
          matching: find.text('Français · 40.0 MB download'),
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(of: tile, matching: find.text('Download')),
      );
      await tester.pumpAndSettle();
      expect(offline.downloads, [('fr', true)]);
      expect(
        find.descendant(
          of: tile,
          matching: find.text('Français · 40.0 MB on this device'),
        ),
        findsOneWidget,
      );
      expect(find.text('French is ready for offline use'), findsOneWidget);
    });

    testWidgets('says that the browser cannot translate offline', (
      tester,
    ) async {
      offline = FakeOfflineTranslator(isAvailable: false);
      await pumpPage(tester);
      await tapNext(tester);
      await tapNext(tester);
      expect(find.textContaining('can’t translate on its own'), findsOneWidget);
      expect(find.byType(OfflineLanguageTile), findsNothing);
    });

    testWidgets('finds the fastest instance end to end', (tester) async {
      when(() => repository.pingInstance(instanceC))
          .thenAnswer((_) async => const Duration(milliseconds: 20));
      await pumpPage(tester);
      await tapNext(tester);
      await tapNext(tester);
      await tapNext(tester);

      await tapVisible(tester, find.text('Find the fastest public instance'));

      expect(find.text('Fastest'), findsOneWidget);
      expect(urlsOf(settings).first, instanceC.url);
    });

    testWidgets('links to the AI provider settings', (tester) async {
      await pumpPage(tester, size: const Size(420, 2400));
      for (var i = 0; i < 3; i++) {
        await tapNext(tester);
      }
      expect(
        find.text(
          'AI translators are optional. You can add one later in '
          'Settings › AI providers.',
        ),
        findsOneWidget,
      );
      await tapVisible(tester, find.text('Open AI provider settings'));
      expect(settings.state.onboardingComplete, isTrue);
      verify(() => router.go('/settings/providers')).called(1);
    });

    testWidgets('keeps form input when moving between steps', (tester) async {
      await pumpPage(tester, size: const Size(420, 2400));
      await tapNext(tester);
      await tapNext(tester);
      await tapNext(tester);
      await tester.enterText(find.byType(TextField), 'my.instance');
      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      await tapNext(tester);
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
      expect(find.byType(PrivacyStep), findsOneWidget);
      expect(find.byType(WelcomeStep), findsNothing);
    });

    testWidgets('fits small phones with large text in dark mode', (
      tester,
    ) async {
      when(() => repository.pingInstance(instanceB))
          .thenAnswer((_) async => throw const MozhiApiException('down'));
      settings.setLanguages(target: _french);
      await pumpPage(
        tester,
        size: const Size(320, 640),
        textScale: 2,
        theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      );

      Future<void> reveal(Finder finder, Type step) async {
        await tester.scrollUntilVisible(
          finder,
          200,
          scrollable: scrollableOf(step),
        );
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
      }

      await tapNext(tester);
      await tapNext(tester);
      await reveal(find.text('Download over Wi-Fi only'), LanguagesStep);
      await tapNext(tester);
      final findFastest = find.text('Find the fastest public instance');
      await reveal(findFastest, ServiceStep);
      await tester.tap(findFastest);
      await tester.pumpAndSettle();
      await reveal(find.text('Unreachable'), ServiceStep);
      expect(find.text('Unreachable'), findsOneWidget);
      await reveal(find.text('Test & add'), ServiceStep);
      await reveal(find.text('Open AI provider settings'), ServiceStep);
      expect(tester.takeException(), isNull);
    });
  });

  group('accessibility at 200% text on a 360dp phone', () {
    const phone = Size(360, 760);

    for (final step in OnboardingStep.values) {
      testWidgets('the ${step.name} step fits and meets the tap target '
          'guidelines', (tester) async {
        final handle = tester.ensureSemantics();
        settings.setLanguages(target: _french);
        await pumpPage(tester, size: phone, textScale: 2);
        for (var i = 0; i < step.index; i++) {
          await tapNext(tester);
        }
        expect(tester.takeException(), isNull);

        // Scroll through the whole step: nothing overflows, and every
        // target on screen is large enough and labelled.
        final scrollable = find
            .descendant(
              of: find.byType(PageView),
              matching: find.byType(Scrollable),
            )
            .last;
        for (var i = 0; i < 40; i++) {
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
          final position = tester.state<ScrollableState>(scrollable).position;
          if (position.pixels >= position.maxScrollExtent) break;
          await tester.drag(scrollable, const Offset(0, -300));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        handle.dispose();
      });
    }
  });
}
