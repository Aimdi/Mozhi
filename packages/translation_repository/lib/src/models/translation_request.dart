import 'package:meta/meta.dart';
import 'package:translation_repository/src/models/language.dart';
import 'package:translation_repository/src/models/translation_options.dart';

@immutable
class TranslationRequest {
  const new({
    required this.text,
    required this.source,
    required this.target,
    this.options = const TranslationOptions(),
    this.recentSourceLanguages = const [],
  });

  final String text;

  /// May be [Language.auto].
  final Language source;

  /// Never auto. May be a custom free-form language for AI engines.
  final Language target;
  final TranslationOptions options;

  /// Codes of languages the user recently translated from, most recent
  /// first. A hint for detecting the language of short [text] when
  /// [source] is auto; it does not change what is asked for, so it is not
  /// part of equality.
  final List<String> recentSourceLanguages;

  TranslationRequest copyWith({
    String? text,
    Language? source,
    Language? target,
    TranslationOptions? options,
    List<String>? recentSourceLanguages,
  }) => TranslationRequest(
    text: text ?? this.text,
    source: source ?? this.source,
    target: target ?? this.target,
    options: options ?? this.options,
    recentSourceLanguages: recentSourceLanguages ?? this.recentSourceLanguages,
  );

  @override
  bool operator ==(Object other) =>
      other is TranslationRequest &&
      other.text == text &&
      other.source == source &&
      other.target == target &&
      other.options == options;

  @override
  int get hashCode => Object.hash(text, source, target, options);
}
