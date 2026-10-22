import 'package:collection/collection.dart';
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
    this.formalityContext = '',
    this.caseSensitiveGlossaryTerms = const {},
  });

  /// Tolerant counterpart of [toJson]: unknown or missing values fall back to
  /// the defaults. Also accepts Kagi's wire values (`default`, `prefer_more`,
  /// `A1`, `male`, ...).
  factory fromJson(Map<String, dynamic> json) => TranslationOptions(
    style: _parseEnum(
      json['style'] ?? json['translation_style'],
      TranslationStyle.values,
      TranslationStyle.natural,
    ),
    formality: _parseEnum(
      json['formality'],
      Formality.values,
      Formality.automatic,
      aliases: const {
        'default': Formality.automatic,
        'auto': Formality.automatic,
        'formal': Formality.more,
        'informal': Formality.less,
      },
    ),
    readingLevel: _parseEnum(
      json['readingLevel'] ?? json['language_complexity'],
      ReadingLevel.values,
      ReadingLevel.standard,
    ),
    speakerGender: _parseGender(
      json['speakerGender'] ?? json['speaker_gender'],
    ),
    addresseeGender: _parseGender(
      json['addresseeGender'] ?? json['addressee_gender'],
    ),
    context: _parseString(json['context']),
    preserveFormatting: _parseBool(
      json['preserveFormatting'] ?? json['preserve_formatting'],
      fallback: true,
    ),
    glossary: _parseGlossary(json['glossary']),
    instructions: _parseString(json['instructions']),
    formalityContext: _parseString(
      json['formalityContext'] ?? json['formality_context'],
    ),
    caseSensitiveGlossaryTerms: _parseTerms(json['caseSensitiveGlossaryTerms']),
  );

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

  /// The terms of [glossary] that only match with their exact
  /// capitalisation (a glossary entry marked case-sensitive). Other terms
  /// match in any case, except acronyms (see `TranslationPrompts
  /// .glossaryOccurrences`).
  final Set<String> caseSensitiveGlossaryTerms;

  /// One-off refinement instruction (from suggestion chips), e.g.
  /// "Make it shorter". Not persisted by the app.
  ///
  /// Prompts render it as a labelled refinement preference, not as a
  /// trusted user instruction: chip instructions are model-generated.
  final String instructions;

  /// Extra tone notes for the chosen [formality] (Kagi's
  /// `formality_context`), e.g. "my boss, but we are on first-name terms".
  /// Only used when [formality] is not [Formality.automatic].
  final String formalityContext;

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
    String? formalityContext,
    Set<String>? caseSensitiveGlossaryTerms,
  }) => TranslationOptions(
    style: style ?? this.style,
    formality: formality ?? this.formality,
    readingLevel: readingLevel ?? this.readingLevel,
    speakerGender: speakerGender ?? this.speakerGender,
    addresseeGender: addresseeGender ?? this.addresseeGender,
    context: context ?? this.context,
    preserveFormatting: preserveFormatting ?? this.preserveFormatting,
    glossary: glossary ?? this.glossary,
    instructions: instructions ?? this.instructions,
    formalityContext: formalityContext ?? this.formalityContext,
    caseSensitiveGlossaryTerms:
        caseSensitiveGlossaryTerms ?? this.caseSensitiveGlossaryTerms,
  );

  /// Enum values serialise by `.name`; unknown values fall back to defaults.
  ///
  /// [instructions] is only written when non-empty (it is a one-off value the
  /// app normally strips before persisting); so is [formalityContext] (as
  /// `formalityContext`; [TranslationOptions.fromJson] also reads Kagi's
  /// `formality_context`) and [caseSensitiveGlossaryTerms] (a list).
  Map<String, dynamic> toJson() => {
    'style': style.name,
    'formality': formality.name,
    'readingLevel': readingLevel.name,
    'speakerGender': speakerGender.name,
    'addresseeGender': addresseeGender.name,
    'context': context,
    'preserveFormatting': preserveFormatting,
    'glossary': Map<String, String>.of(glossary),
    if (instructions.isNotEmpty) 'instructions': instructions,
    if (formalityContext.isNotEmpty) 'formalityContext': formalityContext,
    if (caseSensitiveGlossaryTerms.isNotEmpty)
      'caseSensitiveGlossaryTerms': caseSensitiveGlossaryTerms.toList(),
  };

  static const _glossaryEquality = MapEquality<String, String>();
  static const _termsEquality = SetEquality<String>();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TranslationOptions &&
          other.style == style &&
          other.formality == formality &&
          other.readingLevel == readingLevel &&
          other.speakerGender == speakerGender &&
          other.addresseeGender == addresseeGender &&
          other.context == context &&
          other.preserveFormatting == preserveFormatting &&
          other.instructions == instructions &&
          other.formalityContext == formalityContext &&
          _glossaryEquality.equals(other.glossary, glossary) &&
          _termsEquality.equals(
            other.caseSensitiveGlossaryTerms,
            caseSensitiveGlossaryTerms,
          );

  @override
  int get hashCode => Object.hash(
    style,
    formality,
    readingLevel,
    speakerGender,
    addresseeGender,
    context,
    preserveFormatting,
    instructions,
    formalityContext,
    _glossaryEquality.hash(glossary),
    _termsEquality.hash(caseSensitiveGlossaryTerms),
  );

  @override
  String toString() {
    final terms = caseSensitiveGlossaryTerms.isEmpty
        ? ''
        : ', caseSensitiveGlossaryTerms: $caseSensitiveGlossaryTerms';
    return 'TranslationOptions(style: ${style.name}, '
        'formality: ${formality.name}, readingLevel: ${readingLevel.name}, '
        'speakerGender: ${speakerGender.name}, '
        'addresseeGender: ${addresseeGender.name}, context: $context, '
        'preserveFormatting: $preserveFormatting, glossary: $glossary, '
        'instructions: $instructions, '
        'formalityContext: $formalityContext$terms)';
  }
}

/// Matches [value] against enum names ignoring case, `_` and `-`, so both
/// `preferMore` and `prefer_more` resolve.
T _parseEnum<T extends Enum>(
  Object? value,
  List<T> values,
  T fallback, {
  Map<String, T> aliases = const {},
}) {
  if (value is! String) return fallback;
  final key = _enumKey(value);
  for (final v in values) {
    if (_enumKey(v.name) == key) return v;
  }
  for (final entry in aliases.entries) {
    if (_enumKey(entry.key) == key) return entry.value;
  }
  return fallback;
}

String _enumKey(String s) =>
    s.trim().toLowerCase().replaceAll(RegExp('[_ -]'), '');

Gender _parseGender(Object? value) => _parseEnum(
  value,
  Gender.values,
  Gender.unknown,
  aliases: const {
    'male': Gender.masculine,
    'man': Gender.masculine,
    'female': Gender.feminine,
    'woman': Gender.feminine,
    'nonbinary': Gender.neutral,
    'non-binary': Gender.neutral,
  },
);

String _parseString(Object? value) => value is String ? value : '';

Set<String> _parseTerms(Object? value) => value is List
    ? {
        for (final term in value)
          if (term is String && term.trim().isNotEmpty) term,
      }
    : const {};

bool _parseBool(Object? value, {required bool fallback}) => switch (value) {
  final bool b => b,
  'true' => true,
  'false' => false,
  _ => fallback,
};

Map<String, String> _parseGlossary(Object? value) {
  if (value is Map) {
    return {
      for (final MapEntry(:key, :value) in value.entries)
        if (key is String && value is String && key.trim().isNotEmpty)
          key: value,
    };
  }
  // Also accept a list of {"source": ..., "target": ...} pairs.
  if (value is List) {
    return {
      for (final item in value)
        if (item is Map &&
            item['source'] is String &&
            item['target'] is String &&
            (item['source'] as String).trim().isNotEmpty)
          item['source'] as String: item['target'] as String,
    };
  }
  return const {};
}
