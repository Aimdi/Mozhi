import 'package:mozhi/presets/models/preset.dart';
import 'package:translation_repository/translation_repository.dart';

/// Combines the current [base] options with a [preset] and an active
/// [glossary] (for example `GlossaryCubit.activeGlossary(...)`).
///
/// Precedence:
/// * every preset field (style, formality, reading level, speaker and
///   addressee gender, context, preserve formatting) replaces the [base]
///   value; without a [preset] the base values are kept;
/// * the glossary is [glossary] merged with `base.glossary`, and the base
///   entry wins when both define the same source term (compared trimmed and
///   case-insensitively, like the prompt builder matches terms);
/// * `base.instructions` is always kept.
TranslationOptions applyPresetAndGlossary({
  required TranslationOptions base,
  Preset? preset,
  Map<String, String> glossary = const {},
}) {
  final settings = preset == null ? base : Preset.settingsOf(preset.options);
  final taken = {for (final key in base.glossary.keys) _termKey(key)};
  final merged = <String, String>{
    ...base.glossary,
    for (final MapEntry(:key, :value) in glossary.entries)
      if (key.trim().isNotEmpty && taken.add(_termKey(key))) key: value,
  };
  return settings.copyWith(glossary: merged, instructions: base.instructions);
}

String _termKey(String term) => term.trim().toLowerCase();
