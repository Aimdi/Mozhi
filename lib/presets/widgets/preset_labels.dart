import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/presets/cubit/presets_state.dart';
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

  /// The context sentence of the built-in example [builtIn] in the UI
  /// language; null for an example without one.
  String? presetBuiltInContext(BuiltInPreset builtIn) => switch (builtIn) {
    BuiltInPreset.emailFormal => presetsContextEmailFormal,
    BuiltInPreset.chatCasual => presetsContextChatCasual,
    BuiltInPreset.simpleA2 => null,
  };

  /// [preset] as shown and applied: a built-in example whose context is
  /// still the one it was stored with ([BuiltInPreset.options], English)
  /// gets it in the UI language ([presetBuiltInContext]), like its name.
  /// Other presets, and examples whose context the user changed, are
  /// returned as they are.
  Preset localizedPreset(Preset preset) {
    final builtIn = preset.builtIn;
    if (builtIn == null) return preset;
    final stored = builtIn.options.context;
    final localized = presetBuiltInContext(builtIn);
    if (localized == null ||
        localized == stored ||
        preset.options.context != stored) {
      return preset;
    }
    return preset.copyWith(
      options: preset.options.copyWith(context: localized),
    );
  }

  /// [state] with its presets as shown and applied ([localizedPreset]):
  /// pickers choose from these, so a chosen example applies its context in
  /// the UI language and is found again by `PresetsState.presetFor`.
  PresetsState localizedPresets(PresetsState state) => state.copyWith(
    presets: [for (final preset in state.presets) localizedPreset(preset)],
  );

  /// [options] edited for the built-in example [preset], as stored: the
  /// localised context ([localizedPreset]) goes back to the stored one, so
  /// the example stays in the UI language while its context is unchanged.
  TranslationOptions presetStoredOptions(
    Preset preset,
    TranslationOptions options,
  ) {
    final builtIn = preset.builtIn;
    if (builtIn == null) return options;
    final localized = presetBuiltInContext(builtIn);
    if (localized == null || options.context != localized) return options;
    return options.copyWith(context: builtIn.options.context);
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
