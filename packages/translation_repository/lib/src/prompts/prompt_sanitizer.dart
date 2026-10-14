/// Text hygiene for prompts and model output (prompt-injection hardening).
///
/// Internal helpers shared by `TranslationPrompts`, `MtPrompts` and
/// `ResponseParsers`; not exported from the package.
abstract final class PromptSanitizer {
  /// Inserted after `<` to defuse a tag inside data (see [neutraliseTag]).
  static const zeroWidthSpace = '\u200B';

  /// C0/C1 control characters and the Unicode line/paragraph separators.
  static final _controls = RegExp(r'[\x00-\x1F\x7F-\x9F\u2028\u2029]');

  /// Invisible format characters that can hide or reorder text (zero-width
  /// space, directional marks, embeddings, overrides and isolates, word
  /// joiners, BOM). ZWJ/ZWNJ are kept: scripts and emoji need them.
  static final _invisible = RegExp(
    r'[\u200B\u200E\u200F\u202A-\u202E\u2060-\u2064\u2066-\u2069\uFEFF]',
  );

  /// Double quotes (ASCII and typographic), guillemets and backticks.
  /// Apostrophes (`'`, `’`) are kept: "Shakespeare's English" is harmless
  /// inside the double quotes the prompts put around custom names.
  static final _quotes = RegExp('["`“”„‟″«»‹›‘‛]');

  static final _angleBrackets = RegExp('[<>]');
  static final _whitespace = RegExp(r'\s+');

  /// Inserts a zero-width space after `<` in every opening or closing form
  /// of the [name] tag inside [content] (case-insensitive, with optional
  /// spaces and attributes: `<source>`, `</SOURCE>`, `< / source >`,
  /// `<source lang="x">`), so the data can never close (or reopen) the tag
  /// that wraps it: exactly one real closing tag remains.
  static String neutraliseTag(String content, String name) =>
      content.replaceAll(
        RegExp(
          '<(?=\\s*/?\\s*${RegExp.escape(name)}(?![\\w-]))',
          caseSensitive: false,
        ),
        '<$zeroWidthSpace',
      );

  /// Reverts [neutraliseTag] in model output that copied a defused tag, so
  /// e.g. an HTML `<source>` element survives a round trip. [original] is
  /// the text the user sent; when it already contained `<` + zero-width
  /// space, nothing is changed.
  static String restoreTags(String text, {String original = ''}) {
    const defused = '<$zeroWidthSpace';
    if (original.contains(defused) || !text.contains(defused)) return text;
    return text.replaceAll(defused, '<');
  }

  /// [text] as a single line: control characters become spaces, invisible
  /// format characters are removed, whitespace runs collapse to one space
  /// and the ends are trimmed.
  ///
  /// * [stripQuotes] also removes double quotes, guillemets and backticks.
  /// * [stripAngleBrackets] also removes `<` and `>`.
  /// * [maxLength] caps the result at that many characters (Unicode code
  ///   points); with [atWordBoundary] the cut moves back to the last space
  ///   when that keeps at least three quarters of the text.
  static String singleLine(
    String text, {
    int? maxLength,
    bool stripQuotes = false,
    bool stripAngleBrackets = false,
    bool atWordBoundary = false,
  }) {
    var s = text.replaceAll(_controls, ' ').replaceAll(_invisible, '');
    if (stripQuotes) s = s.replaceAll(_quotes, '');
    if (stripAngleBrackets) s = s.replaceAll(_angleBrackets, ' ');
    s = s.replaceAll(_whitespace, ' ').trim();
    if (maxLength == null) return s;
    return cap(s, maxLength, atWordBoundary: atWordBoundary);
  }

  /// Line breaks (`\r\n`, `\r`, and the Unicode line and paragraph
  /// separators).
  static final _lineBreaks = RegExp('\r\n?|[\u2028\u2029]');

  /// Control characters other than tabs and line feeds.
  static final _controlsButLines = RegExp(r'[\x00-\x08\x0B-\x1F\x7F-\x9F]');

  /// [text] (model output shown to the user) with its lines kept: line
  /// breaks are normalised to `\n`, other control characters (except tabs)
  /// and invisible format characters (see [singleLine]) are removed and the
  /// ends are trimmed. [maxLength] caps the result like [cap].
  static String multiLine(String text, {int? maxLength}) {
    final s = text
        .replaceAll(_lineBreaks, '\n')
        .replaceAll(_controlsButLines, '')
        .replaceAll(_invisible, '')
        .trim();
    return maxLength == null ? s : cap(s, maxLength);
  }

  /// [text] cut to at most [maxLength] Unicode code points (never splitting
  /// a surrogate pair), trimmed at the end. See [singleLine] for
  /// [atWordBoundary].
  static String cap(String text, int maxLength, {bool atWordBoundary = false}) {
    final runes = text.runes;
    if (runes.length <= maxLength) return text;
    var cut = String.fromCharCodes(runes.take(maxLength));
    if (atWordBoundary) {
      final space = cut.lastIndexOf(' ');
      if (space >= cut.length * 3 ~/ 4) cut = cut.substring(0, space);
    }
    return cut.trimRight();
  }

  /// The beginning of [text] that is sent when at most [max] UTF-16 code
  /// units fit: [text] itself when it fits, else its first [max] code
  /// units, cut back to the last whitespace when that keeps more than 80 %
  /// of them, never ending on a lone high surrogate. Always a prefix of
  /// [text], so offsets into it are offsets into [text].
  static String prefix(String text, int max) {
    if (text.length <= max) return text;
    var cut = text.substring(0, max);
    final space = cut.lastIndexOf(_whitespace);
    if (space > max * 0.8) cut = cut.substring(0, space);
    if (cut.isEmpty) return cut;
    final last = cut.codeUnitAt(cut.length - 1);
    if (last >= 0xD800 && last <= 0xDBFF) {
      cut = cut.substring(0, cut.length - 1);
    }
    return cut;
  }
}
