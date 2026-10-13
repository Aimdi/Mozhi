import 'dart:convert';

/// Text document formats the document translator understands.
enum DocumentFormat {
  /// Plain text: translated paragraph by paragraph.
  plainText(['txt', 'text'], 'text/plain', 'txt'),

  /// Markdown: code, inline code, URLs and markup are kept verbatim.
  markdown(['md', 'markdown', 'mdown', 'mkd'], 'text/markdown', 'md'),

  /// SubRip subtitles: numbering and timestamps are kept.
  srt(['srt'], 'application/x-subrip', 'srt'),

  /// WebVTT subtitles: header, notes, styles, timings and cue settings are
  /// kept.
  vtt(['vtt'], 'text/vtt', 'vtt'),

  /// JSON / ARB string tables: only string values are translated; keys,
  /// `@` metadata and ICU placeholders/plurals are kept.
  json(['json', 'arb'], 'application/json', 'json');

  const DocumentFormat(this.extensions, this.mimeType, this.defaultExtension);

  /// File extensions (lower case, without dot).
  final List<String> extensions;
  final String mimeType;
  final String defaultExtension;

  bool get isSubtitle => this == srt || this == vtt;

  /// Whether a bilingual export (original line + translation) makes sense.
  bool get supportsBilingual => isSubtitle;

  /// All supported extensions, e.g. for a file picker filter.
  static List<String> get allExtensions => [
    for (final format in values) ...format.extensions,
  ];

  /// The format for [fileName]'s extension, or null when unsupported.
  static DocumentFormat? fromFileName(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot < 0 || dot == fileName.length - 1) return null;
    final extension = fileName.substring(dot + 1).toLowerCase();
    for (final format in values) {
      if (format.extensions.contains(extension)) return format;
    }
    return null;
  }

  /// Guesses the format of pasted [text].
  static DocumentFormat sniff(String text) {
    final trimmed = text.trimLeft().replaceFirst('﻿', '');
    if (trimmed.startsWith('WEBVTT')) return vtt;
    if (_srtCue.hasMatch(trimmed)) return srt;
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        final value = jsonDecode(trimmed);
        if (value is Map || value is List) return json;
      } on FormatException {
        // Not JSON.
      }
    }
    final strong = _markdownStrong.allMatches(trimmed).length;
    final weak = _markdownWeak.allMatches(trimmed).length;
    if (strong > 0 || weak >= 2) return markdown;
    return plainText;
  }

  static final _srtCue = RegExp(
    r'^\d+[ \t]*\r?\n[ \t]*\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}[ \t]*-->',
  );

  /// Headings, fences and tables.
  static final _markdownStrong = RegExp(
    r'^(?:#{1,6}[ \t]+\S|```|~~~|\|.*\|[ \t]*\r?\n[ \t]*\|?[ \t]*:?-{3,})',
    multiLine: true,
  );

  /// Lists, quotes, links, emphasis and inline code.
  static final _markdownWeak = RegExp(
    r'^[ \t]*(?:[-*+]|\d{1,3}[.)])[ \t]+\S|^>[ \t]?\S|\[[^\]\n]+\]\([^)\s]+\)'
    r'|\*\*[^*\n]+\*\*|`[^`\n]+`',
    multiLine: true,
  );
}

/// Suggests a file name for the translation of [original] (null for pasted
/// text) into the language [targetCode].
///
/// * ARB files with a locale suffix swap the locale (`app_en.arb` ->
///   `app_de.arb`, `intl_pt_BR.arb` -> `intl_es.arb`).
/// * JSON files named after a locale are renamed (`en.json` -> `de.json`).
/// * Otherwise the code is inserted before the extension, replacing an
///   existing language code (`movie.en.srt` -> `movie.de.srt`).
String translatedFileName(
  String? original,
  DocumentFormat format,
  String targetCode,
) {
  final code = _fileCode(targetCode);
  if (original == null || original.trim().isEmpty) {
    return 'translation.$code.${format.defaultExtension}';
  }
  final name = original.split(RegExp(r'[/\\]')).last;
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final extension = dot > 0 ? name.substring(dot + 1) : format.defaultExtension;

  if (extension.toLowerCase() == 'arb') {
    final match = _arbLocale.firstMatch(stem);
    if (match != null) {
      return '${match.group(1)}${code.replaceAll('-', '_')}.$extension';
    }
  }
  if (format == DocumentFormat.json && _localeStem.hasMatch(stem)) {
    return '$code.$extension';
  }
  final inner = stem.lastIndexOf('.');
  if (inner > 0 && _localeStem.hasMatch(stem.substring(inner + 1))) {
    return '${stem.substring(0, inner)}.$code.$extension';
  }
  return '$stem.$code.$extension';
}

/// `app_en`, `intl_pt_BR`, `strings-zh-Hant`.
final _arbLocale = RegExp(
  r'^(.*[_-])([a-z]{2,3}(?:[_-](?:[A-Z]{2}|[A-Z][a-z]{3}|\d{3}))?)$',
);

/// `en`, `pt-BR`, `zh_Hant`.
final _localeStem = RegExp(
  r'^[a-z]{2,3}(?:[_-](?:[A-Za-z]{2}|[A-Z][a-z]{3}|\d{3}))?$',
);

String _fileCode(String code) {
  final cleaned = code
      .trim()
      .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-')
      .replaceAll(RegExp('-{2,}'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');
  if (cleaned.isEmpty) return 'translated';
  // Custom AI "languages" (e.g. "Pirate speak") become lower case slugs.
  return _localeStem.hasMatch(cleaned) ? cleaned : cleaned.toLowerCase();
}
