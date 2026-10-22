import 'package:material_ui/material_ui.dart';

/// The ranges of [text] where [query] occurs, ignoring case (as the
/// searches of History and Settings do), in order and not overlapping.
/// Empty for a blank [query], or when lower-casing changes [text]'s length
/// (a few letters, e.g. "İ", which would shift the ranges).
List<TextRange> matchRanges(String text, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty || text.isEmpty) return const [];
  final haystack = text.toLowerCase();
  if (haystack.length != text.length) return const [];
  final ranges = <TextRange>[];
  var start = haystack.indexOf(needle);
  while (start >= 0) {
    ranges.add(TextRange(start: start, end: start + needle.length));
    start = haystack.indexOf(needle, start + needle.length);
  }
  return ranges;
}

/// [text] as spans with the matches of [query] ([matchRanges]) in
/// [highlight] (merged over [style]); [locale] tags every span (the text's
/// language, for screen readers and glyphs).
TextSpan highlightedSpan(
  String text,
  String query, {
  required TextStyle highlight,
  TextStyle? style,
  Locale? locale,
}) {
  final ranges = matchRanges(text, query);
  if (ranges.isEmpty) return TextSpan(text: text, style: style, locale: locale);
  final merged = (style ?? const TextStyle()).merge(highlight);
  var at = 0;
  return TextSpan(
    style: style,
    locale: locale,
    children: [
      for (final range in ranges) ...[
        if (range.start > at)
          TextSpan(text: text.substring(at, range.start), locale: locale),
        TextSpan(
          text: text.substring(range.start, at = range.end),
          style: merged,
          locale: locale,
        ),
      ],
      if (at < text.length) TextSpan(text: text.substring(at), locale: locale),
    ],
  );
}

/// The style of a search match: bold, in the text colour on a light tint
/// of the primary colour (also over primary-coloured text, which would
/// lose contrast on the tint), readable in light and dark themes.
TextStyle searchHighlightStyle(BuildContext context) {
  final colors = Theme.of(context).colorScheme;
  return TextStyle(
    fontWeight: FontWeight.w700,
    color: colors.onSurface,
    backgroundColor: Color.alphaBlend(
      colors.primary.withValues(alpha: 0.18),
      colors.surface,
    ),
  );
}
