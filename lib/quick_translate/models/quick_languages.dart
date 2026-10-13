import 'package:translation_repository/translation_repository.dart';

/// The short language lists of the compact target picker.
///
/// * [recent]: pinned then recent languages (deduplicated, mapped onto the
///   engine's targets; custom styles only when the engine accepts them).
/// * [common]: the device languages followed by widely used languages, minus
///   anything already in [recent].
/// * [all]: every target of the engine (for searching).
class QuickLanguages {
  const new({
    this.recent = const [],
    this.common = const [],
    this.all = const [],
  });

  /// Builds the lists for a target picker.
  ///
  /// [available] is the engine's target list (the `LanguageCatalog` is
  /// used when it is empty). [preferredCodes] are e.g. the device locale
  /// language codes, shown first among the common languages.
  factory build({
    required List<Language> available,
    List<Language> recent = const [],
    List<Language> pinned = const [],
    List<String> preferredCodes = const [],
    bool allowCustom = false,
    int maxRecent = 8,
    int maxCommon = 12,
  }) {
    final pool = [
      for (final language
          in available.isEmpty ? LanguageCatalog.all : available)
        if (!language.isAuto) language,
    ];
    final seen = <String>{};
    String key(Language language) => language.isCustom
        ? 'custom:${language.code.trim().toLowerCase()}'
        : LanguageMatcher.normalize(language.code);

    Language? resolve(Language wanted) {
      if (wanted.isAuto) return null;
      if (wanted.isCustom) {
        return allowCustom
            ? LanguageMatcher.match(wanted, pool, allowCustom: true)
            : null;
      }
      return LanguageMatcher.match(wanted, pool);
    }

    final recentList = <Language>[];
    for (final wanted in [...pinned, ...recent]) {
      if (recentList.length >= maxRecent) break;
      final match = resolve(wanted);
      if (match != null && seen.add(key(match))) recentList.add(match);
    }

    final commonList = <Language>[];
    final codes = [...preferredCodes, ...commonCodes];
    for (final code in codes) {
      if (commonList.length >= maxCommon) break;
      if (code.trim().isEmpty) continue;
      final match = resolve(Language(code: code, name: code));
      if (match != null && seen.add(key(match))) commonList.add(match);
    }

    return QuickLanguages(
      recent: List.unmodifiable(recentList),
      common: List.unmodifiable(commonList),
      all: List.unmodifiable(pool),
    );
  }

  /// Widely used target languages, in display order.
  static const commonCodes = <String>[
    'en',
    'es',
    'fr',
    'de',
    'zh-CN',
    'ja',
    'ko',
    'ar',
    'hi',
    'pt',
    'ru',
    'it',
    'tr',
    'nl',
    'pl',
    'uk',
    'ta',
  ];

  final List<Language> recent;
  final List<Language> common;
  final List<Language> all;

  /// Languages of [all] matching [query] by English name, native name or
  /// code: prefix matches first, then substring matches; at most [limit].
  List<Language> search(String query, {int limit = 50}) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final starts = <Language>[];
    final contains = <Language>[];
    for (final language in all) {
      final name = language.name.toLowerCase();
      final native = language.nativeName?.toLowerCase() ?? '';
      final code = language.code.toLowerCase();
      if (name.startsWith(q) || native.startsWith(q) || code == q) {
        starts.add(language);
      } else if (name.contains(q) || native.contains(q)) {
        contains.add(language);
      }
    }
    return [...starts, ...contains].take(limit).toList();
  }
}

/// Whether text in [code] is written right to left.
bool isRtlLanguage(String? code) {
  if (code == null || code.isEmpty) return false;
  final primary = code.split(RegExp('[-_]')).first.toLowerCase();
  return const {
    'ar',
    'arc',
    'ckb',
    'dv',
    'fa',
    'he',
    'iw',
    'ks',
    'ps',
    'sd',
    'ug',
    'ur',
    'yi',
  }.contains(primary);
}
