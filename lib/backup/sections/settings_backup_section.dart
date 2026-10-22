import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/core/network/url_credentials.dart';
import 'package:mozhi/settings/data/settings_repository.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

/// The settings ([AppSettings]), section `settings`; with secrets (only
/// when the user opts in) the API keys, custom provider headers and the
/// user names and passwords of instance addresses.
///
/// Data (version 1): `{"settings": AppSettings.toJson(), "secrets":
/// {"apiKeys": {providerId: key}, "headers": {providerId: {name: value}},
/// "instanceCredentials": {url: "user:password"}}}`, `secrets` only when
/// included and there are any.
///
/// Read and written through the [SettingsRepository], so restored secrets
/// go to secure storage exactly as when they are typed in the settings
/// (never into the plain settings). The app's `BackupRestoreListener` then
/// reloads the settings in use.
///
/// A provider or instance keeps this device's key or password when the
/// backup has none for it ([BackupRestoreMode.replace] included).
/// [BackupRestoreMode.replace] makes the backup's settings the settings
/// (setup stays finished when it was). [BackupRestoreMode.merge] keeps this
/// device's settings, privacy choices included, and only adds the AI
/// providers, Mozhi instances and pinned languages it doesn't have (and
/// missing keys of its providers): settings carry no timestamps to tell
/// the newer copy.
class SettingsBackupSection implements BackupSection {
  const new(this._repository);

  /// The section's [id].
  static const sectionId = 'settings';

  final SettingsRepository _repository;

  @override
  String get id => sectionId;

  @override
  int get version => 1;

  /// Whether [data] (written by [export]) holds secrets.
  static bool hasSecrets(Object? data) =>
      data is Map &&
      data['secrets'] is Map &&
      (data['secrets'] as Map).isNotEmpty;

  @override
  Future<Object?> export({required bool includeSecrets}) async {
    final settings = await _load();
    final secrets = includeSecrets ? _Secrets.of(settings).toJson() : null;
    return {
      'settings': settings.toJson(),
      if (secrets != null && secrets.isNotEmpty) 'secrets': secrets,
    };
  }

  @override
  Future<void> restore(
    Object? data, {
    required int version,
    required BackupRestoreMode mode,
  }) async {
    if (version > this.version) {
      throw FormatException('Settings data version $version is newer');
    }
    if (data case {'settings': final Map<dynamic, dynamic> json}) {
      final backup = AppSettings.fromJson(Map<String, dynamic>.from(json));
      final secrets = _Secrets.fromJson(data['secrets']);
      final local = await _load();
      await _repository.save(switch (mode) {
        BackupRestoreMode.replace => _replaced(local, backup, secrets),
        BackupRestoreMode.merge => _merged(local, backup, secrets),
      });
      return;
    }
    throw const FormatException('Invalid settings data');
  }

  /// The stored settings with their secrets. Throws when they could not be
  /// read (defaults must never be backed up, nor saved over them).
  Future<AppSettings> _load() async {
    final settings = await _repository.load();
    if (_repository.loadFailed) throw const SettingsUnavailableException();
    return settings;
  }

  static AppSettings _replaced(
    AppSettings local,
    AppSettings backup,
    _Secrets secrets,
  ) {
    final keep = _Secrets.of(local);
    return backup.copyWith(
      onboardingComplete: local.onboardingComplete || backup.onboardingComplete,
      providers: List.unmodifiable([
        for (final provider in backup.providers)
          keep.applyTo(secrets.applyTo(provider)),
      ]),
      instances: List.unmodifiable([
        for (final instance in backup.instances)
          keep.applyToInstance(secrets.applyToInstance(instance)),
      ]),
    );
  }

  static AppSettings _merged(
    AppSettings local,
    AppSettings backup,
    _Secrets secrets,
  ) {
    final providerIds = {for (final provider in local.providers) provider.id};
    final urls = {
      for (final instance in local.instances)
        urlWithoutCredentials(instance.url),
    };
    final pinned = {
      for (final language in local.pinnedLanguages) language.code,
    };
    return local.copyWith(
      providers: List.unmodifiable([
        for (final provider in local.providers) secrets.applyTo(provider),
        for (final provider in backup.providers)
          if (!providerIds.contains(provider.id))
            secrets.applyTo(_withoutSecrets(provider)),
      ]),
      instances: List.unmodifiable([
        for (final instance in local.instances)
          secrets.applyToInstance(instance),
        for (final instance in backup.instances)
          if (!urls.contains(urlWithoutCredentials(instance.url)))
            secrets.applyToInstance(instance),
      ]),
      pinnedLanguages: List.unmodifiable([
        ...local.pinnedLanguages,
        for (final language in backup.pinnedLanguages)
          if (!pinned.contains(language.code)) language,
      ]),
    );
  }

  static AiProviderConfig _withoutSecrets(AiProviderConfig provider) =>
      provider.copyWith(clearApiKey: true, headers: const {});
}

/// API keys and headers by provider id, and instance credentials by URL
/// (without them).
class _Secrets {
  const new({
    this.apiKeys = const {},
    this.headers = const {},
    this.credentials = const {},
  });

  /// The secrets of [settings].
  factory of(AppSettings settings) => _Secrets(
    apiKeys: {
      for (final provider in settings.providers)
        if (provider.apiKey case final key? when key.isNotEmpty)
          provider.id: key,
    },
    headers: {
      for (final provider in settings.providers)
        if (provider.headers.isNotEmpty) provider.id: provider.headers,
    },
    credentials: {
      for (final instance in settings.instances)
        urlWithoutCredentials(instance.url): ?urlCredentials(instance.url),
    },
  );

  /// Parses [toJson] output; anything invalid is left out.
  factory fromJson(Object? json) {
    if (json is! Map) return const _Secrets();
    Map<String, String> strings(Object? value) => {
      if (value is Map)
        for (final MapEntry(:key, :value) in value.entries)
          if (key is String && value is String && value.isNotEmpty) key: value,
    };
    final headers = json['headers'];
    return _Secrets(
      apiKeys: strings(json['apiKeys']),
      headers: {
        if (headers is Map)
          for (final MapEntry(:key, :value) in headers.entries)
            if (key is String && strings(value).isNotEmpty) key: strings(value),
      },
      credentials: strings(json['instanceCredentials']),
    );
  }

  final Map<String, String> apiKeys;
  final Map<String, Map<String, String>> headers;
  final Map<String, String> credentials;

  /// [provider] with its key and headers from here, where it has none.
  AiProviderConfig applyTo(AiProviderConfig provider) {
    final key = provider.apiKey?.isNotEmpty ?? false
        ? null
        : apiKeys[provider.id];
    final headers = provider.headers.isNotEmpty
        ? null
        : this.headers[provider.id];
    if (key == null && headers == null) return provider;
    return provider.copyWith(apiKey: key, headers: headers);
  }

  /// [instance] with its credentials from here, where it has none.
  MozhiInstance applyToInstance(MozhiInstance instance) {
    if (urlCredentials(instance.url) != null) return instance;
    final credentials = this.credentials[instance.url];
    if (credentials == null) return instance;
    return MozhiInstance(
      url: urlWithCredentials(instance.url, credentials),
      label: instance.label,
      isCustom: instance.isCustom,
    );
  }

  Map<String, Object?> toJson() => {
    if (apiKeys.isNotEmpty) 'apiKeys': apiKeys,
    if (headers.isNotEmpty) 'headers': headers,
    if (credentials.isNotEmpty) 'instanceCredentials': credentials,
  };
}
