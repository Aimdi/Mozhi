import 'dart:async';
import 'dart:developer';

import 'package:bloc/bloc.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mozhi/app/app_dependencies.dart';
import 'package:mozhi/app/fallback_key_value_store.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/platform/shared_text_service.dart';
import 'package:mozhi/settings/data/settings_repository.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:translation_repository/translation_repository.dart';

/// Logs bloc changes and errors (debug builds only).
class AppBlocObserver extends BlocObserver {
  const new();

  @override
  void onChange(BlocBase<dynamic> bloc, Change<dynamic> change) {
    super.onChange(bloc, change);
    log('onChange(${bloc.runtimeType}, $change)', name: 'bloc');
  }

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

  runApp(await builder(await dependencies()));
}

/// Creates the long-lived services and loads the saved settings.
///
/// [prefs] and [secrets] default to the platform stores; secure storage
/// falls back to memory when it is unavailable.
Future<AppDependencies> createDependencies({
  KeyValueStore? prefs,
  KeyValueStore? secrets,
}) async {
  final preferences = prefs ?? PreferencesStore();
  final secretStore = secrets ?? await _secureStore();

  final settingsRepository = SettingsRepository(
    prefs: preferences,
    secrets: secretStore,
  );
  final settings = await settingsRepository.load();

  final translationRepository = TranslationRepository()
    ..updateConfiguration(
      instances: settings.instances,
      providers: settings.providers,
    );

  return AppDependencies(
    translationRepository: translationRepository,
    settingsRepository: settingsRepository,
    historyRepository: HistoryRepository(store: preferences),
    speechService: SpeechService(repository: translationRepository),
    sharedTextService: SharedTextService(),
    settings: settings,
  );
}

Future<KeyValueStore> _secureStore() async {
  final store = FallbackKeyValueStore(
    SecureStore(
      const FlutterSecureStorage(
        // The data-protection keychain needs a provisioning profile
        // (keychain-access-groups); the legacy keychain works unsigned.
        mOptions: MacOsOptions(usesDataProtectionKeychain: false),
      ),
    ),
  );
  await store.probe();
  return store;
}
