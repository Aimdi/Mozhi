import 'package:mozhi/documents/core/document_builder.dart';
import 'package:mozhi/documents/core/document_format.dart';
import 'package:mozhi/documents/core/parsed_document.dart';
import 'package:mozhi/documents/core/parsers/json_parser.dart'
    show DocumentParseException, looksLikeNaturalLanguage;
import 'package:mozhi/documents/core/parsers/locale_rules.dart';
import 'package:mozhi/documents/core/parsers/markup_content.dart';
import 'package:mozhi/documents/core/parsers/xml_tree.dart'
    show checkDocumentLength;

/// Parses Apple `.strings` files ([DocumentFormat.appleStrings]).
///
/// Only the values of `"key" = "value";` pairs are translated; keys,
/// `/* */` and `//` comments, layout and unquoted words are kept. Escapes
/// are read (`\"`, `\\`, `\U00E9`) and written back; `\n`, `\t` and format
/// specifiers (`%@`, `%1$@`, `%lld`, `%#@files@`) are protected, and a
/// literal `%` in a translated format string becomes `%%`.
///
/// The property-list variants of `.strings` (XML or binary) are not
/// supported: they throw [DocumentParseException], like malformed files.
ParsedDocument parseAppleStrings(String text) {
  checkDocumentLength(text, 'Apple strings');
  return _StringsParser(text).parse();
}

class _StringsParser {
  new(this.text);

  final String text;
  final DocumentBuilder builder = DocumentBuilder();
  int _pos = 0;

  Never _fail(String message) {
    final line = '\n'.allMatches(text.substring(0, _pos)).length + 1;
    throw DocumentParseException('Apple strings: line $line: $message');
  }

  ParsedDocument parse() {
    final head = text.trimLeft().replaceFirst('\uFEFF', '');
    if (head.startsWith('<?xml') || head.startsWith('<plist')) {
      throw const DocumentParseException(
        'Apple strings: property list files are not supported, only the '
        '"key" = "value"; text format',
      );
    }
    final nodes = NodeList();
    if (text.startsWith('\uFEFF')) {
      nodes.text('\uFEFF');
      _pos = 1;
    }
    while (true) {
      nodes.text(_skip());
      if (_pos >= text.length) break;
      final keyStart = _pos;
      final key = _token();
      nodes
        ..text(text.substring(keyStart, _pos))
        ..text(_skip());
      if (_pos < text.length && text[_pos] == ';') {
        // `"key";` (the value is the key): nothing to translate.
        nodes.text(';');
        _pos++;
        continue;
      }
      if (_pos >= text.length || text[_pos] != '=') _fail('expected "="');
      nodes.text('=');
      _pos++;
      nodes.text(_skip());
      final valueStart = _pos;
      if (_pos < text.length && text[_pos] == '"') {
        _token();
        nodes
          ..text('"')
          ..addAll(_value(valueStart + 1, _pos - 1, key))
          ..text('"');
      } else {
        _token();
        nodes.text(text.substring(valueStart, _pos));
      }
      nodes.text(_skip());
      if (_pos >= text.length || text[_pos] != ';') _fail('expected ";"');
      nodes.text(';');
      _pos++;
    }
    builder.add(nodes.nodes);
    return builder.build(DocumentFormat.appleStrings);
  }

  /// Skips whitespace and comments; returns them.
  String _skip() {
    final start = _pos;
    while (_pos < text.length) {
      final char = text[_pos];
      if (char.trim().isEmpty) {
        _pos++;
      } else if (text.startsWith('/*', _pos)) {
        final end = text.indexOf('*/', _pos + 2);
        if (end < 0) _fail('unterminated comment');
        _pos = end + 2;
      } else if (text.startsWith('//', _pos)) {
        final end = text.indexOf('\n', _pos);
        _pos = end < 0 ? text.length : end + 1;
      } else {
        break;
      }
    }
    return text.substring(start, _pos);
  }

  /// Reads a quoted string or an unquoted word; returns the decoded text.
  String _token() {
    if (_pos >= text.length) _fail('unexpected end of file');
    if (text[_pos] == '"') {
      final out = StringBuffer();
      _pos++;
      while (true) {
        if (_pos >= text.length) _fail('unterminated string');
        final char = text[_pos];
        if (char == '"') {
          _pos++;
          return out.toString();
        }
        if (char == r'\' && _pos + 1 < text.length) {
          out.write(text[_pos + 1]);
          _pos += 2;
          continue;
        }
        out.write(char);
        _pos++;
      }
    }
    final start = _pos;
    while (_pos < text.length &&
        RegExp(r'[A-Za-z0-9_.$:/\-]').hasMatch(text[_pos])) {
      _pos++;
    }
    if (_pos == start) _fail('expected a quoted string');
    return text.substring(start, _pos);
  }

  /// Nodes for the raw value between [start] and [end] (inside quotes).
  List<DocNode> _value(int start, int end, String key) {
    final items = <Inline>[];
    final plain = StringBuffer();
    void flush() {
      if (plain.isEmpty) return;
      items.add(InlineText(plain.toString()));
      plain.clear();
    }

    var i = start;
    while (i < end) {
      final char = text[i];
      if (char != r'\' || i + 1 >= end) {
        plain.write(char);
        i++;
        continue;
      }
      flush();
      final next = text[i + 1];
      final unicode = RegExp('[Uu]([0-9a-fA-F]{4})').matchAsPrefix(text, i + 1);
      final octal = RegExp('[0-7]{1,3}').matchAsPrefix(text, i + 1);
      if (next == 'n' || next == 't' || next == 'r') {
        items.add(InlineCode.text('\\$next', movable: true));
        i += 2;
      } else if (unicode != null) {
        final raw = text.substring(i, unicode.end);
        final decoded = String.fromCharCode(
          int.parse(unicode.group(1)!, radix: 16),
        );
        items.add(
          decoded.trim().isEmpty || decoded.contains(_control)
              ? InlineCode.text(raw)
              : InlineText(raw, decoded),
        );
        i = unicode.end;
      } else if (octal != null) {
        items.add(InlineCode.text(text.substring(i, octal.end)));
        i = octal.end;
      } else {
        items.add(InlineText(text.substring(i, i + 2), next));
        i += 2;
      }
    }
    flush();
    final inlines = protectInlines(items, LocalisationPatterns.resource);
    final percent = hasFormatConversion(inlines);
    return inlineContent(
      builder,
      inlines,
      escape: (value) {
        final out = StringBuffer();
        for (var k = 0; k < value.length; k++) {
          out.write(switch (value[k]) {
            r'\' => r'\\',
            '"' => r'\"',
            '\n' => r'\n',
            '\t' => r'\t',
            '%' when percent => '%%',
            final other => other,
          });
        }
        return out.toString();
      },
      label: key,
      accept: looksLikeNaturalLanguage,
    );
  }
}

final _control = RegExp(r'\p{C}', unicode: true);
