import 'package:meta/meta.dart';

/// A minimally parsed BCP-47-style tag: `language[-Script][-REGION]`,
/// stored lower-case. Extra subtags (variants, extensions) are ignored and
/// `_` is accepted as separator.
@internal
@immutable
class LanguageTag {
  const new(this.language, {this.script, this.region});

  static final _alpha = RegExp(r'^[a-z]+$');
  static final _digits = RegExp(r'^\d{3}$');

  /// Returns `null` when [code] has no language subtag.
  static LanguageTag? parse(String code) {
    final parts = code
        .trim()
        .toLowerCase()
        .split(RegExp(r'[-_\s]+'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.isEmpty) return null;
    String? script;
    String? region;
    for (final part in parts.skip(1)) {
      if (script == null && region == null && part.length == 4) {
        if (_alpha.hasMatch(part)) script = part;
      } else if (region == null &&
          ((part.length == 2 && _alpha.hasMatch(part)) ||
              _digits.hasMatch(part))) {
        region = part;
      }
    }
    return LanguageTag(parts.first, script: script, region: region);
  }

  final String language;

  /// Four letters, e.g. `hant`, `latn`.
  final String? script;

  /// Two letters or three digits, e.g. `br`, `419`.
  final String? region;

  bool get isAuto => language == 'auto';

  /// `zh-Hant`, `zh-TW`, `zh-HK` and `zh-MO`.
  bool get isTraditionalChinese =>
      script == 'hant' || const {'tw', 'hk', 'mo'}.contains(region);

  /// Canonical casing: `sr-Latn-RS`, `en-US`, `es-419`.
  @override
  String toString() => [
    language,
    if (script case final s?) '${s[0].toUpperCase()}${s.substring(1)}',
    if (region case final r?) r.toUpperCase(),
  ].join('-');

  @override
  bool operator ==(Object other) =>
      other is LanguageTag &&
      other.language == language &&
      other.script == script &&
      other.region == region;

  @override
  int get hashCode => Object.hash(language, script, region);
}
