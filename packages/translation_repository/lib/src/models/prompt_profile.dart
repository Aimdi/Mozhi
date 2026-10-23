/// How prompts are built for an AI model.
///
/// Translation-specialised models (TranslateGemma, Tencent Hy-MT /
/// Hunyuan-MT) expect a fixed single-user-message template and cannot follow
/// the general system prompt, the `[[lang:xx]]` marker or JSON features.
enum PromptProfile {
  /// Pick automatically from the model id ([detect]).
  auto,

  /// The general Kagi-style prompts (system prompt, options, extras).
  general,

  /// Google TranslateGemma template.
  translateGemma,

  /// Tencent Hy-MT / Hunyuan-MT templates (Hy-MT2's: default,
  /// terminology for glossary terms, delimiters for masked spans).
  hunyuanMt;

  /// `translategemma` -> [translateGemma]; `hy-mt`, `hymt`, `hunyuan-mt`
  /// -> [hunyuanMt]; anything else -> [general]. Case-insensitive.
  static PromptProfile detect(String model) {
    final id = model.toLowerCase();
    if (id.contains('translategemma') || id.contains('translate-gemma')) {
      return PromptProfile.translateGemma;
    }
    if (RegExp('hy-?mt|hunyuan-?mt').hasMatch(id)) {
      return PromptProfile.hunyuanMt;
    }
    return PromptProfile.general;
  }

  /// Parses [value] (an enum name); null when unknown.
  static PromptProfile? tryParse(Object? value) {
    for (final profile in PromptProfile.values) {
      if (profile.name == value) return profile;
    }
    return null;
  }

  /// [auto] resolved against [model].
  PromptProfile resolve(String model) =>
      this == PromptProfile.auto ? detect(model) : this;

  /// Whether this profile only supports plain translation (no options, no
  /// custom targets, no JSON extras).
  bool get isTranslationOnly =>
      this == PromptProfile.translateGemma || this == PromptProfile.hunyuanMt;
}
