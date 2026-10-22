import 'package:translation_repository/src/models/models.dart';
import 'package:translation_repository/src/offline/offline_translator.dart';
import 'package:translation_repository/src/repository/offline_engine.dart';

/// `OfflineEngine.translate` for one request of the repository: with a
/// [DetailedOfflineTranslator], [abort] (completed when the caller cancels
/// the translation) stops the work on the device; other translators
/// cannot be stopped and finish in the background.
Future<TranslationResult> translateOffline(
  OfflineEngine offline,
  TranslationEngine engine,
  TranslationRequest request, {
  Future<void>? abort,
}) {
  final translator = offline.translator;
  if (abort == null || translator is! DetailedOfflineTranslator) {
    return offline.translate(engine, request);
  }
  return OfflineEngine(_RequestTranslator(translator, abort: abort))
      .translate(engine, request);
}

/// `TranslationRepository.align` for the on-device engine: [source] is
/// translated again on the device (instant: the engine caches its
/// sentences, and nothing leaves the device) with word alignment, and the
/// aligned words are located in [translation] (the same text when it came
/// from this engine; otherwise each phrase is looked up in order, and
/// those not found are left out).
///
/// Throws an [ArgumentError] when the translator cannot align
/// ([DetailedOfflineTranslator]); blank texts and identical languages give
/// an empty list. Language errors are those of `OfflineEngine.translate`.
Future<List<AlignedSpan>> alignOffline(
  OfflineEngine offline,
  TranslationEngine engine, {
  required String source,
  required String translation,
  required Language sourceLanguage,
  required Language targetLanguage,
}) async {
  final translator = offline.translator;
  if (translator is! DetailedOfflineTranslator) {
    throw ArgumentError.value(
      engine.id,
      'engine',
      'This on-device engine cannot align translations',
    );
  }
  if (source.trim().isEmpty || translation.trim().isEmpty) return const [];
  final detailed = _RequestTranslator(translator, detailed: true);
  await OfflineEngine(detailed).translate(
    engine,
    TranslationRequest(
      text: source,
      source: sourceLanguage,
      target: targetLanguage,
    ),
  );
  final result = detailed.result;
  if (result == null) return const [];
  return locateAlignment(result, translation);
}

/// The [OfflineTranslation.alignedSpans] of [result], with their target
/// ranges in [translation]: as they are when it is [result]'s text, else
/// found again phrase by phrase, in order and at word boundaries (phrases
/// that are not found are left out).
List<AlignedSpan> locateAlignment(
  OfflineTranslation result,
  String translation,
) {
  final spans = result.alignedSpans();
  if (result.text == translation) return spans;
  final located = <AlignedSpan>[];
  var from = 0;
  for (final span in spans) {
    final phrase = result.text.substring(span.targetStart, span.targetEnd);
    final start = _wordAt(translation, phrase, from);
    if (start == null) continue;
    located.add(
      AlignedSpan(
        sourceStart: span.sourceStart,
        sourceEnd: span.sourceEnd,
        targetStart: start,
        targetEnd: start + phrase.length,
      ),
    );
    from = start + phrase.length;
  }
  return located;
}

/// The first index from [from] where [phrase] occurs in [text] as whole
/// words (no letter or digit right before or after it), or null.
int? _wordAt(String text, String phrase, int from) {
  var start = text.indexOf(phrase, from);
  while (start >= 0) {
    final end = start + phrase.length;
    final before = start == 0 || !_letter.hasMatch(text[start - 1]);
    final after = end == text.length || !_letter.hasMatch(text[end]);
    if (before && after) return start;
    start = text.indexOf(phrase, start + 1);
  }
  return null;
}

final _letter = RegExp(r'[\p{L}\p{N}]', unicode: true);

/// The translator as one request of the repository sees it: translations
/// get its [abort], and with [detailed] are made with
/// [DetailedOfflineTranslator.translateDetailed], the last one kept as
/// [result]. Everything else goes to the translator unchanged; [dispose]
/// does nothing (the request does not own it).
final class _RequestTranslator implements OfflineTranslator {
  new(this._translator, {this.abort, this.detailed = false});

  final DetailedOfflineTranslator _translator;
  final Future<void>? abort;
  final bool detailed;

  /// The last detailed translation.
  OfflineTranslation? result;

  @override
  bool get isAvailable => _translator.isAvailable;

  @override
  Set<String> get supportedLanguages => _translator.supportedLanguages;

  @override
  Future<Set<String>> downloadedLanguages() =>
      _translator.downloadedLanguages();

  // OfflineEngine never manages models: these only complete the interface.
  // coverage:ignore-start
  @override
  Future<void> downloadLanguage(String code, {bool wifiOnly = true}) =>
      _translator.downloadLanguage(code, wifiOnly: wifiOnly);

  @override
  Future<void> deleteLanguage(String code) => _translator.deleteLanguage(code);

  @override
  Future<void> dispose() async {}
  // coverage:ignore-end

  @override
  Future<String> translate(
    String text, {
    required String source,
    required String target,
  }) async {
    if (!detailed) {
      return await _translator.translate(
        text,
        source: source,
        target: target,
        abort: abort,
      );
    }
    final translation = await _translator.translateDetailed(
      text,
      source: source,
      target: target,
      abort: abort,
    );
    result = translation;
    return translation.text;
  }

  @override
  Future<String?> identifyLanguage(String text) =>
      _translator.identifyLanguage(text);
}
