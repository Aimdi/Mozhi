import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/onboarding/cubit/onboarding_cubit.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/data/settings_repository.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

class MockTranslationRepository extends Mock implements TranslationRepository;

class MockOnboardingCubit extends MockCubit<OnboardingState>
    implements OnboardingCubit;

class MockGoRouter extends Mock implements GoRouter;

const instanceA = MozhiInstance(
  url: 'https://a.example',
  label: 'Alpha',
  isCustom: false,
);
const instanceB = MozhiInstance(url: 'https://b.example', isCustom: false);
const instanceC = MozhiInstance(
  url: 'https://c.example',
  label: 'Charlie',
  isCustom: false,
);
const testInstances = <MozhiInstance>[instanceA, instanceB, instanceC];

const testSettings = AppSettings(instances: testInstances);

/// A real [SettingsCubit] persisting into memory.
SettingsCubit createSettings([AppSettings settings = testSettings]) =>
    SettingsCubit(
      repository: SettingsRepository(
        prefs: MemoryStore(),
        secrets: MemoryStore(),
      ),
      initial: settings,
    );

/// Urls of the instances in [settings] (in order).
List<String> urlsOf(SettingsCubit settings) => [
  for (final instance in settings.state.instances) instance.url,
];

/// A [MockOnboardingCubit] whose state is [state] and whose async actions
/// complete immediately.
MockOnboardingCubit createOnboardingCubit([
  OnboardingState state = const OnboardingState(),
]) {
  final cubit = MockOnboardingCubit();
  when(() => cubit.state).thenReturn(state);
  when(cubit.findFastestInstance).thenAnswer((_) async {});
  when(() => cubit.addOwnInstance(any())).thenAnswer((_) async {});
  when(cubit.testProvider).thenAnswer((_) async {});
  when(cubit.loadModels).thenAnswer((_) async {});
  return cubit;
}

void registerOnboardingFallbacks() {
  registerFallbackValue(instanceA);
  registerFallbackValue(
    const AiProviderConfig(
      id: 'fallback',
      name: 'Fallback',
      provider: LlmProvider.openAiCompatible,
      baseUrl: 'https://fallback.test',
      model: 'm',
    ),
  );
}

extension PumpOnboarding on WidgetTester {
  /// Sets the logical screen size for this test.
  void setScreenSize(Size size) {
    view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(view.reset);
  }

  /// Pumps [widget] with the onboarding dependencies above a localized
  /// [MaterialApp]. Steps are wrapped in a [Scaffold] when [scaffold].
  Future<void> pumpOnboarding(
    Widget widget, {
    OnboardingCubit? onboarding,
    SettingsCubit? settings,
    TranslationRepository? repository,
    GoRouter? router,
    bool scaffold = true,
    ThemeData? theme,
    double textScale = 1,
  }) {
    final child = scaffold ? Scaffold(body: widget) : widget;
    return pumpWidget(
      RepositoryProvider<TranslationRepository>.value(
        value: repository ?? MockTranslationRepository(),
        child: MultiBlocProvider(
          providers: [
            BlocProvider<SettingsCubit>.value(
              value: settings ?? createSettings(),
            ),
            if (onboarding != null)
              BlocProvider<OnboardingCubit>.value(value: onboarding),
          ],
          child: InheritedGoRouter(
            goRouter: router ?? MockGoRouter(),
            child: MaterialApp(
              theme: theme ?? ThemeData(useMaterial3: true),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(textScale)),
                child: child!,
              ),
              home: child,
            ),
          ),
        ),
      ),
    );
  }
}
