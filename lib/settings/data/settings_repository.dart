import 'dart:async';
import 'dart:convert';

import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/core/network/url_credentials.dart';
import 'package:mozhi/settings/data/provider_identity.dart';
import 'package:mozhi/settings/data/settings_rebase.dart';
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
/// [save] throws a [SecretStorageException] when [secrets] refuses to
/// store a secret; the settings JSON is then not written either.
///
/// [prefs] defaults to [PreferencesStore] and [secrets] to [SecureStore].
/// Saves and [update]s run one at a time, in the order they were called,
/// so the last [save] call always wins.
///
/// Restores and sync merges change the stored settings with [update]
/// (read and written in one step, after the saves before it) and read them
/// with [read]; [load] and [save] are the app's (the settings it holds).
/// When an [update] changed the stored settings after the app last loaded
/// or saved them, [save] applies the app's change to the stored settings
/// ([rebaseSettings]) instead of writing over them, until the app loads
/// them again: neither the change nor the merge is lost.
///
/// Every provider a save removes is remembered ([removedProviders], under
/// [removedProvidersKey] in [prefs]: its id and a hash of its server), so
/// that a sync merge never brings it back or gives its id to another
/// provider.
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

  /// Key of the providers removed from this device ([removedProviders]) in
  /// [prefs]: a JSON list of [RemovedProvider.toJson].
  static const removedProvidersKey = 'settings.v1.removedProviders';

  /// At most this many removed providers are remembered (the latest).
  static const maxRemovedProviders = 200;

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

  /// The settings the app holds: what it last loaded or saved (null
  /// before either).
  AppSettings? _view;

  /// Whether the stored settings are the app's ([_view]) as far as this
  /// repository wrote them: not after an [update] changed them, until the
  /// app loads them again.
  bool _viewStored = false;

  /// How many saves and updates were called (a load that one overtook
  /// leaves the app's settings as they are).
  int _epoch = 0;

  /// [removedProviders], once read.
  List<RemovedProvider>? _removed;

  /// Whether the last [load] could not read the stored settings because
  /// the storage failed (as opposed to nothing or invalid JSON being
  /// stored). [load] returned defaults in that case.
  bool get loadFailed => _loadFailed;

  /// The stored settings, for the app to use (see the class docs).
  Future<AppSettings> load() async {
    final epoch = _epoch;
    final loaded = await _readMigrated();
    // Not when a save or update was called meanwhile: the app's settings
    // are then the saved ones, or the update's write may not be read yet.
    if (!_loadFailed && _epoch == epoch) {
      _view = loaded;
      _viewStored = true;
    }
    return loaded;
  }

  /// The stored settings, like [load], for a reader that is not the app
  /// (backups and sync: the settings the app holds are not taken to be
  /// these). Check [loadFailed] after it.
  Future<AppSettings> read() => _readMigrated();

  /// Applies [change] to the stored settings and writes the result, in one
  /// step after the saves and updates called before (a restore, a sync
  /// merge); returns it. Nothing is written when [change] changes nothing.
  /// Throws [SettingsUnavailableException] when the stored settings can't
  /// be read, and what [save] throws.
  Future<AppSettings> update(AppSettings Function(AppSettings current) change) {
    _epoch++;
    return _queued(() async {
      final current = await _readMigrated(inQueue: true);
      if (_loadFailed) throw const SettingsUnavailableException();
      final next = change(current);
      if (next == current) return current;
      await _save(next);
      _viewStored = false;
      return next;
    });
  }

  /// The providers removed from this device (oldest first), at most
  /// [maxRemovedProviders]; none when they can't be read.
  Future<List<RemovedProvider>> removedProviders() async {
    if (_removed case final removed?) return removed;
    try {
      final raw = await prefs.read(removedProvidersKey);
      if (raw == null) return _removed = const [];
      final json = jsonDecode(raw);
      return _removed = List.unmodifiable([
        if (json is List)
          for (final item in json) ?RemovedProvider.tryParse(item),
      ]);
    } on Object {
      return const [];
    }
  }

  /// The stored settings with their secrets, with what older versions
  /// wrote moved where it belongs (see the class docs): written after the
  /// saves called before, or right away when called by one of them
  /// ([inQueue]).
  Future<AppSettings> _readMigrated({bool inQueue = false}) async {
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
        await (inQueue ? _save(loaded) : _queued(() => _save(loaded)));
      } on Object {
        // Tried again on the next load or save.
      }
    }
    return loaded;
  }

  /// Writes [settings]: the app's settings after a change it made to those
  /// it last loaded or saved. When an [update] changed the stored settings
  /// since, the change is applied to them instead ([rebaseSettings]).
  Future<void> save(AppSettings settings) {
    final base = _view;
    _epoch++;
    _view = settings;
    return _queued(() async {
      if (base != null && !_viewStored) {
        final stored = await _readMigrated(inQueue: true);
        if (!_loadFailed) {
          await _save(
            rebaseSettings(base: base, mine: settings, theirs: stored),
          );
          return;
        }
      }
      await _save(settings);
      _viewStored = true;
    });
  }

  /// Runs [action] after the saves and updates called before it.
  Future<T> _queued<T>(Future<T> Function() action) {
    final result = _pendingSave.then((_) => action());
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
    await _rememberRemoved([
      for (final provider in [...?previous?.providers])
        if (staleIds.contains(provider.id)) provider,
    ], present: settings.providers);
  }

  /// Adds [removed] to [removedProviders] and forgets those [present]
  /// again (on the same server). Best effort: never throws.
  Future<void> _rememberRemoved(
    List<AiProviderConfig> removed, {
    required List<AiProviderConfig> present,
  }) async {
    try {
      final known = await removedProviders();
      if (removed.isEmpty && known.isEmpty) return;
      final back = {
        for (final provider in present)
          RemovedProvider(
            id: provider.id,
            server: ProviderIdentity.serverHash(provider),
          ),
      };
      final added = [
        for (final provider in removed)
          RemovedProvider(
            id: provider.id,
            server: ProviderIdentity.serverHash(provider),
          ),
      ];
      final next = <RemovedProvider>[
        for (final item in known)
          if (!back.contains(item) && !added.contains(item)) item,
        ...added,
      ];
      if (next.length == known.length && removed.isEmpty) return;
      final kept = next.length > maxRemovedProviders
          ? next.sublist(next.length - maxRemovedProviders)
          : next;
      _removed = null;
      if (kept.isEmpty) {
        await prefs.delete(removedProvidersKey);
      } else {
        await prefs.write(
          removedProvidersKey,
          jsonEncode([for (final item in kept) item.toJson()]),
        );
      }
      _removed = List.unmodifiable(kept);
    } on Object {
      // A removed provider may come back from another device's settings.
    }
  }

  /// Stores [value] under [key] in [secrets], or deletes it when [value]
  /// is null or empty; does nothing when [secrets] already holds that
  /// ([_storedSecrets]), or when there is nothing to store for a key that
  /// [load] could not read. A failed write throws a
  /// [SecretStorageException].
  Future<void> _writeSecret(String key, String? value) async {
    final next = (value == null || value.isEmpty) ? null : value;
    if (next == null) {
      if (!_unreadableSecrets.contains(key)) await _deleteSecret(key);
      return;
    }
    if (_storedSecrets.containsKey(key) && _storedSecrets[key] == next) return;
    try {
      await secrets.write(key, next);
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(SecretStorageException(error), stackTrace);
    }
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

/// Thrown by [SettingsRepository.save] when its secure storage
/// ([SettingsRepository.secrets]) refuses to store a secret: an API key,
/// custom provider headers or an instance's user name and password (e.g.
/// the Keystore failing after a working start). Nothing of that save is
/// written to the plain settings, and the secret is never stored anywhere
/// else; the next save tries again.
class SecretStorageException implements Exception {
  const new(this.cause);

  /// What the secure storage threw.
  final Object cause;

  // The cause is left out: platform messages may quote what was stored.
  @override
  String toString() =>
      'SecretStorageException: a secret could not be stored securely';
}
