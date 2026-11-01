import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/presets/models/glossary.dart';
import 'package:mozhi/presets/models/preset.dart';
import 'package:translation_repository/translation_repository.dart';

/// Localised labels shared by the presets and glossary UI.
extension PresetLabels on AppLocalizations {
  /// The user-given name, the localised example name, or "Untitled".
  String presetName(Preset preset) {
    final name = preset.name.trim();
    if (name.isNotEmpty) return name;
    return switch (preset.builtIn) {
      BuiltInPreset.emailFormal => presetsNameEmailFormal,
      BuiltInPreset.chatCasual => presetsNameChatCasual,
      BuiltInPreset.simpleA2 => presetsNameSimpleA2,
      null => presetsUntitled,
    };
  }

  /// Short description of the non-default settings, e.g.
  /// "More formal · Level A2 · Context: An email…".
  String presetSummary(TranslationOptions options) {
    final parts = <String>[
      if (options.style == TranslationStyle.literal) presetsSummaryLiteral,
      if (options.formality != Formality.automatic)
        formalityLabel(options.formality),
      if (options.readingLevel != ReadingLevel.standard)
        presetsSummaryReadingLevel(options.readingLevel.name.toUpperCase()),
      if (options.speakerGender != Gender.unknown)
        presetsSummarySpeaker(genderLabel(options.speakerGender)),
      if (options.addresseeGender != Gender.unknown)
        presetsSummaryAddressee(genderLabel(options.addresseeGender)),
      if (!options.preserveFormatting) presetsSummaryNoFormatting,
      if (options.context.trim().isNotEmpty)
        presetsSummaryContext(options.context.trim()),
    ];
    return parts.isEmpty ? presetsSummaryStandard : parts.join(' · ');
  }

  String formalityLabel(Formality value) => switch (value) {
    Formality.automatic => translateFormalityDefault,
    Formality.more => translateFormalityMore,
    Formality.less => translateFormalityLess,
    Formality.preferMore => translateFormalityPreferMore,
    Formality.preferLess => translateFormalityPreferLess,
  };

  String genderLabel(Gender value) => switch (value) {
    Gender.unknown => translateGenderUnknown,
    Gender.masculine => translateGenderMasculine,
    Gender.feminine => translateGenderFeminine,
    Gender.neutral => translateGenderNeutral,
  };

  String readingLevelLabel(ReadingLevel level) => switch (level) {
    ReadingLevel.standard =>
      '$translateReadingStandard · $translateReadingStandardDescription',
    ReadingLevel.a1 => 'A1 · $translateReadingA1Description',
    ReadingLevel.a2 => 'A2 · $translateReadingA2Description',
    ReadingLevel.b1 => 'B1 · $translateReadingB1Description',
    ReadingLevel.b2 => 'B2 · $translateReadingB2Description',
    ReadingLevel.c1 => 'C1 · $translateReadingC1Description',
    ReadingLevel.c2 => 'C2 · $translateReadingC2Description',
  };

  /// "Any language" or the language's name in the UI language (the code
  /// when unknown).
  String languageScopeName(String scope) => LanguageScope.isAny(scope)
      ? glossariesAnyLanguage
      : languageDisplayNameOf(scope.trim(), localeName);

  /// "English → German".
  String glossaryScope(Glossary glossary) => glossariesScope(
    languageScopeName(glossary.sourceCode),
    languageScopeName(glossary.targetCode),
  );

  String glossaryName(Glossary glossary) =>
      glossary.name.trim().isEmpty ? glossariesUntitled : glossary.name.trim();
}
