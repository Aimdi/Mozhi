import 'dart:convert';

import 'package:mozhi/documents/core/document_builder.dart';
import 'package:mozhi/documents/core/document_format.dart';
import 'package:mozhi/documents/core/parsed_document.dart';
import 'package:mozhi/documents/core/parsers/json_parser.dart'
    show DocumentParseException, looksLikeNaturalLanguage;
import 'package:mozhi/documents/core/parsers/json_tree.dart';
import 'package:mozhi/documents/core/parsers/locale_rules.dart';
import 'package:mozhi/documents/core/parsers/markup_content.dart'
    show NodeList, hasSegment;
import 'package:mozhi/documents/core/parsers/xml_tree.dart'
    show checkDocumentLength;

/// Parses Xcode string catalogues ([DocumentFormat.xcstrings]); the
/// translations are added as the [targetLanguage] localisation.
///
/// For every string the source text is its `sourceLanguage` localisation
/// (or the key when there is none). A [targetLanguage] localisation is
/// added where it is missing or still `new`; existing translations and all
/// other languages, comments, `extractionState` and the layout are kept,
/// and strings with `"shouldTranslate" : false` are skipped. The new
/// localisation mirrors the source one: plural and device variations and
/// substitutions (`%#@files@`, with their `argNum` and `formatSpecifier`)
/// get one translation per case; plural cases follow the target
/// language's categories (a missing case is filled from `other`). New
/// string units are marked `needs_review`. Format specifiers (`%@`,
/// `%lld`, `%1$@`) are protected and a literal `%` is doubled.
///
/// Without a [targetLanguage] (or when it is the source language) nothing
/// is translated.
///
/// Throws [DocumentParseException] for invalid JSON or JSON that is not a
/// string catalogue.
ParsedDocument parseXcstrings(String text, {String? targetLanguage}) {
  checkDocumentLength(text, 'String catalog');
  final root = parseJsonTree(text, format: 'String catalog');
  if (root is! JsonObject || root['strings'] is! JsonObject) {
    throw const DocumentParseException(
      'String catalog: no "strings" object at the top level',
    );
  }
  return _XcstringsParser(
    text,
    root,
    canonicalLanguageTag(targetLanguage),
  ).parse();
}

final _conversion = RegExp('^(?:${LocalisationPatterns.printf})\$');

/// One string unit's place in a localisation.
sealed class _Shape {
  const new();
}

/// `"stringUnit" : {...}` (and maybe `"substitutions"`) holding the value
/// number [index].
final class _Unit extends _Shape {
  const new(this.index);

  final int index;
}

/// `"variations" : { kind : { case : shape } }`.
final class _Variations extends _Shape {
  const new(this.kind, this.cases);

  final String kind;
  final Map<String, _Localization> cases;
}

/// A localisation (or a variation case): a unit or variations, plus
/// substitutions.
final class _Localization {
  const new(this.shape, this.substitutions);

  final _Shape? shape;
  final Map<String, _Substitution> substitutions;
}

final class _Substitution {
  const new(this.raw, this.variations);

  /// Raw JSON of the members other than `variations` (argNum, ...).
  final Map<String, String> raw;
  final _Variations? variations;
}

/// Raw JSON text, printed as it is.
final class _Raw {
  const new(this.text);

  final String text;
}

class _XcstringsParser {
  new(this.text, this.root, this.target)
    : sourceLanguage =
          canonicalLanguageTag(
            (root['sourceLanguage'] is JsonString)
                ? (root['sourceLanguage']! as JsonString).value
                : 'en',
          ) ??
          'en';

  final String text;
  final JsonObject root;
  final String? target;
  final String sourceLanguage;
  final DocumentBuilder builder = DocumentBuilder();

  late final String _indent = _detectIndent();
  late final String _colon = _detectColon();
  late final String _newline = text.contains('\r\n') ? '\r\n' : '\n';

  String _detectIndent() {
    final first = root.members.isEmpty ? null : root.members.first;
    if (first == null) return '  ';
    final lineStart = text.lastIndexOf('\n', first.keyStart) + 1;
    final indent = text.substring(lineStart, first.keyStart);
    return indent.trim().isEmpty && indent.isNotEmpty ? indent : '  ';
  }

  String _detectColon() {
    final first = root.members.isEmpty ? null : root.members.first;
    if (first == null) return ' : ';
    final keyEnd = text.indexOf('"', first.keyStart + 1);
    // Skip escaped quotes in the key.
    var end = keyEnd;
    while (end > 0 && text[end - 1] == r'\') {
      end = text.indexOf('"', end + 1);
    }
    return text.substring(end + 1, first.value.start);
  }

  ParsedDocument parse() {
    final strings = root['strings']! as JsonObject;
    final edits = <({int start, int end, List<DocNode> nodes})>[];
    final language = target;
    if (language != null && language != sourceLanguage) {
      for (final member in strings.members) {
        final edit = _entry(member, language);
        if (edit != null) edits.add(edit);
      }
    }
    final nodes = NodeList();
    var position = 0;
    for (final edit in edits) {
      nodes
        ..text(text.substring(position, edit.start))
        ..addAll(edit.nodes);
      position = edit.end;
    }
    nodes.text(text.substring(position));
    builder.add(nodes.nodes);
    return builder.build(DocumentFormat.xcstrings);
  }

  String _pad(int depth) => List.filled(depth, _indent).join();

  ({int start, int end, List<DocNode> nodes})? _entry(
    JsonMember member,
    String language,
  ) {
    final entry = member.value;
    if (entry is! JsonObject) return null;
    final should = entry['shouldTranslate'];
    if (should is JsonLiteral &&
        text.substring(should.start, should.end) == 'false') {
      return null;
    }
    final localizations = entry['localizations'];
    final locales = localizations is JsonObject ? localizations : null;
    JsonMember? existing;
    JsonNode? source;
    for (final locale in locales?.members ?? const <JsonMember>[]) {
      final tag = canonicalLanguageTag(locale.key);
      if (tag == language) existing = locale;
      if (tag == sourceLanguage) source = locale.value;
    }
    if (existing != null && !_needsTranslation(existing.value)) return null;

    // The source values, in order, and the shape to rebuild.
    final values = <String>[];
    final _Localization shape;
    if (source is JsonObject) {
      shape = _readLocalization(source, values);
    } else {
      values.add(member.key);
      shape = const _Localization(_Unit(0), {});
    }
    if (values.isEmpty || values.any((value) => value.contains('\u0000'))) {
      return null;
    }

    final children = <DocNode>[];
    for (var i = 0; i < values.length; i++) {
      if (i > 0) children.add(const TextNode('\u0000'));
      final pieces = protect(values[i], LocalisationPatterns.resource);
      final percent = pieces.any(
        (piece) =>
            piece is TokenPiece &&
            _conversion.hasMatch((piece.nodes.single as TextNode).text),
      );
      children.addAll(
        builder.content(
          pieces,
          label: member.key,
          accept: looksLikeNaturalLanguage,
          escape: percent ? (value) => value.replaceAll('%', '%%') : null,
        ),
      );
    }
    if (!hasSegment(children)) return null;

    final localeDepth = entry.depth + 2;
    String print(String rendered) =>
        _print(_build(shape, rendered.split('\u0000'), language), localeDepth);

    final int start;
    final int end;
    final String Function(String rendered) encode;
    if (existing != null) {
      start = existing.value.start;
      end = existing.value.end;
      encode = print;
    } else if (locales != null) {
      final insert = _insertion(locales, language);
      start = insert.start;
      end = insert.end;
      encode = (rendered) => insert.wrap(print(rendered));
    } else {
      final localesDepth = entry.depth + 1;
      final insert = _insertion(entry, 'localizations');
      start = insert.start;
      end = insert.end;
      encode = (rendered) {
        final open = '{$_newline${_pad(localeDepth)}';
        final close = '$_newline${_pad(localesDepth)}}';
        final locale = '${jsonEncode(language)}$_colon${print(rendered)}';
        return insert.wrap('$open$locale$close');
      };
    }
    return (
      start: start,
      end: end,
      nodes: [
        EncodedNode(
          raw: text.substring(start, end),
          children: children,
          encode: encode,
        ),
      ],
    );
  }

  /// Where a member named [key] goes in [object] (sorted like Xcode
  /// writes it), and how to write it there given its value.
  ({int start, int end, String Function(String value) wrap}) _insertion(
    JsonObject object,
    String key,
  ) {
    final depth = object.depth + 1;
    final name = jsonEncode(key);
    final members = object.members;
    if (members.isEmpty) {
      // Replace the inside of `{ }`.
      return (
        start: object.start + 1,
        end: object.end - 1,
        wrap: (value) =>
            '$_newline${_pad(depth)}$name$_colon$value$_newline'
            '${_pad(object.depth)}',
      );
    }
    var index = members.indexWhere((member) => member.key.compareTo(key) > 0);
    if (index < 0) index = members.length;
    if (index == 0) {
      final first = members.first;
      final lineStart = text.lastIndexOf('\n', first.keyStart) + 1;
      final indent = text.substring(lineStart, first.keyStart);
      final sameLine = indent.trim().isNotEmpty;
      return (
        start: first.keyStart,
        end: first.keyStart,
        wrap: (value) => sameLine
            ? '$name$_colon$value, '
            : '$name$_colon$value,$_newline$indent',
      );
    }
    final previous = members[index - 1];
    return (
      start: previous.value.end,
      end: previous.value.end,
      wrap: (value) => ',$_newline${_pad(depth)}$name$_colon$value',
    );
  }

  /// Whether an existing localisation still waits for a translation.
  bool _needsTranslation(JsonNode localization) {
    var units = 0;
    var waiting = 0;
    void visit(JsonNode node) {
      if (node is! JsonObject) return;
      final unit = node['stringUnit'];
      if (unit is JsonObject) {
        units++;
        final state = unit['state'];
        final value = unit['value'];
        if ((state is JsonString && state.value == 'new') ||
            value is! JsonString ||
            value.value.isEmpty) {
          waiting++;
        }
      }
      for (final member in node.members) {
        if (member.key != 'stringUnit') visit(member.value);
      }
    }

    visit(localization);
    return units == 0 || waiting == units;
  }

  _Localization _readLocalization(JsonObject node, List<String> values) {
    _Shape? shape;
    final unit = node['stringUnit'];
    final variations = node['variations'];
    if (unit is JsonObject && unit['value'] is JsonString) {
      values.add((unit['value']! as JsonString).value);
      shape = _Unit(values.length - 1);
    } else if (variations is JsonObject) {
      shape = _readVariations(variations, values);
    }
    final substitutions = <String, _Substitution>{};
    final subs = node['substitutions'];
    if (subs is JsonObject) {
      for (final member in subs.members) {
        final value = member.value;
        if (value is! JsonObject) continue;
        final raw = <String, String>{};
        _Variations? inner;
        for (final field in value.members) {
          if (field.key == 'variations' && field.value is JsonObject) {
            inner = _readVariations(field.value as JsonObject, values);
          } else {
            raw[field.key] = text.substring(field.value.start, field.value.end);
          }
        }
        substitutions[member.key] = _Substitution(raw, inner);
      }
    }
    return _Localization(shape, substitutions);
  }

  _Variations? _readVariations(JsonObject node, List<String> values) {
    for (final member in node.members) {
      final cases = member.value;
      if (cases is! JsonObject) continue;
      return _Variations(member.key, {
        for (final entry in cases.members)
          if (entry.value is JsonObject)
            entry.key: _readLocalization(entry.value as JsonObject, values),
      });
    }
    return null;
  }

  /// The target localisation as an ordered map ready for [_print].
  Map<String, Object> _build(
    _Localization localization,
    List<String> values,
    String language,
  ) {
    final result = <String, Object>{};
    switch (localization.shape) {
      case _Unit(:final index):
        result['stringUnit'] = {
          'state': 'needs_review',
          'value': index < values.length ? values[index] : values.last,
        };
      case final _Variations variations:
        result['variations'] = _buildVariations(variations, values, language);
      case null:
        break;
    }
    if (localization.substitutions.isNotEmpty) {
      result['substitutions'] = {
        for (final MapEntry(:key, value: substitution)
            in localization.substitutions.entries)
          key: {
            for (final MapEntry(key: name, value: raw)
                in substitution.raw.entries)
              name: _Raw(raw),
            if (substitution.variations case final inner?)
              'variations': _buildVariations(inner, values, language),
          },
      };
    }
    return _sorted(result);
  }

  Map<String, Object> _buildVariations(
    _Variations variations,
    List<String> values,
    String language,
  ) {
    var cases = variations.cases;
    if (variations.kind == 'plural') {
      final categories = pluralCategories(language);
      if (categories != null && cases.isNotEmpty) {
        final fallback = cases['other'] ?? cases.values.last;
        cases = {
          for (final category in categories)
            category: cases[category] ?? fallback,
        };
      }
    }
    return {
      variations.kind: _sorted({
        for (final MapEntry(:key, :value) in cases.entries)
          key: _build(value, values, language),
      }),
    };
  }

  /// [map] with its keys sorted, as Xcode writes them.
  static Map<String, Object> _sorted(Map<String, Object> map) {
    final keys = map.keys.toList()..sort();
    return {for (final key in keys) key: map[key]!};
  }

  /// Prints [value] like Xcode, the opening brace at [depth].
  String _print(Object value, int depth) {
    switch (value) {
      case _Raw(:final text):
        return text;
      case String():
        return jsonEncode(value);
      case Map<String, Object>():
        if (value.isEmpty) return '{$_newline$_newline${_pad(depth)}}';
        final inner = _pad(depth + 1);
        return [
          '{',
          [
            for (final MapEntry(:key, value: item) in value.entries)
              '$inner${jsonEncode(key)}$_colon${_print(item, depth + 1)}',
          ].join(',$_newline'),
          '${_pad(depth)}}',
        ].join(_newline);
    }
    // coverage:ignore-start
    throw ArgumentError.value(value, 'value');
    // coverage:ignore-end
  }
}
