/// JSON read into a tree that keeps the position of every value, for
/// editing a file in place (Xcode string catalogues).
library;

import 'dart:convert';

import 'package:mozhi/documents/core/parsers/json_parser.dart'
    show DocumentParseException;

/// A JSON value and where it is in the source.
sealed class JsonNode {
  const new(this.start, this.end, this.depth);

  final int start;
  final int end;

  /// Nesting depth (0 for the top-level value).
  final int depth;
}

/// `{...}`.
final class JsonObject extends JsonNode {
  const new(super.start, super.end, super.depth, this.members);

  final List<JsonMember> members;

  JsonMember? member(String key) {
    for (final member in members) {
      if (member.key == key) return member;
    }
    return null;
  }

  JsonNode? operator [](String key) => member(key)?.value;
}

/// `"key": value` inside a [JsonObject].
final class JsonMember {
  const new(this.key, this.keyStart, this.value);

  final String key;
  final int keyStart;
  final JsonNode value;
}

/// `[...]`.
final class JsonArray extends JsonNode {
  const new(super.start, super.end, super.depth, this.items);

  final List<JsonNode> items;
}

/// A string literal, decoded.
final class JsonString extends JsonNode {
  const new(super.start, super.end, super.depth, this.value);

  final String value;
}

/// A number, `true`, `false` or `null`.
final class JsonLiteral extends JsonNode {
  const new(super.start, super.end, super.depth);
}

/// Parses [text] (after validating it with `jsonDecode`); [format] names
/// the file type in error messages.
///
/// Throws [DocumentParseException] for invalid JSON or nesting deeper than
/// [maxDepth].
JsonNode parseJsonTree(
  String text, {
  required String format,
  int maxDepth = 64,
}) {
  final start = text.startsWith('\uFEFF') ? 1 : 0;
  try {
    jsonDecode(start == 0 ? text : text.substring(start));
  } on FormatException catch (error) {
    throw DocumentParseException('$format: ${error.message}');
  }
  return _JsonTreeParser(text, start, format, maxDepth).parse();
}

class _JsonTreeParser {
  new(this.text, this._pos, this.format, this.maxDepth);

  final String text;
  final String format;
  final int maxDepth;
  int _pos;

  JsonNode parse() {
    _space();
    return _value(0);
  }

  void _space() {
    while (_pos < text.length && ' \t\r\n'.contains(text[_pos])) {
      _pos++;
    }
  }

  JsonNode _value(int depth) {
    if (depth > maxDepth) {
      throw DocumentParseException('$format: values nested too deeply');
    }
    final start = _pos;
    switch (text[_pos]) {
      case '{':
        _pos++;
        _space();
        final members = <JsonMember>[];
        if (text[_pos] != '}') {
          while (true) {
            _space();
            final keyStart = _pos;
            final key = _string();
            _space();
            _pos++; // :
            _space();
            members.add(JsonMember(key, keyStart, _value(depth + 1)));
            _space();
            if (text[_pos++] == '}') break;
          }
        } else {
          _pos++;
        }
        return JsonObject(start, _pos, depth, members);
      case '[':
        _pos++;
        _space();
        final items = <JsonNode>[];
        if (text[_pos] != ']') {
          while (true) {
            _space();
            items.add(_value(depth + 1));
            _space();
            if (text[_pos++] == ']') break;
          }
        } else {
          _pos++;
        }
        return JsonArray(start, _pos, depth, items);
      case '"':
        final value = _string();
        return JsonString(start, _pos, depth, value);
      default:
        while (_pos < text.length && !',]} \t\r\n'.contains(text[_pos])) {
          _pos++;
        }
        return JsonLiteral(start, _pos, depth);
    }
  }

  String _string() {
    final start = _pos;
    _pos++;
    while (text[_pos] != '"') {
      _pos += text[_pos] == r'\' ? 2 : 1;
    }
    _pos++;
    return jsonDecode(text.substring(start, _pos)) as String;
  }
}
