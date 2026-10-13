import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:translation_repository/translation_repository.dart';

/// Localized labels for proofreading enums and edit categories.
extension ProofreadLabels on AppLocalizations {
  String proofreadWritingStyle(WritingStyle style) => switch (style) {
    WritingStyle.general => proofreadStyleGeneral,
    WritingStyle.academic => proofreadStyleAcademic,
    WritingStyle.business => proofreadStyleBusiness,
    WritingStyle.casual => proofreadStyleCasual,
    WritingStyle.creative => proofreadStyleCreative,
    WritingStyle.email => proofreadStyleEmail,
  };

  String proofreadCorrectionLevel(CorrectionLevel level) => switch (level) {
    CorrectionLevel.light => proofreadLevelLight,
    CorrectionLevel.standard => proofreadLevelStandard,
    CorrectionLevel.comprehensive => proofreadLevelComprehensive,
  };

  String proofreadLevelDescription(CorrectionLevel level) => switch (level) {
    CorrectionLevel.light => proofreadLevelLightDescription,
    CorrectionLevel.standard => proofreadLevelStandardDescription,
    CorrectionLevel.comprehensive => proofreadLevelComprehensiveDescription,
  };

  String proofreadFormality(Formality formality) => switch (formality) {
    Formality.automatic => proofreadFormalityAutomatic,
    Formality.more => proofreadFormalityMore,
    Formality.less => proofreadFormalityLess,
    Formality.preferMore => proofreadFormalityPreferMore,
    Formality.preferLess => proofreadFormalityPreferLess,
  };

  /// Category label; unknown categories are shown humanized
  /// (`fact_check` -> `Fact check`).
  String proofreadCategory(String category) {
    return switch (_normalize(category)) {
      'grammar' => proofreadCategoryGrammar,
      'spelling' => proofreadCategorySpelling,
      'punctuation' => proofreadCategoryPunctuation,
      'style' => proofreadCategoryStyle,
      'clarity' => proofreadCategoryClarity,
      'word_choice' || 'wordchoice' => proofreadCategoryWordChoice,
      'tone' => proofreadCategoryTone,
      'repetition' => proofreadCategoryRepetition,
      'other' => proofreadCategoryOther,
      _ => _humanize(category),
    };
  }

  static String _humanize(String category) {
    final words = category.trim().replaceAll(RegExp(r'[_\s-]+'), ' ');
    if (words.isEmpty) return words;
    return words[0].toUpperCase() + words.substring(1);
  }

  /// User-facing message for a proofreading error.
  String proofreadError(Object? error) => switch (error) {
    LlmRefusalException() => proofreadErrorRefused,
    LlmApiException(isAuthError: true) => proofreadErrorAuth,
    LlmApiException(isRateLimited: true) => proofreadErrorRateLimited,
    LlmApiException(:final message) when message.trim().isNotEmpty =>
      proofreadErrorProvider(message.trim()),
    _ => proofreadErrorGeneric,
  };
}

/// Icon for an edit category.
IconData proofreadCategoryIcon(String category) =>
    switch (_normalize(category)) {
      'spelling' => Icons.spellcheck,
      'punctuation' => Icons.format_quote_outlined,
      'style' || 'tone' => Icons.brush_outlined,
      'clarity' => Icons.lightbulb_outline,
      'word_choice' || 'wordchoice' => Icons.swap_horiz,
      'repetition' => Icons.repeat,
      _ => Icons.edit_note,
    };

String _normalize(String category) =>
    category.trim().toLowerCase().replaceAll(RegExp(r'[\s-]+'), '_');
