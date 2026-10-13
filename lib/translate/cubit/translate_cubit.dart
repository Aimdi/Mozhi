import 'package:bloc/bloc.dart';
import 'package:mozhi/translate/cubit/translate_state.dart';
import 'package:translation_repository/translation_repository.dart';

export 'translate_state.dart';

/// Drives the translate screen.
///
/// * Reads initial engine/languages/options from [settings] and writes
///   selection changes back (`setEngine`, `setLanguages`,
///   `addRecentLanguage`, `setOptions`).
/// * Typing ([setInput]) debounces and auto-translates when
///   `instantTranslate` (Mozhi) / `instantTranslateAi` (AI) is on; any new
///   translation cancels the in-flight one (stream subscription cancel).
/// * Completed translations are added to [history] when `saveHistory`.
/// * Changing text/engine/languages/options clears extras.
/// * When the detected language equals the target (auto source), the target
///   switches to the most recent other language (Kagi/Google smart swap).
class TranslateCubit extends Cubit<TranslateState> {
  new() : super(const TranslateState());

  /// Loads engines + language lists for the selected engine. Call on start
  /// and whenever instances/providers change ([refresh] forces refetch).
  Future<void> loadEngines({bool refresh = false}) =>
      throw UnimplementedError();

  /// Keeps current languages when possible via `LanguageMatcher`.
  Future<void> selectEngine(TranslationEngine engine) =>
      throw UnimplementedError();
  void setInput(String text) => throw UnimplementedError();

  /// Replaces input and translates immediately (share intents, history).
  void setInputAndTranslate(String text) => throw UnimplementedError();
  void setSource(Language language) => throw UnimplementedError();
  void setTarget(Language language) => throw UnimplementedError();

  /// Swaps languages (detected language when auto) and moves the output
  /// into the input.
  void swap() => throw UnimplementedError();
  void setOptions(TranslationOptions options) => throw UnimplementedError();

  /// Translate now (button / Ctrl+Enter).
  Future<void> translate() => throw UnimplementedError();
  void clear() => throw UnimplementedError();

  /// Re-translates with the suggestion's instruction as a one-off.
  Future<void> applySuggestion(RefinementSuggestion suggestion) =>
      throw UnimplementedError();

  /// Replaces the output with an alternative (and records it in history).
  void useAlternative(String text) => throw UnimplementedError();

  /// Replaces the first occurrence of [insight.targetText] in the output
  /// with [variation], and updates the insight's targetText.
  void applyVariation(WordInsight insight, String variation) =>
      throw UnimplementedError();

  void setCompareMode({required bool enabled}) => throw UnimplementedError();
  Future<void> runCompare() => throw UnimplementedError();

  /// Selects [entry] as the main result (and its engine).
  void useCompareEntry(CompareEntry entry) => throw UnimplementedError();

  Future<void> loadAlternatives({String? span}) => throw UnimplementedError();
  Future<void> loadInsights() => throw UnimplementedError();
  Future<void> loadSuggestions() => throw UnimplementedError();
  Future<void> explain({String? question}) => throw UnimplementedError();

  /// Dictionary for the (short) input.
  Future<void> lookUp() => throw UnimplementedError();
  void clearExtras() => throw UnimplementedError();
}
