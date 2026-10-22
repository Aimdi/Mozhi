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
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/backup/view/backup_restore_listener.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/dictionary/data/dictionary_packs.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/history/view/widgets/history_retention_listener.dart';
import 'package:mozhi/image_translate/data/lost_image_recovery.dart'
    deferred as lost_image;
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/onboarding/onboarding_redirect.dart';
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';
import 'package:mozhi/platform/android_device.dart';
import 'package:mozhi/platform/secure_screen_listener.dart';
import 'package:mozhi/platform/shared_text_service.dart';
import 'package:mozhi/platform/system_bars.dart';
import 'package:mozhi/presets/view/presets_providers.dart';
import 'package:mozhi/presets/widgets/saved_glossaries_binding.dart';
import 'package:mozhi/quick_translate/quick_translate_host.dart';
import 'package:mozhi/quick_translate/view/quick_translate_sheet.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/data/settings_repository.dart';
import 'package:mozhi/settings/models/app_languages.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/widgets/settings_save_failure_listener.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/sync/data/sync_service.dart';
import 'package:mozhi/sync/view/sync_scope.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/usage/data/usage_tracker.dart';
import 'package:mozhi/usage/widgets/usage_warning_listener.dart';
import 'package:mozhi/voice/offline/offline_speech.dart';
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
      // Without "Remember quality selection" each start begins in the
      // default quality mode.
      initial: _deps.settings.atLaunch(),
    );
    _historyCubit = HistoryCubit(
      repository: _deps.historyRepository,
      maxAge: _settingsCubit.state.historyRetention.maxAge,
      incognito: _settingsCubit.state.incognito,
      saveHistory: _settingsCubit.state.saveHistory,
    );
    // The phrasebook's Favorites collection is the history's favourites.
    _deps.phrasebookRepository?.attachFavorites(
      HistoryCubitFavorites(_historyCubit),
    );
    // Before anything can send text: the privacy settings guard every
    // request of the repository.
    _applyPrivacy(_settingsCubit.state);
    _translateCubit = TranslateCubit(
      repository: _deps.translationRepository,
      settings: _settingsCubit,
      history: _historyCubit,
      usageTracker: _deps.usageTracker,
    );
    // The engines are needed by the first screen: start right away.
    unawaited(_translateCubit.loadEngines());

    // `https://host/Mozhi/app/?text=…` (query before the `#/` fragment).
    final webLink = kIsWeb
        ? TranslateLink.fromUri(Uri.base) // coverage:ignore-line
        : null;
    _router = createAppRouter(
      navigatorKey: _navigatorKey,
      onTranslateLink: _openLink,
      // A link must open what it links to, not the onboarding (nor the
      // first tab of the user's order).
      launchRedirect: (location) => webLink != null
          ? null
          : onboardingRedirect(_settingsCubit.state, location) ??
                homeRedirect(_settingsCubit.state, location),
    );
    if (webLink != null) _openLink(webLink); // coverage:ignore-line

    _sharedText = SharedTextHandler(
      service: _deps.sharedTextService,
      translateCubit: _translateCubit,
      onShowTranslate: () => _router.go(AppRoutes.translate),
      onQuickTranslate: (request) => unawaited(_showQuickTranslate(request)),
    );
    unawaited(_sharedText.start());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadAfterFirstFrame();
      _warnSecretsInMemory();
    });
  }

  /// Reads what the first screen does not need once it is on screen: the
  /// history (decoding up to 1000 entries, tens of milliseconds) and the
  /// usage counters (they also load on first use). Both would otherwise
  /// compete with the first frame whenever the store answers quickly (web,
  /// cached preferences).
  void _loadAfterFirstFrame() {
    if (!mounted) return;
    unawaited(_historyCubit.load());
    unawaited(_deps.usageTracker.load().then<void>((_) {}, onError: (_) {}));
    unawaited(_recoverLostPhoto());
  }

  /// Android may end the app while the camera is open (it needs a lot of
  /// memory): a photo taken then opens on the image screen.
  Future<void> _recoverLostPhoto() async {
    // The quick translate window shows only its sheet: the photo is left
    // for the main window.
    if (!runsOnAndroid || QuickTranslateHost.instance.isActive) return;
    // coverage:ignore-start
    try {
      await lost_image.loadLibrary();
      if (await lost_image.LostImageRecovery.recover() && mounted) {
        unawaited(_router.push<void>(AppRoutes.image));
      }
    } on Object {
      // Nothing to continue with.
    }
    // coverage:ignore-end
  }

  @override
  void dispose() {
    unawaited(_sharedText.dispose());
    _router.dispose();
    unawaited(_translateCubit.close());
    unawaited(_historyCubit.close());
    unawaited(_settingsCubit.close());
    unawaited(_deps.speechInputService.dispose());
    unawaited(_deps.offlineSpeech?.dispose());
    unawaited(_deps.speechService.dispose());
    unawaited(_deps.usageTracker.dispose());
    unawaited(_deps.offlineTranslator.dispose());
    unawaited(_deps.backupRegistry?.dispose());
    unawaited(_deps.syncService?.dispose());
    unawaited(_deps.phrasebookRepository?.dispose());
    super.dispose();
  }

  void _openLink(TranslateLink link) {
    unawaited(link.applyTo(_translateCubit));
  }

  /// Text selected in another app: the quick translate sheet (dialog on
  /// wide windows) above whatever is shown.
  Future<void> _showQuickTranslate(QuickTranslateRequest request) async {
    var context = _navigatorKey.currentContext;
    // coverage:ignore-start
    if (context == null) {
      // Called before the first frame: wait for the navigator.
      await WidgetsBinding.instance.endOfFrame;
      context = _navigatorKey.currentContext;
    }
    if (!mounted || context == null || !context.mounted) {
      // A "Translate offline" selection never goes to the translate tab,
      // whose engines could send it over the network.
      if (!request.offlineOnly) request.onOpenInApp();
      return;
    }
    // coverage:ignore-end
    await showQuickTranslate(
      context,
      text: request.text,
      canReplace: request.canReplace,
      onReplace: request.onReplace,
      onOpenInApp: request.onOpenInApp,
      offlineOnly: request.offlineOnly,
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

  /// The privacy mode last pushed to the repository.
  PrivacyMode? _privacyMode;

  void _applyPrivacy(AppSettings settings) {
    _privacyMode = settings.privacyMode;
    _deps.translationRepository.updatePrivacy(
      mode: settings.privacyMode,
      approvedPairs: settings.networkPairs,
      consentedProviders: settings.consentedProviders,
      maskPersonalData: settings.maskPersonalData,
    );
  }

  void _onPrivacyChanged(AppSettings settings) {
    final modeChanged = settings.privacyMode != _privacyMode;
    _applyPrivacy(settings);
    // The mode decides which engine and language lists may be loaded.
    if (modeChanged) unawaited(_translateCubit.loadEngines());
  }

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
        // Only where Whisper runs (the voice settings look for it).
        if (_deps.offlineSpeech case final offlineSpeech?)
          RepositoryProvider<OfflineSpeech>.value(value: offlineSpeech),
        // The offline dictionaries (`maybeDictionaryPacks` finds them).
        if (_deps.dictionaryPacks case final dictionaryPacks?)
          RepositoryProvider<DictionaryPacks>.value(value: dictionaryPacks),
        RepositoryProvider<OfflineTranslator>.value(
          value: _deps.offlineTranslator,
        ),
        RepositoryProvider<UsageTracker>.value(value: _deps.usageTracker),
        // What backups, sync and pairing carry.
        if (_deps.backupRegistry case final backupRegistry?)
          RepositoryProvider<BackupRegistry>.value(value: backupRegistry),
        // Sync with the user's WebDAV folder (its settings find it).
        if (_deps.syncService case final syncService?)
          RepositoryProvider<SyncService>.value(value: syncService),
        // The phrasebook (`maybePhrasebookRepository` finds it).
        if (_deps.phrasebookRepository case final phrasebook?)
          RepositoryProvider<PhrasebookRepository>.value(value: phrasebook),
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
          child: SavedGlossariesBinding(
            child: SecureScreenListener(
              child: HistoryRetentionListener(
                child: MultiBlocListener(
                  listeners: [
                    BlocListener<SettingsCubit, AppSettings>(
                      listenWhen: privacyChanged,
                      listener: (context, settings) =>
                          _onPrivacyChanged(settings),
                    ),
                    BlocListener<SettingsCubit, AppSettings>(
                      listenWhen: engineConfigurationChanged,
                      listener: (context, settings) =>
                          _applyEngineConfiguration(settings),
                    ),
                  ],
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
                          // Null follows the device ("System default").
                          locale: AppLanguages.resolve(settings.appLocale),
                          localeListResolutionCallback:
                              AppLanguages.resolveDeviceLocales,
                          localizationsDelegates: appLocalizationsDelegates,
                          supportedLocales: AppLanguages.supported,
                          routerConfig: _router,
                          // Transparent system bars whose icons follow the
                          // theme (edge to edge on Android).
                          builder: (context, child) => SystemBarsStyle(
                            child: SettingsSaveFailureListener(
                              messengerKey: _messengerKey,
                              child: UsageWarningListener(
                                tracker: _deps.usageTracker,
                                messengerKey: _messengerKey,
                                providerName: _providerName,
                                // Reloads what a restore changed.
                                child: BackupRestoreListener(
                                  // Syncs at start and after changes.
                                  child: SyncScope.wrap(
                                    service: _deps.syncService,
                                    child: child ?? const SizedBox.shrink(),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
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

/// Whether [current] changes what the [TranslationRepository] enforces
/// before text leaves the device (privacy mode, approved language pairs,
/// consented providers).
bool privacyChanged(AppSettings previous, AppSettings current) =>
    previous.privacyMode != current.privacyMode ||
    !listEquals(previous.networkPairs, current.networkPairs) ||
    !listEquals(previous.consentedProviders, current.consentedProviders);

/// Whether [current] changes how the app looks (including the language of
/// its texts).
bool appearanceChanged(AppSettings previous, AppSettings current) =>
    previous.appLocale != current.appLocale ||
    previous.themeMode != current.themeMode ||
    previous.dynamicColor != current.dynamicColor ||
    previous.pureBlack != current.pureBlack ||
    previous.seedColor != current.seedColor;
