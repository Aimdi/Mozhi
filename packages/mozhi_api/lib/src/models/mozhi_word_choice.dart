import 'package:meta/meta.dart';
import 'package:mozhi_api/src/models/json_readers.dart';

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

  factory fromJson(Map<String, dynamic> json) => MozhiWordChoice(
    word: readString(json['word']),
    definition: readString(json['definition']),
    example: readString(json['example']),
    examplesSource: readStringList(json['examples_source']),
    examplesTarget: readStringList(json['examples_target']),
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

  @override
  bool operator ==(Object other) =>
      other is MozhiWordChoice &&
      other.word == word &&
      other.definition == definition &&
      other.example == example;

  @override
  int get hashCode => Object.hash(word, definition, example);
}
