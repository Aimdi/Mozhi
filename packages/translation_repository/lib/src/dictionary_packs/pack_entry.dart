import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

const _json = DeepCollectionEquality();

/// One entry of a dictionary pack: a headword with one part of speech, as
/// Wiktionary has it (a word with several parts of speech or etymologies
/// has several entries).
///
/// Stored as a compact JSON object (see [toJson]): `w` word, `p` part of
/// speech, `i` IPA, `s` senses, `y` synonyms, `r` related words, `e`
/// etymology, `t` translations by language. Empty fields are left out.
@immutable
final class DictionaryPackEntry {
  const new({
    required this.word,
    this.partOfSpeech = '',
    this.pronunciation = '',
    this.senses = const [],
    this.synonyms = const [],
    this.relatedWords = const [],
    this.etymology = '',
    this.translations = const {},
  });

  /// Reads [toJson]'s object. Throws [FormatException] for a malformed one.
  factory fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      throw FormatException('Invalid pack entry', json);
    }
    final word = _string(json, 'w');
    if (word.isEmpty) throw FormatException('Pack entry without a word', json);
    final translations = json['t'];
    if (translations != null && translations is! Map<String, Object?>) {
      throw FormatException('Invalid translations', translations);
    }
    return DictionaryPackEntry(
      word: word,
      partOfSpeech: _string(json, 'p'),
      pronunciation: _string(json, 'i'),
      senses: [
        for (final sense in _list(json, 's'))
          DictionaryPackSense.fromJson(sense),
      ],
      synonyms: _strings(json, 'y'),
      relatedWords: _strings(json, 'r'),
      etymology: _string(json, 'e'),
      translations: {
        for (final MapEntry(:key, :value)
            in (translations as Map<String, Object?>? ?? const {}).entries)
          key: [
            for (final item in _listOf(value))
              DictionaryPackTranslation.fromJson(item),
          ],
      },
    );
  }

  final String word;

  /// E.g. `noun`, `verb` (Wiktionary's part of speech names).
  final String partOfSpeech;

  /// IPA without slashes or brackets, e.g. `haʊs`.
  final String pronunciation;
  final List<DictionaryPackSense> senses;
  final List<String> synonyms;

  /// Antonyms, derived and related terms.
  final List<String> relatedWords;
  final String etymology;

  /// Renderings of [word] by language code (the pack's targets).
  final Map<String, List<DictionaryPackTranslation>> translations;

  /// Whether every sense is an inflected or alternative form of another
  /// word ([DictionaryPackSense.formOf]), such as `went` (past of `go`).
  bool get isFormOf =>
      senses.isNotEmpty && senses.every((sense) => sense.formOf.isNotEmpty);

  Map<String, Object?> toJson() => {
    'w': word,
    if (partOfSpeech.isNotEmpty) 'p': partOfSpeech,
    if (pronunciation.isNotEmpty) 'i': pronunciation,
    if (senses.isNotEmpty) 's': [for (final sense in senses) sense.toJson()],
    if (synonyms.isNotEmpty) 'y': synonyms,
    if (relatedWords.isNotEmpty) 'r': relatedWords,
    if (etymology.isNotEmpty) 'e': etymology,
    if (translations.isNotEmpty)
      't': {
        for (final MapEntry(:key, :value) in translations.entries)
          key: [for (final translation in value) translation.toJson()],
      },
  };

  @override
  bool operator ==(Object other) =>
      other is DictionaryPackEntry && _json.equals(other.toJson(), toJson());

  @override
  int get hashCode => _json.hash(toJson());

  @override
  String toString() => 'DictionaryPackEntry($word, $partOfSpeech)';
}

/// One sense of a [DictionaryPackEntry]: `g` gloss, `q` qualifiers, `x`
/// examples, `o` the word it is a form of.
@immutable
final class DictionaryPackSense {
  const new({
    required this.gloss,
    this.tags = '',
    this.examples = const [],
    this.formOf = '',
  });

  factory fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      throw FormatException('Invalid pack sense', json);
    }
    return DictionaryPackSense(
      gloss: _string(json, 'g'),
      tags: _string(json, 'q'),
      examples: [
        for (final example in _list(json, 'x'))
          DictionaryPackExample.fromJson(example),
      ],
      formOf: _string(json, 'o'),
    );
  }

  /// The definition, in the pack's gloss language.
  final String gloss;

  /// Qualifiers such as `informal, US`.
  final String tags;
  final List<DictionaryPackExample> examples;

  /// The lemma when this sense is an inflected or alternative form of it.
  final String formOf;

  Map<String, Object?> toJson() => {
    'g': gloss,
    if (tags.isNotEmpty) 'q': tags,
    if (examples.isNotEmpty)
      'x': [for (final example in examples) example.toJson()],
    if (formOf.isNotEmpty) 'o': formOf,
  };

  @override
  bool operator ==(Object other) =>
      other is DictionaryPackSense && _json.equals(other.toJson(), toJson());

  @override
  int get hashCode => _json.hash(toJson());
}

/// An example sentence and its translation (empty when the data has none),
/// stored as `[text, translation]`.
@immutable
final class DictionaryPackExample {
  const new(this.text, [this.translation = '']);

  factory fromJson(Object? json) {
    if (json is! List<Object?> ||
        json.isEmpty ||
        json.length > 2 ||
        json.any((part) => part is! String)) {
      throw FormatException('Invalid pack example', json);
    }
    return DictionaryPackExample(
      json[0]! as String,
      json.length > 1 ? json[1]! as String : '',
    );
  }

  final String text;
  final String translation;

  List<Object?> toJson() => [text, if (translation.isNotEmpty) translation];

  @override
  bool operator ==(Object other) =>
      other is DictionaryPackExample &&
      other.text == text &&
      other.translation == translation;

  @override
  int get hashCode => Object.hash(text, translation);
}

/// A rendering of an entry in another language, stored as `[word, sense]`:
/// [sense] is the index of the sense it translates, or -1 for the entry as
/// a whole.
@immutable
final class DictionaryPackTranslation {
  const new(this.word, [this.sense = -1]);

  factory fromJson(Object? json) {
    if (json is! List<Object?> ||
        json.length != 2 ||
        json[0] is! String ||
        json[1] is! int) {
      throw FormatException('Invalid pack translation', json);
    }
    return DictionaryPackTranslation(json[0]! as String, json[1]! as int);
  }

  final String word;
  final int sense;

  List<Object?> toJson() => [word, sense];

  @override
  bool operator ==(Object other) =>
      other is DictionaryPackTranslation &&
      other.word == word &&
      other.sense == sense;

  @override
  int get hashCode => Object.hash(word, sense);
}

String _string(Map<String, Object?> json, String key) => switch (json[key]) {
  null => '',
  final String value => value,
  final other => throw FormatException('"$key" must be a string', other),
};

List<Object?> _list(Map<String, Object?> json, String key) =>
    _listOf(json[key]);

List<Object?> _listOf(Object? value) => switch (value) {
  null => const [],
  final List<Object?> list => list,
  final other => throw FormatException('Expected a list', other),
};

List<String> _strings(Map<String, Object?> json, String key) => [
  for (final value in _list(json, key))
    if (value is String)
      value
    else
      throw FormatException('"$key" must hold strings', value),
];
