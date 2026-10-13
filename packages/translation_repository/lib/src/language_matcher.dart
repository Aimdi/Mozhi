import 'package:translation_repository/src/models/language.dart';

/// Maps a language code onto the closest entry of another engine's list
/// so the user's selection survives engine switches.
///
/// Rules (first match wins): exact code (case-insensitive, `_`==`-`);
/// known aliases (`nb`<->`no`, `he`<->`iw`, `jv`<->`jw`, `fil`<->`tl`,
/// `zh`/`zh-Hans`/`zh-CN`/`zh-SG`, `zh-Hant`/`zh-TW`/`zh-HK`, `pt`/`pt-BR`/
/// `pt-PT`, `sr`/`sr-Cyrl`, `ku`/`kmr`, `mni-Mtei`/`mni`, `ckb`/`ku-IQ`);
/// same primary subtag (`en-GB` -> `en`, `en` -> first `en-*`);
/// finally case-insensitive English name equality.
/// Custom languages only match custom entries or are returned as-is when
/// [allowCustom] is true.
abstract final class LanguageMatcher {
  static Language? match(
    Language wanted,
    List<Language> available, {
    bool allowCustom = false,
  }) {
    throw UnimplementedError('TODO(translation_repository)');
  }

  /// Normalises engine-specific codes to catalogue codes
  /// (e.g. `iw` -> `he`, `zh-CN` -> `zh-CN`, `ZH_tw` -> `zh-TW`).
  static String normalize(String code) {
    throw UnimplementedError('TODO(translation_repository)');
  }
}
