/// A position-keeping lexer for HTML and XML, used by the markup document
/// parsers (HTML/XHTML, XLIFF, Android strings).
///
/// Unlike `tokenizeHtml` (web pages), every token records where it starts
/// and ends in the source, and the tokens cover the input without gaps, so
/// a document can be rebuilt byte for byte. Malformed markup never throws:
/// what cannot be read as markup (a stray `<`, an unterminated tag) is
/// text.
library;

/// Kinds of [MarkupToken].
enum MarkupKind {
  /// Character data, entities undecoded.
  text,

  /// Content of `<script>`, `<style>`, `<title>`, `<textarea>` and other
  /// raw text elements (HTML only).
  rawText,

  /// `<name attr="value">` or `<name/>`.
  startTag,

  /// `</name>`.
  endTag,

  /// `<!-- ... -->` (also bogus comments such as `</ x>`).
  comment,

  /// `<![CDATA[ ... ]]>`.
  cdata,

  /// `<?target ... ?>` (also the XML declaration).
  processing,

  /// `<!DOCTYPE ...>` and other markup declarations.
  declaration,
}

/// An attribute of a start tag, with the positions of its parts.
final class MarkupAttribute {
  const new({
    required this.name,
    required this.start,
    required this.end,
    this.valueStart = -1,
    this.valueEnd = -1,
    this.quote = '',
  });

  /// The name as written.
  final String name;

  /// Where the name starts.
  final int start;

  /// Where the attribute ends (after the closing quote).
  final int end;

  /// The raw value's span (inside the quotes); -1 without a value.
  final int valueStart;
  final int valueEnd;

  /// `"`, `'`, or empty for an unquoted value (or none).
  final String quote;

  bool get hasValue => valueStart >= 0;

  /// The raw (undecoded) value in [source].
  String rawValue(String source) =>
      hasValue ? source.substring(valueStart, valueEnd) : '';
}

/// A token of [lexMarkup].
final class MarkupToken {
  const new(
    this.kind,
    this.start,
    this.end, {
    this.name = '',
    this.attributes = const [],
    this.selfClosing = false,
  });

  final MarkupKind kind;

  /// Span of the token in the source (end exclusive).
  final int start;
  final int end;

  /// The tag name as written (tags only).
  final String name;

  final List<MarkupAttribute> attributes;

  /// Written as `<name ... />`.
  final bool selfClosing;

  /// [name] in ASCII lower case.
  String get lowerName => asciiLower(name);

  /// [name] without its namespace prefix (`xliff:g` -> `g`).
  String get localName {
    final colon = name.indexOf(':');
    return colon < 0 ? name : name.substring(colon + 1);
  }

  String raw(String source) => source.substring(start, end);

  /// The attribute called [attributeName] (ASCII case-insensitive when
  /// [ignoreCase]), or null.
  MarkupAttribute? attribute(String attributeName, {bool ignoreCase = false}) {
    final wanted = ignoreCase ? asciiLower(attributeName) : attributeName;
    for (final attribute in attributes) {
      final name = ignoreCase ? asciiLower(attribute.name) : attribute.name;
      if (name == wanted) return attribute;
    }
    return null;
  }
}

/// Elements whose content is text up to their end tag in HTML.
const htmlRawTextElements = {
  'script',
  'style',
  'xmp',
  'iframe',
  'noembed',
  'noframes',
  'plaintext',
  'title',
  'textarea',
};

/// Splits [source] (from [start]) into tokens that cover it completely.
///
/// With [html], raw text elements (`<script>`, `<style>`, `<title>`, ...)
/// are read up to their end tag and processing instructions end at the
/// first `>`; otherwise (XML) they end at `?>`.
List<MarkupToken> lexMarkup(
  String source, {
  required bool html,
  int start = 0,
}) {
  final scan = _Scan(source);
  final tokens = <MarkupToken>[];
  final length = source.length;
  var pos = start;
  var textStart = start;

  void text(int end) {
    if (end > textStart) {
      tokens.add(MarkupToken(MarkupKind.text, textStart, end));
    }
  }

  while (pos < length) {
    final lt = source.indexOf('<', pos);
    if (lt < 0 || lt + 1 >= length) break;
    final next = source.codeUnitAt(lt + 1);

    MarkupToken? token;
    if (_isNameStart(next)) {
      token = _startTag(scan, lt);
    } else if (next == _slash) {
      token = _endTag(scan, lt);
    } else if (next == _bang) {
      token = _bangToken(source, lt);
    } else if (next == _question) {
      final close = html
          ? source.indexOf('>', lt + 2)
          : source.indexOf('?>', lt + 2);
      final end = close < 0 ? length : close + (html ? 1 : 2);
      token = MarkupToken(MarkupKind.processing, lt, end);
    }
    if (token == null) {
      // A literal "<": keep it as text.
      pos = lt + 1;
      continue;
    }
    // A tag cut off by the end of the input: like browsers, nothing after
    // it is markup any more (and nothing is read twice).
    if (identical(token, _unterminated)) break;
    text(lt);
    tokens.add(token);
    pos = token.end;
    textStart = pos;

    if (html &&
        token.kind == MarkupKind.startTag &&
        !token.selfClosing &&
        htmlRawTextElements.contains(token.lowerName)) {
      final close = _findEndTag(source, token.lowerName, pos);
      final end = close < 0 ? length : close;
      if (end > pos) tokens.add(MarkupToken(MarkupKind.rawText, pos, end));
      pos = end;
      textStart = pos;
    }
  }
  text(length);
  return tokens;
}

/// Returned for a tag that the end of the input cuts off.
const _unterminated = MarkupToken(MarkupKind.text, 0, 0);

MarkupToken? _startTag(_Scan scan, int lt) {
  final source = scan.source;
  final length = source.length;
  var i = lt + 1;
  while (i < length && !_isTagNameEnd(source.codeUnitAt(i))) {
    i++;
  }
  final name = source.substring(lt + 1, i);
  final attributes = <MarkupAttribute>[];
  var selfClosing = false;
  while (true) {
    while (i < length) {
      final c = source.codeUnitAt(i);
      if (_isSpace(c)) {
        i++;
      } else if (c == _slash) {
        selfClosing = i + 1 < length && source.codeUnitAt(i + 1) == _gt;
        i++;
      } else {
        break;
      }
    }
    if (i >= length) return _unterminated;
    if (source.codeUnitAt(i) == _gt) {
      return MarkupToken(
        MarkupKind.startTag,
        lt,
        i + 1,
        name: name,
        attributes: attributes,
        selfClosing: selfClosing,
      );
    }
    selfClosing = false;
    if (source.codeUnitAt(i) == _lt) return null;

    final nameStart = i;
    i++;
    while (i < length) {
      final c = source.codeUnitAt(i);
      if (_isSpace(c) || c == _slash || c == _gt || c == _equals) break;
      i++;
    }
    final attributeName = source.substring(nameStart, i);
    var afterName = i;
    while (afterName < length && _isSpace(source.codeUnitAt(afterName))) {
      afterName++;
    }
    if (afterName >= length || source.codeUnitAt(afterName) != _equals) {
      attributes.add(
        MarkupAttribute(name: attributeName, start: nameStart, end: i),
      );
      continue;
    }
    i = afterName + 1;
    while (i < length && _isSpace(source.codeUnitAt(i))) {
      i++;
    }
    if (i >= length) return _unterminated;
    final quote = source.codeUnitAt(i);
    if (quote == _doubleQuote || quote == _singleQuote) {
      final close = scan.indexOfQuote(quote, i + 1);
      if (close < 0) return _unterminated;
      attributes.add(
        MarkupAttribute(
          name: attributeName,
          start: nameStart,
          end: close + 1,
          valueStart: i + 1,
          valueEnd: close,
          quote: String.fromCharCode(quote),
        ),
      );
      i = close + 1;
    } else {
      final valueStart = i;
      while (i < length) {
        final c = source.codeUnitAt(i);
        if (_isSpace(c) || c == _gt) break;
        i++;
      }
      attributes.add(
        MarkupAttribute(
          name: attributeName,
          start: nameStart,
          end: i,
          valueStart: valueStart,
          valueEnd: i,
        ),
      );
    }
  }
}

MarkupToken? _endTag(_Scan scan, int lt) {
  final source = scan.source;
  final length = source.length;
  if (lt + 2 < length && _isNameStart(source.codeUnitAt(lt + 2))) {
    var i = lt + 2;
    while (i < length && !_isTagNameEnd(source.codeUnitAt(i))) {
      i++;
    }
    final name = source.substring(lt + 2, i);
    final gt = _findTagEnd(scan, i);
    if (gt < 0) return _unterminated;
    return MarkupToken(MarkupKind.endTag, lt, gt + 1, name: name);
  }
  if (lt + 2 >= length) return null;
  // `</>` and `</ ...>`: a bogus comment.
  final gt = source.indexOf('>', lt + 2);
  return MarkupToken(MarkupKind.comment, lt, gt < 0 ? length : gt + 1);
}

MarkupToken _bangToken(String source, int lt) {
  final length = source.length;
  if (source.startsWith('<!--', lt)) {
    final end = source.indexOf('-->', lt + 4);
    return MarkupToken(MarkupKind.comment, lt, end < 0 ? length : end + 3);
  }
  if (source.startsWith('<![CDATA[', lt)) {
    final end = source.indexOf(']]>', lt + 9);
    return MarkupToken(MarkupKind.cdata, lt, end < 0 ? length : end + 3);
  }
  // <!DOCTYPE ...>, possibly with an internal subset in brackets.
  var i = lt + 2;
  var depth = 0;
  while (i < length) {
    final c = source.codeUnitAt(i);
    if (c == _doubleQuote || c == _singleQuote) {
      final close = source.indexOf(String.fromCharCode(c), i + 1);
      if (close < 0) return MarkupToken(MarkupKind.declaration, lt, length);
      i = close + 1;
      continue;
    }
    if (c == _openBracket) depth++;
    if (c == _closeBracket && depth > 0) depth--;
    if (c == _gt && depth == 0) {
      return MarkupToken(MarkupKind.declaration, lt, i + 1);
    }
    i++;
  }
  return MarkupToken(MarkupKind.declaration, lt, length);
}

/// Index of the `>` closing a tag whose name ended at [from], honouring
/// quoted attribute values; -1 when unterminated.
int _findTagEnd(_Scan scan, int from) {
  final source = scan.source;
  final length = source.length;
  var i = from;
  while (i < length) {
    final c = source.codeUnitAt(i);
    if (c == _gt) return i;
    if (c == _doubleQuote || c == _singleQuote) {
      final close = scan.indexOfQuote(c, i + 1);
      if (close < 0) return -1;
      i = close + 1;
      continue;
    }
    i++;
  }
  return -1;
}

/// The source being lexed, with the last position of each quote so that an
/// unclosed quote is found in constant time (otherwise every later tag
/// would scan to the end again).
final class _Scan {
  new(this.source)
    : _lastDouble = source.lastIndexOf('"'),
      _lastSingle = source.lastIndexOf("'");

  final String source;
  final int _lastDouble;
  final int _lastSingle;

  int indexOfQuote(int quote, int from) {
    final last = quote == _doubleQuote ? _lastDouble : _lastSingle;
    if (from > last) return -1;
    return source.indexOf(String.fromCharCode(quote), from);
  }
}

/// Index of `</name` (ASCII case-insensitive, followed by whitespace, `/`,
/// `>` or the end) at or after [from]; -1 when absent.
int _findEndTag(String source, String name, int from) {
  var i = from;
  while (true) {
    final candidate = source.indexOf('</', i);
    if (candidate < 0) return -1;
    final nameEnd = candidate + 2 + name.length;
    if (nameEnd <= source.length &&
        asciiLower(source.substring(candidate + 2, nameEnd)) == name &&
        (nameEnd == source.length ||
            _isTagNameEnd(source.codeUnitAt(nameEnd)))) {
      return candidate;
    }
    i = candidate + 2;
  }
}

/// [value] with ASCII letters in lower case.
String asciiLower(String value) {
  for (var i = 0; i < value.length; i++) {
    final c = value.codeUnitAt(i);
    if (c >= 0x41 && c <= 0x5A) {
      final units = value.codeUnits.toList();
      for (var j = i; j < units.length; j++) {
        final u = units[j];
        if (u >= 0x41 && u <= 0x5A) units[j] = u + 0x20;
      }
      return String.fromCharCodes(units);
    }
  }
  return value;
}

/// ASCII letters, `_` and `:` (XML name start characters in practice).
bool _isNameStart(int c) =>
    (c >= 0x41 && c <= 0x5A) ||
    (c >= 0x61 && c <= 0x7A) ||
    c == 0x5F ||
    c == 0x3A;

bool _isSpace(int c) =>
    c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0C || c == 0x0D;

bool _isTagNameEnd(int c) => _isSpace(c) || c == _slash || c == _gt;

const _lt = 0x3C; // <
const _slash = 0x2F; // /
const _gt = 0x3E; // >
const _bang = 0x21; // !
const _question = 0x3F; // ?
const _equals = 0x3D; // =
const _doubleQuote = 0x22; // "
const _singleQuote = 0x27; // '
const _openBracket = 0x5B; // [
const _closeBracket = 0x5D; // ]
