import 'package:equatable/equatable.dart';
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
/// Secrets stay with the server they are for. A provider's API key and
/// headers only move between this device's provider and the backup's
/// provider of the same id when both are on the same server
/// ([sameServer]: the same service, provider type and normalised base
/// URL), so a backup can't point one of this device's providers somewhere
/// else and keep its key. Instance passwords go by the instance address.
///
/// [BackupRestoreMode.replace] makes the backup's settings the settings
/// (setup stays finished when it was); a provider or instance keeps this
/// device's key or password when the backup has none for it (on the same
/// server). [BackupRestoreMode.merge] keeps this device's settings,
/// privacy choices included, and only adds the AI providers and pinned
/// languages it doesn't have, and the backup's keys of providers on the
/// same server where this device has none (settings carry no timestamps
/// to tell the newer copy). Merge never adds Mozhi instances: the failover
/// may send the user's text to any instance in the list without asking,
/// so only Replace, the user's explicit choice, takes the backup's
/// instances. A provider Merge adds is only used once the user picks it:
/// consents and engine choices still naming its id are dropped, and one
/// that would get text without asking first ([asksBeforeFirstUse]) comes
/// turned off.
///
/// [additions] tells what a restore adds, for the review before it and
/// its result.
class SettingsBackupSection implements BackupSection {
  const new(this._repository);

  /// The section's [id].
  static const sectionId = 'settings';

  static const _version = 1;

  final SettingsRepository _repository;

  @override
  String get id => sectionId;

  @override
  int get version => _version;

  /// Whether [data] (written by [export]) holds secrets.
  static bool hasSecrets(Object? data) =>
      data is Map &&
      data['secrets'] is Map &&
      (data['secrets'] as Map).isNotEmpty;

  /// Whether [a] and [b] send to the same server the same way: the same
  /// service, provider type and base URL ([normalizedBaseUrl]). Only then
  /// do API keys and headers carry over between them.
  static bool sameServer(AiProviderConfig a, AiProviderConfig b) =>
      a.service == b.service &&
      a.provider == b.provider &&
      normalizedBaseUrl(a.baseUrl) == normalizedBaseUrl(b.baseUrl);

  /// [url] normalised for [sameServer]: trimmed, `https://` added (or
  /// `http://` for a local host) when it has no scheme, as the clients
  /// do, scheme and host in lower case, without the default port, the
  /// fragment and trailing slashes. Empty for an empty [url] (a service's
  /// official API).
  static String normalizedBaseUrl(String url) {
    var text = url.trim();
    while (text.endsWith('/')) {
      text = text.substring(0, text.length - 1);
    }
    if (text.isEmpty) return '';
    if (!text.contains('://')) {
      final host = Uri.tryParse('http://$text')?.host ?? '';
      text = '${AiProviderConfig.isLocalHost(host) ? 'http' : 'https'}://$text';
    }
    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasAuthority) return text;
    var path = uri.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return Uri(
      scheme: uri.scheme.toLowerCase(),
      userInfo: uri.userInfo,
      host: uri.host.toLowerCase(),
      port: uri.hasPort ? uri.port : null,
      path: path,
      query: uri.hasQuery ? uri.query : null,
    ).toString();
  }

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
    final (backup, secrets) = _parse(data, version: version);
    final local = await _load();
    await _repository.save(_restored(local, backup, secrets, mode));
  }

  /// What restoring [data] (written by [export] at [version]) would add
  /// to this device's settings, with each mode: the AI providers and Mozhi
  /// instances that are new here (see [SettingsBackupAdditions]). Throws
  /// like [restore] (a [FormatException] for invalid or newer data, a
  /// [SettingsUnavailableException] when the settings can't be read);
  /// changes nothing.
  Future<Map<BackupRestoreMode, SettingsBackupAdditions>> additions(
    Object? data, {
    required int version,
  }) async {
    final (backup, secrets) = _parse(data, version: version);
    final local = await _load();
    return {
      for (final mode in BackupRestoreMode.values)
        mode: SettingsBackupAdditions.between(
          local,
          _restored(local, backup, secrets, mode),
        ),
    };
  }

  /// The backup's settings and secrets in [data].
  static (AppSettings, _Secrets) _parse(Object? data, {required int version}) {
    if (version > _version) {
      throw FormatException('Settings data version $version is newer');
    }
    if (data case {'settings': final Map<dynamic, dynamic> json}) {
      return (
        _plain(AppSettings.fromJson(Map<String, dynamic>.from(json))),
        _Secrets.fromJson(data['secrets']),
      );
    }
    throw const FormatException('Invalid settings data');
  }

  /// [settings] without the secrets a crafted file may put in its plain
  /// part ([export] never does): API keys, headers and instance
  /// credentials only come from `secrets`, so [hasSecrets] tells the whole
  /// story.
  static AppSettings _plain(AppSettings settings) => settings.copyWith(
    providers: List.unmodifiable(settings.providers.map(_withoutSecrets)),
    instances: List.unmodifiable([
      for (final instance in settings.instances)
        MozhiInstance(
          url: urlWithoutCredentials(instance.url),
          label: instance.label,
          isCustom: instance.isCustom,
        ),
    ]),
  );

  /// The stored settings with their secrets. Throws when they could not be
  /// read (defaults must never be backed up, nor saved over them).
  Future<AppSettings> _load() async {
    final settings = await _repository.load();
    if (_repository.loadFailed) throw const SettingsUnavailableException();
    return settings;
  }

  static AppSettings _restored(
    AppSettings local,
    AppSettings backup,
    _Secrets secrets,
    BackupRestoreMode mode,
  ) => switch (mode) {
    BackupRestoreMode.replace => _replaced(local, backup, secrets),
    BackupRestoreMode.merge => _merged(local, backup, secrets),
  };

  static AppSettings _replaced(
    AppSettings local,
    AppSettings backup,
    _Secrets secrets,
  ) {
    final mine = {
      for (final provider in local.providers) provider.id: provider,
    };
    final keep = _Secrets.of(local);
    return backup.copyWith(
      onboardingComplete: local.onboardingComplete || backup.onboardingComplete,
      providers: List.unmodifiable([
        for (final provider in backup.providers)
          if (mine[provider.id] case final own? when sameServer(own, provider))
            _filled(
              secrets.applyTo(provider),
              apiKey: own.apiKey,
              headers: own.headers,
            )
          else
            secrets.applyTo(provider),
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
    // The first provider of each id (a crafted backup may repeat one).
    final theirs = <String, AiProviderConfig>{};
    for (final provider in backup.providers) {
      theirs.putIfAbsent(provider.id, () => provider);
    }
    final mine = {for (final provider in local.providers) provider.id};
    final added = [
      for (final provider in theirs.values)
        if (!mine.contains(provider.id))
          _offUnlessAsked(secrets.applyTo(_withoutSecrets(provider))),
    ];
    final addedIds = {for (final provider in added) provider.id};
    // Choices left behind for a removed provider of that id must not pick
    // up the one the backup adds.
    bool stale(String? engineId) =>
        engineId != null &&
        addedIds.contains(TranslationRepository.providerIdOf(engineId));
    String? Function()? cleared(String? engineId) =>
        stale(engineId) ? () => null : null;
    final pinned = {
      for (final language in local.pinnedLanguages) language.code,
    };
    return local.copyWith(
      providers: List.unmodifiable([
        for (final provider in local.providers)
          if (theirs[provider.id] case final copy?
              when sameServer(provider, copy))
            secrets.applyTo(provider)
          else
            provider,
        ...added,
      ]),
      instances: List.unmodifiable([
        for (final instance in local.instances)
          secrets.applyToInstance(instance),
      ]),
      pinnedLanguages: List.unmodifiable([
        ...local.pinnedLanguages,
        for (final language in backup.pinnedLanguages)
          if (!pinned.contains(language.code)) language,
      ]),
      consentedProviders: List.unmodifiable(
        local.consentedProviders.where((id) => !addedIds.contains(id)),
      ),
      engineId: cleared(local.engineId),
      assistEngineId: cleared(local.assistEngineId),
      fastEngineId: cleared(local.fastEngineId),
      bestEngineId: cleared(local.bestEngineId),
      compareEngineIds: List.unmodifiable(
        local.compareEngineIds.where((id) => !stale(id)),
      ),
    );
  }

  static AiProviderConfig _withoutSecrets(AiProviderConfig provider) =>
      provider.copyWith(clearApiKey: true, headers: const {});

  /// [provider] turned off, unless the app asks the user before its first
  /// text goes to it (see [asksBeforeFirstUse]).
  static AiProviderConfig _offUnlessAsked(AiProviderConfig provider) =>
      asksBeforeFirstUse(provider)
      ? provider
      : provider.copyWith(enabled: false);

  /// Whether text only goes to [provider] once the user consented to that
  /// provider: a cloud provider (`TranslationRepository.updatePrivacy`,
  /// [CloudProviderDestination], as the repository resolves it: DeepL
  /// always, an AI provider unless it is on a private network). Others (an
  /// AI provider on a private network, a LibreTranslate server) need no
  /// consent of their own, and an AI one may be picked by itself (the
  /// first AI engine assists and proofreads when none is chosen), so Merge
  /// adds them turned off.
  static bool asksBeforeFirstUse(AiProviderConfig provider) =>
      switch (provider.service) {
        MtService.deepl => true,
        MtService.libreTranslate => false,
        MtService.llm => DataDestination.forUrl(
          provider.baseUrl.trim(),
          cloudProvider: '',
        ) is CloudProviderDestination,
      };

  /// [provider] with [apiKey] and [headers] where it has none.
  static AiProviderConfig _filled(
    AiProviderConfig provider, {
    String? apiKey,
    Map<String, String>? headers,
  }) {
    final hasKey = provider.apiKey?.isNotEmpty ?? false;
    final key = hasKey || (apiKey?.isEmpty ?? true) ? null : apiKey;
    final extra = provider.headers.isNotEmpty || (headers?.isEmpty ?? true)
        ? null
        : headers;
    if (key == null && extra == null) return provider;
    return provider.copyWith(apiKey: key, headers: extra);
  }
}

/// What restoring a settings backup adds to where this device can send
/// text ([SettingsBackupSection.additions]): the AI and translation
/// [providers] it doesn't have (or has on another server), and the Mozhi
/// [instances] it doesn't have. Without their keys, headers and
/// passwords.
class SettingsBackupAdditions extends Equatable {
  const new({this.providers = const [], this.instances = const []});

  /// What [after] has that [before] doesn't: providers without a provider
  /// of the same id on the same server ([SettingsBackupSection.sameServer])
  /// in [before], and instances whose address [before] doesn't have.
  factory between(AppSettings before, AppSettings after) {
    final urls = {
      for (final instance in before.instances)
        urlWithoutCredentials(instance.url),
    };
    final providers = <AiProviderConfig>[];
    for (final provider in after.providers) {
      bool same(AiProviderConfig other) =>
          other.id == provider.id &&
          SettingsBackupSection.sameServer(other, provider);
      if (before.providers.any(same) || providers.any(same)) continue;
      providers.add(provider.copyWith(clearApiKey: true, headers: const {}));
    }
    final instances = <MozhiInstance>[];
    for (final instance in after.instances) {
      final url = urlWithoutCredentials(instance.url);
      if (!urls.add(url)) continue;
      instances.add(
        MozhiInstance(
          url: url,
          label: instance.label,
          isCustom: instance.isCustom,
        ),
      );
    }
    return SettingsBackupAdditions(
      providers: List.unmodifiable(providers),
      instances: List.unmodifiable(instances),
    );
  }

  /// New AI and translation providers, in the backup's order.
  final List<AiProviderConfig> providers;

  /// New Mozhi instances (their addresses without passwords), in the
  /// backup's order.
  final List<MozhiInstance> instances;

  /// Whether nothing is added.
  bool get isEmpty => providers.isEmpty && instances.isEmpty;

  /// The host [provider] sends to; empty when it uses its service's
  /// official API (no base URL).
  static String hostOf(AiProviderConfig provider) {
    final url = SettingsBackupSection.normalizedBaseUrl(provider.baseUrl);
    return url.isEmpty ? '' : Uri.tryParse(url)?.host ?? url;
  }

  /// The host of [instance] (its address when it has none).
  static String instanceHostOf(MozhiInstance instance) {
    final host = Uri.tryParse(instance.url)?.host ?? '';
    return host.isEmpty ? instance.url : host;
  }

  @override
  List<Object?> get props => [providers, instances];
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
  /// Only for a provider on the server these secrets are for: callers
  /// check [SettingsBackupSection.sameServer].
  AiProviderConfig applyTo(AiProviderConfig provider) =>
      SettingsBackupSection._filled(
        provider,
        apiKey: apiKeys[provider.id],
        headers: headers[provider.id],
      );

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
