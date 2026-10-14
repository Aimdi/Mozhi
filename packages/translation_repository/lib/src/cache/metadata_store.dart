/// A small persistent key-value store for metadata the
/// `TranslationRepository` keeps across launches (Mozhi engine and
/// language lists), so the translate screen can start instantly and work
/// offline.
///
/// Implementations should be cheap to call; failures may be thrown and are
/// ignored by the repository (the data is only a cache).
abstract interface class MetadataStore {
  /// The value stored under [key], or null.
  Future<String?> read(String key);

  /// Stores [value] under [key], replacing any previous value.
  Future<void> write(String key, String value);
}

/// A [MetadataStore] kept in memory (tests, or no persistence at all).
class MemoryMetadataStore implements MetadataStore {
  /// Starts with a copy of [initial].
  new([Map<String, String>? initial]) : values = {...?initial};

  /// The stored values by key.
  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}
