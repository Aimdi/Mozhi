import 'package:bergamot_translator/bergamot_translator.dart'
    show BergamotWebRequirement;
import 'package:translation_repository/translation_repository.dart';

/// [OfflineTranslator] where no on-device engine runs: a browser without
/// what the web engine needs, and any platform where Mozilla's Bergamot
/// engine could not be set up (see `lib/platform/offline_engine.dart`).
///
/// It is never [isAvailable], so `TranslationRepository` offers no offline
/// engine and the Offline languages screen explains why; it knows no
/// languages, identifies nothing and refuses every model operation with an
/// [UnsupportedError].
class UnavailableOfflineTranslator implements OfflineTranslator {
  const new({this.webRequirement});

  /// In the web app: what the browser lacks for the on-device engine (the
  /// first one to tell the user about), or null (not the web, or the
  /// engine failed to start for another reason).
  final BergamotWebRequirement? webRequirement;

  @override
  bool get isAvailable => false;

  @override
  Set<String> get supportedLanguages => const {};

  @override
  Future<Set<String>> downloadedLanguages() async => const {};

  @override
  Future<void> downloadLanguage(String code, {bool wifiOnly = true}) =>
      Future.error(UnsupportedError('Offline translation is not available'));

  @override
  Future<void> deleteLanguage(String code) =>
      Future.error(UnsupportedError('Offline translation is not available'));

  @override
  Future<String> translate(
    String text, {
    required String source,
    required String target,
  }) => Future.error(UnsupportedError('Offline translation is not available'));

  @override
  Future<String?> identifyLanguage(String text) async => null;

  @override
  Future<void> dispose() async {}
}
