import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

class MockSettingsCubit extends MockCubit<AppSettings> implements SettingsCubit;

class MockHistoryCubit extends MockCubit<HistoryState> implements HistoryCubit;

class MockTranslateCubit extends MockCubit<TranslateState>
    implements TranslateCubit;

class MockTranslationRepository extends Mock implements TranslationRepository;

class MockGoRouter extends Mock implements GoRouter;

/// A [MockGoRouter] whose navigation calls succeed.
MockGoRouter createRouter() {
  final router = MockGoRouter();
  when(() => router.push<Object?>(any(), extra: any(named: 'extra')))
      .thenAnswer((_) async => null);
  when(router.canPop).thenReturn(true);
  return router;
}

MockSettingsCubit createSettingsCubit([AppSettings? settings]) {
  final cubit = MockSettingsCubit();
  when(() => cubit.state).thenReturn(settings ?? const AppSettings());
  return cubit;
}

MockHistoryCubit createHistoryCubit([HistoryState? state]) {
  final cubit = MockHistoryCubit();
  when(() => cubit.state)
      .thenReturn(state ?? const HistoryState(status: HistoryStatus.ready));
  when(() => cubit.add(any())).thenAnswer((_) async {});
  when(() => cubit.delete(any())).thenAnswer((_) async {});
  when(() => cubit.toggleFavorite(any())).thenAnswer((_) async {});
  when(() => cubit.clear(keepFavorites: any(named: 'keepFavorites')))
      .thenAnswer((_) async {});
  when(cubit.load).thenAnswer((_) async {});
  return cubit;
}

extension PumpView on WidgetTester {
  /// Sets the logical screen size for this test.
  void setScreenSize(Size size) {
    view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(view.reset);
  }

  /// Pumps [widget] the way the app does: repositories, cubits and the
  /// router are provided above the [MaterialApp].
  Future<void> pumpView(
    Widget widget, {
    SettingsCubit? settings,
    HistoryCubit? history,
    TranslateCubit? translate,
    TranslationRepository? repository,
    GoRouter? router,
    double textScale = 1,
    ThemeData? theme,
  }) {
    return pumpWidget(
      RepositoryProvider<TranslationRepository>.value(
        value: repository ?? MockTranslationRepository(),
        child: MultiBlocProvider(
          providers: [
            BlocProvider<SettingsCubit>.value(
              value: settings ?? createSettingsCubit(),
            ),
            BlocProvider<HistoryCubit>.value(
              value: history ?? createHistoryCubit(),
            ),
            BlocProvider<TranslateCubit>.value(
              value: translate ?? MockTranslateCubit(),
            ),
          ],
          child: InheritedGoRouter(
            goRouter: router ?? createRouter(),
            child: MaterialApp(
              theme: theme ?? ThemeData(useMaterial3: true),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(textScale)),
                child: child!,
              ),
              home: widget,
            ),
          ),
        ),
      ),
    );
  }
}

/// Registers mocktail fallback values for the types used with `any()`.
void registerFallbacks() {
  registerFallbackValue(ThemeMode.system);
  registerFallbackValue(const MozhiInstance(url: 'https://fallback.test'));
  registerFallbackValue(
    const AiProviderConfig(
      id: 'fallback',
      name: 'Fallback',
      provider: LlmProvider.openAiCompatible,
      baseUrl: 'https://fallback.test',
      model: 'm',
    ),
  );
  registerFallbackValue(Language.auto);
  registerFallbackValue(
    HistoryEntry(
      id: 'fallback',
      text: '',
      translation: '',
      source: Language.auto,
      target: Language.auto,
      engineId: '',
      engineName: '',
      createdAt: DateTime(2026),
    ),
  );
}
