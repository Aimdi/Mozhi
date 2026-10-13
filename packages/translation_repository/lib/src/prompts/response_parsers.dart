import 'package:translation_repository/src/models/models.dart';

/// Lenient parsers for LLM output.
abstract final class ResponseParsers {
  /// Extracts the first JSON object from [text]: strips ```json fences,
  /// leading prose and `<think>` blocks, tolerates trailing commas and
  /// smart quotes around keys. Throws [FormatException] when nothing
  /// parseable is found.
  static Map<String, dynamic> extractJsonObject(String text) {
    throw UnimplementedError('TODO(translation_repository)');
  }

  /// Splits a leading `[[lang:xx]]` marker (also tolerating `[lang:xx]`,
  /// `⟦xx⟧`, `[[xx]]`, surrounding whitespace, and a newline after it).
  /// Returns (code or null, remaining text). While streaming, call with the
  /// accumulated text; [isMarkerPending] tells whether the prefix could
  /// still become a marker (so the UI should not show it yet).
  static ({String? language, String text}) splitLanguageMarker(String text) {
    throw UnimplementedError('TODO(translation_repository)');
  }

  static bool isMarkerPending(String accumulated) {
    throw UnimplementedError('TODO(translation_repository)');
  }

  /// Removes wrapping quotes / `<translation>` / `<source>` tags /
  /// "Translation:" prefixes that models sometimes add, only when the
  /// source text itself did not have them.
  static String cleanTranslation(String output, {required String source}) {
    throw UnimplementedError('TODO(translation_repository)');
  }

  static AlternativeTranslations parseAlternatives(String output) {
    throw UnimplementedError('TODO(translation_repository)');
  }

  /// Drops insights whose `target` is not a substring of [translation].
  static List<WordInsight> parseInsights(
    String output, {
    required String translation,
  }) {
    throw UnimplementedError('TODO(translation_repository)');
  }

  static List<RefinementSuggestion> parseSuggestions(String output) {
    throw UnimplementedError('TODO(translation_repository)');
  }

  static DictionaryEntry parseDictionary(String output) {
    throw UnimplementedError('TODO(translation_repository)');
  }

  /// Drops edits whose `original` does not occur in [input].
  static ProofreadResult parseProofread(String output, {required String input}) {
    throw UnimplementedError('TODO(translation_repository)');
  }

  static DetectedLanguage parseDetectedLanguage(String output) {
    throw UnimplementedError('TODO(translation_repository)');
  }
}
