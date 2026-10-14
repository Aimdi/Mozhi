import 'package:translation_repository/translation_repository.dart';

/// [OfflineTranslator] for builds without an on-device engine (the F-Droid
/// build has no Google ML Kit).
///
/// It is never [isAvailable], so `TranslationRepository` offers no offline
/// engine and the Offline languages screen explains why; it knows no
/// languages, identifies nothing and refuses every model operation with an
/// [UnsupportedError].
class UnavailableOfflineTranslator implements OfflineTranslator {
  const new();

  @override
  bool get isAvailable => false;

  @override
  Set<String> get supportedLanguages => const {};

  @override
  Future<Set<String>> downloadedLanguages() async => const {};

  @override
  Future<void> downloadLanguage(String code, {bool wifiOnly = true}) =>
      Future.error(UnsupportedError('Offline translation is not included'));

  @override
  Future<void> deleteLanguage(String code) =>
      Future.error(UnsupportedError('Offline translation is not included'));

  @override
  Future<String> translate(
    String text, {
    required String source,
    required String target,
  }) => Future.error(UnsupportedError('Offline translation is not included'));

  @override
  Future<String?> identifyLanguage(String text) async => null;

  @override
  Future<void> dispose() async {}
}
