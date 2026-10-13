import 'dart:async';
import 'dart:convert';

import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

/// Loads/saves [AppSettings]: JSON under key `settings.v1` in [prefs];
/// each provider's API key under `apikey.<providerId>` in [secrets].
/// Missing or corrupt JSON falls back to defaults (never throws from
/// [load]). [save] deletes keys of providers that no longer exist.
///
/// A storage error while reading is not treated as "nothing stored": [load]
/// then returns defaults but sets [loadFailed], and [save] never overwrites
/// settings it could not read (it rethrows read errors, and throws
/// [SettingsUnavailableException] when stored settings exist that the
/// failed [load] did not see). A later successful [load] lifts this.
///
/// [prefs] defaults to [PreferencesStore] and [secrets] to [SecureStore].
/// Saves are serialised, so the last [save] call always wins.
class SettingsRepository {
  new({KeyValueStore? prefs, KeyValueStore? secrets})
    : prefs = prefs ?? PreferencesStore(),
      secrets = secrets ?? SecureStore();

  /// Key of the settings JSON in [prefs].
  static const settingsKey = 'settings.v1';

  /// Key of the API key of provider [providerId] in [secrets].
  static String apiKeyKey(String providerId) => 'apikey.$providerId';

  final KeyValueStore prefs;
  final KeyValueStore secrets;

  /// Provider ids known to have (had) a stored key, from the last
  /// load/save. Used together with the stored JSON to find orphan keys.
  final Set<String> _knownProviderIds = {};

  Future<void> _pendingSave = Future.value();

  bool _loadFailed = false;

  /// Whether the last [load] could not read the stored settings because
  /// the storage failed (as opposed to nothing or invalid JSON being
  /// stored). [load] returned defaults in that case.
  bool get loadFailed => _loadFailed;

  Future<AppSettings> load() async {
    AppSettings? stored;
    try {
      stored = _decode(await prefs.read(settingsKey));
      _loadFailed = false;
    } on Object {
      _loadFailed = true;
    }
    final settings = stored ?? const AppSettings();
    _knownProviderIds.addAll(settings.providers.map((p) => p.id));
    if (settings.providers.isEmpty) return settings;
    final providers = <AiProviderConfig>[];
    for (final provider in settings.providers) {
      final apiKey = await _readApiKey(provider.id);
      providers.add(
        apiKey == null ? provider : provider.copyWith(apiKey: apiKey),
      );
    }
    return settings.copyWith(providers: List.unmodifiable(providers));
  }

  Future<void> save(AppSettings settings) {
    final result = _pendingSave.then((_) => _save(settings));
    _pendingSave = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> _save(AppSettings settings) async {
    // Storage errors propagate: never overwrite what could not be read.
    final previous = _decode(await prefs.read(settingsKey));
    if (_loadFailed) {
      // [settings] derive from the defaults of a failed load; writing them
      // would replace the real settings and delete their API keys.
      if (previous != null) throw const SettingsUnavailableException();
      _loadFailed = false;
    }
    final staleIds = {
      ..._knownProviderIds,
      ...?previous?.providers.map((p) => p.id),
    };

    await prefs.write(settingsKey, jsonEncode(settings.toJson()));

    for (final provider in settings.providers) {
      staleIds.remove(provider.id);
      final apiKey = provider.apiKey;
      if (apiKey == null || apiKey.isEmpty) {
        await secrets.delete(apiKeyKey(provider.id));
      } else {
        await secrets.write(apiKeyKey(provider.id), apiKey);
      }
    }
    for (final id in staleIds) {
      await secrets.delete(apiKeyKey(id));
    }
    _knownProviderIds
      ..clear()
      ..addAll(settings.providers.map((p) => p.id));
  }

  /// The settings (without API keys) stored as [raw], or null when nothing
  /// (valid) is stored.
  static AppSettings? _decode(String? raw) {
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return null;
      return AppSettings.fromJson(json);
    } on Object {
      return null;
    }
  }

  Future<String?> _readApiKey(String providerId) async {
    try {
      final key = await secrets.read(apiKeyKey(providerId));
      return (key?.isEmpty ?? true) ? null : key;
    } on Object {
      return null;
    }
  }
}

/// Thrown by [SettingsRepository.save] after a [SettingsRepository.load]
/// that failed to read the storage, when settings are stored after all:
/// saving would overwrite them with settings derived from the defaults.
class SettingsUnavailableException implements Exception {
  const new();

  @override
  String toString() =>
      'SettingsUnavailableException: the stored settings could not be '
      'loaded, so they are not overwritten';
}
