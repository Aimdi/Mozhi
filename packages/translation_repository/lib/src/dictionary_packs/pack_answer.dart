import 'package:translation_repository/src/dictionary_packs/key_folder.dart';
import 'package:translation_repository/src/dictionary_packs/offline_dictionary.dart';
import 'package:translation_repository/src/dictionary_packs/pack_entry.dart';
import 'package:translation_repository/src/dictionary_packs/pack_reader.dart';
import 'package:translation_repository/src/models/ai_features.dart';

/// How a pack's entries become one [DictionaryEntry] for the dictionary
/// screens.
extension DictionaryPackAnswers on DictionaryPackReader {
  /// Most senses, examples, synonyms and related words in an answer.
  static const maxSenses = 24;
  static const maxExamples = 12;
  static const maxWords = 12;

  /// Most translations per sense.
  static const maxTranslations = 6;

  /// The answer for [word], with translations into [target] (a language
  /// code) when the pack has them; null when the pack does not have it.
  ///
  /// * The entries [word] is the headword of win: the ones written exactly
  ///   like it, else the same but for case, else the same but for case
  ///   and accents (`cafe` finds `café`), merged into one entry (each
  ///   part of speech's senses in turn).
  /// * Else, when [word] is an inflected form, its lemma's entries
  ///   ([OfflineDictionaryAnswer.inflectedForm]: `went` answers with
  ///   `go`).
  /// * Else entries that only say which word [word] is a form of (the
  ///   pack has no entry for that word).
  ///
  /// Other words [word] is an inflected form of are listed in
  /// [OfflineDictionaryAnswer.otherLemmas].
  Future<OfflineDictionaryAnswer?> define(String word, {String? target}) async {
    final query = DictionaryKeyFolder.collapseSpaces(word);
    final hits = await lookUp(query);
    if (hits.isEmpty) return null;
    final direct = [
      for (final hit in hits)
        if (!hit.viaForm) hit.entry,
    ];
    final lemmas = [
      for (final hit in hits)
        if (hit.viaForm && !hit.entry.isFormOf) hit.entry,
    ];
    final full = [
      for (final entry in direct)
        if (!entry.isFormOf) entry,
    ];
    List<DictionaryPackEntry> chosen;
    String? inflectedForm;
    if (full.isNotEmpty) {
      chosen = _closest(full, query);
    } else if (lemmas.isNotEmpty) {
      final lemma = lemmas.first.word;
      chosen = [
        for (final entry in lemmas)
          if (entry.word == lemma) entry,
      ];
      inflectedForm = query;
    } else {
      chosen = _closest(direct, query);
    }
    final shown = {for (final entry in chosen) entry.word};
    final others = <String>[];
    void addOther(String lemma) {
      final clean = lemma.trim();
      if (clean.isNotEmpty &&
          !shown.contains(clean) &&
          !others.contains(clean)) {
        others.add(clean);
      }
    }

    for (final entry in lemmas) {
      addOther(entry.word);
    }
    if (full.isNotEmpty) {
      for (final entry in direct) {
        for (final sense in entry.senses) {
          addOther(sense.formOf);
        }
      }
    }
    return OfflineDictionaryAnswer(
      entry: mergePackEntries(chosen, target: target),
      language: header.language,
      attribution: header.attribution,
      inflectedForm: inflectedForm,
      otherLemmas: List.unmodifiable(others),
    );
  }

  /// The entries of [entries] written closest to [query]: exactly, else
  /// the same but for case, else all of them (folded alike).
  static List<DictionaryPackEntry> _closest(
    List<DictionaryPackEntry> entries,
    String query,
  ) {
    final exact = [
      for (final entry in entries)
        if (entry.word == query) entry,
    ];
    if (exact.isNotEmpty) return exact;
    final lower = query.toLowerCase();
    final caseless = [
      for (final entry in entries)
        if (entry.word.toLowerCase() == lower) entry,
    ];
    if (caseless.isNotEmpty) return caseless;
    final first = entries.first.word;
    return [
      for (final entry in entries)
        if (entry.word == first) entry,
    ];
  }
}

/// [entries] (one headword, one entry per part of speech) as one
/// [DictionaryEntry]: the first IPA and etymology, every part of speech,
/// each entry's senses in turn (with their qualifiers as the usage and
/// their translations into [target]), the examples, synonyms and related
/// words, within the limits of [DictionaryPackAnswers].
DictionaryEntry mergePackEntries(
  List<DictionaryPackEntry> entries, {
  String? target,
}) {
  if (entries.isEmpty) throw ArgumentError.value(entries, 'entries', 'Empty');
  final word = entries.first.word;
  final partsOfSpeech = <String>[];
  final senses = <DictionarySense>[];
  final examples = <DictionaryExample>[];
  final synonyms = <String>[];
  final related = <String>[];
  void addWord(List<String> list, String value) {
    final clean = value.trim();
    if (clean.isEmpty ||
        clean == word ||
        list.contains(clean) ||
        list.length >= DictionaryPackAnswers.maxWords) {
      return;
    }
    list.add(clean);
  }

  for (final entry in entries) {
    final pos = entry.partOfSpeech.trim();
    if (pos.isNotEmpty && !partsOfSpeech.contains(pos)) partsOfSpeech.add(pos);
    final translations = _translationsFor(entry, target);
    for (final (index, sense) in entry.senses.indexed) {
      for (final example in sense.examples) {
        if (examples.length < DictionaryPackAnswers.maxExamples &&
            example.text.trim().isNotEmpty) {
          examples.add(
            DictionaryExample(
              source: example.text.trim(),
              translation: example.translation.trim(),
            ),
          );
        }
      }
      final gloss = sense.gloss.trim();
      if (gloss.isEmpty || senses.length >= DictionaryPackAnswers.maxSenses) {
        continue;
      }
      final words = <String>[];
      for (final translation in translations) {
        final rendering = translation.word.trim();
        final applies =
            translation.sense == index || (index == 0 && translation.sense < 0);
        if (applies &&
            rendering.isNotEmpty &&
            !words.contains(rendering) &&
            words.length < DictionaryPackAnswers.maxTranslations) {
          words.add(rendering);
        }
      }
      senses.add(
        DictionarySense(
          definition: gloss,
          partOfSpeech: pos,
          translations: List.unmodifiable(words),
          usage: sense.tags.trim(),
        ),
      );
    }
    for (final synonym in entry.synonyms) {
      addWord(synonyms, synonym);
    }
    for (final word in entry.relatedWords) {
      addWord(related, word);
    }
  }
  String first(String Function(DictionaryPackEntry entry) field) {
    for (final entry in entries) {
      final value = field(entry).trim();
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  return DictionaryEntry(
    word: word,
    pronunciation: first((entry) => entry.pronunciation),
    partsOfSpeech: List.unmodifiable(partsOfSpeech),
    senses: List.unmodifiable(senses),
    examples: List.unmodifiable(examples),
    synonyms: List.unmodifiable(synonyms),
    etymology: first((entry) => entry.etymology),
    relatedWords: List.unmodifiable(related),
  );
}

/// [entry]'s translations into [target]: its own code, else the same
/// primary language (`zh-TW` uses `zh`, `pt` uses `pt-BR`).
List<DictionaryPackTranslation> _translationsFor(
  DictionaryPackEntry entry,
  String? target,
) {
  if (target == null || entry.translations.isEmpty) return const [];
  final exact = entry.translations[target];
  if (exact != null) return exact;
  for (final MapEntry(:key, :value) in entry.translations.entries) {
    if (dictionaryLanguageMatches(key, target)) return value;
  }
  return const [];
}
