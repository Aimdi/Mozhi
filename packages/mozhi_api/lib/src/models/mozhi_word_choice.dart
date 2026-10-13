import 'package:meta/meta.dart';

/// Dictionary-style data for a single word, returned by some engines
/// (mostly Google and Reverso) inside `word_choices`.
@immutable
class MozhiWordChoice {
  const new({
    required this.word,
    this.definition = '',
    this.example = '',
    this.examplesSource = const [],
    this.examplesTarget = const [],
  });

  factory fromJson(Map<String, dynamic> json) =>
      MozhiWordChoice(
        word: (json['word'] ?? '') as String,
        definition: (json['definition'] ?? '') as String,
        example: (json['example'] ?? '') as String,
        examplesSource: _stringList(json['examples_source']),
        examplesTarget: _stringList(json['examples_target']),
      );

  final String word;
  final String definition;

  /// Google only: a single example sentence.
  final String example;
  final List<String> examplesSource;
  final List<String> examplesTarget;

  Map<String, dynamic> toJson() => {
    'word': word,
    'definition': definition,
    'example': example,
    'examples_source': examplesSource,
    'examples_target': examplesTarget,
  };

  static List<String> _stringList(Object? value) => value is List
      ? value.whereType<String>().toList(growable: false)
      : const [];

  @override
  bool operator ==(Object other) =>
      other is MozhiWordChoice &&
      other.word == word &&
      other.definition == definition &&
      other.example == example;

  @override
  int get hashCode => Object.hash(word, definition, example);
}
