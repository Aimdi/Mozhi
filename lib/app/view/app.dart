import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/app_dependencies.dart';
import 'package:mozhi/app/router.dart';
import 'package:mozhi/app/shared_text_handler.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/app/translate_link.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/platform/shared_text_service.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/data/settings_repository.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

/// Root widget: provides the [AppDependencies] and the app-wide cubits,
/// keeps the [TranslationRepository] in sync with the settings and routes
/// text shared by the OS to the translate screen.
class App extends StatefulWidget {
  const new({required this.dependencies, super.key});

  final AppDependencies dependencies;

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  late final SettingsCubit _settingsCubit;
  late final HistoryCubit _historyCubit;
  late final TranslateCubit _translateCubit;
  late final GoRouter _router;
  late final SharedTextHandler _sharedText;
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();

  AppDependencies get _deps => widget.dependencies;

  @override
  void initState() {
    super.initState();
    _settingsCubit = SettingsCubit(
      repository: _deps.settingsRepository,
      initial: _deps.settings,
    );
    _historyCubit = HistoryCubit(repository: _deps.historyRepository);
    unawaited(_historyCubit.load());
    _translateCubit = TranslateCubit(
      repository: _deps.translationRepository,
      settings: _settingsCubit,
      history: _historyCubit,
    );
    unawaited(_translateCubit.loadEngines());
    _router = createAppRouter(onTranslateLink: _openLink);

    // coverage:ignore-start
    if (kIsWeb) {
      // `https://host/Mozhi/?text=…` (query before the `#/` fragment).
      final link = TranslateLink.fromUri(Uri.base);
      if (link != null) _openLink(link);
    }
    // coverage:ignore-end

    _sharedText = SharedTextHandler(
      service: _deps.sharedTextService,
      translateCubit: _translateCubit,
      onShowTranslate: () => _router.go(AppRoutes.translate),
      onReplaceAvailable: _offerReplace,
    );
    unawaited(_sharedText.start());
  }

  @override
  void dispose() {
    unawaited(_sharedText.dispose());
    _router.dispose();
    unawaited(_translateCubit.close());
    unawaited(_historyCubit.close());
    unawaited(_settingsCubit.close());
    super.dispose();
  }

  void _openLink(TranslateLink link) {
    unawaited(link.applyTo(_translateCubit));
  }

  /// Text selected in another (editable) app was translated: offer to put
  /// the translation back in its place.
  void _offerReplace() {
    final messenger = _messengerKey.currentState;
    if (messenger == null) return;
    final l10n = messenger.context.l10n;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(l10n.appProcessTextReady),
          showCloseIcon: true,
          action: SnackBarAction(
            label: l10n.appProcessTextReplace,
            onPressed: () => unawaited(_sharedText.replaceSelection()),
          ),
        ),
      );
  }

  // ---------------------------------------------------------------------

  void _applyEngineConfiguration(AppSettings settings) {
    _deps.translationRepository.updateConfiguration(
      instances: settings.instances,
      providers: settings.providers,
    );
    unawaited(_translateCubit.loadEngines(refresh: true));
  }

  @override
  Widget build(BuildContext context) {
    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider<TranslationRepository>.value(
          value: _deps.translationRepository,
        ),
        RepositoryProvider<SettingsRepository>.value(
          value: _deps.settingsRepository,
        ),
        RepositoryProvider<HistoryRepository>.value(
          value: _deps.historyRepository,
        ),
        RepositoryProvider<SpeechService>.value(value: _deps.speechService),
        RepositoryProvider<SharedTextService>.value(
          value: _deps.sharedTextService,
        ),
      ],
      child: MultiBlocProvider(
        providers: [
          BlocProvider<SettingsCubit>.value(value: _settingsCubit),
          BlocProvider<HistoryCubit>.value(value: _historyCubit),
          BlocProvider<TranslateCubit>.value(value: _translateCubit),
        ],
        child: BlocListener<SettingsCubit, AppSettings>(
          listenWhen: engineConfigurationChanged,
          listener: (context, settings) => _applyEngineConfiguration(settings),
          child: BlocBuilder<SettingsCubit, AppSettings>(
            buildWhen: appearanceChanged,
            builder: (context, settings) => DynamicColorBuilder(
              builder: (lightDynamic, darkDynamic) {
                final themes = AppThemes.fromSettings(
                  settings,
                  lightDynamic: lightDynamic,
                  darkDynamic: darkDynamic,
                );
                return MaterialApp.router(
                  onGenerateTitle: (context) => context.l10n.appTitle,
                  debugShowCheckedModeBanner: false,
                  scaffoldMessengerKey: _messengerKey,
                  theme: themes.light,
                  darkTheme: themes.dark,
                  themeMode: settings.themeMode,
                  localizationsDelegates: appLocalizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  routerConfig: _router,
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Whether [current] changes what the [TranslationRepository] needs to
/// know (instances, their order, or AI providers).
bool engineConfigurationChanged(AppSettings previous, AppSettings current) {
  bool sameInstance(MozhiInstance a, MozhiInstance b) =>
      a.url == b.url && a.label == b.label;
  bool sameProvider(AiProviderConfig a, AiProviderConfig b) =>
      a == b && a.presetId == b.presetId && mapEquals(a.headers, b.headers);
  bool sameList<T>(List<T> a, List<T> b, bool Function(T, T) same) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!same(a[i], b[i])) return false;
    }
    return true;
  }

  return !sameList(previous.instances, current.instances, sameInstance) ||
      !sameList(previous.providers, current.providers, sameProvider);
}

/// Whether [current] changes how the app looks.
bool appearanceChanged(AppSettings previous, AppSettings current) =>
    previous.themeMode != current.themeMode ||
    previous.dynamicColor != current.dynamicColor ||
    previous.pureBlack != current.pureBlack ||
    previous.seedColor != current.seedColor;
