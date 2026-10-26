/// ICU MessageFormat inside markup content: Angular and other XLIFF
/// producers write `{VAR_PLURAL, plural, =1 {one item} other {...}}` with
/// inline codes in the variants.
library;

import 'package:mozhi/documents/core/document_builder.dart';
import 'package:mozhi/documents/core/parsed_document.dart';
import 'package:mozhi/documents/core/parsers/markup_content.dart';

final _icuHeader = RegExp(
  r'\{\s*[A-Za-z_][\w.]*\s*,\s*(?:plural|select|selectordinal)\s*,',
);

/// Turns the ICU arguments in [inlines] into codes: simple arguments
/// (`{name}`) become plain codes, `plural`/`select`/`selectordinal` keep
/// their structure in one code while each variant's text becomes a
/// segment of [builder] (built with [variant]). Returns [inlines]
/// unchanged when they hold no complex argument or the syntax is broken.
List<Inline> icuInlines(
  List<Inline> inlines,
  DocumentBuilder builder,
  List<DocNode> Function(List<Inline> variant) variant,
) {
  final decoded = StringBuffer();
  for (final item in inlines) {
    if (item is InlineText) decoded.write(item.text);
  }
  if (!_icuHeader.hasMatch(decoded.toString())) return inlines;

  final units = <_Unit>[];
  for (final item in inlines) {
    if (item is InlineText && item.source == item.text) {
      for (var i = 0; i < item.source.length; i++) {
        units.add(_Unit.char(item.source[i]));
      }
    } else {
      units.add(_Unit.opaque(item));
    }
  }
  final parser = _IcuParser(units);
  try {
    // Parse once to validate before any segment is created.
    parser
      ..message(nested: false, inPlural: false, build: null)
      ..pos = 0;
    return parser.message(nested: false, inPlural: false, build: variant);
  } on FormatException {
    return inlines;
  }
}

final class _Unit {
  const new char(String this.char) : item = null;
  const new opaque(Inline this.item) : char = null;

  final String? char;
  final Inline? item;
}

class _IcuParser {
  new(this.units);

  final List<_Unit> units;
  int pos = 0;

  static const _complex = {'plural', 'select', 'selectordinal'};

  String? _char([int offset = 0]) {
    final index = pos + offset;
    return index < units.length ? units[index].char : null;
  }

  /// Reads a message up to the `}` closing it ([nested]) or the end.
  List<Inline> message({
    required bool nested,
    required bool inPlural,
    required List<DocNode> Function(List<Inline>)? build,
  }) {
    final result = <Inline>[];
    final text = StringBuffer();
    void flush() {
      if (text.isEmpty) return;
      result.add(InlineText(text.toString()));
      text.clear();
    }

    while (pos < units.length) {
      final unit = units[pos];
      final char = unit.char;
      if (char == null) {
        flush();
        result.add(unit.item!);
        pos++;
        continue;
      }
      if (char == '}') {
        if (nested) break;
        throw const FormatException('Unbalanced }');
      }
      if (char == '{' && _char(1) == '{') {
        // A `{{template}}` placeholder.
        flush();
        final start = pos;
        while (pos < units.length && !(_char() == '}' && _char(1) == '}')) {
          pos++;
        }
        if (pos >= units.length) throw const FormatException('Unclosed {{');
        pos += 2;
        result.add(InlineCode.text(_raw(start, pos)));
        continue;
      }
      if (char == '{') {
        flush();
        result.add(_argument(inPlural: inPlural, build: build));
        continue;
      }
      if (char == '#' && inPlural) {
        flush();
        result.add(InlineCode.text('#'));
        pos++;
        continue;
      }
      text.write(char);
      pos++;
    }
    if (nested && pos >= units.length) {
      throw const FormatException('Unclosed {');
    }
    flush();
    return result;
  }

  String _spaces() {
    final buffer = StringBuffer();
    while (true) {
      final char = _char();
      if (char == null || !' \t\r\n'.contains(char)) break;
      buffer.write(char);
      pos++;
    }
    return buffer.toString();
  }

  String _word() {
    final buffer = StringBuffer();
    while (true) {
      final char = _char();
      if (char == null || ' \t\r\n,{}'.contains(char)) break;
      buffer.write(char);
      pos++;
    }
    return buffer.toString();
  }

  Inline _argument({
    required bool inPlural,
    required List<DocNode> Function(List<Inline>)? build,
  }) {
    final start = pos;
    pos++; // {
    _spaces();
    final name = _word();
    _spaces();
    if (name.isEmpty) throw const FormatException('Bad argument');
    if (_char() == '}') {
      pos++;
      return InlineCode.text(_raw(start, pos));
    }
    if (_char() != ',') throw const FormatException('Bad argument');
    pos++;
    _spaces();
    final type = _word();
    _spaces();
    if (!_complex.contains(type)) {
      var depth = 1;
      while (pos < units.length && depth > 0) {
        final char = _char();
        if (char == '{') depth++;
        if (char == '}') depth--;
        pos++;
      }
      if (depth != 0) throw const FormatException('Unclosed {');
      return InlineCode.text(_raw(start, pos));
    }
    if (_char() != ',') throw const FormatException('Bad complex argument');
    pos++;

    final nodes = <DocNode>[];
    final literal = StringBuffer(_raw(start, pos));
    void flush() {
      if (literal.isEmpty) return;
      nodes.add(TextNode(literal.toString()));
      literal.clear();
    }

    final variantInPlural = type != 'select' || inPlural;
    var variants = 0;
    while (true) {
      literal.write(_spaces());
      final char = _char();
      if (char == null) throw const FormatException('Unclosed argument');
      if (char == '}') {
        if (variants == 0) throw const FormatException('No variants');
        literal.write('}');
        pos++;
        break;
      }
      if (_startsWith('offset:')) {
        final offsetStart = pos;
        pos += 'offset:'.length;
        _spaces();
        _word();
        literal.write(_raw(offsetStart, pos));
        continue;
      }
      final selector = _word();
      if (selector.isEmpty) throw const FormatException('Bad selector');
      literal
        ..write(selector)
        ..write(_spaces());
      if (_char() != '{') throw const FormatException('Expected {');
      literal.write('{');
      pos++;
      final variant = message(
        nested: true,
        inPlural: variantInPlural,
        build: build,
      );
      flush();
      if (build != null) nodes.addAll(build(variant));
      literal.write('}');
      pos++;
      variants++;
    }
    flush();
    return InlineCode(nodes);
  }

  bool _startsWith(String text) {
    for (var i = 0; i < text.length; i++) {
      if (_char(i) != text[i]) return false;
    }
    return true;
  }

  /// The source text of `units[from..to)` (only characters: arguments'
  /// headers never contain codes).
  String _raw(int from, int to) {
    final buffer = StringBuffer();
    for (var i = from; i < to; i++) {
      final unit = units[i];
      buffer.write(
        unit.char ??
            switch (unit.item!) {
              InlineText(:final source) => source,
              InlineCode(:final nodes) => identityText(nodes),
            },
      );
    }
    return buffer.toString();
  }
}
