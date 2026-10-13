import 'package:mozhi/settings/models/app_settings.dart';

/// Loads/saves [AppSettings]: JSON under key `settings.v1` in [prefs];
/// each provider's API key under `apikey.<providerId>` in [secrets].
/// Corrupt JSON falls back to defaults (never throws from [load]).
/// [save] deletes keys of providers that no longer exist.
class SettingsRepository {
  new();

  Future<AppSettings> load() => throw UnimplementedError('TODO(app-data)');

  Future<void> save(AppSettings settings) =>
      throw UnimplementedError('TODO(app-data)');
}
