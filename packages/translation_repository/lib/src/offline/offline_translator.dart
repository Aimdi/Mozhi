import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:translation_repository/src/models/aligned_span.dart';

/// On-device ("Offline") translation backend, e.g. Google ML Kit on
/// Android/iOS. Implemented outside this pure-Dart package (see
/// `packages/mlkit_translator`) and injected into `TranslationRepository`.
///
/// Backends with more to offer (cancellation, warm-up, alignment and
/// confidence) also implement [DetailedOfflineTranslator].
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

/// An [OfflineTranslator] whose requests can be cancelled and warmed up,
/// and whose translations can say where each sentence and word came from
/// and how sure the engine was ([translateDetailed]).
///
/// A separate interface, so that every [OfflineTranslator] keeps working:
/// callers check for it (`translator is DetailedOfflineTranslator`) and
/// fall back to [OfflineTranslator.translate].
abstract interface class DetailedOfflineTranslator
    implements OfflineTranslator {
  /// [OfflineTranslator.translate]. Once [abort] completes, the request
  /// stops before the next piece of work (a request waiting for the
  /// engine never starts) and fails with
  /// [OfflineTranslationCancelledException].
  @override
  Future<String> translate(
    String text, {
    required String source,
    required String target,
    Future<void>? abort,
  });

  /// [translate] with the [OfflineTranslation.sentences] of the result:
  /// which source sentence and word each part of the translation comes
  /// from, and the engine's confidence ([OfflineSentence.isLowConfidence]).
  Future<OfflineTranslation> translateDetailed(
    String text, {
    required String source,
    required String target,
    Future<void>? abort,
  });

  /// Loads the models of [source] → [target] ahead of the first
  /// translation (when the on-device engine is selected for an installed
  /// pair, or the input gains focus), so that it starts at once.
  ///
  /// Never downloads anything and never throws: returns false (and does
  /// nothing) for an `auto` source, a pair without models on the device or
  /// an engine that cannot run; true once the models are loaded.
  Future<bool> preload({required String source, required String target});
}

/// An [OfflineTranslator] whose language downloads can be stopped
/// ([cancelDownload]).
///
/// A separate interface, so that every [OfflineTranslator] keeps working:
/// callers check for it (`translator is CancellableDownloads`) and offer
/// no Cancel otherwise.
abstract interface class CancellableDownloads implements OfflineTranslator {
  /// Stops every running [OfflineTranslator.downloadLanguage] of [code]:
  /// the request is closed, nothing more is written, and those calls fail
  /// with [OfflineDownloadCancelledException]. The language stays not
  /// downloaded, unless its models were installed already. What was
  /// received may be kept (never as an installed model) so that the next
  /// download of [code] resumes it.
  ///
  /// Completes once those downloads have stopped; does nothing when no
  /// download of [code] is running. Never throws.
  Future<void> cancelDownload(String code);
}

/// A download was stopped with [CancellableDownloads.cancelDownload]
/// before it finished. Nothing was installed by it.
final class OfflineDownloadCancelledException implements Exception {
  const new([this.language]);

  /// The language whose download was cancelled, when known.
  final String? language;

  @override
  String toString() => 'OfflineDownloadCancelledException(${language ?? ''})';
}

/// The request was cancelled (its `abort` completed) before it finished.
final class OfflineTranslationCancelledException implements Exception {
  const new();

  @override
  String toString() => 'OfflineTranslationCancelledException()';
}

/// A translation with what [DetailedOfflineTranslator.translateDetailed]
/// knows about it. Offsets are UTF-16 code units (like
/// [String.substring]): source offsets into the text that was translated,
/// target offsets into [text]. Starts are inclusive, ends exclusive.
@immutable
final class OfflineTranslation {
  const new({required this.text, this.sentences = const []});

  /// The translation.
  final String text;

  /// The translated sentences in order (none when the engine reports
  /// none, e.g. for blank text or identical languages).
  final List<OfflineSentence> sentences;

  /// Alignment probability a word needs to be highlighted with its source
  /// word by [alignedSpans].
  static const minAlignment = 0.2;

  /// Whether the engine is unsure about any sentence.
  bool get hasLowConfidence => sentences.any((s) => s.isLowConfidence);

  /// The sentences the engine is unsure about (for "this sentence may be
  /// wrong" hints).
  List<OfflineSentence> get lowConfidenceSentences => [
    for (final sentence in sentences)
      if (sentence.isLowConfidence) sentence,
  ];

  /// The word alignment as [AlignedSpan]s for highlighting a word and its
  /// counterpart (`TranslationRepository.align`): one span per translated
  /// word whose source word is known with at least [minimum] probability;
  /// neighbouring words that come from the same source word are one span.
  /// In translation order.
  List<AlignedSpan> alignedSpans({double minimum = minAlignment}) {
    final spans = <AlignedSpan>[];
    for (final sentence in sentences) {
      AlignedSpan? open;
      for (final word in sentence.words) {
        final (start, end) = (word.sourceStart, word.sourceEnd);
        final aligned =
            start != null &&
            end != null &&
            end > start &&
            word.targetEnd > word.targetStart &&
            (word.alignment ?? 0) >= minimum;
        if (!aligned) {
          if (open != null) spans.add(open);
          open = null;
          continue;
        }
        if (open != null &&
            open.sourceStart == start &&
            open.sourceEnd == end) {
          open = AlignedSpan(
            sourceStart: start,
            sourceEnd: end,
            targetStart: open.targetStart,
            targetEnd: word.targetEnd,
          );
          continue;
        }
        if (open != null) spans.add(open);
        open = AlignedSpan(
          sourceStart: start,
          sourceEnd: end,
          targetStart: word.targetStart,
          targetEnd: word.targetEnd,
        );
      }
      if (open != null) spans.add(open);
    }
    return spans;
  }

  static const _sentences = ListEquality<OfflineSentence>();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OfflineTranslation &&
          other.text == text &&
          _sentences.equals(other.sentences, sentences);

  @override
  int get hashCode => Object.hash(text, _sentences.hash(sentences));

  @override
  String toString() =>
      'OfflineTranslation(${text.length} chars, '
      '${sentences.length} sentences)';
}

/// One sentence of an [OfflineTranslation]: its range in the source text
/// and in the translation, the engine's confidence and its words.
@immutable
final class OfflineSentence {
  const new({
    required this.sourceStart,
    required this.sourceEnd,
    required this.targetStart,
    required this.targetEnd,
    this.score,
    this.isLowConfidence = false,
    this.words = const [],
  });

  /// Start of the sentence in the source text (inclusive).
  final int sourceStart;

  /// End of the sentence in the source text (exclusive).
  final int sourceEnd;

  /// Start of its translation in [OfflineTranslation.text] (inclusive).
  final int targetStart;

  /// End of its translation in [OfflineTranslation.text] (exclusive).
  final int targetEnd;

  /// The engine's confidence in the translation, on the engine's own
  /// scale (Bergamot: the mean log-probability of its words, at most 0;
  /// closer to 0 is surer). Null when the engine does not say.
  final double? score;

  /// Whether the engine is unsure about this sentence (its [score] is below
  /// the engine's threshold): worth a "may be inaccurate" hint, or a
  /// second opinion from another engine.
  final bool isLowConfidence;

  /// The translated words in order (none when the engine reports none).
  final List<OfflineWord> words;

  /// The sentence in [source] (the text that was translated).
  String sourceIn(String source) => source.substring(sourceStart, sourceEnd);

  /// The sentence in [translation] ([OfflineTranslation.text]).
  String targetIn(String translation) =>
      translation.substring(targetStart, targetEnd);

  /// This sentence with every source offset moved by [source] and every
  /// target offset by [target] (for pieces of a longer text).
  OfflineSentence shift({int source = 0, int target = 0}) =>
      source == 0 && target == 0
      ? this
      : OfflineSentence(
          sourceStart: sourceStart + source,
          sourceEnd: sourceEnd + source,
          targetStart: targetStart + target,
          targetEnd: targetEnd + target,
          score: score,
          isLowConfidence: isLowConfidence,
          words: [
            for (final word in words)
              word.shift(source: source, target: target),
          ],
        );

  /// This sentence with [isLowConfidence] set to [value].
  OfflineSentence withLowConfidence({required bool value}) =>
      value == isLowConfidence
      ? this
      : OfflineSentence(
          sourceStart: sourceStart,
          sourceEnd: sourceEnd,
          targetStart: targetStart,
          targetEnd: targetEnd,
          score: score,
          isLowConfidence: value,
          words: words,
        );

  static const _words = ListEquality<OfflineWord>();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OfflineSentence &&
          other.sourceStart == sourceStart &&
          other.sourceEnd == sourceEnd &&
          other.targetStart == targetStart &&
          other.targetEnd == targetEnd &&
          other.score == score &&
          other.isLowConfidence == isLowConfidence &&
          _words.equals(other.words, words);

  @override
  int get hashCode => Object.hash(
    sourceStart,
    sourceEnd,
    targetStart,
    targetEnd,
    score,
    isLowConfidence,
    _words.hash(words),
  );

  @override
  String toString() =>
      'OfflineSentence($sourceStart-$sourceEnd -> $targetStart-$targetEnd'
      '${score == null ? '' : ', score $score'}'
      '${isLowConfidence ? ', low confidence' : ''}, '
      '${words.length} words)';
}

/// One translated word of an [OfflineSentence] and the source word it
/// comes from.
@immutable
final class OfflineWord {
  const new({
    required this.targetStart,
    required this.targetEnd,
    this.sourceStart,
    this.sourceEnd,
    this.alignment,
    this.score,
  });

  /// Start of the word in [OfflineTranslation.text] (inclusive).
  final int targetStart;

  /// End of the word in [OfflineTranslation.text] (exclusive).
  final int targetEnd;

  /// Start of the source word it translates (inclusive), or null when the
  /// engine does not say.
  final int? sourceStart;

  /// End of the source word it translates (exclusive), or null.
  final int? sourceEnd;

  /// How sure the engine is that the word comes from that source word,
  /// 0-1; null when unknown.
  final double? alignment;

  /// The engine's confidence in the word, on the scale of
  /// [OfflineSentence.score]; null when unknown.
  final double? score;

  /// This word with every source offset moved by [source] and every target
  /// offset by [target].
  OfflineWord shift({int source = 0, int target = 0}) =>
      source == 0 && target == 0
      ? this
      : OfflineWord(
          targetStart: targetStart + target,
          targetEnd: targetEnd + target,
          sourceStart: sourceStart == null ? null : sourceStart! + source,
          sourceEnd: sourceEnd == null ? null : sourceEnd! + source,
          alignment: alignment,
          score: score,
        );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OfflineWord &&
          other.targetStart == targetStart &&
          other.targetEnd == targetEnd &&
          other.sourceStart == sourceStart &&
          other.sourceEnd == sourceEnd &&
          other.alignment == alignment &&
          other.score == score;

  @override
  int get hashCode => Object.hash(
    targetStart,
    targetEnd,
    sourceStart,
    sourceEnd,
    alignment,
    score,
  );

  @override
  String toString() =>
      'OfflineWord($targetStart-$targetEnd'
      '${sourceStart == null ? '' : ' <- $sourceStart-$sourceEnd'})';
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
