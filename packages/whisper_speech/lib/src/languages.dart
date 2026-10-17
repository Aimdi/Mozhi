/// The 99 languages of Whisper's multilingual tiny/base models: Whisper
/// code -> English name, in Whisper's token order (whisper.cpp `g_lang`;
/// Cantonese, `yue`, only exists in large-v3 and is left out).
const Map<String, String> whisperLanguages = {
  'en': 'English',
  'zh': 'Chinese',
  'de': 'German',
  'es': 'Spanish',
  'ru': 'Russian',
  'ko': 'Korean',
  'fr': 'French',
  'ja': 'Japanese',
  'pt': 'Portuguese',
  'tr': 'Turkish',
  'pl': 'Polish',
  'ca': 'Catalan',
  'nl': 'Dutch',
  'ar': 'Arabic',
  'sv': 'Swedish',
  'it': 'Italian',
  'id': 'Indonesian',
  'hi': 'Hindi',
  'fi': 'Finnish',
  'vi': 'Vietnamese',
  'he': 'Hebrew',
  'uk': 'Ukrainian',
  'el': 'Greek',
  'ms': 'Malay',
  'cs': 'Czech',
  'ro': 'Romanian',
  'da': 'Danish',
  'hu': 'Hungarian',
  'ta': 'Tamil',
  'no': 'Norwegian',
  'th': 'Thai',
  'ur': 'Urdu',
  'hr': 'Croatian',
  'bg': 'Bulgarian',
  'lt': 'Lithuanian',
  'la': 'Latin',
  'mi': 'Maori',
  'ml': 'Malayalam',
  'cy': 'Welsh',
  'sk': 'Slovak',
  'te': 'Telugu',
  'fa': 'Persian',
  'lv': 'Latvian',
  'bn': 'Bengali',
  'sr': 'Serbian',
  'az': 'Azerbaijani',
  'sl': 'Slovenian',
  'kn': 'Kannada',
  'et': 'Estonian',
  'mk': 'Macedonian',
  'br': 'Breton',
  'eu': 'Basque',
  'is': 'Icelandic',
  'hy': 'Armenian',
  'ne': 'Nepali',
  'mn': 'Mongolian',
  'bs': 'Bosnian',
  'kk': 'Kazakh',
  'sq': 'Albanian',
  'sw': 'Swahili',
  'gl': 'Galician',
  'mr': 'Marathi',
  'pa': 'Punjabi',
  'si': 'Sinhala',
  'km': 'Khmer',
  'sn': 'Shona',
  'yo': 'Yoruba',
  'so': 'Somali',
  'af': 'Afrikaans',
  'oc': 'Occitan',
  'ka': 'Georgian',
  'be': 'Belarusian',
  'tg': 'Tajik',
  'sd': 'Sindhi',
  'gu': 'Gujarati',
  'am': 'Amharic',
  'yi': 'Yiddish',
  'lo': 'Lao',
  'uz': 'Uzbek',
  'fo': 'Faroese',
  'ht': 'Haitian Creole',
  'ps': 'Pashto',
  'tk': 'Turkmen',
  'nn': 'Norwegian Nynorsk',
  'mt': 'Maltese',
  'sa': 'Sanskrit',
  'lb': 'Luxembourgish',
  'my': 'Myanmar (Burmese)',
  'bo': 'Tibetan',
  'tl': 'Tagalog',
  'mg': 'Malagasy',
  'as': 'Assamese',
  'tt': 'Tatar',
  'haw': 'Hawaiian',
  'ln': 'Lingala',
  'ha': 'Hausa',
  'ba': 'Bashkir',
  'jw': 'Javanese',
  'su': 'Sundanese',
};

/// The code to pass to Whisper for an app / BCP-47 language [code] (`en`,
/// `pt-BR`, `zh-TW`, `sr_Latn`, `iw`, `jv`, `fil`, `nb`, ...), or null
/// when Whisper should detect the language: [code] is null, empty, `auto`
/// or a language Whisper does not know (e.g. `yue`, `qu`).
///
/// Only the primary language subtag counts (Whisper has no regions or
/// scripts: `zh-TW` -> `zh`, `pa-Arab` -> `pa`), after aliases: `iw` ->
/// `he`, `in` -> `id`, `ji` -> `yi`, `jv` -> `jw` (Whisper's code for
/// Javanese), `fil` -> `tl`, `nb`/`nob` -> `no`, `nno` -> `nn`, `cmn` ->
/// `zh`.
String? whisperLanguageFor(String? code) {
  if (code == null) return null;
  final primary = code.trim().toLowerCase().split(RegExp('[-_]')).first;
  if (primary.isEmpty || primary == 'auto') return null;
  final language = _aliases[primary] ?? primary;
  return whisperLanguages.containsKey(language) ? language : null;
}

/// The app / BCP-47 code for a Whisper language code (the reverse of
/// [whisperLanguageFor]): `jw` -> `jv`, otherwise the code itself. Null
/// for codes that are not Whisper languages.
String? languageForWhisper(String? whisperCode) {
  if (whisperCode == null || !whisperLanguages.containsKey(whisperCode)) {
    return null;
  }
  return whisperCode == 'jw' ? 'jv' : whisperCode;
}

const _aliases = <String, String>{
  'iw': 'he',
  'in': 'id',
  'ji': 'yi',
  'jv': 'jw',
  'fil': 'tl',
  'nb': 'no',
  'nob': 'no',
  'nno': 'nn',
  'cmn': 'zh',
};
