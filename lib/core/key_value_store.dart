import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Minimal async string store so repositories are testable without
/// platform channels.
abstract interface class KeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Plain preferences (settings, history).
///
/// The underlying [SharedPreferencesAsync] is created lazily on first use, so
/// constructing a [PreferencesStore] never touches platform plugins (handy in
/// tests and before plugin registration). Failures surface from the
/// individual operations instead.
class PreferencesStore implements KeyValueStore {
  new([SharedPreferencesAsync? prefs]) : _instance = prefs;

  SharedPreferencesAsync? _instance;

  SharedPreferencesAsync get _prefs => _instance ??= SharedPreferencesAsync();

  @override
  Future<String?> read(String key) => _prefs.getString(key);

  @override
  Future<void> write(String key, String value) => _prefs.setString(key, value);

  @override
  Future<void> delete(String key) => _prefs.remove(key);
}

/// Encrypted storage for API keys.
class SecureStore implements KeyValueStore {
  new([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// In-memory store for tests and as a fallback when secure storage is
/// unavailable.
class MemoryStore implements KeyValueStore {
  new([Map<String, String>? initial]) : values = {...?initial};

  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}
