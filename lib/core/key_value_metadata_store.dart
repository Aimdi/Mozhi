import 'package:mozhi/core/key_value_store.dart';
import 'package:translation_repository/translation_repository.dart';

/// Persists the translation repository's metadata (Mozhi engine and
/// language lists) in a [KeyValueStore], usually the app's
/// [PreferencesStore].
class KeyValueMetadataStore implements MetadataStore {
  new(this._store);

  final KeyValueStore _store;

  @override
  Future<String?> read(String key) => _store.read(key);

  @override
  Future<void> write(String key, String value) => _store.write(key, value);
}
