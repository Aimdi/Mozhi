import 'package:mozhi/documents/core/document_builder.dart';
import 'package:mozhi/documents/core/document_format.dart';
import 'package:mozhi/documents/core/parsed_document.dart';
import 'package:mozhi/documents/core/parsers/json_parser.dart'
    show DocumentParseException, looksLikeNaturalLanguage;
import 'package:mozhi/documents/core/parsers/locale_rules.dart'
    show LocalisationPatterns;
import 'package:mozhi/documents/core/parsers/markup_content.dart'
    show NodeList, hasSegment;
import 'package:mozhi/documents/core/parsers/xml_tree.dart'
    show checkDocumentLength;
import 'package:translation_repository/translation_repository.dart'
    show ProtectedPatterns;

/// Parses TOML localisation and configuration files ([DocumentFormat.toml]:
/// Hugo i18n, Rust/Cargo apps, …).
///
/// Preserves tables (`[section]`), arrays of tables (`[[items]]`), inline
/// tables (`{ a = "b" }`), arrays (`[...]`), `#` comments (including inline
/// comments), keys, numbers, booleans and dates/times. Basic strings
/// (`"..."`), multiline basic strings (`"""..."""`), literal strings
/// (`'...'`) and multiline literal strings (`'''...'''`) are translated while
/// protecting placeholders (`%{name}`, `{{name}}`, `${name}`, `{name}`,
/// printf, HTML tags, URLs and e-mail addresses).
///
/// Throws [DocumentParseException] for malformed TOML.
ParsedDocument parseToml(String text) {
  checkDocumentLength(text, 'TOML');
  return _TomlParser(text).parse();
}

const _skipLeafKeys = {
  'id',
  'uuid',
  'guid',
  'slug',
  'url',
  'uri',
  'href',
  'src',
  'path',
  'filepath',
  'dir',
  'directory',
  'route',
  'endpoint',
  'host',
  'hostname',
  'port',
  'ip',
  'email',
  'mail',
  'color',
  'colour',
  'bgcolor',
  'icon',
  'image',
  'img',
  'avatar',
  'logo',
  'font',
  'locale',
  'lang',
  'language',
  'code',
  'currency',
  'timezone',
  'tz',
  'version',
  'date',
  'time',
  'datetime',
  'timestamp',
  'hash',
  'checksum',
  'token',
  'secret',
  'regex',
  'regexp',
  'pattern',
  'class',
  'classname',
  'style',
  'method',
  'format',
  'encoding',
  'mime',
  'mimetype',
};

final RegExp _tomlPlaceholders = ProtectedPatterns.combine([
  LocalisationPatterns.htmlTag,
  ProtectedPatterns.url,
  ProtectedPatterns.email,
  r'\{\{\{?[^{}]*\}\}\}?',
  r'%\{[A-Za-z_][\w.-]*\}',
  r'\$\{[A-Za-z_][\w.-]*\}',
  LocalisationPatterns.braces,
  LocalisationPatterns.printfInText,
]);

class _TomlParser {
  new(this.source);

  final String source;
  final DocumentBuilder builder = DocumentBuilder();
  final NodeList _nodes = NodeList();
  int _pos = 0;
  String _section = '';

  Never _fail(String message) {
    final line = '\n'.allMatches(source.substring(0, _pos)).length + 1;
    throw DocumentParseException('TOML: line $line: $message');
  }

  ParsedDocument parse() {
    if (source.startsWith('\uFEFF')) {
      _nodes.text('\uFEFF');
      _pos = 1;
    }
    while (true) {
      _skipTrivia();
      if (_pos >= source.length) break;
      final ch = source[_pos];
      if (ch == '[') {
        _parseTableHeader();
      } else {
        _parseKeyValue(prefixPath: _section, inInlineTable: false);
      }
      _skipHorizontalSpaceAndComment();
      if (_pos < source.length) {
        if (source[_pos] == '\r' || source[_pos] == '\n') {
          _consumeLineBreak();
        } else {
          _fail('unexpected character "${source[_pos]}"');
        }
      }
    }
    builder.add(_nodes.nodes);
    return builder.build(DocumentFormat.toml);
  }

  void _skipTrivia() {
    final start = _pos;
    while (_pos < source.length) {
      final ch = source[_pos];
      if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n') {
        _pos++;
      } else if (ch == '#') {
        while (_pos < source.length && source[_pos] != '\n') {
          _pos++;
        }
      } else {
        break;
      }
    }
    if (_pos > start) _nodes.text(source.substring(start, _pos));
  }

  void _skipHorizontalSpace() {
    final start = _pos;
    while (_pos < source.length &&
        (source[_pos] == ' ' || source[_pos] == '\t')) {
      _pos++;
    }
    if (_pos > start) _nodes.text(source.substring(start, _pos));
  }

  void _skipHorizontalSpaceAndComment() {
    final start = _pos;
    while (_pos < source.length &&
        (source[_pos] == ' ' || source[_pos] == '\t')) {
      _pos++;
    }
    if (_pos < source.length && source[_pos] == '#') {
      while (_pos < source.length &&
          source[_pos] != '\n' &&
          source[_pos] != '\r') {
        _pos++;
      }
    }
    if (_pos > start) _nodes.text(source.substring(start, _pos));
  }

  void _consumeLineBreak() {
    final start = _pos;
    if (_pos < source.length && source[_pos] == '\r') _pos++;
    if (_pos < source.length && source[_pos] == '\n') _pos++;
    _nodes.text(source.substring(start, _pos));
  }

  void _parseTableHeader() {
    final arrayTable = _pos + 1 < source.length && source[_pos + 1] == '[';
    _nodes.text(arrayTable ? '[[' : '[');
    _pos += arrayTable ? 2 : 1;
    _skipHorizontalSpace();
    final keyParts = _parseDottedKey();
    _skipHorizontalSpace();
    if (arrayTable) {
      if (_pos + 1 >= source.length ||
          source[_pos] != ']' ||
          source[_pos + 1] != ']') {
        _fail('expected "]]" to close array of tables');
      }
      _nodes.text(']]');
      _pos += 2;
    } else {
      if (_pos >= source.length || source[_pos] != ']') {
        _fail('expected "]" to close table header');
      }
      _nodes.text(']');
      _pos++;
    }
    _section = keyParts.join('.');
  }

  List<String> _parseDottedKey() {
    final parts = <String>[];
    while (true) {
      final start = _pos;
      final part = _parseSingleKey();
      parts.add(part);
      _nodes.text(source.substring(start, _pos));
      _skipHorizontalSpace();
      if (_pos < source.length && source[_pos] == '.') {
        _nodes.text('.');
        _pos++;
        _skipHorizontalSpace();
        continue;
      }
      break;
    }
    return parts;
  }

  String _parseSingleKey() {
    if (_pos >= source.length) _fail('expected key');
    final ch = source[_pos];
    if (ch == '"') {
      final start = _pos;
      _pos++;
      while (_pos < source.length) {
        final c = source[_pos];
        if (c == '\n' || c == '\r') _fail('unterminated quoted key');
        if (c == r'\') {
          _pos += 2;
          continue;
        }
        if (c == '"') {
          _pos++;
          return _decodeBasic(source.substring(start + 1, _pos - 1));
        }
        _pos++;
      }
      _fail('unterminated quoted key');
    }
    if (ch == "'") {
      final start = _pos;
      _pos++;
      while (_pos < source.length) {
        final c = source[_pos];
        if (c == '\n' || c == '\r') _fail('unterminated literal key');
        if (c == "'") {
          _pos++;
          return source.substring(start + 1, _pos - 1);
        }
        _pos++;
      }
      _fail('unterminated literal key');
    }
    final start = _pos;
    while (_pos < source.length && _isBareKeyChar(source.codeUnitAt(_pos))) {
      _pos++;
    }
    if (_pos == start) _fail('invalid key');
    return source.substring(start, _pos);
  }

  static bool _isBareKeyChar(int unit) =>
      (unit >= 0x41 && unit <= 0x5A) ||
      (unit >= 0x61 && unit <= 0x7A) ||
      (unit >= 0x30 && unit <= 0x39) ||
      unit == 0x5F ||
      unit == 0x2D;

  void _parseKeyValue({
    required String prefixPath,
    required bool inInlineTable,
  }) {
    final parts = _parseDottedKey();
    _skipHorizontalSpace();
    if (_pos >= source.length || source[_pos] != '=') {
      _fail('expected "=" after key "${parts.join('.')}"');
    }
    _nodes.text('=');
    _pos++;
    _skipHorizontalSpace();
    final keyPath = prefixPath.isEmpty
        ? parts.join('.')
        : '$prefixPath.${parts.join('.')}';
    final leafKey = parts.last;
    _parseValue(
      path: keyPath,
      skip: _skipLeafKeys.contains(leafKey.toLowerCase()),
      inInlineTable: inInlineTable,
    );
  }

  void _parseValue({
    required String path,
    required bool skip,
    required bool inInlineTable,
  }) {
    if (_pos >= source.length) _fail('expected value');
    if (source.startsWith('"""', _pos)) {
      _parseMultilineBasicString(path, skip: skip);
      return;
    }
    if (source.startsWith("'''", _pos)) {
      _parseMultilineLiteralString(path, skip: skip);
      return;
    }
    final ch = source[_pos];
    if (ch == '"') {
      _parseBasicString(path, skip: skip);
      return;
    }
    if (ch == "'") {
      _parseLiteralString(path, skip: skip);
      return;
    }
    if (ch == '[') {
      _parseArray(path, skip: skip);
      return;
    }
    if (ch == '{') {
      _parseInlineTable(path);
      return;
    }
    // Primitive: boolean, number, or date/time.
    final start = _pos;
    while (_pos < source.length) {
      final c = source[_pos];
      if (c == '\n' ||
          c == '\r' ||
          c == '#' ||
          c == ',' ||
          c == ']' ||
          c == '}') {
        break;
      }
      _pos++;
    }
    final raw = source.substring(start, _pos);
    final trimmed = raw.trimRight();
    if (trimmed.isEmpty) _fail('missing value');
    if (!_isValidPrimitive(trimmed)) {
      _fail('invalid value "$trimmed"');
    }
    // Rewind trailing horizontal whitespace so caller handles it.
    _pos = start + trimmed.length;
    _nodes.text(trimmed);
  }

  void _parseBasicString(String path, {required bool skip}) {
    final start = _pos;
    _pos++; // opening "
    while (_pos < source.length) {
      final ch = source[_pos];
      if (ch == '\n' || ch == '\r') _fail('unterminated basic string');
      if (ch == r'\') {
        if (_pos + 1 >= source.length) _fail('unterminated escape');
        _pos += 2;
        continue;
      }
      if (ch == '"') {
        _pos++;
        final raw = source.substring(start, _pos);
        final decoded = _decodeBasic(raw.substring(1, raw.length - 1));
        if (skip) {
          _nodes.text(raw);
          return;
        }
        final contentNodes = builder.content(
          protect(decoded, _tomlPlaceholders),
          label: path,
          accept: looksLikeNaturalLanguage,
        );
        if (!hasSegment(contentNodes)) {
          _nodes.text(raw);
        } else {
          _nodes.addAll([
            EncodedNode(
              raw: raw,
              children: contentNodes,
              encode: _encodeBasicString,
            ),
          ]);
        }
        return;
      }
      _pos++;
    }
    _fail('unterminated basic string');
  }

  void _parseLiteralString(String path, {required bool skip}) {
    final start = _pos;
    _pos++; // opening '
    while (_pos < source.length) {
      final ch = source[_pos];
      if (ch == '\n' || ch == '\r') _fail('unterminated literal string');
      if (ch == "'") {
        _pos++;
        final raw = source.substring(start, _pos);
        final decoded = raw.substring(1, raw.length - 1);
        if (skip) {
          _nodes.text(raw);
          return;
        }
        final contentNodes = builder.content(
          protect(decoded, _tomlPlaceholders),
          label: path,
          accept: looksLikeNaturalLanguage,
        );
        if (!hasSegment(contentNodes)) {
          _nodes.text(raw);
        } else {
          _nodes.addAll([
            EncodedNode(
              raw: raw,
              children: contentNodes,
              encode: _encodeLiteralString,
            ),
          ]);
        }
        return;
      }
      _pos++;
    }
    _fail('unterminated literal string');
  }

  void _parseMultilineBasicString(String path, {required bool skip}) {
    final start = _pos;
    _pos += 3; // """
    while (_pos < source.length) {
      if (source[_pos] == r'\') {
        if (_pos + 1 >= source.length) _fail('unterminated escape');
        _pos += 2;
        continue;
      }
      if (source.startsWith('"""', _pos)) {
        // Up to 2 additional quotes allowed inside the closing delimiter.
        _pos += 3;
        var extra = 0;
        while (extra < 2 && _pos < source.length && source[_pos] == '"') {
          _pos++;
          extra++;
        }
        final raw = source.substring(start, _pos);
        var inner = raw.substring(3, raw.length - 3);
        var leadingNewline = '';
        if (inner.startsWith('\r\n')) {
          leadingNewline = '\r\n';
          inner = inner.substring(2);
        } else if (inner.startsWith('\n')) {
          leadingNewline = '\n';
          inner = inner.substring(1);
        }
        final decoded = _decodeBasic(inner, multiline: true);
        if (skip) {
          _nodes.text(raw);
          return;
        }
        final contentNodes = builder.content(
          protect(decoded, _tomlPlaceholders),
          label: path,
          accept: looksLikeNaturalLanguage,
        );
        if (!hasSegment(contentNodes)) {
          _nodes.text(raw);
        } else {
          _nodes.addAll([
            EncodedNode(
              raw: raw,
              children: contentNodes,
              encode: (value) =>
                  '"""$leadingNewline${_escapeMultilineBasic(value)}"""',
            ),
          ]);
        }
        return;
      }
      _pos++;
    }
    _fail('unterminated multiline basic string');
  }

  void _parseMultilineLiteralString(String path, {required bool skip}) {
    final start = _pos;
    _pos += 3; // '''
    while (_pos < source.length) {
      if (source.startsWith("'''", _pos)) {
        _pos += 3;
        var extra = 0;
        while (extra < 2 && _pos < source.length && source[_pos] == "'") {
          _pos++;
          extra++;
        }
        final raw = source.substring(start, _pos);
        var inner = raw.substring(3, raw.length - 3);
        var leadingNewline = '';
        if (inner.startsWith('\r\n')) {
          leadingNewline = '\r\n';
          inner = inner.substring(2);
        } else if (inner.startsWith('\n')) {
          leadingNewline = '\n';
          inner = inner.substring(1);
        }
        if (skip) {
          _nodes.text(raw);
          return;
        }
        final contentNodes = builder.content(
          protect(inner, _tomlPlaceholders),
          label: path,
          accept: looksLikeNaturalLanguage,
        );
        if (!hasSegment(contentNodes)) {
          _nodes.text(raw);
        } else {
          _nodes.addAll([
            EncodedNode(
              raw: raw,
              children: contentNodes,
              encode: (value) => value.contains("'''")
                  ? '"""$leadingNewline${_escapeMultilineBasic(value)}"""'
                  : "'''$leadingNewline$value'''",
            ),
          ]);
        }
        return;
      }
      _pos++;
    }
    _fail('unterminated multiline literal string');
  }

  void _parseArray(String path, {required bool skip}) {
    _nodes.text('[');
    _pos++;
    var index = 0;
    while (true) {
      _skipTrivia();
      if (_pos >= source.length) _fail('unclosed array');
      if (source[_pos] == ']') {
        _nodes.text(']');
        _pos++;
        return;
      }
      _parseValue(path: '$path[$index]', skip: skip, inInlineTable: false);
      index++;
      _skipTrivia();
      if (_pos >= source.length) _fail('unclosed array');
      if (source[_pos] == ',') {
        _nodes.text(',');
        _pos++;
      } else if (source[_pos] == ']') {
        _nodes.text(']');
        _pos++;
        return;
      } else {
        _fail('expected "," or "]" in array');
      }
    }
  }

  void _parseInlineTable(String path) {
    _nodes.text('{');
    _pos++;
    _skipHorizontalSpace();
    if (_pos < source.length && source[_pos] == '}') {
      _nodes.text('}');
      _pos++;
      return;
    }
    while (true) {
      _skipHorizontalSpace();
      if (_pos >= source.length) _fail('unclosed inline table');
      _parseKeyValue(prefixPath: path, inInlineTable: true);
      _skipHorizontalSpace();
      if (_pos >= source.length) _fail('unclosed inline table');
      if (source[_pos] == ',') {
        _nodes.text(',');
        _pos++;
      } else if (source[_pos] == '}') {
        _nodes.text('}');
        _pos++;
        return;
      } else {
        _fail('expected "," or "}" in inline table');
      }
    }
  }

  String _decodeBasic(String body, {bool multiline = false}) {
    final out = StringBuffer();
    for (var i = 0; i < body.length; i++) {
      final ch = body[i];
      if (ch != r'\') {
        out.write(ch);
        continue;
      }
      if (i + 1 >= body.length) _fail('trailing backslash in string');
      final next = body[++i];
      switch (next) {
        case 'b':
          out.write('\b');
        case 't':
          out.write('\t');
        case 'n':
          out.write('\n');
        case 'f':
          out.write('\f');
        case 'r':
          out.write('\r');
        case '"':
          out.write('"');
        case r'\':
          out.write(r'\');
        case 'u':
          if (i + 4 >= body.length) _fail(r'invalid \u escape');
          final code = int.tryParse(body.substring(i + 1, i + 5), radix: 16);
          if (code == null) _fail(r'invalid \u escape');
          out.writeCharCode(code);
          i += 4;
        case 'U':
          if (i + 8 >= body.length) _fail(r'invalid \U escape');
          final code = int.tryParse(body.substring(i + 1, i + 9), radix: 16);
          if (code == null || code > 0x10FFFF) _fail(r'invalid \U escape');
          out.writeCharCode(code);
          i += 8;
        case ' ' || '\t' || '\r' || '\n' when multiline:
          // Line-ending backslash trims whitespace and newlines.
          while (i < body.length &&
              (body[i] == ' ' ||
                  body[i] == '\t' ||
                  body[i] == '\r' ||
                  body[i] == '\n')) {
            i++;
          }
          i--;
        default:
          _fail('invalid escape sequence "\\$next"');
      }
    }
    return out.toString();
  }

  static String _encodeBasicString(String value) {
    final out = StringBuffer('"');
    for (var i = 0; i < value.length; i++) {
      final ch = value[i];
      out.write(switch (ch) {
        r'\' => r'\\',
        '"' => r'\"',
        '\n' => r'\n',
        '\r' => r'\r',
        '\t' => r'\t',
        '\b' => r'\b',
        '\f' => r'\f',
        _ => ch,
      });
    }
    out.write('"');
    return out.toString();
  }

  static String _encodeLiteralString(String value) {
    if (value.contains("'") || value.contains('\n') || value.contains('\r')) {
      return _encodeBasicString(value);
    }
    return "'$value'";
  }

  static String _escapeMultilineBasic(String value) {
    final out = StringBuffer();
    for (var i = 0; i < value.length; i++) {
      final ch = value[i];
      if (ch == r'\') {
        out.write(r'\\');
      } else if (ch == '"' && value.startsWith('"""', i)) {
        out.write(r'\"');
      } else {
        out.write(ch);
      }
    }
    return out.toString();
  }

  static final _primitivePattern = RegExp(
    '^(?:true|false'
    '|[+-]?(?:inf|nan)'
    '|0x[0-9a-fA-F_]+|0o[0-7_]+|0b[01_]+'
    r'|[+-]?\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d[\d_]*)?'
    r'|\d{4}-\d{2}-\d{2}(?:[Tt ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[Zz]|[+-]\d{2}:\d{2})?)?'
    r'|\d{2}:\d{2}:\d{2}(?:\.\d+)?)$',
  );

  static bool _isValidPrimitive(String text) =>
      _primitivePattern.hasMatch(text);
}
