import 'package:meta/meta.dart';

/// Mirrors Kagi Translate's settings panel. Only AI engines honour these.

enum TranslationStyle { natural, literal }

/// Kagi: `default | more | less | prefer_more | prefer_less`.
enum Formality { automatic, more, less, preferMore, preferLess }

/// CEFR reading level of the output (`standard` = no simplification).
enum ReadingLevel { standard, a1, a2, b1, b2, c1, c2 }

enum Gender { unknown, masculine, feminine, neutral }

@immutable
class TranslationOptions {
  const new({
    this.style = TranslationStyle.natural,
    this.formality = Formality.automatic,
    this.readingLevel = ReadingLevel.standard,
    this.speakerGender = Gender.unknown,
    this.addresseeGender = Gender.unknown,
    this.context = '',
    this.preserveFormatting = true,
    this.glossary = const {},
    this.instructions = '',
  });

  factory fromJson() {
    throw UnimplementedError('TODO(translation_repository)');
  }

  final TranslationStyle style;
  final Formality formality;
  final ReadingLevel readingLevel;
  final Gender speakerGender;
  final Gender addresseeGender;

  /// Free-text context, e.g. "text message to my landlord".
  final String context;

  /// Keep line breaks, Markdown, HTML tags, placeholders, emoji, URLs.
  final bool preserveFormatting;

  /// Source term -> required target term.
  final Map<String, String> glossary;

  /// One-off refinement instruction (from suggestion chips), e.g.
  /// "Make it shorter". Not persisted by the app.
  final String instructions;

  bool get isDefault => this == const TranslationOptions();

  TranslationOptions copyWith({
    TranslationStyle? style,
    Formality? formality,
    ReadingLevel? readingLevel,
    Gender? speakerGender,
    Gender? addresseeGender,
    String? context,
    bool? preserveFormatting,
    Map<String, String>? glossary,
    String? instructions,
  }) {
    throw UnimplementedError('TODO(translation_repository)');
  }

  /// Enum values serialise by `.name`; unknown values fall back to defaults.
  Map<String, dynamic> toJson() {
    throw UnimplementedError('TODO(translation_repository)');
  }

  @override
  bool operator ==(Object other) {
    throw UnimplementedError('TODO(translation_repository): deep equality');
  }

  @override
  int get hashCode {
    throw UnimplementedError('TODO(translation_repository)');
  }
}
