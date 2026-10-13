/// Language-code helpers for read-aloud.
///
/// Translation engines use Google-style codes (`iw`, `jw`, `zh-CN`,
/// `mni-Mtei`); device speech engines expect BCP-47 tags. Custom AI
/// "languages" (`Pirate speak`) and the `auto` pseudo language cannot be
/// spoken at all.
library;

final _codePattern = RegExp(
  r'^[a-z]{2,3}(-[a-z0-9]{2,8})*$',
  caseSensitive: false,
);

/// Legacy / Google-specific codes mapped to the BCP-47 tag device engines
/// know (keys are lower case).
const _deviceAliases = <String, String>{
  'iw': 'he',
  'jw': 'jv',
  'in': 'id',
  'ji': 'yi',
  'tl': 'fil',
  'no': 'nb',
  'zh': 'zh-CN',
  'zh-hans': 'zh-CN',
  'zh-hant': 'zh-TW',
  'mni-mtei': 'mni',
};

/// Whether [languageCode] looks like a real language code (not `auto`, not
/// a free-form custom language). Used as the default "Mozhi can speak this"
/// check: Mozhi's `/api/tts` takes the translation engine's own codes.
bool isSpeakableLanguageCode(String languageCode) {
  final code = languageCode.trim().replaceAll('_', '-');
  return code.toLowerCase() != 'auto' && _codePattern.hasMatch(code);
}

/// The BCP-47 tag for [languageCode] as device speech engines expect it
/// (`iw` → `he`, `zh` → `zh-CN`, `pt_br` → `pt-BR`), or null when the code
/// cannot be spoken (see [isSpeakableLanguageCode]).
String? speechLanguageTag(String languageCode) {
  if (!isSpeakableLanguageCode(languageCode)) return null;
  final code = languageCode.trim().replaceAll('_', '-');
  final tag = _deviceAliases[code.toLowerCase()] ?? code;
  final [language, ...rest] = tag.split('-');
  return [language.toLowerCase(), ...rest.map(_canonicalSubtag)].join('-');
}

/// Regions upper case (`BR`, `419`), scripts title case (`Hant`), anything
/// else lower case.
String _canonicalSubtag(String subtag) => switch (subtag.length) {
  2 || 3 => subtag.toUpperCase(),
  4 => '${subtag[0].toUpperCase()}${subtag.substring(1).toLowerCase()}',
  _ => subtag.toLowerCase(),
};

/// Picks the entry of [available] (engine language tags such as `en-US`)
/// that best matches [tag]: an exact (case-insensitive) match, else the
/// first entry with the same primary language. Null when none matches.
String? matchLanguageTag(String tag, Iterable<String> available) {
  String normalize(String value) => value.replaceAll('_', '-').toLowerCase();
  final wanted = normalize(tag);
  final primary = wanted.split('-').first;
  String? samePrimary;
  for (final candidate in available) {
    final normalized = normalize(candidate);
    if (normalized == wanted) return candidate;
    if (normalized.split('-').first == primary) samePrimary ??= candidate;
  }
  return samePrimary;
}
