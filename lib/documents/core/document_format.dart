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
  json(['json', 'arb'], 'application/json', 'json'),

  /// HTML and XHTML pages: text is translated, markup, scripts and styles
  /// are kept.
  html(['html', 'htm', 'xhtml'], 'text/html', 'html'),

  /// XLIFF 1.2 and 2.x translation files: sources are translated into
  /// their targets.
  xliff(['xlf', 'xliff'], 'application/xliff+xml', 'xlf'),

  /// Android string resources (`res/values/strings.xml`).
  androidStrings(['xml'], 'application/xml', 'xml'),

  /// Gettext catalogues (`.po`, `.pot` templates).
  po(['po', 'pot'], 'text/x-gettext-translation', 'po'),

  /// Comma-separated values.
  csv(['csv'], 'text/csv', 'csv'),

  /// Tab-separated values.
  tsv(['tsv', 'tab'], 'text/tab-separated-values', 'tsv'),

  /// Apple `.strings` files.
  appleStrings(['strings'], 'text/plain', 'strings'),

  /// Xcode string catalogues (`.xcstrings`, JSON).
  xcstrings(['xcstrings'], 'application/json', 'xcstrings'),

  /// Word documents (Office Open XML).
  docx(
    ['docx'],
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'docx',
  ),

  /// PowerPoint presentations (Office Open XML).
  pptx(
    ['pptx'],
    'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'pptx',
  ),

  /// Excel workbooks (Office Open XML).
  xlsx(
    ['xlsx'],
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'xlsx',
  ),

  /// OpenDocument text.
  odt(['odt'], 'application/vnd.oasis.opendocument.text', 'odt'),

  /// OpenDocument presentations.
  odp(['odp'], 'application/vnd.oasis.opendocument.presentation', 'odp'),

  /// OpenDocument spreadsheets.
  ods(['ods'], 'application/vnd.oasis.opendocument.spreadsheet', 'ods'),

  /// EPUB e-books.
  epub(['epub'], 'application/epub+zip', 'epub');

  new(this.extensions, this.mimeType, this.defaultExtension);

  /// File extensions (lower case, without dot).
  final List<String> extensions;
  final String mimeType;
  final String defaultExtension;

  bool get isSubtitle => this == srt || this == vtt;

  /// Whether the format records the target language (it is passed to
  /// `parseDocument`, and the document is parsed again when it changes).
  bool get usesTargetLanguage =>
      this == xliff || this == po || this == xcstrings || this == html;

  /// Whether files of this format are ZIP packages (office documents and
  /// e-books) rather than text: they are read and written as bytes, never
  /// pasted.
  bool get isBinary => switch (this) {
    docx || pptx || xlsx || odt || odp || ods || epub => true,
    _ => false,
  };

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
  ///
  /// Recognised besides subtitles, JSON and Markdown: HTML (a document or
  /// a fragment that starts with an HTML element and is not Markdown with
  /// some HTML in it), XLIFF (`<xliff>` root), Android strings
  /// (`<resources>` root), gettext PO (`msgid` and `msgstr` lines), Xcode
  /// string catalogues (JSON with `strings` and `sourceLanguage`), Apple
  /// `.strings` (only `"key" = "value";` lines and comments) and TSV
  /// (cells copied from a spreadsheet: the same number of tabs on every
  /// line). CSV is never guessed (too much plain text has commas).
  static DocumentFormat sniff(String text) {
    // trimLeft() also drops a byte order mark.
    final trimmed = text.trimLeft();
    if (trimmed.startsWith('WEBVTT')) return vtt;
    if (_srtCue.hasMatch(trimmed)) return srt;
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        final value = jsonDecode(trimmed);
        if (value is Map &&
            value['strings'] is Map &&
            (value.containsKey('sourceLanguage') ||
                value.containsKey('version'))) {
          return xcstrings;
        }
        if (value is Map || value is List) return json;
      } on FormatException {
        // Not JSON.
      }
    }
    final strong = _markdownStrong.allMatches(trimmed).length;
    if (trimmed.startsWith('<')) {
      final markup = _sniffMarkup(trimmed, markdown: strong > 0);
      if (markup != null) return markup;
    }
    if (_poMsgid.hasMatch(trimmed) &&
        _poMsgstr.hasMatch(trimmed) &&
        !trimmed.contains('```')) {
      return po;
    }
    if (_isAppleStrings(trimmed)) return appleStrings;
    if (_isTsv(trimmed)) return tsv;
    final weak = _markdownWeak.allMatches(trimmed).length;
    if (strong > 0 || weak >= 2) return markdown;
    return plainText;
  }

  /// HTML, XLIFF or Android strings from the first element of [text].
  static DocumentFormat? _sniffMarkup(String text, {required bool markdown}) {
    // Moves through the text without copying it (linear time for a text
    // full of declarations and comments).
    var start = 0;
    while (true) {
      while (start < text.length && text[start].trim().isEmpty) {
        start++;
      }
      final prolog = _markupProlog.matchAsPrefix(text, start);
      if (prolog == null) break;
      if (_htmlDoctype.matchAsPrefix(text, start) != null) return html;
      start = prolog.end;
    }
    final element = _firstElement.matchAsPrefix(text, start);
    if (element == null) return null;
    final name = element.group(1)!.toLowerCase();
    final local = name.contains(':')
        ? name.substring(name.indexOf(':') + 1)
        : name;
    if (local == 'xliff') return xliff;
    if (local == 'resources') return androidStrings;
    if (name == 'html') return html;
    if (markdown || !_htmlElements.contains(name)) return null;
    // A fragment: at least one closing tag or void element.
    return _closingOrVoid.hasMatch(text) ? html : null;
  }

  static bool _isAppleStrings(String text) {
    if (!text.startsWith('"') && !text.startsWith('/')) return false;
    final code = _withoutBlockComments(text)
        .split(RegExp(r'\r?\n'))
        .where(
          (line) => line.trim().isNotEmpty && !line.trimLeft().startsWith('//'),
        )
        .toList();
    return code.isNotEmpty && code.every(_appleStringsPair.hasMatch);
  }

  /// [text] with each `/* … */` comment replaced by a line break (an
  /// unclosed one runs to the end). A loop, as `/\*[\s\S]*?\*/` scans to
  /// the end of the text from every `/*` that is never closed.
  static String _withoutBlockComments(String text) {
    final out = StringBuffer();
    var position = 0;
    while (true) {
      final open = text.indexOf('/*', position);
      if (open == -1) break;
      final close = text.indexOf('*/', open + 2);
      if (close == -1) break;
      out
        ..write(text.substring(position, open))
        ..write('\n');
      position = close + 2;
    }
    out.write(text.substring(position));
    return out.toString();
  }

  static bool _isTsv(String text) {
    final lines = text
        .trimRight()
        .split(RegExp(r'\r?\n|\r'))
        .where((line) => line.trim().isNotEmpty)
        .toList();
    if (lines.length < 2) return false;
    final tabs = '\t'.allMatches(lines.first).length;
    if (tabs == 0) return false;
    return lines.every((line) => '\t'.allMatches(line).length == tabs) &&
        lines.any(_innerTab.hasMatch);
  }

  // `(?:\[…\]\s*)?>` rather than `(?:\[…\])?\s*>`: the spaces before
  // `>` are part of `[^>\[]*` unless there is an internal subset.
  static final _markupProlog = RegExp(
    r'<\?[\s\S]*?\?>|<!--[\s\S]*?-->|<!DOCTYPE[^>\[]*(?:\[[\s\S]*?\]\s*)?>',
    caseSensitive: false,
  );
  static final _htmlDoctype = RegExp(
    r'<!DOCTYPE\s+html[\s>]',
    caseSensitive: false,
  );
  static final _firstElement = RegExp(r'<([A-Za-z][\w:.-]*)[\s/>]');
  static final _closingOrVoid = RegExp(
    r'</[A-Za-z][\w-]*\s*>|<(?:br|hr|img|input|meta|link)\b',
    caseSensitive: false,
  );

  /// Elements that start an HTML fragment.
  static const _htmlElements = {
    'a',
    'abbr',
    'address',
    'article',
    'aside',
    'b',
    'blockquote',
    'body',
    'br',
    'button',
    'caption',
    'cite',
    'code',
    'dd',
    'details',
    'dfn',
    'div',
    'dl',
    'dt',
    'em',
    'figure',
    'footer',
    'form',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'head',
    'header',
    'hr',
    'i',
    'img',
    'label',
    'li',
    'link',
    'main',
    'mark',
    'meta',
    'nav',
    'ol',
    'p',
    'pre',
    'q',
    's',
    'section',
    'small',
    'span',
    'strong',
    'sub',
    'summary',
    'sup',
    'table',
    'tbody',
    'td',
    'th',
    'thead',
    'title',
    'tr',
    'u',
    'ul',
  };

  static final _poMsgid = RegExp(r'^msgid[ \t]+"', multiLine: true);
  static final _poMsgstr = RegExp(
    r'^msgstr(?:\[\d+\])?[ \t]+"',
    multiLine: true,
  );
  static final _appleStringsPair = RegExp(
    r'^\s*"(?:[^"\\]|\\.)*"\s*=\s*"(?:[^"\\]|\\.)*"\s*;\s*(?://.*)?$',
  );
  static final _innerTab = RegExp(r'\S\t+\S');

  static final _srtCue = RegExp(
    r'^\d+[ \t]*\r?\n[ \t]*\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}[ \t]*-->',
  );

  /// Headings, fences and tables.
  ///
  /// The sniffing patterns take linear time: no two adjacent repetitions
  /// match the same characters (`[ \t]*(?:\|[ \t]*)?`, not
  /// `[ \t]*\|?[ \t]*`), and a link text never contains `[` (or every `[`
  /// of a line full of them would scan to its end).
  static final _markdownStrong = RegExp(
    r'^(?:#{1,6}[ \t]+\S|```|~~~'
    r'|\|.*\|[ \t]*\r?\n[ \t]*(?:\|[ \t]*)?:?-{3,})',
    multiLine: true,
  );

  /// Lists, quotes, links, emphasis and inline code.
  static final _markdownWeak = RegExp(
    r'^[ \t]*(?:[-*+]|\d{1,3}[.)])[ \t]+\S|^>[ \t]?\S'
    r'|\[[^\[\]\n]+\]\([^)\s]+\)|\*\*[^*\n]+\*\*|`[^`\n]+`',
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
      .replaceAll(RegExp('[^A-Za-z0-9_-]+'), '-')
      .replaceAll(RegExp('-{2,}'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');
  if (cleaned.isEmpty) return 'translated';
  // Custom AI "languages" (e.g. "Pirate speak") become lower case slugs.
  return _localeStem.hasMatch(cleaned) ? cleaned : cleaned.toLowerCase();
}
