/// On-device ("Offline") translation backend, e.g. Google ML Kit on
/// Android/iOS. Implemented outside this pure-Dart package (see
/// `packages/mlkit_translator`) and injected into `TranslationRepository`.
abstract interface class OfflineTranslator {
  /// False on platforms without a backend (web, desktop).
  bool get isAvailable;

  /// BCP-47 codes this backend can translate between (e.g. 59 ML Kit
  /// languages: `af`, `sq`, `ar`, ..., `zh`, `cy`).
  Set<String> get supportedLanguages;

  /// Languages whose models are on the device.
  Future<Set<String>> downloadedLanguages();

  /// Downloads the model for [code] (~30 MB). With [wifiOnly] the download
  /// waits for an unmetered connection.
  Future<void> downloadLanguage(String code, {bool wifiOnly = true});

  Future<void> deleteLanguage(String code);

  /// Translates between two supported languages. Throws
  /// [OfflineModelMissingException] when a model is not downloaded (it must
  /// never start a silent download over mobile data).
  Future<String> translate(
    String text, {
    required String source,
    required String target,
  });

  /// BCP-47 code of [text]'s language, or null when undetermined.
  Future<String?> identifyLanguage(String text);

  Future<void> dispose();
}

/// The models for [languages] must be downloaded first.
final class OfflineModelMissingException implements Exception {
  const new(this.languages);

  final List<String> languages;

  @override
  String toString() => 'OfflineModelMissingException(${languages.join(', ')})';
}

/// The language is not supported by the offline backend.
final class OfflineLanguageUnsupportedException implements Exception {
  const new(this.language);

  final String language;

  @override
  String toString() => 'OfflineLanguageUnsupportedException($language)';
}
