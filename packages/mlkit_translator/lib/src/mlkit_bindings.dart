import 'package:google_mlkit_language_id/google_mlkit_language_id.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

/// The small slice of the ML Kit plugins that `MlKitOfflineTranslator`
/// uses, so it can be unit-tested with fakes.
///
/// All codes are ML Kit model codes (see `MlKitLanguageCodes.supported`).
abstract interface class MlKitBindings {
  /// Whether the model for [code] is on the device.
  Future<bool> isModelDownloaded(String code);

  /// Downloads the model for [code]; true on success (or when it already
  /// is on the device). With [wifiRequired] the download waits for Wi-Fi.
  Future<bool> downloadModel(String code, {required bool wifiRequired});

  /// Deletes the model for [code]; true on success (or when it was absent).
  Future<bool> deleteModel(String code);

  /// A translator between two (downloaded) models.
  MlKitTextTranslator createTranslator({
    required String source,
    required String target,
  });

  /// A language identifier that reports languages with at least
  /// [confidenceThreshold] confidence (0..1).
  MlKitLanguageIdentifier createLanguageIdentifier({
    required double confidenceThreshold,
  });
}

/// A native translator for one language pair.
abstract interface class MlKitTextTranslator {
  Future<String> translate(String text);

  /// Releases the native translator.
  Future<void> close();
}

/// A native language identifier.
abstract interface class MlKitLanguageIdentifier {
  /// BCP-47 code of [text]'s language, `und` when undetermined.
  Future<String> identify(String text);

  /// Releases the native identifier.
  Future<void> close();
}

/// [MlKitBindings] backed by `google_mlkit_translation` and
/// `google_mlkit_language_id` (Android and iOS only).
class GoogleMlKitBindings implements MlKitBindings {
  new({OnDeviceTranslatorModelManager? modelManager})
    : _models = modelManager ?? OnDeviceTranslatorModelManager();

  final OnDeviceTranslatorModelManager _models;

  @override
  Future<bool> isModelDownloaded(String code) =>
      _models.isModelDownloaded(code);

  @override
  Future<bool> downloadModel(String code, {required bool wifiRequired}) =>
      _models.downloadModel(code, isWifiRequired: wifiRequired);

  @override
  Future<bool> deleteModel(String code) => _models.deleteModel(code);

  @override
  MlKitTextTranslator createTranslator({
    required String source,
    required String target,
  }) => _PluginTextTranslator(
    OnDeviceTranslator(
      sourceLanguage: _language(source),
      targetLanguage: _language(target),
    ),
  );

  @override
  MlKitLanguageIdentifier createLanguageIdentifier({
    required double confidenceThreshold,
  }) => _PluginLanguageIdentifier(
    LanguageIdentifier(confidenceThreshold: confidenceThreshold),
  );

  static TranslateLanguage _language(String code) {
    final language = BCP47Code.fromRawValue(code);
    if (language == null) {
      throw ArgumentError.value(code, 'code', 'Not an ML Kit language');
    }
    return language;
  }
}

class _PluginTextTranslator implements MlKitTextTranslator {
  new(this._translator);

  final OnDeviceTranslator _translator;

  @override
  Future<String> translate(String text) => _translator.translateText(text);

  @override
  Future<void> close() => _translator.close();
}

class _PluginLanguageIdentifier implements MlKitLanguageIdentifier {
  new(this._identifier);

  final LanguageIdentifier _identifier;

  @override
  Future<String> identify(String text) => _identifier.identifyLanguage(text);

  @override
  Future<void> close() => _identifier.close();
}
