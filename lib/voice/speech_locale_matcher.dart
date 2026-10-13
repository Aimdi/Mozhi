import 'package:flutter/foundation.dart' show immutable;

/// Maps Mozhi / BCP-47 language codes onto speech recogniser locale ids.
///
/// Recognisers name their locales inconsistently (`en_US` on Android,
/// `en-US` on iOS/web, `cmn-Hans-CN` on some Google builds, legacy `iw` /
/// `in` / `fil` / `nb` codes), so both sides are parsed into
/// language/script/region before comparing.
abstract final class SpeechLocaleMatcher {
  /// Returns the recogniser locale id in [localeIds] that best fits
  /// [languageCode], or null to let the recogniser use its system default.
  ///
  /// Rules:
  /// * null, empty, `auto` or unparsable codes (custom AI "languages") ->
  ///   null;
  /// * only locales with the same primary language (after alias
  ///   normalisation: `iw`=`he`, `in`=`id`, `ji`=`yi`, `jw`=`jv`,
  ///   `fil`=`tl`, `nb`/`nob`=`no`, `cmn`=`zh`) are considered; none ->
  ///   null;
  /// * an exact match wins (case and `_`/`-` insensitive), then the same
  ///   region (`es-419` accepts any Latin American region), then the same
  ///   script, then [systemLocaleId], then a common default region
  ///   (`en` -> `en-US`, `pt` -> `pt-BR`, ...), then the first locale with
  ///   the same primary subtag in [localeIds] order.
  static String? match(
    String? languageCode,
    Iterable<String> localeIds, {
    String? systemLocaleId,
  }) {
    if (languageCode == null) return null;
    final wanted = _Tag.parse(languageCode);
    if (wanted == null || wanted.language == 'auto') return null;
    final system = systemLocaleId == null ? null : _Tag.parse(systemLocaleId);

    String? best;
    var bestScore = -1;
    for (final id in localeIds) {
      final candidate = _Tag.parse(id);
      if (candidate == null || candidate.language != wanted.language) {
        continue;
      }
      final score = _score(wanted, candidate, system);
      if (score > bestScore) {
        best = id;
        bestScore = score;
      }
    }
    return best;
  }

  /// Normalises a locale id to `language[-Script][-REGION]` with canonical
  /// casing and aliases applied (`EN_us` -> `en-US`, `iw_IL` -> `he-IL`).
  /// Returns null when [code] is not a language tag.
  static String? normalize(String code) => _Tag.parse(code)?.toString();

  static int _score(_Tag wanted, _Tag candidate, _Tag? system) {
    var score = 0;
    if (candidate == wanted) score += 1000;
    if (wanted.region != null) {
      if (candidate.region == wanted.region) {
        score += 100;
      } else if (wanted.region == '419' &&
          _latinAmerica.contains(candidate.region)) {
        score += 50;
      }
    }
    if (candidate.script == wanted.script) score += 10;
    if (candidate == system) score += 4;
    if (wanted.region == null &&
        candidate.region != null &&
        _defaultRegions[wanted.language] == candidate.region) {
      score += 2;
    }
    return score;
  }

  static const _aliases = <String, String>{
    'iw': 'he',
    'in': 'id',
    'ji': 'yi',
    'jw': 'jv',
    'fil': 'tl',
    'nb': 'no',
    'nob': 'no',
    'cmn': 'zh',
  };

  /// Region used when only a language is requested and neither the system
  /// locale nor a region decides.
  static const _defaultRegions = <String, String>{
    'en': 'US',
    'es': 'ES',
    'fr': 'FR',
    'de': 'DE',
    'pt': 'BR',
    'it': 'IT',
    'nl': 'NL',
    'zh': 'CN',
    'ar': 'SA',
    'ta': 'IN',
    'ur': 'PK',
    'sw': 'KE',
  };

  static const _latinAmerica = <String>{
    'AR', 'BO', 'CL', 'CO', 'CR', 'CU', 'DO', 'EC', 'GT', 'HN', //
    'MX', 'NI', 'PA', 'PE', 'PR', 'PY', 'SV', 'US', 'UY', 'VE',
  };
}

/// A parsed `language[-Script][-REGION]` tag (variants are ignored).
@immutable
final class _Tag {
  const new(this.language, this.script, this.region);

  static final _languagePattern = RegExp(r'^[a-z]{2,8}$');
  static final _scriptPattern = RegExp(r'^[a-z]{4}$');
  static final _regionPattern = RegExp(r'^([a-z]{2}|\d{3})$');

  static _Tag? parse(String code) {
    final parts = code
        .trim()
        .toLowerCase()
        .split(RegExp('[-_]'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.isEmpty || !_languagePattern.hasMatch(parts.first)) return null;
    final language = SpeechLocaleMatcher._aliases[parts.first] ?? parts.first;
    String? script;
    String? region;
    for (final part in parts.skip(1)) {
      if (script == null && region == null && _scriptPattern.hasMatch(part)) {
        script = '${part[0].toUpperCase()}${part.substring(1)}';
      } else if (region == null && _regionPattern.hasMatch(part)) {
        region = part.toUpperCase();
      }
    }
    return _Tag(language, script, region);
  }

  final String language;
  final String? script;
  final String? region;

  @override
  bool operator ==(Object other) =>
      other is _Tag &&
      other.language == language &&
      other.script == script &&
      other.region == region;

  @override
  int get hashCode => Object.hash(language, script, region);

  @override
  String toString() => [language, ?script, ?region].join('-');
}
