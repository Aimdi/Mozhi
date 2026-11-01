// Region names from Unicode CLDR 48 (`cldr-localenames-full`,
// `main/<locale>/territories.json`), for the regions of the bundled public
// Mozhi instances (`MozhiPublicInstance.all`) in the app's UI languages.
// Add a region here when the snapshot gets a server in a new one.

/// The name of the region [code] (ISO 3166-1 alpha-2, e.g. `DE`) in the
/// UI language [locale] (`AppLocalizations.localeName`, e.g. `de`), from
/// CLDR; the English name for other UI languages; null for a region the
/// app has no name for.
String? regionName(String code, String locale) {
  final names = _regionNames[code.trim().toUpperCase()];
  if (names == null) return null;
  final language = locale.split(RegExp('[-_]')).first.toLowerCase();
  return names[language] ?? names['en'];
}

/// Region code -> UI language -> name.
const _regionNames = <String, Map<String, String>>{
  'DE': {
    'ar': 'ألمانيا',
    'de': 'Deutschland',
    'en': 'Germany',
    'es': 'Alemania',
    'fr': 'Allemagne',
    'hi': 'जर्मनी',
    'id': 'Jerman',
    'it': 'Germania',
    'ja': 'ドイツ',
    'ko': '독일',
    'nl': 'Duitsland',
    'pl': 'Niemcy',
    'pt': 'Alemanha',
    'ru': 'Германия',
    'ta': 'ஜெர்மனி',
    'tr': 'Almanya',
    'uk': 'Німеччина',
    'vi': 'Đức',
    'zh': '德国',
  },
  'IN': {
    'ar': 'الهند',
    'de': 'Indien',
    'en': 'India',
    'es': 'India',
    'fr': 'Inde',
    'hi': 'भारत',
    'id': 'India',
    'it': 'India',
    'ja': 'インド',
    'ko': '인도',
    'nl': 'India',
    'pl': 'Indie',
    'pt': 'Índia',
    'ru': 'Индия',
    'ta': 'இந்தியா',
    'tr': 'Hindistan',
    'uk': 'Індія',
    'vi': 'Ấn Độ',
    'zh': '印度',
  },
  'RU': {
    'ar': 'روسيا',
    'de': 'Russland',
    'en': 'Russia',
    'es': 'Rusia',
    'fr': 'Russie',
    'hi': 'रूस',
    'id': 'Rusia',
    'it': 'Russia',
    'ja': 'ロシア',
    'ko': '러시아',
    'nl': 'Rusland',
    'pl': 'Rosja',
    'pt': 'Rússia',
    'ru': 'Россия',
    'ta': 'ரஷ்யா',
    'tr': 'Rusya',
    'uk': 'Росія',
    'vi': 'Nga',
    'zh': '俄罗斯',
  },
  'US': {
    'ar': 'الولايات المتحدة',
    'de': 'Vereinigte Staaten',
    'en': 'United States',
    'es': 'Estados Unidos',
    'fr': 'États-Unis',
    'hi': 'संयुक्त राज्य',
    'id': 'Amerika Serikat',
    'it': 'Stati Uniti',
    'ja': 'アメリカ合衆国',
    'ko': '미국',
    'nl': 'Verenigde Staten',
    'pl': 'Stany Zjednoczone',
    'pt': 'Estados Unidos',
    'ru': 'Соединенные Штаты',
    'ta': 'அமெரிக்கா',
    'tr': 'Amerika Birleşik Devletleri',
    'uk': 'Сполучені Штати',
    'vi': 'Hoa Kỳ',
    'zh': '美国',
  },
};
