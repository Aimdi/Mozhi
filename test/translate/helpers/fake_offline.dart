import 'dart:io';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:translation_repository/translation_repository.dart';

/// An [OfflineTranslator] with fixed languages: [supportedLanguages] and
/// the [downloaded] ones (English is always there, like Bergamot's).
class FakeOfflineTranslator implements OfflineTranslator {
  new({
    this.isAvailable = true,
    this.supportedLanguages = const {'en', 'de', 'fr', 'ja'},
    Set<String> downloaded = const {},
    this.fails = false,
  }) : downloaded = {'en', ...downloaded};

  @override
  final bool isAvailable;

  @override
  final Set<String> supportedLanguages;

  /// Languages whose models are on the "device".
  final Set<String> downloaded;

  /// Whether [downloadedLanguages] throws.
  final bool fails;

  @override
  Future<Set<String>> downloadedLanguages() async {
    if (fails) throw StateError('storage unavailable');
    return downloaded;
  }

  @override
  Future<void> downloadLanguage(String code, {bool wifiOnly = true}) async {}

  @override
  Future<void> deleteLanguage(String code) async {}

  @override
  Future<String> translate(
    String text, {
    required String source,
    required String target,
  }) async => text;

  @override
  Future<String?> identifyLanguage(String text) async => null;

  @override
  Future<void> dispose() async {}
}

class _NoEngine implements BergamotEngine {
  @override
  Future<String> translate(
    List<ModelPaths> chain,
    String text, {
    bool html = false,
  }) async => text;

  @override
  Future<void> release(String key) async {}

  @override
  Future<void> dispose() async {}
}

/// A [BergamotTranslator] whose catalog has German and French (both
/// directions) with these download sizes per direction; it is never asked
/// to download or translate.
BergamotTranslator fakeBergamot({
  int germanBytes = 12 * 1024 * 1024,
  int frenchBytes = 15 * 1024 * 1024,
}) {
  Map<String, Object?> model(String source, String target, int bytes) {
    Map<String, Object?> file(String kind, int size) => {
      'name': '$kind.$source$target.bin',
      'url': 'https://models.example/$source$target/$kind.gz',
      'size': size,
      'sha256': '0' * 64,
      'uncompressedSize': size,
      'uncompressedSha256': '0' * 64,
    };
    return {
      'source': source,
      'target': target,
      'version': 'v1',
      'files': {
        'model': file('model', bytes),
        'lexicalShortlist': file('lexicalShortlist', 0),
        'vocab': file('vocab', 0),
      },
    };
  }

  return BergamotTranslator(
    catalog: ModelCatalog.fromJson({
      'schemaVersion': 1,
      'models': [
        model('de', 'en', germanBytes),
        model('en', 'de', germanBytes),
        model('fr', 'en', frenchBytes),
        model('en', 'fr', frenchBytes),
      ],
    }),
    root: Directory.systemTemp,
    isMeteredConnection: () async => false,
    engine: _NoEngine(),
    isAvailable: true,
  );
}
