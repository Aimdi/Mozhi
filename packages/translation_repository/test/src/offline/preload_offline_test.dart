import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

const _en = Language(code: 'en', name: 'English');
const _de = Language(code: 'de', name: 'German');
const _ja = Language(code: 'ja', name: 'Japanese');

/// A [DetailedOfflineTranslator] that records its preloads.
class _Preloading implements DetailedOfflineTranslator {
  @override
  bool get isAvailable => true;

  @override
  Set<String> get supportedLanguages => const {'en', 'de'};

  /// What [preload] answers.
  bool answer = true;

  /// What [preload] throws instead, when set.
  Error? failure;

  final preloads = <(String, String)>[];

  @override
  Future<bool> preload({required String source, required String target}) async {
    preloads.add((source, target));
    final failure = this.failure;
    if (failure != null) throw failure;
    return answer;
  }

  @override
  Future<String> translate(
    String text, {
    required String source,
    required String target,
    Future<void>? abort,
  }) async => text;

  @override
  Future<OfflineTranslation> translateDetailed(
    String text, {
    required String source,
    required String target,
    Future<void>? abort,
  }) async => OfflineTranslation(text: text);

  @override
  Future<Set<String>> downloadedLanguages() async => supportedLanguages;

  @override
  Future<void> downloadLanguage(String code, {bool wifiOnly = true}) async {}

  @override
  Future<void> deleteLanguage(String code) async {}

  @override
  Future<String?> identifyLanguage(String text) async => null;

  @override
  Future<void> dispose() async {}
}

/// An [OfflineTranslator] that cannot preload.
class _Plain implements OfflineTranslator {
  @override
  bool get isAvailable => true;

  @override
  Set<String> get supportedLanguages => const {'en', 'de'};

  @override
  Future<String> translate(
    String text, {
    required String source,
    required String target,
  }) async => text;

  @override
  Future<Set<String>> downloadedLanguages() async => supportedLanguages;

  @override
  Future<void> downloadLanguage(String code, {bool wifiOnly = true}) async {}

  @override
  Future<void> deleteLanguage(String code) async {}

  @override
  Future<String?> identifyLanguage(String text) async => null;

  @override
  Future<void> dispose() async {}
}

void main() {
  final offline = TranslationEngine.offline();

  group('TranslationRepository.preloadOffline', () {
    test('preloads the pair with the engine codes', () async {
      final translator = _Preloading();
      final repository = TranslationRepository(offline: translator);
      expect(
        await repository.preloadOffline(offline, source: _en, target: _de),
        isTrue,
      );
      expect(translator.preloads, [('en', 'de')]);
    });

    test("passes on the translator's answer", () async {
      final translator = _Preloading()..answer = false;
      final repository = TranslationRepository(offline: translator);
      expect(
        await repository.preloadOffline(offline, source: _de, target: _en),
        isFalse,
      );
      expect(translator.preloads, [('de', 'en')]);
    });

    test('is false when the translator fails', () async {
      final translator = _Preloading()..failure = StateError('no models');
      final repository = TranslationRepository(offline: translator);
      expect(
        await repository.preloadOffline(offline, source: _en, target: _de),
        isFalse,
      );
    });

    test('does nothing for an automatic source', () async {
      final translator = _Preloading();
      final repository = TranslationRepository(offline: translator);
      expect(
        await repository.preloadOffline(
          offline,
          source: Language.auto,
          target: _de,
        ),
        isFalse,
      );
      expect(translator.preloads, isEmpty);
    });

    test('does nothing for a language the engine lacks', () async {
      final translator = _Preloading();
      final repository = TranslationRepository(offline: translator);
      expect(
        await repository.preloadOffline(offline, source: _ja, target: _de),
        isFalse,
      );
      expect(
        await repository.preloadOffline(offline, source: _en, target: _en),
        isFalse,
      );
      expect(translator.preloads, isEmpty);
    });

    test('does nothing for another engine', () async {
      final translator = _Preloading();
      final repository = TranslationRepository(offline: translator);
      const mozhi = TranslationEngine(
        id: 'mozhi:google',
        name: 'Google',
        kind: EngineKind.mozhi,
      );
      expect(
        await repository.preloadOffline(mozhi, source: _en, target: _de),
        isFalse,
      );
      expect(translator.preloads, isEmpty);
    });

    test('does nothing without a translator that can preload', () async {
      final repository = TranslationRepository(offline: _Plain());
      expect(
        await repository.preloadOffline(offline, source: _en, target: _de),
        isFalse,
      );
      expect(
        await TranslationRepository().preloadOffline(
          offline,
          source: _en,
          target: _de,
        ),
        isFalse,
      );
    });
  });
}
