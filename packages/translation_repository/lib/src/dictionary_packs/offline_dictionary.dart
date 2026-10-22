import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:translation_repository/src/dictionary_packs/pack_header.dart';
import 'package:translation_repository/src/models/ai_features.dart';

/// What an offline dictionary has for a word: an entry for the dictionary
/// screens, the language of the word, and the credit its data needs.
@immutable
final class OfflineDictionaryAnswer {
  const new({
    required this.entry,
    required this.language,
    required this.attribution,
    this.inflectedForm,
    this.otherLemmas = const [],
  });

  final DictionaryEntry entry;

  /// The language of the word (the dictionary's language code, e.g. `es`).
  final String language;
  final DictionaryAttribution attribution;

  /// The text that was looked up, when [entry] is the word it is an
  /// inflected form of (`went`, answered with `go`); null when [entry] is
  /// for the text itself.
  final String? inflectedForm;

  /// Other words the text is an inflected form of (`saw`: also `see`).
  final List<String> otherLemmas;

  @override
  bool operator ==(Object other) =>
      other is OfflineDictionaryAnswer &&
      other.entry == entry &&
      other.language == language &&
      other.attribution == attribution &&
      other.inflectedForm == inflectedForm &&
      const ListEquality<String>().equals(other.otherLemmas, otherLemmas);

  @override
  int get hashCode => Object.hash(
    entry,
    language,
    attribution,
    inflectedForm,
    const ListEquality<String>().hash(otherLemmas),
  );

  @override
  String toString() => 'OfflineDictionaryAnswer(${entry.word}, $language)';
}

/// Dictionaries on the device (the app's downloaded dictionary packs):
/// look-ups that need no network and no AI, and send nothing anywhere.
abstract interface class OfflineDictionary {
  /// Language codes of the installed dictionaries.
  Future<List<String>> installedLanguages();

  /// Fires when dictionaries are installed or removed.
  Stream<void> get changes;

  /// The entry for [word] in the dictionary of [language] (a language code;
  /// null tries every installed dictionary and answers with the closest
  /// match), with translations into [target] when the dictionary has them.
  /// Null when no installed dictionary has the word.
  Future<OfflineDictionaryAnswer?> lookUp(
    String word, {
    String? language,
    String? target,
  });

  /// Up to [limit] words that start with [prefix] in the dictionary of
  /// [language] (null: every installed dictionary), for suggestions.
  Future<List<String>> suggest(String prefix, {String? language, int limit});
}

/// Whether a dictionary of [dictionaryLanguage] has the words of the app
/// language [code]: the same code, or the same primary language (`pt-BR`
/// and `pt`, `zh-TW` and `zh`), ignoring case and `_`/`-`.
bool dictionaryLanguageMatches(String dictionaryLanguage, String code) {
  String normal(String value) =>
      value.trim().replaceAll('_', '-').toLowerCase();
  final pack = normal(dictionaryLanguage);
  final app = normal(code);
  if (pack.isEmpty || app.isEmpty) return false;
  return pack == app || pack.split('-').first == app.split('-').first;
}
