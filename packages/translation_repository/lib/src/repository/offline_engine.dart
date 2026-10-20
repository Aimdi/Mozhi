import 'package:translation_repository/src/language_catalog.dart';
import 'package:translation_repository/src/language_matcher.dart';
import 'package:translation_repository/src/models/models.dart';
import 'package:translation_repository/src/offline/offline_translator.dart';
import 'package:translation_repository/src/repository/mappers.dart';
import 'package:translation_repository/src/repository/repository_exceptions.dart';

/// Language lists and translation for the on-device engine
/// ([TranslationEngine.offline]) backed by an [OfflineTranslator].
class OfflineEngine {
  new(this.translator);

  final OfflineTranslator translator;

  bool get isAvailable => translator.isAvailable;

  List<Language>? _languages;
  Set<String>? _languagesFor;

  /// The backend's languages ([OfflineTranslator.supportedLanguages]) with
  /// their backend codes, catalogue names and native names, sorted by name.
  List<Language> get languages {
    final supported = translator.supportedLanguages;
    if (_languages != null && identical(_languagesFor, supported)) {
      return _languages!;
    }
    final languages = [
      for (final code in supported)
        if (code.trim().isNotEmpty)
          Language(
            code: code,
            name: LanguageCatalog.byCode(code)?.name ?? code,
            nativeName: LanguageCatalog.byCode(code)?.nativeName,
          ),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    _languagesFor = supported;
    return _languages = List.unmodifiable(languages);
  }

  /// [Language.auto] followed by [languages].
  List<Language> get sourceLanguages =>
      List.unmodifiable([Language.auto, ...languages]);

  /// The backend code for [language], or null when the backend has no
  /// model for it. A Traditional Chinese [isTarget] is never mapped onto a
  /// Simplified model.
  String? codeFor(Language language, {bool isTarget = false}) {
    if (language.isCustom || language.isAuto) return null;
    final match = LanguageMatcher.match(language, languages);
    if (match == null) return null;
    final wanted = LanguageMatcher.normalize(language.code);
    if (isTarget &&
        wanted == 'zh-TW' &&
        LanguageMatcher.normalize(match.code) != wanted) {
      return null;
    }
    return match.code;
  }

  /// Translates [request] on the device; one final result.
  ///
  /// An auto source is identified with [OfflineTranslator.identifyLanguage];
  /// when it cannot tell, the only downloaded language that can be
  /// translated into the target is used ([onlyDownloadedSource]), else
  /// [SourceLanguageRequiredException] is thrown. Languages
  /// without a model throw [OfflineLanguageUnsupportedException]; models
  /// that are not downloaded throw [OfflineModelMissingException] (from the
  /// backend).
  Future<TranslationResult> translate(
    TranslationEngine engine,
    TranslationRequest request,
  ) async {
    if (!translator.isAvailable) {
      throw ArgumentError.value(
        engine.id,
        'engine',
        'Offline translation is not available on this device',
      );
    }
    if (request.source.isCustom || request.target.isCustom) {
      final custom = request.source.isCustom ? request.source : request.target;
      throw ArgumentError.value(
        custom.code,
        request.source.isCustom ? 'source' : 'target',
        'Custom languages require an AI engine',
      );
    }
    final stopwatch = Stopwatch()..start();
    final target =
        codeFor(request.target, isTarget: true) ??
        (throw OfflineLanguageUnsupportedException(request.target.code));
    String? detected;
    final String source;
    if (request.source.isAuto) {
      var identified = await translator.identifyLanguage(request.text);
      detected = normalizeDetected(identified);
      if (identified == null || detected == null) {
        identified =
            await onlyDownloadedSource(target) ??
            (throw SourceLanguageRequiredException(engineId: engine.id));
        detected = normalizeDetected(identified);
      }
      source =
          codeFor(Language(code: identified, name: identified)) ??
          (throw OfflineLanguageUnsupportedException(identified));
    } else {
      source =
          codeFor(request.source) ??
          (throw OfflineLanguageUnsupportedException(request.source.code));
    }
    final text = source == target
        ? request.text
        : await translator.translate(
            request.text,
            source: source,
            target: target,
          );
    return TranslationResult(
      engineId: engine.id,
      engineName: engine.name,
      text: text,
      detectedSource: detected,
      elapsed: stopwatch.elapsed,
    );
  }

  /// The backend code of the one downloaded language other than [target]
  /// (a backend code), or null when there are none or several: with only
  /// English and German on the device, text into German is English and
  /// text into English is German, whatever a word or two looks like.
  Future<String?> onlyDownloadedSource(String target) async {
    final Set<String> downloaded;
    try {
      downloaded = await translator.downloadedLanguages();
    } on Object {
      return null;
    }
    final wanted = LanguageMatcher.normalize(target);
    final candidates = {
      for (final code in downloaded)
        if (codeFor(Language(code: code, name: code)) case final mapped?
            when LanguageMatcher.normalize(mapped) != wanted)
          mapped,
    };
    return candidates.length == 1 ? candidates.single : null;
  }
}
