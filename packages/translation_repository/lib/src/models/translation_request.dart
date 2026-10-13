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
  });

  final String text;

  /// May be [Language.auto].
  final Language source;

  /// Never auto. May be a custom free-form language for AI engines.
  final Language target;
  final TranslationOptions options;

  TranslationRequest copyWith({
    String? text,
    Language? source,
    Language? target,
    TranslationOptions? options,
  }) => TranslationRequest(
    text: text ?? this.text,
    source: source ?? this.source,
    target: target ?? this.target,
    options: options ?? this.options,
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
