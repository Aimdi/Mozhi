import 'dart:async';
import 'dart:convert';

import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/core/network/url_credentials.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

/// Loads/saves [AppSettings]: JSON under key `settings.v1` in [prefs],
/// without secrets ([AppSettings.toJson]). The secrets live in [secrets]:
/// each provider's API key under `apikey.<providerId>` ([apiKeyKey]), its
/// custom headers as a JSON object under `apiheaders.<providerId>`
/// ([headersKey]), and the user names and passwords of instance URLs
/// (`https://user:password@host`) as one JSON object (URL without them →
/// `user:password`) under [instanceCredentialsKey]. Missing or corrupt JSON
/// falls back to defaults (never throws from [load]). [save] deletes the
/// secrets of providers and instances that no longer exist.
///
/// Settings written by older versions kept headers and instance
/// credentials in the plain JSON: [load] moves them to [secrets] and
/// rewrites the JSON without them. It also drops the attribution headers
/// older versions added to OpenRouter providers
/// ([legacyAttributionHeaders]).
///
/// A storage error while reading is not treated as "nothing stored": [load]
/// then returns defaults but sets [loadFailed], and [save] never overwrites
/// settings it could not read (it rethrows read errors, and throws
/// [SettingsUnavailableException] when stored settings exist that the
/// failed [load] did not see). A later successful [load] lifts this.
///
/// [load] reads all secrets at once. [save] writes only the secrets that
/// changed since they were last read or written: settings are saved after
/// every change (a new language pair after each translation), and each
/// Keystore write is slow and can fail. A secret that [load] could not read
/// is not deleted by a later [save] that still has no value for it (that
/// would turn a passing storage error into a lost API key); removing its
/// provider or instance still deletes it.
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

  /// Key of the custom headers (a JSON object) of provider [providerId] in
  /// [secrets].
  static String headersKey(String providerId) => 'apiheaders.$providerId';

  /// Headers older versions of the OpenRouter preset added to identify the
  /// app; [load] removes them from saved providers.
  static const legacyAttributionHeaders = {
    'HTTP-Referer': 'https://github.com/Aimdi/Mozhi',
    'X-Title': 'Mozhi',
  };

  /// Key of the instance credentials in [secrets]: a JSON object from
  /// instance URL (without credentials) to its user-info
  /// ([urlCredentials]).
  static const instanceCredentialsKey = 'instancecreds';

  final KeyValueStore prefs;
  final KeyValueStore secrets;

  /// Provider ids known to have (had) a stored key, from the last
  /// load/save. Used together with the stored JSON to find orphan keys.
  final Set<String> _knownProviderIds = {};

  /// What [secrets] holds (null: nothing) under each key, as last read or
  /// written by this repository; keys missing here are unknown.
  final Map<String, String?> _storedSecrets = {};

  /// Keys whose last read in [load] failed: what they hold is unknown.
  final Set<String> _unreadableSecrets = {};

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
    // Written by an older version: secrets in the plain JSON.
    var outdated =
        settings.providers.any((p) => p.headers.isNotEmpty) ||
        settings.instances.any((i) => urlCredentials(i.url) != null);

    // Every secret at once: each is a separate Keystore call.
    final (apiKeys, storedHeaders, storedCredentials) = await (
      Future.wait([
        for (final provider in settings.providers)
          _readSecret(apiKeyKey(provider.id)),
      ]),
      Future.wait([
        for (final provider in settings.providers)
          // Older versions kept the headers in the JSON itself.
          if (provider.headers.isEmpty)
            _readSecret(headersKey(provider.id))
          else
            Future<String?>.value(),
      ]),
      _readCredentials(),
    ).wait;

    final providers = <AiProviderConfig>[];
    for (final (index, provider) in settings.providers.indexed) {
      final apiKey = apiKeys[index];
      final stored = provider.headers.isNotEmpty
          ? provider.headers
          : _decodeStrings(storedHeaders[index]) ?? const <String, String>{};
      final headers = {
        for (final MapEntry(:key, :value) in stored.entries)
          if (legacyAttributionHeaders[key] != value) key: value,
      };
      if (headers.length != stored.length) outdated = true;
      providers.add(
        provider.copyWith(apiKey: apiKey, headers: Map.unmodifiable(headers)),
      );
    }
    final instances = <MozhiInstance>[
      for (final instance in settings.instances)
        switch (storedCredentials[instance.url]) {
          final credentials? when urlCredentials(instance.url) == null =>
            MozhiInstance(
              url: urlWithCredentials(instance.url, credentials),
              label: instance.label,
              isCustom: instance.isCustom,
            ),
          _ => instance,
        },
    ];
    final loaded = settings.copyWith(
      providers: List.unmodifiable(providers),
      instances: List.unmodifiable(instances),
    );
    if (outdated && !_loadFailed) {
      try {
        // Moves secrets to [secrets] and drops them from the JSON.
        await save(loaded);
      } on Object {
        // Tried again on the next load or save.
      }
    }
    return loaded;
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
    // Secrets first: the JSON written below no longer holds the headers
    // and credentials that older versions kept there.
    for (final provider in settings.providers) {
      staleIds.remove(provider.id);
      await _writeSecret(apiKeyKey(provider.id), provider.apiKey);
      await _writeSecret(
        headersKey(provider.id),
        provider.headers.isEmpty ? null : jsonEncode(provider.headers),
      );
    }
    final credentials = <String, String>{
      for (final instance in settings.instances)
        urlWithoutCredentials(instance.url): ?urlCredentials(instance.url),
    };
    final encodedCredentials = credentials.isEmpty
        ? null
        : jsonEncode(credentials);
    if (encodedCredentials != null) {
      await _writeSecret(instanceCredentialsKey, encodedCredentials);
    }

    await prefs.write(settingsKey, jsonEncode(settings.toJson()));

    if (encodedCredentials == null) {
      await _writeSecret(instanceCredentialsKey, null);
    }
    for (final id in staleIds) {
      await _deleteSecret(apiKeyKey(id));
      await _deleteSecret(headersKey(id));
    }
    _knownProviderIds
      ..clear()
      ..addAll(settings.providers.map((p) => p.id));
  }

  /// Stores [value] under [key] in [secrets], or deletes it when [value]
  /// is null or empty; does nothing when [secrets] already holds that
  /// ([_storedSecrets]), or when there is nothing to store for a key that
  /// [load] could not read.
  Future<void> _writeSecret(String key, String? value) async {
    final next = (value == null || value.isEmpty) ? null : value;
    if (next == null) {
      if (!_unreadableSecrets.contains(key)) await _deleteSecret(key);
      return;
    }
    if (_storedSecrets.containsKey(key) && _storedSecrets[key] == next) return;
    await secrets.write(key, next);
    _storedSecrets[key] = next;
    _unreadableSecrets.remove(key);
  }

  /// Deletes [key] from [secrets] unless it is known to hold nothing.
  Future<void> _deleteSecret(String key) async {
    if (_storedSecrets.containsKey(key) && _storedSecrets[key] == null) return;
    await secrets.delete(key);
    _storedSecrets[key] = null;
    _unreadableSecrets.remove(key);
  }

  /// The settings (without the secrets kept in [secrets], unless an older
  /// version wrote them) stored as [raw], or null when nothing (valid) is
  /// stored.
  static AppSettings? _decode(String? raw) {
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return null;
      var settings = AppSettings.fromJson(json);
      // Settings saved before onboarding existed belong to people who
      // already set the app up: don't send them through it again.
      if (!json.containsKey('onboardingComplete')) {
        settings = settings.copyWith(onboardingComplete: true);
      }
      // Settings saved before privacy modes existed keep working as they
      // did: network engines without asking (cloud providers still ask).
      if (!json.containsKey('privacyMode')) {
        settings = settings.copyWith(privacyMode: PrivacyMode.online);
      }
      return settings;
    } on Object {
      return null;
    }
  }

  /// The non-empty value of [key] in [secrets], or null (also when the
  /// store fails, which marks [key] unreadable).
  Future<String?> _readSecret(String key) async {
    final String? value;
    try {
      value = await secrets.read(key);
    } on Object {
      _storedSecrets.remove(key);
      _unreadableSecrets.add(key);
      return null;
    }
    final stored = (value?.isEmpty ?? true) ? null : value;
    _storedSecrets[key] = stored;
    _unreadableSecrets.remove(key);
    return stored;
  }

  /// The stored instance credentials ([instanceCredentialsKey]); empty
  /// when there are none or they cannot be read.
  Future<Map<String, String>> _readCredentials() async =>
      _decodeStrings(await _readSecret(instanceCredentialsKey)) ?? const {};

  /// The string values of the JSON object [raw] (headers, credentials as
  /// written by [_save]), or null when there are none (or [raw] is not a
  /// JSON object).
  static Map<String, String>? _decodeStrings(String? raw) {
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return null;
      final values = {
        for (final MapEntry(:key, :value) in json.entries)
          if (value is String) key: value,
      };
      return values.isEmpty ? null : Map.unmodifiable(values);
    } on FormatException {
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
