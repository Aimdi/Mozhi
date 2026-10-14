import 'package:equatable/equatable.dart';
import 'package:translation_repository/translation_repository.dart';

/// A source → target language combination the user translated with, e.g.
/// for a list of recent pairs. [source] may be [Language.auto].
///
/// Equality follows [Language] equality (code and custom flag), so the
/// same pair with different display names is still the same pair.
class LanguagePair extends Equatable {
  const new({required this.source, required this.target});

  /// Parses JSON written by [toJson]. Throws when `source` or `target` is
  /// missing or invalid.
  factory fromJson(Map<String, dynamic> json) => LanguagePair(
    source: Language.fromJson(
      Map<String, dynamic>.from(json['source'] as Map<dynamic, dynamic>),
    ),
    target: Language.fromJson(
      Map<String, dynamic>.from(json['target'] as Map<dynamic, dynamic>),
    ),
  );

  final Language source;
  final Language target;

  Map<String, dynamic> toJson() => {
    'source': source.toJson(),
    'target': target.toJson(),
  };

  @override
  List<Object?> get props => [source, target];

  @override
  String toString() => 'LanguagePair(${source.code} → ${target.code})';
}
