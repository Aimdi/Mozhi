import 'package:translation_repository/src/models/language.dart';

/// Static catalogue of world languages for AI engines (which can translate
/// between any pair). ~200 entries: every Google Translate language plus
/// common regional variants (pt-BR, pt-PT, zh-CN/zh-Hans, zh-TW/zh-Hant,
/// yue, es-419, fr-CA, en-GB, en-US, sr-Latn, ckb, several Arabic
/// varieties), each with English [Language.name] and [Language.nativeName].
/// Sorted by English name. Never contains `auto`.
abstract final class LanguageCatalog {
  static List<Language> get all {
    throw UnimplementedError('TODO(translation_repository)');
  }

  /// Exact-code lookup after normalisation (case-insensitive, `_` -> `-`).
  static Language? byCode(String code) {
    throw UnimplementedError('TODO(translation_repository)');
  }

  /// English name for [code], or [code] itself when unknown.
  static String nameOf(String code) {
    throw UnimplementedError('TODO(translation_repository)');
  }

  /// Popular suggestions for custom AI targets, e.g. "Pirate speak",
  /// "LinkedIn Speak", "Gen Z slang", "Shakespearean English",
  /// "Plain English (ELI5)", "Corporate jargon", "Emoji".
  static const customSuggestions = <String>[
    'LinkedIn Speak',
    'Pirate speak',
    'Gen Z slang',
    'Shakespearean English',
    'Plain English (explain like I am five)',
    'Corporate jargon',
    'Formal business email',
    'Emoji',
  ];
}
