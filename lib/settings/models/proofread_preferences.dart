import 'package:equatable/equatable.dart';
import 'package:translation_repository/translation_repository.dart';

/// The proofreading options the user last chose (style, correction level,
/// formality, tone, reading level and regional variety), kept across app
/// starts in `AppSettings.proofread`.
class ProofreadPreferences extends Equatable {
  const new({
    this.writingStyle = WritingStyle.general,
    this.correctionLevel = CorrectionLevel.standard,
    this.formality = Formality.automatic,
    this.tone = WritingTone.automatic,
    this.readingLevel = ReadingLevel.standard,
    this.variety,
  });

  /// Tolerant counterpart of [toJson]: missing or unknown values fall back
  /// to their defaults. Never throws.
  factory fromJson(Map<String, dynamic> json) {
    const defaults = ProofreadPreferences();
    T value<T extends Enum>(List<T> values, Object? name, T fallback) =>
        values.asNameMap()[name] ?? fallback;
    return ProofreadPreferences(
      writingStyle: value(
        WritingStyle.values,
        json['writingStyle'],
        defaults.writingStyle,
      ),
      correctionLevel: value(
        CorrectionLevel.values,
        json['correctionLevel'],
        defaults.correctionLevel,
      ),
      formality: value(Formality.values, json['formality'], defaults.formality),
      tone: value(WritingTone.values, json['tone'], defaults.tone),
      readingLevel: value(
        ReadingLevel.values,
        json['readingLevel'],
        defaults.readingLevel,
      ),
      variety: ProofreadVariety.values.asNameMap()[json['variety']],
    );
  }

  final WritingStyle writingStyle;
  final CorrectionLevel correctionLevel;
  final Formality formality;
  final WritingTone tone;
  final ReadingLevel readingLevel;

  /// Regional variety to convert to; null keeps the author's.
  final ProofreadVariety? variety;

  Map<String, dynamic> toJson() => {
    'writingStyle': writingStyle.name,
    'correctionLevel': correctionLevel.name,
    'formality': formality.name,
    'tone': tone.name,
    'readingLevel': readingLevel.name,
    if (variety != null) 'variety': variety!.name,
  };

  @override
  List<Object?> get props => [
    writingStyle,
    correctionLevel,
    formality,
    tone,
    readingLevel,
    variety,
  ];
}
