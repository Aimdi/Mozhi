import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/cubit/offline_models_cubit.dart';
import 'package:mozhi/offline/data/offline_model_details.dart';
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
  return cubit;
}

void registerOnboardingFallbacks() {
  registerFallbackValue(instanceA);
  registerFallbackValue(Language.auto);
}

/// An on-device engine with English (built in), German, French and
/// Spanish; [downloaded] languages are on the device.
class FakeOfflineTranslator implements OfflineTranslator {
  new({this.isAvailable = true, Set<String>? downloaded, this.failWith})
    : downloaded = downloaded ?? {'en'};

  @override
  final bool isAvailable;

  final Set<String> downloaded;

  /// Thrown by [downloadLanguage] when set.
  Exception? failWith;

  /// The `wifiOnly` of every [downloadLanguage] call, by language.
  final List<(String, bool)> downloads = [];

  /// Completes a download when set (otherwise downloads finish at once).
  Completer<void>? gate;

  @override
  Set<String> get supportedLanguages => const {'en', 'de', 'fr', 'es'};

  @override
  Future<Set<String>> downloadedLanguages() async => {...downloaded};

  @override
  Future<void> downloadLanguage(String code, {bool wifiOnly = true}) async {
    downloads.add((code, wifiOnly));
    await gate?.future;
    if (failWith case final error?) {
      failWith = null;
      throw error;
    }
    downloaded.add(code);
  }

  @override
  Future<void> deleteLanguage(String code) async => downloaded.remove(code);

  @override
  Future<String> translate(
    String text, {
    required String source,
    required String target,
  }) async => text;

  @override
  Future<String?> identifyLanguage(String text) async => null;

  @override
  Future<void> dispose() async {}
}

/// [OfflineModelDetails] of a [FakeOfflineTranslator]: 0 bytes for English,
/// 40 MiB for the others.
class FakeModelDetails implements OfflineModelDetails {
  new(this.translator);

  final FakeOfflineTranslator translator;

  static const int size = 40 * 1024 * 1024;

  @override
  int downloadSize(String code) => code == 'en' ? 0 : size;

  @override
  Future<OfflineStorage> storage(Iterable<String> codes) async =>
      OfflineStorage(
        installedBytes: {
          for (final code in translator.downloaded)
            if (code != 'en') code: size,
        },
      );

  @override
  Future<void> download(
    String code, {
    required bool wifiOnly,
    void Function(double fraction)? onProgress,
  }) async {
    onProgress?.call(0.5);
    await translator.downloadLanguage(code, wifiOnly: wifiOnly);
  }
}

/// A loaded [OfflineModelsCubit] over [translator] (default: a
/// [FakeOfflineTranslator] with sizes).
Future<OfflineModelsCubit> createOfflineModels([
  FakeOfflineTranslator? translator,
]) async {
  final engine = translator ?? FakeOfflineTranslator();
  final cubit = OfflineModelsCubit(
    translator: engine,
    store: MemoryStore(),
    details: FakeModelDetails(engine),
  );
  await cubit.load();
  return cubit;
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
    OfflineModelsCubit? offline,
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
            if (offline != null)
              BlocProvider<OfflineModelsCubit>.value(value: offline),
          ],
          child: InheritedGoRouter(
            goRouter: router ?? MockGoRouter(),
            child: MaterialApp(
              theme: theme ?? ThemeData(useMaterial3: true),
              localizationsDelegates: appLocalizationsDelegates,
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
