import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

const _list = ListEquality<Object?>();

/// Kagi `/api/alternative-translations` equivalent.
@immutable
class AlternativeTranslations {
  const new({
    required this.description,
    required this.alternatives,
  });

  /// One sentence describing the main translation's choices.
  final String description;
  final List<Alternative> alternatives;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AlternativeTranslations &&
          other.description == description &&
          _list.equals(other.alternatives, alternatives);

  @override
  int get hashCode => Object.hash(description, _list.hash(alternatives));
}

@immutable
class Alternative {
  const new({required this.text, this.explanation = ''});

  final String text;

  /// How it differs, e.g. "slightly more formal".
  final String explanation;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Alternative &&
          other.text == text &&
          other.explanation == explanation;

  @override
  int get hashCode => Object.hash(text, explanation);
}

/// Kagi word insights: an underlined span of the translation with
/// variations the user can swap in.
@immutable
class WordInsight {
  const new({
    required this.sourceText,
    required this.targetText,
    this.type = 'nuance',
    this.explanation = '',
    this.variations = const [],
  });

  /// The source phrase.
  final String sourceText;

  /// The exact substring of the translation this insight refers to.
  final String targetText;

  /// `idiom` | `nuance` | `wordplay` | `cultural` | `grammar` | `ambiguity`
  /// | other short label.
  final String type;
  final String explanation;
  final List<Alternative> variations;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WordInsight &&
          other.sourceText == sourceText &&
          other.targetText == targetText &&
          other.type == type &&
          other.explanation == explanation &&
          _list.equals(other.variations, variations);

  @override
  int get hashCode => Object.hash(sourceText, targetText, type, explanation, _list.hash(variations));
}

/// A refinement chip shown under the output (Kagi translation-suggestions).
@immutable
class RefinementSuggestion {
  const new({
    required this.label,
    required this.instruction,
    this.description = '',
    this.icon = 'tune',
  });

  /// Short label in the UI language, e.g. "More formal".
  final String label;

  /// Instruction appended to the next translation request.
  final String instruction;
  final String description;

  /// A Material icon name hint: tune | formal | casual | shorter | longer |
  /// simplify | fluent | literal.
  final String icon;

  /// Built-in chips always available for AI engines.
  static const defaults = <RefinementSuggestion>[
    RefinementSuggestion(label: 'More formal', instruction: 'Make the translation more formal.', icon: 'formal'),
    RefinementSuggestion(label: 'More casual', instruction: 'Make the translation more casual and conversational.', icon: 'casual'),
    RefinementSuggestion(label: 'Shorter', instruction: 'Make the translation more concise without losing meaning.', icon: 'shorter'),
    RefinementSuggestion(label: 'Simpler', instruction: 'Use simpler words and sentence structure.', icon: 'simplify'),
    RefinementSuggestion(label: 'More fluent', instruction: 'Make it sound completely natural to a native speaker, prioritising idiomatic phrasing.', icon: 'fluent'),
    RefinementSuggestion(label: 'More literal', instruction: 'Stay closer to the source wording and structure.', icon: 'literal'),
  ];

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RefinementSuggestion &&
          other.label == label &&
          other.instruction == instruction &&
          other.description == description &&
          other.icon == icon;

  @override
  int get hashCode => Object.hash(label, instruction, description, icon);
}

/// Kagi dictionary entry (LLM generated).
@immutable
class DictionaryEntry {
  const new({
    required this.word,
    this.pronunciation = '',
    this.partsOfSpeech = const [],
    this.senses = const [],
    this.examples = const [],
    this.synonyms = const [],
    this.etymology = '',
    this.notes = '',
  });

  final String word;

  /// IPA.
  final String pronunciation;
  final List<String> partsOfSpeech;
  final List<DictionarySense> senses;
  final List<DictionaryExample> examples;
  final List<String> synonyms;
  final String etymology;
  final String notes;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DictionaryEntry &&
          other.word == word &&
          other.pronunciation == pronunciation &&
          _list.equals(other.partsOfSpeech, partsOfSpeech) &&
          _list.equals(other.senses, senses) &&
          _list.equals(other.examples, examples) &&
          _list.equals(other.synonyms, synonyms) &&
          other.etymology == etymology &&
          other.notes == notes;

  @override
  int get hashCode => Object.hash(word, pronunciation, _list.hash(partsOfSpeech), _list.hash(senses), _list.hash(examples), _list.hash(synonyms), etymology, notes);
}

@immutable
class DictionarySense {
  const new({
    required this.definition,
    this.partOfSpeech = '',
    this.translations = const [],
    this.usage = '',
  });

  final String definition;
  final String partOfSpeech;

  /// Renderings in the target language.
  final List<String> translations;

  /// e.g. "informal", "rare", "British".
  final String usage;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DictionarySense &&
          other.definition == definition &&
          other.partOfSpeech == partOfSpeech &&
          _list.equals(other.translations, translations) &&
          other.usage == usage;

  @override
  int get hashCode => Object.hash(definition, partOfSpeech, _list.hash(translations), usage);
}

@immutable
class DictionaryExample {
  const new({required this.source, this.translation = ''});

  final String source;
  final String translation;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DictionaryExample &&
          other.source == source &&
          other.translation == translation;

  @override
  int get hashCode => Object.hash(source, translation);
}

enum WritingStyle { general, academic, business, casual, creative, email }

enum CorrectionLevel { light, standard, comprehensive }

/// Kagi proofread result.
@immutable
class ProofreadResult {
  const new({
    required this.correctedText,
    this.edits = const [],
    this.detectedLanguage,
    this.summary = '',
  });

  final String correctedText;
  final List<ProofreadEdit> edits;
  final String? detectedLanguage;

  /// One or two sentences on overall style/tone/repetition.
  final String summary;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProofreadResult &&
          other.correctedText == correctedText &&
          _list.equals(other.edits, edits) &&
          other.detectedLanguage == detectedLanguage &&
          other.summary == summary;

  @override
  int get hashCode => Object.hash(correctedText, _list.hash(edits), detectedLanguage, summary);
}

@immutable
class ProofreadEdit {
  const new({
    required this.original,
    required this.replacement,
    this.explanation = '',
    this.category = 'grammar',
  });

  /// Exact substring of the input text.
  final String original;
  final String replacement;
  final String explanation;

  /// grammar | spelling | punctuation | style | clarity | word_choice |
  /// tone | repetition.
  final String category;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProofreadEdit &&
          other.original == original &&
          other.replacement == replacement &&
          other.explanation == explanation &&
          other.category == category;

  @override
  int get hashCode => Object.hash(original, replacement, explanation, category);
}

/// Language detection outcome.
@immutable
class DetectedLanguage {
  const new({
    required this.code,
    this.isUncertain = false,
    this.isMixed = false,
    this.alternatives = const [],
  });

  final String code;
  final bool isUncertain;
  final bool isMixed;
  final List<String> alternatives;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DetectedLanguage &&
          other.code == code &&
          other.isUncertain == isUncertain &&
          other.isMixed == isMixed &&
          _list.equals(other.alternatives, alternatives);

  @override
  int get hashCode => Object.hash(code, isUncertain, isMixed, _list.hash(alternatives));
}

/// Result of translating an image.
@immutable
class ImageTranslationResult {
  const new({
    this.translatedImage,
    this.sourceText = '',
    this.translatedText = '',
    this.notes = '',
  });

  /// Rendered translated image (Mozhi/Google only), PNG/JPEG bytes.
  final List<int>? translatedImage;
  final String sourceText;
  final String translatedText;

  /// Extra context a vision model gave about the image.
  final String notes;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ImageTranslationResult &&
          _list.equals(other.translatedImage, translatedImage) &&
          other.sourceText == sourceText &&
          other.translatedText == translatedText &&
          other.notes == notes;

  @override
  int get hashCode => Object.hash(_list.hash(translatedImage), sourceText, translatedText, notes);
}
