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
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/onboarding/onboarding_redirect.dart';
import 'package:mozhi/platform/shared_text_service.dart';
import 'package:mozhi/presets/view/presets_providers.dart';
import 'package:mozhi/quick_translate/view/quick_translate_sheet.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/data/settings_repository.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/usage/data/usage_tracker.dart';
import 'package:mozhi/usage/widgets/usage_warning_listener.dart';
import 'package:mozhi/voice/speech_input_service.dart';
import 'package:translation_repository/translation_repository.dart';

/// Root widget: provides the [AppDependencies] and the app-wide cubits,
/// keeps the [TranslationRepository] in sync with the settings, shows the
/// first-run onboarding and routes text shared by the OS (quick translate
/// for selections in other apps, the translate tab otherwise).
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
  final _navigatorKey = GlobalKey<NavigatorState>(debugLabel: 'root');
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
    unawaited(_deps.usageTracker.load().then<void>((_) {}, onError: (_) {}));

    // `https://host/Mozhi/app/?text=…` (query before the `#/` fragment).
    final webLink = kIsWeb ? TranslateLink.fromUri(Uri.base) : null;
    _router = createAppRouter(
      navigatorKey: _navigatorKey,
      onTranslateLink: _openLink,
      // A link must open what it links to, not the onboarding.
      launchRedirect: (location) => webLink != null
          ? null
          : onboardingRedirect(_settingsCubit.state, location),
    );
    if (webLink != null) _openLink(webLink); // coverage:ignore-line

    _sharedText = SharedTextHandler(
      service: _deps.sharedTextService,
      translateCubit: _translateCubit,
      onShowTranslate: () => _router.go(AppRoutes.translate),
      onQuickTranslate: (request) => unawaited(_showQuickTranslate(request)),
    );
    unawaited(_sharedText.start());
    WidgetsBinding.instance.addPostFrameCallback((_) => _warnSecretsInMemory());
  }

  @override
  void dispose() {
    unawaited(_sharedText.dispose());
    _router.dispose();
    unawaited(_translateCubit.close());
    unawaited(_historyCubit.close());
    unawaited(_settingsCubit.close());
    unawaited(_deps.speechInputService.dispose());
    unawaited(_deps.speechService.dispose());
    unawaited(_deps.usageTracker.dispose());
    unawaited(_deps.offlineTranslator.dispose());
    super.dispose();
  }

  void _openLink(TranslateLink link) {
    unawaited(link.applyTo(_translateCubit));
  }

  /// Text selected in another app: the quick translate sheet (dialog on
  /// wide windows) above whatever is shown.
  Future<void> _showQuickTranslate(QuickTranslateRequest request) async {
    var context = _navigatorKey.currentContext;
    if (context == null) {
      // Launched with the selection: wait for the first frame.
      await WidgetsBinding.instance.endOfFrame;
      context = _navigatorKey.currentContext;
    }
    if (!mounted || context == null || !context.mounted) {
      request.onOpenInApp(); // coverage:ignore-line
      return; // coverage:ignore-line
    }
    await showQuickTranslate(
      context,
      text: request.text,
      canReplace: request.canReplace,
      onReplace: request.onReplace,
      onOpenInApp: request.onOpenInApp,
    );
  }

  /// Secure storage is unavailable (no keyring, insecure web context, ...):
  /// say once that API keys only last for this session.
  void _warnSecretsInMemory() {
    if (!mounted || !_deps.secretsInMemory) return;
    final messenger = _messengerKey.currentState;
    if (messenger == null) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(messenger.context.l10n.appSecureStorageUnavailable),
        showCloseIcon: true,
        duration: const Duration(seconds: 10),
      ),
    );
  }

  String? _providerName(String providerId) {
    for (final provider in _settingsCubit.state.providers) {
      if (provider.id == providerId) return provider.name;
    }
    return null;
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
        RepositoryProvider<SpeechInputService>.value(
          value: _deps.speechInputService,
        ),
        RepositoryProvider<OfflineTranslator>.value(
          value: _deps.offlineTranslator,
        ),
        RepositoryProvider<UsageTracker>.value(value: _deps.usageTracker),
        // Preferences only: secrets are never handed to the widget tree.
        RepositoryProvider<KeyValueStore>.value(value: _deps.preferences),
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
        child: PresetsProviders(
          store: _deps.preferences,
          child: BlocListener<SettingsCubit, AppSettings>(
            listenWhen: engineConfigurationChanged,
            listener: (context, settings) =>
                _applyEngineConfiguration(settings),
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
                    builder: null ?? (context, child) => child ?? UsageWarningListener(
                      tracker: _deps.usageTracker,
                      messengerKey: _messengerKey,
                      providerName: _providerName,
                      child: child ?? const SizedBox.shrink(),
                    ),
                  );
                },
              ),
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
