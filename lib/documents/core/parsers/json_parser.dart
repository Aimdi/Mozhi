import 'dart:convert';

import 'package:mozhi/documents/core/document_builder.dart';
import 'package:mozhi/documents/core/document_format.dart';
import 'package:mozhi/documents/core/parsed_document.dart';
import 'package:mozhi/documents/core/parsers/protected_patterns.dart';

/// Thrown when a document cannot be parsed in the requested format.
class DocumentParseException implements Exception {
  const DocumentParseException(this.message);

  final String message;

  @override
  String toString() => 'DocumentParseException: $message';
}

/// JSON string tables (i18next, vue-i18n, Chrome `messages.json`, …) and
/// Flutter ARB files.
///
/// Only string *values* are translated — never keys, numbers, booleans or
/// anything under a key starting with `@` (ARB metadata, `@@locale`). The
/// original formatting (indentation, key order, escapes of untouched
/// values) is preserved byte for byte.
///
/// Values are read as ICU messages: simple arguments (`{name}`,
/// `{n, number}`) and `#` become placeholders; `plural`/`select`/
/// `selectordinal` keep their structure while each variant's text is
/// translated (the whole argument is a placeholder of the surrounding
/// sentence). `{{name}}`, `%s`, `$t(key)`, HTML tags and URLs are also
/// protected. Values that are not natural language (no letters, URLs,
/// identifiers like `snake_case`/`camelCase`, paths, colours) are skipped.
///
/// Throws [DocumentParseException] for invalid JSON.
ParsedDocument parseJson(String text) {
  try {
    jsonDecode(text);
  } on FormatException catch (error) {
    throw DocumentParseException(error.message);
  }
  return _JsonParser(text).parse();
}

/// Whether a JSON string value (placeholders removed) looks like text for
/// people rather than an identifier, path or code.
bool looksLikeNaturalLanguage(String text) {
  final value = text.trim();
  if (!containsLetter(value)) return false;
  if (value.contains(RegExp(r'\s'))) return true;
  return !_identifier.hasMatch(value) &&
      !_path.hasMatch(value) &&
      !_hexColor.hasMatch(value);
}

final _identifier = RegExp(
  r'^(?:[a-z0-9]+(?:[_.][a-z0-9]+)+'
  r'|[a-z]+(?:[A-Z][a-z0-9]*)+'
  r'|[A-Z0-9]+(?:_[A-Z0-9]+)+'
  r'|[a-z]+[0-9]+[a-z0-9]*)$',
);
final _path = RegExp(r'^[\w.~-]*[/\\][\w./\\~-]*$');
final _hexColor = RegExp(
  r'^#(?:[0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$',
);

class _JsonParser {
  _JsonParser(this.source);

  final String source;
  final DocumentBuilder builder = DocumentBuilder();
  int _pos = 0;

  ParsedDocument parse() {
    _whitespace();
    _value('', skip: false);
    builder.literal(source.substring(_pos));
    return builder.build(DocumentFormat.json);
  }

  void _whitespace() {
    final start = _pos;
    while (_pos < source.length && _isWhitespace(source.codeUnitAt(_pos))) {
      _pos++;
    }
    builder.literal(source.substring(start, _pos));
  }

  static bool _isWhitespace(int unit) =>
      unit == 0x20 || unit == 0x0A || unit == 0x0D || unit == 0x09;

  void _value(String path, {required bool skip}) {
    switch (source[_pos]) {
      case '{':
        _object(path, skip: skip);
      case '[':
        _array(path, skip: skip);
      case '"':
        final raw = _string();
        if (skip) {
          builder.literal(raw);
        } else {
          _stringValue(raw, path);
        }
      default:
        final start = _pos;
        while (_pos < source.length && !',]} \t\r\n'.contains(source[_pos])) {
          _pos++;
        }
        builder.literal(source.substring(start, _pos));
    }
  }

  void _object(String path, {required bool skip}) {
    _symbol();
    _whitespace();
    if (source[_pos] == '}') {
      _symbol();
      return;
    }
    while (true) {
      final rawKey = _string();
      builder.literal(rawKey);
      final key = jsonDecode(rawKey) as String;
      _whitespace();
      _symbol(); // ':'
      _whitespace();
      _value(
        path.isEmpty ? key : '$path.$key',
        skip: skip || key.startsWith('@'),
      );
      _whitespace();
      final separator = source[_pos];
      _symbol();
      if (separator == '}') return;
      _whitespace();
    }
  }

  void _array(String path, {required bool skip}) {
    _symbol();
    _whitespace();
    if (source[_pos] == ']') {
      _symbol();
      return;
    }
    var index = 0;
    while (true) {
      _value('$path[$index]', skip: skip);
      index++;
      _whitespace();
      final separator = source[_pos];
      _symbol();
      if (separator == ']') return;
      _whitespace();
    }
  }

  void _symbol() {
    builder.literal(source[_pos]);
    _pos++;
  }

  /// Reads a string literal (with quotes) and returns its raw text.
  String _string() {
    final start = _pos;
    _pos++;
    while (source[_pos] != '"') {
      _pos += source[_pos] == r'\' ? 2 : 1;
    }
    _pos++;
    return source.substring(start, _pos);
  }

  void _stringValue(String raw, String path) {
    final value = jsonDecode(raw) as String;
    List<Piece> pieces;
    try {
      pieces = IcuMessageParser(value, builder, label: path).parse();
    } on FormatException {
      pieces = protect(value, _fallbackPattern);
    }
    final nodes = builder.content(
      pieces,
      label: path,
      accept: looksLikeNaturalLanguage,
    );
    if (nodes.every((node) => node is TextNode)) {
      builder.literal(raw);
    } else {
      builder.add([EncodedNode(raw: raw, children: nodes, encode: jsonEncode)]);
    }
  }

  static final _fallbackPattern = ProtectedPatterns.combine([
    r'\{[^{}]*\}',
    ProtectedPatterns.htmlTag,
    ProtectedPatterns.url,
    ProtectedPatterns.email,
    ProtectedPatterns.template,
    ProtectedPatterns.printf,
  ]);
}

/// Reads an ICU MessageFormat string into [Piece]s. Variant messages of
/// `plural`/`select`/`selectordinal` arguments become segments of
/// [builder]; the arguments themselves become [TokenPiece]s.
///
/// The whole message is validated before any segment is created.
/// Apostrophes are taken literally (Flutter's default). Throws
/// [FormatException] on unbalanced braces or malformed arguments.
class IcuMessageParser {
  IcuMessageParser(this.source, this.builder, {this.label});

  final String source;
  final DocumentBuilder builder;
  final String? label;
  int _pos = 0;

  static const _complex = {'plural', 'select', 'selectordinal'};

  List<Piece> parse() {
    final message = _message(inPlural: false, nested: false);
    if (_pos != source.length) {
      throw FormatException('Unexpected "}"', source, _pos);
    }
    return _pieces(message);
  }

  List<Piece> _pieces(List<_Icu> message) => [
    for (final part in message)
      ...switch (part) {
        _IcuText(:final text) => protect(text, ProtectedPatterns.json),
        _IcuToken(:final text) => [TokenPiece.text(text)],
        _IcuComplex(:final parts) => [
          TokenPiece([
            for (final item in parts)
              ...switch (item) {
                final String literal => [TextNode(literal)],
                final List<_Icu> variant => builder.content(
                  _pieces(variant),
                  label: label,
                  accept: looksLikeNaturalLanguage,
                ),
                _ => const <DocNode>[],
              },
          ]),
        ],
      },
  ];

  List<_Icu> _message({required bool inPlural, required bool nested}) {
    final parts = <_Icu>[];
    final text = StringBuffer();
    void flush() {
      if (text.isEmpty) return;
      parts.add(_IcuText(text.toString()));
      text.clear();
    }

    while (_pos < source.length) {
      final char = source[_pos];
      if (char == '}') {
        if (nested) break;
        throw FormatException('Unbalanced "}"', source, _pos);
      }
      if (char == '{') {
        flush();
        if (_pos + 1 < source.length && source[_pos + 1] == '{') {
          final end = source.indexOf('}}', _pos + 2);
          if (end == -1) throw FormatException('Unclosed "{{"', source, _pos);
          parts.add(_IcuToken(source.substring(_pos, end + 2)));
          _pos = end + 2;
        } else {
          parts.add(_argument(inPlural: inPlural));
        }
        continue;
      }
      if (char == '#' && inPlural) {
        flush();
        parts.add(const _IcuToken('#'));
        _pos++;
        continue;
      }
      text.write(char);
      _pos++;
    }
    if (nested && _pos >= source.length) {
      throw FormatException('Unclosed "{"', source, _pos);
    }
    flush();
    return parts;
  }

  _Icu _argument({required bool inPlural}) {
    final start = _pos;
    _pos++; // {
    _spaces();
    final name = _word();
    _spaces();
    if (name.isEmpty || _pos >= source.length) {
      throw FormatException('Bad argument', source, start);
    }
    if (source[_pos] == '}') {
      _pos++;
      return _IcuToken(source.substring(start, _pos));
    }
    if (source[_pos] != ',') {
      throw FormatException('Bad argument', source, _pos);
    }
    _pos++;
    _spaces();
    final type = _word();
    _spaces();
    if (!_complex.contains(type)) {
      var depth = 1;
      while (_pos < source.length && depth > 0) {
        final char = source[_pos];
        if (char == '{') depth++;
        if (char == '}') depth--;
        _pos++;
      }
      if (depth != 0) throw FormatException('Unclosed "{"', source, start);
      return _IcuToken(source.substring(start, _pos));
    }
    if (_pos >= source.length || source[_pos] != ',') {
      throw FormatException('Bad $type', source, _pos);
    }
    _pos++;

    final parts = <Object>[];
    final literal = StringBuffer(source.substring(start, _pos));
    void flush() {
      if (literal.isEmpty) return;
      parts.add(literal.toString());
      literal.clear();
    }

    final variantInPlural = type == 'select' ? inPlural : true;
    var variants = 0;
    while (true) {
      literal.write(_spaces());
      if (_pos >= source.length) {
        throw FormatException('Unclosed $type', source, start);
      }
      if (source[_pos] == '}') {
        if (variants == 0) throw FormatException('Empty $type', source, start);
        literal.write('}');
        _pos++;
        break;
      }
      if (source.startsWith('offset:', _pos)) {
        final offsetStart = _pos;
        _pos += 'offset:'.length;
        _spaces();
        _word();
        literal.write(source.substring(offsetStart, _pos));
        continue;
      }
      final selector = _word();
      if (selector.isEmpty) {
        throw FormatException('Bad selector', source, _pos);
      }
      literal
        ..write(selector)
        ..write(_spaces());
      if (_pos >= source.length || source[_pos] != '{') {
        throw FormatException('Expected "{"', source, _pos);
      }
      literal.write('{');
      _pos++;
      flush();
      parts.add(_message(inPlural: variantInPlural, nested: true));
      variants++;
      literal.write('}');
      _pos++;
    }
    flush();
    return _IcuComplex(parts);
  }

  String _word() {
    final start = _pos;
    while (_pos < source.length && !' \t\r\n,{}'.contains(source[_pos])) {
      _pos++;
    }
    return source.substring(start, _pos);
  }

  String _spaces() {
    final start = _pos;
    while (_pos < source.length && ' \t\r\n'.contains(source[_pos])) {
      _pos++;
    }
    return source.substring(start, _pos);
  }
}

sealed class _Icu {
  const _Icu();
}

final class _IcuText extends _Icu {
  const _IcuText(this.text);

  final String text;
}

/// A simple argument (`{name}`, `{n, number}`), `#` or `{{name}}`.
final class _IcuToken extends _Icu {
  const _IcuToken(this.text);

  final String text;
}

/// A plural/select argument: literal structure strings and variant
/// messages (`List<_Icu>`).
final class _IcuComplex extends _Icu {
  const _IcuComplex(this.parts);

  final List<Object> parts;
}
