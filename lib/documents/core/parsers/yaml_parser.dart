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
import 'package:mozhi/documents/core/source_line.dart';
import 'package:translation_repository/translation_repository.dart'
    show ProtectedPatterns;

/// Parses YAML localisation files ([DocumentFormat.yaml]: Rails i18n,
/// i18next, Hugo, MkDocs, …).
///
/// Preserves indentation, comments (`#`), blank lines, document markers
/// (`---`, `...`), keys, anchors/aliases, tags, quoted vs unquoted scalars
/// and block scalars (`|`, `>` with chomping/indent indicators).
///
/// Only natural-language string values are translated; keys, booleans,
/// numbers, null values, ISO dates, URLs, paths, identifiers and technical
/// metadata keys are skipped. Placeholders (`%{name}`, `{{name}}`,
/// `${name}`, `{name}`, printf, HTML tags, URLs and e-mail addresses) are
/// protected.
///
/// Throws [DocumentParseException] for malformed YAML (tab indentation,
/// unterminated quotes, invalid block scalar headers or unclosed flow
/// collections).
ParsedDocument parseYaml(String text) {
  checkDocumentLength(text, 'YAML');
  return _YamlParser(text).parse();
}

/// Leaf keys whose scalar values are technical metadata rather than prose.
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
  'created_at',
  'updated_at',
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
  'content_type',
};

final RegExp _yamlPlaceholders = ProtectedPatterns.combine([
  LocalisationPatterns.htmlTag,
  ProtectedPatterns.url,
  ProtectedPatterns.email,
  r'\{\{\{?[^{}]*\}\}\}?',
  r'%\{[A-Za-z_][\w.-]*\}',
  r'\$\{[A-Za-z_][\w.-]*\}',
  LocalisationPatterns.braces,
  LocalisationPatterns.printfInText,
]);

final _yamlNullOrBool = RegExp(
  r'^(?:true|false|yes|no|on|off|null|~)$',
  caseSensitive: false,
);

final _yamlNumber = RegExp(
  r'^[+-]?(?:0x[0-9a-fA-F_]+|0o[0-7_]+|\d[\d_]*(?:\.[\d_]*)?(?:[eE][+-]?\d+)?'
  r'|\.\d[\d_]*(?:[eE][+-]?\d+)?|\.(?:inf|nan))$',
  caseSensitive: false,
);

final _yamlDate = RegExp(
  r'^\d{4}-\d{2}-\d{2}(?:[Tt ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[Zz]|[+-]\d{2}:?\d{2})?)?$',
);

final _blockHeader = RegExp(
  r'^([|>])([+-])?([1-9])?(?:([+-]))?(?:[ \t]+(#.*))?[ \t]*$',
);

final _leadingIndicator = RegExp(r'''^[-?:,\[\]{}#&*!|>'"%@`]''');

class _YamlParser {
  new(this.text) : lines = splitLines(text);

  final String text;
  final List<SourceLine> lines;
  final DocumentBuilder builder = DocumentBuilder();
  final List<({int indent, String key})> _path = [];

  ParsedDocument parse() {
    final nodes = NodeList();
    var i = 0;
    while (i < lines.length) {
      final line = lines[i];
      var content = line.content;
      var bom = '';
      if (i == 0 && content.startsWith('\uFEFF')) {
        bom = '\uFEFF';
        content = content.substring(1);
      }

      if (content.trim().isEmpty || content.trimLeft().startsWith('#')) {
        nodes.text(line.full);
        i++;
        continue;
      }

      final indent = _leadingSpaces(content, i);
      final rest = content.substring(indent);

      if (rest == '---' ||
          rest.startsWith('--- ') ||
          rest.startsWith('---\t') ||
          rest == '...' ||
          rest.startsWith('... ') ||
          rest.startsWith('...\t')) {
        _path.clear();
        nodes.text(line.full);
        i++;
        continue;
      }

      if (bom.isNotEmpty) nodes.text(bom);

      // Sequence item: `- ...`
      if (rest == '-' || rest.startsWith('- ') || rest.startsWith('-\t')) {
        while (_path.isNotEmpty && _path.last.indent > indent) {
          _path.removeLast();
        }
        final dashLen = rest.length == 1 ? 1 : _afterDash(rest);
        final prefix = content.substring(0, indent + dashLen);
        final afterDash = content.substring(indent + dashLen);
        if (afterDash.trim().isEmpty || afterDash.trimLeft().startsWith('#')) {
          nodes.text('$content${line.ending}');
          i++;
          continue;
        }
        // Check if `- key: value` (compact mapping inside sequence).
        final mapping = _splitMapping(afterDash, i);
        if (mapping != null) {
          final itemIndent = indent + dashLen;
          final key = mapping.key;
          final label = _labelFor(itemIndent, key);
          final nextLine = _handleMappingValue(
            nodes: nodes,
            prefix: '$prefix${mapping.keyAndColon}',
            rawAfterColon: mapping.afterColon,
            lineIndex: i,
            parentIndent: itemIndent,
            key: key,
            label: label,
          );
          i = nextLine;
          continue;
        }
        // Scalar or block scalar sequence item.
        final label = _currentPath();
        i = _handleValue(
          nodes: nodes,
          prefix: prefix,
          rawValue: afterDash,
          lineIndex: i,
          parentIndent: indent,
          skipKey: false,
          label: label,
        );
        continue;
      }

      // Mapping entry: `key: value`
      final mapping = _splitMapping(rest, i);
      if (mapping != null) {
        final key = mapping.key;
        final label = _labelFor(indent, key);
        i = _handleMappingValue(
          nodes: nodes,
          prefix: '${content.substring(0, indent)}${mapping.keyAndColon}',
          rawAfterColon: mapping.afterColon,
          lineIndex: i,
          parentIndent: indent,
          key: key,
          label: label,
        );
        continue;
      }

      // Continuation / flow / standalone line (preserve verbatim, validate quotes).
      _validateUnclosedQuotes(rest, i);
      nodes.text('$content${line.ending}');
      i++;
    }

    builder.add(nodes.nodes);
    return builder.build(DocumentFormat.yaml);
  }

  int _afterDash(String rest) {
    var pos = 1;
    while (pos < rest.length && (rest[pos] == ' ' || rest[pos] == '\t')) {
      pos++;
    }
    return pos;
  }

  int _leadingSpaces(String content, int lineIndex) {
    var i = 0;
    while (i < content.length) {
      final c = content.codeUnitAt(i);
      if (c == 0x20) {
        i++;
      } else if (c == 0x09) {
        throw DocumentParseException(
          'YAML: line ${lineIndex + 1}: '
          'tab character cannot be used for indentation',
        );
      } else {
        break;
      }
    }
    return i;
  }

  String _labelFor(int indent, String key) {
    while (_path.isNotEmpty && _path.last.indent >= indent) {
      _path.removeLast();
    }
    _path.add((indent: indent, key: key));
    return _currentPath();
  }

  String _currentPath() => [for (final p in _path) p.key].join('.');

  int _handleMappingValue({
    required NodeList nodes,
    required String prefix,
    required String rawAfterColon,
    required int lineIndex,
    required int parentIndent,
    required String key,
    required String label,
  }) {
    final skipKey = _skipLeafKeys.contains(key.toLowerCase());
    return _handleValue(
      nodes: nodes,
      prefix: prefix,
      rawValue: rawAfterColon,
      lineIndex: lineIndex,
      parentIndent: parentIndent,
      skipKey: skipKey,
      label: label,
    );
  }

  int _handleValue({
    required NodeList nodes,
    required String prefix,
    required String rawValue,
    required int lineIndex,
    required int parentIndent,
    required bool skipKey,
    required String label,
  }) {
    final ending = lines[lineIndex].ending;
    final leadSpaceLen = rawValue.length - rawValue.trimLeft().length;
    final leadSpace = rawValue.substring(0, leadSpaceLen);
    var body = rawValue.substring(leadSpaceLen);

    // Empty value or comment only -> nested block follows on next lines.
    if (body.isEmpty || body.startsWith('#')) {
      nodes.text('$prefix$rawValue$ending');
      return lineIndex + 1;
    }

    // Consume optional YAML properties (`&anchor`, `!tag`, `!!str`).
    final propPrefix = StringBuffer();
    while (body.startsWith('&') || body.startsWith('!')) {
      final tokenEnd = _propertyEnd(body);
      propPrefix.write(body.substring(0, tokenEnd));
      body = body.substring(tokenEnd);
      final ws = body.length - body.trimLeft().length;
      propPrefix.write(body.substring(0, ws));
      body = body.substring(ws);
    }

    final fullPrefix = '$prefix$leadSpace$propPrefix';
    if (body.isEmpty || body.startsWith('#')) {
      nodes.text('$fullPrefix$body$ending');
      return lineIndex + 1;
    }

    // Alias (`*anchor`) -> never translate.
    if (body.startsWith('*')) {
      nodes.text('$fullPrefix$body$ending');
      return lineIndex + 1;
    }

    // Block scalar (`|`, `>`, `|-`, `>+`, `|2`, ...).
    if (body.startsWith('|') || body.startsWith('>')) {
      return _parseBlockScalar(
        nodes: nodes,
        headerPrefix: fullPrefix,
        header: body,
        lineIndex: lineIndex,
        parentIndent: parentIndent,
        skipKey: skipKey,
        label: label,
      );
    }

    // Flow collection (`[...]` or `{...}`) on this line.
    if (body.startsWith('[') || body.startsWith('{')) {
      return _parseFlowValue(
        nodes: nodes,
        prefix: fullPrefix,
        firstLineBody: body,
        lineIndex: lineIndex,
        skipKey: skipKey,
        label: label,
      );
    }

    // Double-quoted scalar `"..."`.
    if (body.startsWith('"')) {
      return _parseDoubleQuoted(
        nodes: nodes,
        prefix: fullPrefix,
        body: body,
        lineIndex: lineIndex,
        skipKey: skipKey,
        label: label,
      );
    }

    // Single-quoted scalar `'...'`.
    if (body.startsWith("'")) {
      return _parseSingleQuoted(
        nodes: nodes,
        prefix: fullPrefix,
        body: body,
        lineIndex: lineIndex,
        skipKey: skipKey,
        label: label,
      );
    }

    // Plain unquoted scalar.
    final (scalar, comment) = _splitPlainComment(body);
    final trimmed = scalar.trimRight();
    final trailingSpace = scalar.substring(trimmed.length);
    if (skipKey || !_isTranslatablePlain(trimmed)) {
      nodes.text('$fullPrefix$body$ending');
      return lineIndex + 1;
    }
    final contentNodes = builder.content(
      protect(trimmed, _yamlPlaceholders),
      label: label,
      accept: looksLikeNaturalLanguage,
    );
    if (!hasSegment(contentNodes)) {
      nodes.text('$fullPrefix$body$ending');
      return lineIndex + 1;
    }
    nodes
      ..text(fullPrefix)
      ..addAll([
        EncodedNode(
          raw: trimmed,
          children: contentNodes,
          encode: _encodePlainOrQuoted,
        ),
      ])
      ..text('$trailingSpace$comment$ending');
    return lineIndex + 1;
  }

  int _parseBlockScalar({
    required NodeList nodes,
    required String headerPrefix,
    required String header,
    required int lineIndex,
    required int parentIndent,
    required bool skipKey,
    required String label,
  }) {
    final match = _blockHeader.firstMatch(header);
    if (match == null) {
      throw DocumentParseException(
        'YAML: line ${lineIndex + 1}: invalid block scalar header "$header"',
      );
    }
    final folded = match.group(1) == '>';
    final explicitIndentStr = match.group(3);
    final explicitIndent = explicitIndentStr == null
        ? null
        : parentIndent + int.parse(explicitIndentStr);

    nodes.text('$headerPrefix$header${lines[lineIndex].ending}');

    // Scan block body lines.
    var blockIndent = explicitIndent;
    var end = lineIndex + 1;
    while (end < lines.length) {
      final raw = lines[end].content;
      if (raw.trim().isEmpty) {
        end++;
        continue;
      }
      final spaces = _leadingSpacesBlock(raw);
      if (blockIndent == null) {
        if (spaces <= parentIndent) break;
        blockIndent = spaces;
      }
      if (spaces < blockIndent) break;
      end++;
    }

    if (end == lineIndex + 1 || blockIndent == null) {
      return end;
    }

    // Keep trailing blank lines verbatim outside the translated content.
    var contentEnd = end;
    while (contentEnd > lineIndex + 1 &&
        lines[contentEnd - 1].content.trim().isEmpty) {
      contentEnd--;
    }
    if (contentEnd == lineIndex + 1 || skipKey) {
      nodes.text(joinLines(lines, lineIndex + 1, end));
      return end;
    }

    final indentStr = ' ' * blockIndent;
    final dominant = dominantLineBreak(lines);

    if (!folded) {
      // Literal block `|`: preserve every line break.
      final pieces = <Piece>[];
      for (var k = lineIndex + 1; k < contentEnd; k++) {
        final raw = lines[k].content;
        final stripped = raw.length >= blockIndent
            ? raw.substring(blockIndent)
            : '';
        if (k > lineIndex + 1) {
          final prevEnding = lines[k - 1].ending;
          final linePrefix = raw.length >= blockIndent ? indentStr : raw;
          pieces.add(TextPiece('$prevEnding$linePrefix', '\n'));
        }
        if (stripped.isNotEmpty) {
          pieces.addAll(protect(stripped, _yamlPlaceholders));
        }
      }
      final firstRaw = lines[lineIndex + 1].content;
      final firstPrefix = firstRaw.length >= blockIndent ? indentStr : firstRaw;
      final blockNodes = builder.content(
        pieces,
        lineBreak: dominant,
        continuation: indentStr,
        label: label,
        accept: looksLikeNaturalLanguage,
      );
      if (!hasSegment(blockNodes)) {
        nodes.text(joinLines(lines, lineIndex + 1, end));
        return end;
      }
      nodes
        ..text(firstPrefix)
        ..addAll(blockNodes)
        ..text(lines[contentEnd - 1].ending)
        ..text(joinLines(lines, contentEnd, end));
      return end;
    }

    // Folded block `>`: fold single line breaks between normal lines into
    // spaces.
    final rawBlock = joinLines(lines, lineIndex + 1, contentEnd);
    final decoded = _decodeFolded(lineIndex + 1, contentEnd, blockIndent);
    final blockNodes = builder.content(
      protect(decoded, _yamlPlaceholders),
      lineBreak: dominant,
      label: label,
      accept: looksLikeNaturalLanguage,
    );
    if (!hasSegment(blockNodes)) {
      nodes.text(joinLines(lines, lineIndex + 1, end));
      return end;
    }
    final lastEnding = lines[contentEnd - 1].ending;
    nodes
      ..addAll([
        EncodedNode(
          raw: rawBlock,
          children: blockNodes,
          encode: (translated) {
            final indented = translated
                .replaceAll('\r\n', '\n')
                .split('\n')
                .map((l) => l.isEmpty ? '' : '$indentStr$l')
                .join(dominant);
            return '$indented$lastEnding';
          },
        ),
      ])
      ..text(joinLines(lines, contentEnd, end));
    return end;
  }

  String _decodeFolded(int start, int end, int blockIndent) {
    final out = StringBuffer();
    var prevNormal = false;
    for (var k = start; k < end; k++) {
      final raw = lines[k].content;
      final stripped = raw.length >= blockIndent
          ? raw.substring(blockIndent)
          : '';
      if (stripped.isEmpty) {
        out.write('\n');
        prevNormal = false;
        continue;
      }
      final moreIndented =
          stripped.startsWith(' ') || stripped.startsWith('\t');
      if (k > start) {
        if (prevNormal && !moreIndented) {
          out.write(' ');
        } else {
          out.write('\n');
        }
      }
      out.write(stripped);
      prevNormal = !moreIndented;
    }
    return out.toString();
  }

  int _leadingSpacesBlock(String content) {
    var i = 0;
    while (i < content.length && content.codeUnitAt(i) == 0x20) {
      i++;
    }
    return i;
  }

  int _parseDoubleQuoted({
    required NodeList nodes,
    required String prefix,
    required String body,
    required int lineIndex,
    required bool skipKey,
    required String label,
  }) {
    final endQuote = _findDoubleQuoteEnd(body);
    if (endQuote < 0) {
      // Check multi-line double-quoted string.
      var j = lineIndex + 1;
      final joined = StringBuffer(body)..write(lines[lineIndex].ending);
      var closedLine = -1;
      var closedAt = -1;
      while (j < lines.length) {
        final c = lines[j].content;
        final close = _findDoubleQuoteEndInContinuation(c);
        if (close >= 0) {
          closedLine = j;
          closedAt = joined.length + close;
          joined.write(c);
          break;
        }
        joined
          ..write(c)
          ..write(lines[j].ending);
        j++;
      }
      if (closedLine < 0) {
        throw DocumentParseException(
          'YAML: line ${lineIndex + 1}: unterminated double-quoted string',
        );
      }
      final full = joined.toString();
      final rawLiteral = full.substring(0, closedAt + 1);
      final trailing =
          '${full.substring(closedAt + 1)}${lines[closedLine].ending}';
      if (skipKey) {
        nodes.text('$prefix$rawLiteral$trailing');
        return closedLine + 1;
      }
      final decoded = _decodeDoubleQuoted(
        rawLiteral.substring(1, rawLiteral.length - 1),
        lineIndex,
      );
      final contentNodes = builder.content(
        protect(decoded, _yamlPlaceholders),
        label: label,
        accept: looksLikeNaturalLanguage,
      );
      if (!hasSegment(contentNodes)) {
        nodes.text('$prefix$rawLiteral$trailing');
        return closedLine + 1;
      }
      nodes
        ..text(prefix)
        ..addAll([
          EncodedNode(
            raw: rawLiteral,
            children: contentNodes,
            encode: _encodeDoubleQuoted,
          ),
        ])
        ..text(trailing);
      return closedLine + 1;
    }

    final rawLiteral = body.substring(0, endQuote + 1);
    final trailing =
        '${body.substring(endQuote + 1)}${lines[lineIndex].ending}';
    if (skipKey) {
      nodes.text('$prefix$rawLiteral$trailing');
      return lineIndex + 1;
    }
    final decoded = _decodeDoubleQuoted(
      rawLiteral.substring(1, rawLiteral.length - 1),
      lineIndex,
    );
    final contentNodes = builder.content(
      protect(decoded, _yamlPlaceholders),
      label: label,
      accept: looksLikeNaturalLanguage,
    );
    if (!hasSegment(contentNodes)) {
      nodes.text('$prefix$rawLiteral$trailing');
      return lineIndex + 1;
    }
    nodes
      ..text(prefix)
      ..addAll([
        EncodedNode(
          raw: rawLiteral,
          children: contentNodes,
          encode: _encodeDoubleQuoted,
        ),
      ])
      ..text(trailing);
    return lineIndex + 1;
  }

  int _parseSingleQuoted({
    required NodeList nodes,
    required String prefix,
    required String body,
    required int lineIndex,
    required bool skipKey,
    required String label,
  }) {
    final endQuote = _findSingleQuoteEnd(body);
    if (endQuote < 0) {
      throw DocumentParseException(
        'YAML: line ${lineIndex + 1}: unterminated single-quoted string',
      );
    }
    final rawLiteral = body.substring(0, endQuote + 1);
    final trailing =
        '${body.substring(endQuote + 1)}${lines[lineIndex].ending}';
    if (skipKey) {
      nodes.text('$prefix$rawLiteral$trailing');
      return lineIndex + 1;
    }
    final decoded = rawLiteral
        .substring(1, rawLiteral.length - 1)
        .replaceAll("''", "'");
    final contentNodes = builder.content(
      protect(decoded, _yamlPlaceholders),
      label: label,
      accept: looksLikeNaturalLanguage,
    );
    if (!hasSegment(contentNodes)) {
      nodes.text('$prefix$rawLiteral$trailing');
      return lineIndex + 1;
    }
    nodes
      ..text(prefix)
      ..addAll([
        EncodedNode(
          raw: rawLiteral,
          children: contentNodes,
          encode: _encodeSingleQuoted,
        ),
      ])
      ..text(trailing);
    return lineIndex + 1;
  }

  int _parseFlowValue({
    required NodeList nodes,
    required String prefix,
    required String firstLineBody,
    required int lineIndex,
    required bool skipKey,
    required String label,
  }) {
    final openChar = firstLineBody[0];
    final closeChar = openChar == '[' ? ']' : '}';
    final combined = StringBuffer(firstLineBody);
    var endLine = lineIndex;
    var depth = 0;
    var inDouble = false;
    var inSingle = false;
    var escaped = false;
    var closeOffset = -1;

    void scan(String chunk, int baseOffset) {
      for (var k = 0; k < chunk.length; k++) {
        final ch = chunk[k];
        if (inDouble) {
          if (escaped) {
            escaped = false;
          } else if (ch == r'\') {
            escaped = true;
          } else if (ch == '"') {
            inDouble = false;
          }
          continue;
        }
        if (inSingle) {
          if (ch == "'") {
            if (k + 1 < chunk.length && chunk[k + 1] == "'") {
              k++;
            } else {
              inSingle = false;
            }
          }
          continue;
        }
        if (ch == '#') break;
        if (ch == '"') {
          inDouble = true;
        } else if (ch == "'") {
          inSingle = true;
        } else if (ch == openChar) {
          depth++;
        } else if (ch == closeChar) {
          depth--;
          if (depth == 0) {
            closeOffset = baseOffset + k;
            return;
          }
        }
      }
    }

    scan(firstLineBody, 0);
    while (closeOffset < 0 && endLine + 1 < lines.length) {
      combined.write(lines[endLine].ending);
      endLine++;
      final base = combined.length;
      combined.write(lines[endLine].content);
      scan(lines[endLine].content, base);
    }

    if (closeOffset < 0 || inDouble || inSingle) {
      throw DocumentParseException(
        'YAML: line ${lineIndex + 1}: unclosed flow collection "$openChar"',
      );
    }

    final full = combined.toString();
    final trailing =
        '${full.substring(closeOffset + 1)}${lines[endLine].ending}';
    final flowText = full.substring(0, closeOffset + 1);
    if (skipKey) {
      nodes.text('$prefix$flowText$trailing');
      return endLine + 1;
    }

    nodes
      ..text(prefix)
      ..addAll(_translateFlowStrings(flowText, label, lineIndex))
      ..text(trailing);
    return endLine + 1;
  }

  /// Translates quoted strings inside a flow collection (`["a", "b"]` or
  /// `{title: "Hello"}`), skipping mapping keys.
  List<DocNode> _translateFlowStrings(
    String flow,
    String label,
    int lineIndex,
  ) {
    final out = NodeList();
    var pos = 0;
    var last = 0;
    while (pos < flow.length) {
      final ch = flow[pos];
      if (ch == '"' || ch == "'") {
        final start = pos;
        final end = ch == '"'
            ? _findDoubleQuoteEndFrom(flow, start)
            : _findSingleQuoteEndFrom(flow, start);
        if (end < 0) break;
        // Check if this quoted string is a mapping key (followed by `:`).
        var after = end + 1;
        while (after < flow.length &&
            (flow[after] == ' ' || flow[after] == '\t')) {
          after++;
        }
        final isKey = after < flow.length && flow[after] == ':';
        if (!isKey) {
          final rawLiteral = flow.substring(start, end + 1);
          final decoded = ch == '"'
              ? _decodeDoubleQuoted(
                  rawLiteral.substring(1, rawLiteral.length - 1),
                  lineIndex,
                )
              : rawLiteral
                    .substring(1, rawLiteral.length - 1)
                    .replaceAll("''", "'");
          final contentNodes = builder.content(
            protect(decoded, _yamlPlaceholders),
            label: label,
            accept: looksLikeNaturalLanguage,
          );
          if (hasSegment(contentNodes)) {
            out
              ..text(flow.substring(last, start))
              ..addAll([
                EncodedNode(
                  raw: rawLiteral,
                  children: contentNodes,
                  encode: ch == '"' ? _encodeDoubleQuoted : _encodeSingleQuoted,
                ),
              ]);
            last = end + 1;
          }
        }
        pos = end + 1;
      } else {
        pos++;
      }
    }
    out.text(flow.substring(last));
    return out.nodes;
  }

  void _validateUnclosedQuotes(String rest, int lineIndex) {
    if (rest.startsWith('"') && _findDoubleQuoteEnd(rest) < 0) {
      throw DocumentParseException(
        'YAML: line ${lineIndex + 1}: unterminated double-quoted string',
      );
    }
    if (rest.startsWith("'") && _findSingleQuoteEnd(rest) < 0) {
      throw DocumentParseException(
        'YAML: line ${lineIndex + 1}: unterminated single-quoted string',
      );
    }
  }

  /// Splits `key: value` into key, raw `key:` prefix and everything after `:`.
  ({String key, String keyAndColon, String afterColon})? _splitMapping(
    String text,
    int lineIndex,
  ) {
    if (text.isEmpty) return null;
    if (text[0] == '"') {
      final end = _findDoubleQuoteEnd(text);
      if (end < 0) {
        throw DocumentParseException(
          'YAML: line ${lineIndex + 1}: unterminated quoted key',
        );
      }
      var pos = end + 1;
      while (pos < text.length && (text[pos] == ' ' || text[pos] == '\t')) {
        pos++;
      }
      if (pos >= text.length || text[pos] != ':') return null;
      if (pos + 1 < text.length &&
          text[pos + 1] != ' ' &&
          text[pos + 1] != '\t') {
        return null;
      }
      final key = _decodeDoubleQuoted(text.substring(1, end), lineIndex);
      return (
        key: key,
        keyAndColon: text.substring(0, pos + 1),
        afterColon: text.substring(pos + 1),
      );
    }
    if (text[0] == "'") {
      final end = _findSingleQuoteEnd(text);
      if (end < 0) {
        throw DocumentParseException(
          'YAML: line ${lineIndex + 1}: unterminated quoted key',
        );
      }
      var pos = end + 1;
      while (pos < text.length && (text[pos] == ' ' || text[pos] == '\t')) {
        pos++;
      }
      if (pos >= text.length || text[pos] != ':') return null;
      if (pos + 1 < text.length &&
          text[pos + 1] != ' ' &&
          text[pos + 1] != '\t') {
        return null;
      }
      final key = text.substring(1, end).replaceAll("''", "'");
      return (
        key: key,
        keyAndColon: text.substring(0, pos + 1),
        afterColon: text.substring(pos + 1),
      );
    }
    if (text[0] == '[' || text[0] == '{' || text[0] == '#') return null;
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (ch == '#' && i > 0 && (text[i - 1] == ' ' || text[i - 1] == '\t')) {
        return null;
      }
      if (ch == ':') {
        if (i + 1 == text.length || text[i + 1] == ' ' || text[i + 1] == '\t') {
          final key = text.substring(0, i).trim();
          if (key.isEmpty) return null;
          return (
            key: key,
            keyAndColon: text.substring(0, i + 1),
            afterColon: text.substring(i + 1),
          );
        }
      }
    }
    return null;
  }

  static int _propertyEnd(String text) {
    var i = 0;
    while (i < text.length && text[i] != ' ' && text[i] != '\t') {
      i++;
    }
    return i;
  }

  static (String, String) _splitPlainComment(String text) {
    for (var i = 0; i < text.length; i++) {
      if (text[i] == '#' &&
          i > 0 &&
          (text[i - 1] == ' ' || text[i - 1] == '\t')) {
        return (text.substring(0, i), text.substring(i));
      }
    }
    return (text, '');
  }

  static bool _isTranslatablePlain(String value) {
    if (value.isEmpty) return false;
    if (_yamlNullOrBool.hasMatch(value)) return false;
    if (_yamlNumber.hasMatch(value)) return false;
    if (_yamlDate.hasMatch(value)) return false;
    return true;
  }

  static int _findDoubleQuoteEnd(String text) =>
      _findDoubleQuoteEndFrom(text, 0);

  static int _findDoubleQuoteEndFrom(String text, int start) {
    var i = start + 1;
    while (i < text.length) {
      final ch = text[i];
      if (ch == r'\') {
        i += 2;
        continue;
      }
      if (ch == '"') return i;
      i++;
    }
    return -1;
  }

  static int _findDoubleQuoteEndInContinuation(String text) {
    var i = 0;
    while (i < text.length) {
      final ch = text[i];
      if (ch == r'\') {
        i += 2;
        continue;
      }
      if (ch == '"') return i;
      i++;
    }
    return -1;
  }

  static int _findSingleQuoteEnd(String text) =>
      _findSingleQuoteEndFrom(text, 0);

  static int _findSingleQuoteEndFrom(String text, int start) {
    var i = start + 1;
    while (i < text.length) {
      if (text[i] == "'") {
        if (i + 1 < text.length && text[i + 1] == "'") {
          i += 2;
          continue;
        }
        return i;
      }
      i++;
    }
    return -1;
  }

  static String _decodeDoubleQuoted(String body, int lineIndex) {
    final out = StringBuffer();
    for (var i = 0; i < body.length; i++) {
      final ch = body[i];
      if (ch != r'\') {
        out.write(ch);
        continue;
      }
      if (i + 1 >= body.length) {
        throw DocumentParseException(
          'YAML: line ${lineIndex + 1}: '
          'trailing backslash in double-quoted string',
        );
      }
      final next = body[++i];
      switch (next) {
        case 'n':
          out.write('\n');
        case 'r':
          out.write('\r');
        case 't':
          out.write('\t');
        case 'b':
          out.write('\b');
        case 'f':
          out.write('\f');
        case '0':
          out.writeCharCode(0);
        case '"':
          out.write('"');
        case r'\':
          out.write(r'\');
        case '/':
          out.write('/');
        case ' ':
          out.write(' ');
        case 'x' when i + 2 < body.length:
          final hex = body.substring(i + 1, i + 3);
          final code = int.tryParse(hex, radix: 16);
          if (code != null) {
            out.writeCharCode(code);
            i += 2;
          } else {
            out.write(r'\x');
          }
        case 'u' when i + 4 < body.length:
          final hex = body.substring(i + 1, i + 5);
          final code = int.tryParse(hex, radix: 16);
          if (code != null) {
            out.writeCharCode(code);
            i += 4;
          } else {
            out.write(r'\u');
          }
        case 'U' when i + 8 < body.length:
          final hex = body.substring(i + 1, i + 9);
          final code = int.tryParse(hex, radix: 16);
          if (code != null && code <= 0x10FFFF) {
            out.writeCharCode(code);
            i += 8;
          } else {
            out.write(r'\U');
          }
        case '\n':
          while (i + 1 < body.length &&
              (body[i + 1] == ' ' || body[i + 1] == '\t')) {
            i++;
          }
        case '\r':
          if (i + 1 < body.length && body[i + 1] == '\n') i++;
          while (i + 1 < body.length &&
              (body[i + 1] == ' ' || body[i + 1] == '\t')) {
            i++;
          }
        default:
          out.write(next);
      }
    }
    return out.toString();
  }

  static String _encodeDoubleQuoted(String value) {
    final out = StringBuffer('"');
    for (var i = 0; i < value.length; i++) {
      final ch = value[i];
      out.write(switch (ch) {
        r'\' => r'\\',
        '"' => r'\"',
        '\n' => r'\n',
        '\r' => r'\r',
        '\t' => r'\t',
        _ => ch,
      });
    }
    out.write('"');
    return out.toString();
  }

  static String _encodeSingleQuoted(String value) {
    if (value.contains('\n') || value.contains('\r') || value.contains('\t')) {
      return _encodeDoubleQuoted(value);
    }
    return "'${value.replaceAll("'", "''")}'";
  }

  static String _encodePlainOrQuoted(String value) {
    if (_needsQuotingInYaml(value)) return _encodeDoubleQuoted(value);
    return value;
  }

  static bool _needsQuotingInYaml(String value) {
    if (value.isEmpty) return true;
    if (value != value.trim()) return true;
    if (value.contains('\n') || value.contains('\r') || value.contains('\t')) {
      return true;
    }
    if (_leadingIndicator.hasMatch(value)) return true;
    if (value.contains(': ') ||
        value.endsWith(':') ||
        value.contains(' #') ||
        value.contains('\t#')) {
      return true;
    }
    if (_yamlNullOrBool.hasMatch(value) || _yamlNumber.hasMatch(value)) {
      return true;
    }
    return false;
  }
}
