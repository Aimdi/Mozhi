import 'dart:async';
import 'dart:developer';

import 'package:bloc/bloc.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mozhi/app/app_dependencies.dart';
import 'package:mozhi/app/fallback_key_value_store.dart';
import 'package:mozhi/app/third_party_licenses.dart';
import 'package:mozhi/core/key_value_metadata_store.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/core/network/network_session.dart';
import 'package:mozhi/core/on_device_ml.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/platform/offline_engine.dart';
import 'package:mozhi/platform/shared_text_service.dart';
import 'package:mozhi/settings/data/settings_repository.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/usage/data/usage_tracker.dart';
import 'package:mozhi/voice/speech_input_service.dart';
import 'package:translation_repository/translation_repository.dart';

/// Logs bloc changes and errors (debug builds only).
///
/// Only type names are logged, never the states themselves: they hold the
/// user's text, translations and, while onboarding, an API key.
class AppBlocObserver extends BlocObserver {
  const new();

  @override
  void onChange(BlocBase<dynamic> bloc, Change<dynamic> change) {
    super.onChange(bloc, change);
    log(describeChange(bloc, change), name: 'bloc');
  }

  /// The log line for [change] of [bloc]: type names only.
  @visibleForTesting
  static String describeChange(
    BlocBase<dynamic> bloc,
    Change<dynamic> change,
  ) =>
      'onChange(${bloc.runtimeType}: '
      '${change.currentState.runtimeType} -> '
      '${change.nextState.runtimeType})';

  @override
  void onError(BlocBase<dynamic> bloc, Object error, StackTrace stackTrace) {
    log(
      'onError(${bloc.runtimeType})',
      name: 'bloc',
      error: error,
      stackTrace: stackTrace,
    );
    super.onError(bloc, error, stackTrace);
  }
}

/// Initialises Flutter, creates the [AppDependencies] (with [dependencies])
/// and runs the widget returned by [builder].
Future<void> bootstrap(
  FutureOr<Widget> Function(AppDependencies dependencies) builder, {
  Future<AppDependencies> Function() dependencies = createDependencies,
}) async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    log(details.exceptionAsString(), name: 'mozhi', stackTrace: details.stack);
  };
  PlatformDispatcher.instance.onError = (error, stackTrace) {
    log('Uncaught error', name: 'mozhi', error: error, stackTrace: stackTrace);
    return true;
  };

  if (kDebugMode) Bloc.observer = const AppBlocObserver();
  registerThirdPartyLicenses(includeMlKit: mlKitIncluded);

  runApp(await builder(await dependencies()));
}

/// Creates the long-lived services and loads the saved settings.
///
/// [prefs] and [secrets] default to the platform stores; secure storage
/// falls back to memory when it is unavailable (reported by
/// [AppDependencies.secretsInMemory]). [offlineTranslator] defaults to
/// [createOfflineTranslator]: Mozilla's Bergamot engine (Android; never
/// available on the web), created while the settings load. Its model
/// downloads go through [NetworkSession.current] (the proxy setting).
///
/// Every backend client of the [TranslationRepository] comes from one
/// [NetworkSession] built from the saved `httpProxy` (a later change
/// applies after a restart), which becomes [NetworkSession.current].
/// [network] replaces it (tests).
Future<AppDependencies> createDependencies({
  KeyValueStore? prefs,
  KeyValueStore? secrets,
  OfflineTranslator? offlineTranslator,
  NetworkSession Function(String? proxy)? network,
}) async {
  // Started first: loading the model catalog runs while the stores open.
  final offlineFuture = offlineTranslator != null
      ? Future.value(offlineTranslator)
      : createOfflineTranslator();
  final preferences = prefs ?? PreferencesStore();
  final secretStore = secrets ?? await _secureStore();

  final settingsRepository = SettingsRepository(
    prefs: preferences,
    secrets: secretStore,
  );
  final settings = await settingsRepository.load();

  final session = (network ?? _networkSession)(settings.httpProxy);
  NetworkSession.current = session;

  final offline = await offlineFuture;
  final translationRepository =
      TranslationRepository(
        mozhiClientFactory: session.mozhiClient,
        llmClientFactory: session.llmClient,
        deeplClientFactory: session.deeplClient,
        libreTranslateClientFactory: session.libreClient,
        offline: offline,
        // Engine and language lists survive restarts: instant start, offline.
        metadataStore: KeyValueMetadataStore(preferences),
      )..updateConfiguration(
        instances: settings.instances,
        providers: settings.providers,
      );

  return AppDependencies(
    translationRepository: translationRepository,
    settingsRepository: settingsRepository,
    historyRepository: HistoryRepository(store: preferences),
    speechService: SpeechService(
      repository: translationRepository,
      store: preferences,
    ),
    sharedTextService: SharedTextService(),
    settings: settings,
    preferences: preferences,
    secrets: secretStore,
    speechInputService: SpeechInputService(store: preferences),
    offlineTranslator: offline,
    usageTracker: UsageTracker(store: preferences),
    network: session,
  );
}

NetworkSession _networkSession(String? proxy) => NetworkSession(proxy: proxy);

/// Options of the platform secure storage.
///
/// On the web, keys are kept in `sessionStorage` (gone when the tab
/// closes): browser storage is readable by any script of the origin, and
/// the encryption key sits next to the data, so nothing is persisted.
const appSecureStorage = FlutterSecureStorage(
  // Keys stay on this device: not in iCloud Keychain, not restored from an
  // encrypted backup onto another phone (docs/security.md).
  iOptions: IOSOptions(
    accessibility: KeychainAccessibility.unlocked_this_device,
  ),
  // The data-protection keychain needs a provisioning profile
  // (keychain-access-groups); the legacy keychain works unsigned.
  mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  webOptions: WebOptions(useSessionStorage: true),
);

Future<KeyValueStore> _secureStore() async {
  final store = FallbackKeyValueStore(SecureStore(appSecureStorage));
  await store.probe();
  return store;
}
