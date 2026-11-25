import 'dart:convert';

import 'package:mozhi_cli/src/errors.dart';

/// A single translatable unit extracted from a structured document.
class DocumentSegment {
  const new({required this.id, required this.text});

  /// Human-readable locator (key path, cue number, line number, cell ref).
  final String id;

  /// Source text to translate.
  final String text;
}

/// Result of parsing a document into translatable [segments] plus a
/// [rebuild] function that splices translated strings back into the original
/// structure.
class ParsedDocument {
  const new({
    required this.format,
    required this.segments,
    required this.rebuild,
  });

  /// Canonical format name (`txt`, `md`, `json`, `arb`, `srt`, `vtt`, `po`,
  /// `properties`, `yaml`, `csv`, `tsv`).
  final String format;

  /// Translatable segments in document order.
  final List<DocumentSegment> segments;

  /// Reassembles the document with `translations` (same length as [segments]).
  final String Function(List<String> translations) rebuild;
}

/// Pure-Dart parsers and serializers for structured text & localization files.
abstract final class DocumentHandlers {
  /// Extensions supported by [parse].
  static const supportedExtensions = [
    '.txt',
    '.md',
    '.json',
    '.arb',
    '.srt',
    '.vtt',
    '.po',
    '.properties',
    '.yml',
    '.yaml',
    '.csv',
    '.tsv',
  ];

  /// Parses [content] according to the extension of [filePath] (or explicit
  /// [formatOverride]).
  static ParsedDocument parse(
    String filePath,
    String content, {
    String? formatOverride,
  }) {
    final ext = (formatOverride ?? _extensionOf(filePath))
        .trim()
        .toLowerCase()
        .replaceFirst(RegExp(r'^\.'), '');
    return switch (ext) {
      'txt' => _parsePlainText(content),
      'md' || 'markdown' => _parseMarkdown(content),
      'json' => _parseJson(content, isArb: false),
      'arb' => _parseJson(content, isArb: true),
      'srt' => _parseSrt(content),
      'vtt' => _parseVtt(content),
      'po' => _parsePo(content),
      'properties' => _parseProperties(content),
      'yml' || 'yaml' => _parseYaml(content),
      'csv' => _parseDelimited(content, delimiter: ',', format: 'csv'),
      'tsv' => _parseDelimited(content, delimiter: '\t', format: 'tsv'),
      _ => throw CliException.usage(
        'Unsupported document format '
        '"${ext.isEmpty ? filePath : '.$ext'}".',
        hint: 'Supported formats: ${supportedExtensions.join(', ')}.',
      ),
    };
  }

  static String _extensionOf(String path) {
    final slash = path.lastIndexOf(RegExp(r'[/\\]'));
    final name = slash < 0 ? path : path.substring(slash + 1);
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? '' : name.substring(dot + 1);
  }

  static String _eolOf(String content) =>
      content.contains('\r\n') ? '\r\n' : '\n';

  // ---------------------------------------------------------------------------
  // Plain text (.txt)
  // ---------------------------------------------------------------------------

  static ParsedDocument _parsePlainText(String content) {
    final eol = _eolOf(content);
    final normalized = content.replaceAll('\r\n', '\n');
    final trailingNewline = normalized.endsWith('\n');
    final body = trailingNewline
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
    final lines = body.isEmpty ? const <String>[] : body.split('\n');

    final parts = <_TextPart>[];
    final segments = <DocumentSegment>[];
    final buffer = <String>[];
    var paragraphIndex = 0;

    void flushParagraph() {
      if (buffer.isEmpty) return;
      final text = buffer.join('\n');
      final segIndex = segments.length;
      segments.add(DocumentSegment(id: 'p${++paragraphIndex}', text: text));
      parts.add(_TextPart.segment(segIndex));
      buffer.clear();
    }

    for (final line in lines) {
      if (line.trim().isEmpty) {
        flushParagraph();
        parts.add(_TextPart.literal(line));
      } else {
        buffer.add(line);
      }
    }
    flushParagraph();

    return ParsedDocument(
      format: 'txt',
      segments: segments,
      rebuild: (translations) {
        final out = [
          for (final part in parts)
            if (part.segmentIndex != null)
              translations[part.segmentIndex!]
            else
              part.literal!,
        ].join(eol);
        return trailingNewline ? '$out$eol' : out;
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Markdown (.md)
  // ---------------------------------------------------------------------------

  static final _mdHeading = RegExp(r'^(\s{0,3}#{1,6}[ \t]+)(.+)$');
  static final _mdList = RegExp(r'^(\s*(?:[-*+]|\d+[.)])[ \t]+)(.+)$');
  static final _mdQuote = RegExp(r'^(\s*(?:>[ \t]?)+)(.+)$');
  static final _mdFence = RegExp(r'^\s*(`{3,}|~{3,})');
  static final _mdHr = RegExp(r'^\s*(?:[-*_]\s*){3,}$');

  static ParsedDocument _parseMarkdown(String content) {
    final eol = _eolOf(content);
    final normalized = content.replaceAll('\r\n', '\n');
    final trailingNewline = normalized.endsWith('\n');
    final body = trailingNewline
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
    final lines = body.isEmpty ? const <String>[] : body.split('\n');

    final parts = <_TextPart>[];
    final segments = <DocumentSegment>[];
    var i = 0;

    // Preserve leading YAML frontmatter verbatim.
    if (lines.isNotEmpty && lines.first.trim() == '---') {
      final end = lines.indexWhere((l) => l.trim() == '---', 1);
      if (end > 0) {
        for (var j = 0; j <= end; j++) {
          parts.add(_TextPart.literal(lines[j]));
        }
        i = end + 1;
      }
    }

    var inFence = false;
    String? fenceMarker;
    var segCount = 0;
    final paraBuffer = <String>[];

    void flushPara() {
      if (paraBuffer.isEmpty) return;
      final text = paraBuffer.join('\n');
      final idx = segments.length;
      segments.add(DocumentSegment(id: 'md:${++segCount}', text: text));
      parts.add(_TextPart.segment(idx));
      paraBuffer.clear();
    }

    while (i < lines.length) {
      final line = lines[i++];
      if (inFence) {
        parts.add(_TextPart.literal(line));
        final trimmed = line.trimLeft();
        if (fenceMarker != null && trimmed.startsWith(fenceMarker)) {
          inFence = false;
          fenceMarker = null;
        }
        continue;
      }
      final fenceMatch = _mdFence.firstMatch(line);
      if (fenceMatch != null) {
        flushPara();
        inFence = true;
        final marker = fenceMatch.group(1)!;
        fenceMarker = marker[0] * marker.length;
        parts.add(_TextPart.literal(line));
        continue;
      }
      if (line.trim().isEmpty || _mdHr.hasMatch(line)) {
        flushPara();
        parts.add(_TextPart.literal(line));
        continue;
      }
      final structured =
          _mdHeading.firstMatch(line) ??
          _mdList.firstMatch(line) ??
          _mdQuote.firstMatch(line);
      if (structured != null) {
        flushPara();
        final prefix = structured.group(1)!;
        final text = structured.group(2)!;
        if (text.trim().isEmpty) {
          parts.add(_TextPart.literal(line));
        } else {
          final idx = segments.length;
          segments.add(DocumentSegment(id: 'md:${++segCount}', text: text));
          parts.add(_TextPart.prefixedSegment(prefix, idx));
        }
        continue;
      }
      paraBuffer.add(line);
    }
    flushPara();

    return ParsedDocument(
      format: 'md',
      segments: segments,
      rebuild: (translations) {
        final out = [
          for (final part in parts)
            if (part.segmentIndex != null)
              '${part.prefix ?? ''}${translations[part.segmentIndex!]}'
            else
              part.literal!,
        ].join(eol);
        return trailingNewline ? '$out$eol' : out;
      },
    );
  }

  // ---------------------------------------------------------------------------
  // JSON / ARB (.json, .arb)
  // ---------------------------------------------------------------------------

  static ParsedDocument _parseJson(String content, {required bool isArb}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException catch (error) {
      throw CliException.usage(
        'Invalid ${isArb ? 'ARB' : 'JSON'} document: ${error.message}',
      );
    }
    final indent = _detectJsonIndent(content);
    final trailingNewline = content.endsWith('\n');
    final eol = _eolOf(content);
    final segments = <DocumentSegment>[];

    void collect(Object? node, String path) {
      if (node is Map) {
        for (final MapEntry(:key, :value) in node.entries) {
          final keyStr = '$key';
          if (isArb && keyStr.startsWith('@')) continue;
          final childPath = path.isEmpty ? keyStr : '$path.$keyStr';
          if (value is String) {
            if (value.trim().isNotEmpty) {
              segments.add(DocumentSegment(id: childPath, text: value));
            }
          } else {
            collect(value, childPath);
          }
        }
      } else if (node is List) {
        for (var i = 0; i < node.length; i++) {
          final item = node[i];
          final childPath = '$path[$i]';
          if (item is String) {
            if (item.trim().isNotEmpty) {
              segments.add(DocumentSegment(id: childPath, text: item));
            }
          } else {
            collect(item, childPath);
          }
        }
      }
    }

    collect(decoded, '');

    return ParsedDocument(
      format: isArb ? 'arb' : 'json',
      segments: segments,
      rebuild: (translations) {
        var cursor = 0;
        Object? replace(Object? node) {
          if (node is Map) {
            return {
              for (final MapEntry(:key, :value) in node.entries)
                '$key': (isArb && '$key'.startsWith('@'))
                    ? value
                    : value is String
                    ? (value.trim().isNotEmpty ? translations[cursor++] : value)
                    : replace(value),
            };
          }
          if (node is List) {
            return [
              for (final item in node)
                if (item is String)
                  if (item.trim().isNotEmpty) translations[cursor++] else item
                else
                  replace(item),
            ];
          }
          return node;
        }

        final rebuilt = replace(decoded);
        var encoded = JsonEncoder.withIndent(indent).convert(rebuilt);
        if (eol == '\r\n') encoded = encoded.replaceAll('\n', '\r\n');
        return trailingNewline ? '$encoded$eol' : encoded;
      },
    );
  }

  static String _detectJsonIndent(String content) {
    final match = RegExp(r'\n([ \t]+)"').firstMatch(content);
    return match?.group(1) ?? '  ';
  }

  // ---------------------------------------------------------------------------
  // SubRip (.srt) and WebVTT (.vtt)
  // ---------------------------------------------------------------------------

  static final _srtTiming = RegExp(
    r'^\d{1,2}:\d{2}:\d{2}[,.]\d{3}\s*-->\s*\d{1,2}:\d{2}:\d{2}[,.]\d{3}',
  );
  static final _vttTiming = RegExp(
    r'^(?:\d{1,2}:)?\d{2}:\d{2}\.\d{3}\s*-->\s*(?:\d{1,2}:)?\d{2}:\d{2}\.\d{3}',
  );

  static ParsedDocument _parseSrt(String content) =>
      _parseSubtitles(content, format: 'srt', timingPattern: _srtTiming);

  static ParsedDocument _parseVtt(String content) =>
      _parseSubtitles(content, format: 'vtt', timingPattern: _vttTiming);

  static ParsedDocument _parseSubtitles(
    String content, {
    required String format,
    required RegExp timingPattern,
  }) {
    final eol = _eolOf(content);
    final normalized = content.replaceAll('\r\n', '\n');
    final trailingNewline = normalized.endsWith('\n');
    final body = trailingNewline
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
    final lines = body.isEmpty ? const <String>[] : body.split('\n');

    final parts = <_TextPart>[];
    final segments = <DocumentSegment>[];
    var cueCount = 0;
    var i = 0;

    while (i < lines.length) {
      final line = lines[i];
      if (format == 'vtt' &&
          (line.startsWith('NOTE') ||
              line.startsWith('STYLE') ||
              line.startsWith('REGION') ||
              (i == 0 && line.startsWith('WEBVTT')))) {
        // Keep header/metadata/NOTE blocks verbatim until the next blank line.
        while (i < lines.length && lines[i].trim().isNotEmpty) {
          parts.add(_TextPart.literal(lines[i++]));
        }
        continue;
      }

      if (timingPattern.hasMatch(line.trim())) {
        parts.add(_TextPart.literal(line));
        i++;
        final cueLines = <String>[];
        while (i < lines.length && lines[i].trim().isNotEmpty) {
          cueLines.add(lines[i++]);
        }
        if (cueLines.isNotEmpty) {
          final text = cueLines.join('\n');
          final idx = segments.length;
          segments.add(DocumentSegment(id: 'cue:${++cueCount}', text: text));
          parts.add(_TextPart.segment(idx));
        }
        continue;
      }

      parts.add(_TextPart.literal(line));
      i++;
    }

    return ParsedDocument(
      format: format,
      segments: segments,
      rebuild: (translations) {
        final out = [
          for (final part in parts)
            if (part.segmentIndex != null)
              translations[part.segmentIndex!].replaceAll('\n', eol)
            else
              part.literal!,
        ].join(eol);
        return trailingNewline ? '$out$eol' : out;
      },
    );
  }

  // ---------------------------------------------------------------------------
  // GNU gettext (.po)
  // ---------------------------------------------------------------------------

  static ParsedDocument _parsePo(String content) {
    final eol = _eolOf(content);
    final normalized = content.replaceAll('\r\n', '\n');
    final trailingNewline = normalized.endsWith('\n');
    final body = trailingNewline
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
    final lines = body.isEmpty ? const <String>[] : body.split('\n');

    final parts = <_TextPart>[];
    final segments = <DocumentSegment>[];
    var entryCount = 0;

    String? currentMsgId;
    String? currentMsgIdPlural;
    var i = 0;

    (String, int) readQuotedBlock(int start, String firstRemainder) {
      final buf = StringBuffer(_unquotePo(firstRemainder));
      var next = start + 1;
      while (next < lines.length && lines[next].trimLeft().startsWith('"')) {
        buf.write(_unquotePo(lines[next].trim()));
        next++;
      }
      return (buf.toString(), next);
    }

    while (i < lines.length) {
      final line = lines[i];
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        currentMsgId = null;
        currentMsgIdPlural = null;
        parts.add(_TextPart.literal(line));
        i++;
        continue;
      }
      if (trimmed.startsWith('#') || trimmed.startsWith('msgctxt ')) {
        parts.add(_TextPart.literal(line));
        i++;
        continue;
      }
      if (trimmed.startsWith('msgid_plural ')) {
        final (value, next) = readQuotedBlock(
          i,
          trimmed.substring('msgid_plural '.length).trim(),
        );
        currentMsgIdPlural = value;
        for (var j = i; j < next; j++) {
          parts.add(_TextPart.literal(lines[j]));
        }
        i = next;
        continue;
      }
      if (trimmed.startsWith('msgid ')) {
        final (value, next) = readQuotedBlock(
          i,
          trimmed.substring('msgid '.length).trim(),
        );
        currentMsgId = value;
        for (var j = i; j < next; j++) {
          parts.add(_TextPart.literal(lines[j]));
        }
        i = next;
        continue;
      }
      if (trimmed.startsWith('msgstr ')) {
        final (_, next) = readQuotedBlock(
          i,
          trimmed.substring('msgstr '.length).trim(),
        );
        // Header entry has msgid "": keep untouched!
        if (currentMsgId != null && currentMsgId.trim().isNotEmpty) {
          final idx = segments.length;
          segments.add(
            DocumentSegment(id: 'po:${++entryCount}', text: currentMsgId),
          );
          parts.add(_TextPart.poSegment('msgstr ', idx));
        } else {
          for (var j = i; j < next; j++) {
            parts.add(_TextPart.literal(lines[j]));
          }
        }
        i = next;
        continue;
      }
      final pluralMatch = RegExp(r'^(msgstr\[\d+\]\s+)(.*)$')
          .firstMatch(trimmed);
      if (pluralMatch != null) {
        final prefix = pluralMatch.group(1)!;
        final (_, next) = readQuotedBlock(i, pluralMatch.group(2)!.trim());
        final source = prefix.startsWith('msgstr[0]')
            ? currentMsgId
            : (currentMsgIdPlural ?? currentMsgId);
        if (source != null && source.trim().isNotEmpty) {
          final idx = segments.length;
          segments.add(DocumentSegment(id: 'po:${++entryCount}', text: source));
          parts.add(_TextPart.poSegment(prefix, idx));
        } else {
          for (var j = i; j < next; j++) {
            parts.add(_TextPart.literal(lines[j]));
          }
        }
        i = next;
        continue;
      }
      parts.add(_TextPart.literal(line));
      i++;
    }

    return ParsedDocument(
      format: 'po',
      segments: segments,
      rebuild: (translations) {
        final out = [
          for (final part in parts)
            if (part.segmentIndex != null)
              '${part.prefix!}${_quotePo(translations[part.segmentIndex!])}'
            else
              part.literal!,
        ].join(eol);
        return trailingNewline ? '$out$eol' : out;
      },
    );
  }

  static String _unquotePo(String token) {
    final trimmed = token.trim();
    if (trimmed.length < 2 ||
        !trimmed.startsWith('"') ||
        !trimmed.endsWith('"')) {
      return trimmed;
    }
    final inner = trimmed.substring(1, trimmed.length - 1);
    final out = StringBuffer();
    for (var i = 0; i < inner.length; i++) {
      if (inner[i] == r'\' && i + 1 < inner.length) {
        switch (inner[++i]) {
          case 'n':
            out.write('\n');
          case 't':
            out.write('\t');
          case 'r':
            out.write('\r');
          case '"':
            out.write('"');
          case r'\':
            out.write(r'\');
          case final other:
            out.write(other);
        }
      } else {
        out.write(inner[i]);
      }
    }
    return out.toString();
  }

  static String _quotePo(String value) {
    final escaped = value
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('\r', r'\r')
        .replaceAll('\t', r'\t')
        .replaceAll('\n', r'\n');
    return '"$escaped"';
  }

  // ---------------------------------------------------------------------------
  // Java .properties
  // ---------------------------------------------------------------------------

  static ParsedDocument _parseProperties(String content) {
    final eol = _eolOf(content);
    final normalized = content.replaceAll('\r\n', '\n');
    final trailingNewline = normalized.endsWith('\n');
    final body = trailingNewline
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
    final lines = body.isEmpty ? const <String>[] : body.split('\n');

    final parts = <_TextPart>[];
    final segments = <DocumentSegment>[];
    var i = 0;

    while (i < lines.length) {
      final line = lines[i++];
      final trimmed = line.trimLeft();
      if (trimmed.isEmpty ||
          trimmed.startsWith('#') ||
          trimmed.startsWith('!')) {
        parts.add(_TextPart.literal(line));
        continue;
      }

      // Join backslash line continuations.
      var logical = line;
      while (_endsWithOddBackslashes(logical) && i < lines.length) {
        final head = logical.substring(0, logical.length - 1);
        logical = '$head${lines[i++].trimLeft()}';
      }

      final split = _splitPropertyLine(logical);
      if (split == null) {
        parts.add(_TextPart.literal(logical));
        continue;
      }
      final (:key, :prefix, :rawValue) = split;
      final decoded = _unescapeProperties(rawValue);
      if (decoded.trim().isEmpty) {
        parts.add(_TextPart.literal(logical));
        continue;
      }
      final idx = segments.length;
      segments.add(DocumentSegment(id: key, text: decoded));
      parts.add(_TextPart.propertiesSegment(prefix, idx));
    }

    return ParsedDocument(
      format: 'properties',
      segments: segments,
      rebuild: (translations) {
        final out = [
          for (final part in parts)
            if (part.segmentIndex != null)
              '${part.prefix!}'
                  '${_escapeProperties(translations[part.segmentIndex!])}'
            else
              part.literal!,
        ].join(eol);
        return trailingNewline ? '$out$eol' : out;
      },
    );
  }

  static bool _endsWithOddBackslashes(String line) {
    var count = 0;
    for (var i = line.length - 1; i >= 0 && line[i] == r'\'; i--) {
      count++;
    }
    return count.isOdd;
  }

  static ({String key, String prefix, String rawValue})? _splitPropertyLine(
    String line,
  ) {
    var i = 0;
    while (i < line.length && (line[i] == ' ' || line[i] == '\t')) {
      i++;
    }
    final keyStart = i;
    while (i < line.length) {
      final c = line[i];
      if (c == r'\' && i + 1 < line.length) {
        i += 2;
        continue;
      }
      if (c == '=' || c == ':' || c == ' ' || c == '\t') break;
      i++;
    }
    if (i == keyStart) return null;
    final key = line.substring(keyStart, i);
    while (i < line.length && (line[i] == ' ' || line[i] == '\t')) {
      i++;
    }
    if (i < line.length && (line[i] == '=' || line[i] == ':')) {
      i++;
      while (i < line.length && (line[i] == ' ' || line[i] == '\t')) {
        i++;
      }
    }
    return (
      key: key,
      prefix: line.substring(0, i),
      rawValue: line.substring(i),
    );
  }

  static String _unescapeProperties(String raw) {
    final out = StringBuffer();
    for (var i = 0; i < raw.length; i++) {
      if (raw[i] == r'\' && i + 1 < raw.length) {
        switch (raw[++i]) {
          case 'n':
            out.write('\n');
          case 't':
            out.write('\t');
          case 'r':
            out.write('\r');
          case r'\':
            out.write(r'\');
          case final other:
            out.write(other);
        }
      } else {
        out.write(raw[i]);
      }
    }
    return out.toString();
  }

  static String _escapeProperties(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('\r', r'\r')
      .replaceAll('\n', r'\n')
      .replaceAll('\t', r'\t');

  // ---------------------------------------------------------------------------
  // YAML (.yml, .yaml)
  // ---------------------------------------------------------------------------

  static final _yamlMapping = RegExp(r'^([ \t]*)([^:#\s][^:]*?)(:[ \t]+)(.*)$');
  static final _yamlListItem = RegExp(r'^([ \t]*-[ \t]+)(.+)$');
  static final _yamlBlockHeader = RegExp(r'^[|>][+-]?\d*(?:\s+#.*)?$');
  static final _yamlNonString = RegExp(
    r'^(?:true|false|null|~|yes|no|on|off|[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?|0x[0-9a-fA-F]+)$',
    caseSensitive: false,
  );

  static ParsedDocument _parseYaml(String content) {
    final eol = _eolOf(content);
    final normalized = content.replaceAll('\r\n', '\n');
    final trailingNewline = normalized.endsWith('\n');
    final body = trailingNewline
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
    final lines = body.isEmpty ? const <String>[] : body.split('\n');

    final parts = <_TextPart>[];
    final segments = <DocumentSegment>[];
    var i = 0;
    var itemCount = 0;

    while (i < lines.length) {
      final line = lines[i++];
      final trimmed = line.trim();
      if (trimmed.isEmpty ||
          trimmed.startsWith('#') ||
          trimmed == '---' ||
          trimmed == '...') {
        parts.add(_TextPart.literal(line));
        continue;
      }

      // List item: `  - "hello"` or `  - hello` (but not `- key: value`).
      final listMatch = _yamlListItem.firstMatch(line);
      if (listMatch != null && !listMatch.group(2)!.contains(': ')) {
        final prefix = listMatch.group(1)!;
        final rawValue = listMatch.group(2)!;
        final parsed = _parseYamlScalar(rawValue);
        if (parsed != null) {
          final idx = segments.length;
          segments.add(
            DocumentSegment(id: 'yaml[${++itemCount}]', text: parsed.text),
          );
          parts.add(
            _TextPart.yamlScalar(
              prefix: prefix,
              segmentIndex: idx,
              quote: parsed.quote,
              suffix: parsed.suffix,
            ),
          );
        } else {
          parts.add(_TextPart.literal(line));
        }
        continue;
      }

      final mapMatch = _yamlMapping.firstMatch(line);
      if (mapMatch != null) {
        final indent = mapMatch.group(1)!;
        final key = mapMatch.group(2)!.trim();
        final sep = mapMatch.group(3)!;
        final rawValue = mapMatch.group(4)!;
        final trimmedVal = rawValue.trim();

        // Block scalar (`|` or `>`).
        if (_yamlBlockHeader.hasMatch(trimmedVal)) {
          parts.add(_TextPart.literal(line));
          final blockLines = <String>[];
          String? blockIndent;
          while (i < lines.length) {
            final nextLine = lines[i];
            if (nextLine.trim().isEmpty) {
              blockLines.add('');
              i++;
              continue;
            }
            final nextIndent = RegExp(r'^[ \t]*')
                .firstMatch(nextLine)!
                .group(0)!;
            if (nextIndent.length <= indent.length) break;
            blockIndent ??= nextIndent;
            blockLines.add(
              nextLine.length >= blockIndent.length
                  ? nextLine.substring(blockIndent.length)
                  : nextLine.trimLeft(),
            );
            i++;
          }
          // Keep trailing blank lines outside the translated block.
          final trailingBlanks = <String>[];
          while (blockLines.isNotEmpty && blockLines.last.isEmpty) {
            trailingBlanks.add(blockLines.removeLast());
          }
          final blockText = blockLines.join('\n');
          if (blockText.trim().isNotEmpty && blockIndent != null) {
            final idx = segments.length;
            segments.add(DocumentSegment(id: key, text: blockText));
            parts.add(_TextPart.yamlBlock(blockIndent, idx));
          }
          for (final blank in trailingBlanks) {
            parts.add(_TextPart.literal(blank));
          }
          continue;
        }

        final parsed = _parseYamlScalar(rawValue);
        if (parsed != null) {
          final idx = segments.length;
          segments.add(DocumentSegment(id: key, text: parsed.text));
          parts.add(
            _TextPart.yamlScalar(
              prefix: '$indent${mapMatch.group(2)!}$sep',
              segmentIndex: idx,
              quote: parsed.quote,
              suffix: parsed.suffix,
            ),
          );
          continue;
        }
      }

      parts.add(_TextPart.literal(line));
    }

    return ParsedDocument(
      format: 'yaml',
      segments: segments,
      rebuild: (translations) {
        final out = <String>[];
        for (final part in parts) {
          if (part.yamlBlockIndent != null) {
            out.add(
              translations[part.segmentIndex!]
                  .split('\n')
                  .map((l) => l.isEmpty ? '' : '${part.yamlBlockIndent!}$l')
                  .join(eol),
            );
          } else if (part.segmentIndex != null) {
            final value = _formatYamlScalar(
              translations[part.segmentIndex!],
              quote: part.quote,
            );
            out.add('${part.prefix!}$value${part.suffix ?? ''}');
          } else {
            out.add(part.literal!);
          }
        }
        final joined = out.join(eol);
        return trailingNewline ? '$joined$eol' : joined;
      },
    );
  }

  static ({String text, String? quote, String suffix})? _parseYamlScalar(
    String raw,
  ) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty ||
        trimmed.startsWith('[') ||
        trimmed.startsWith('{') ||
        trimmed.startsWith('&') ||
        trimmed.startsWith('*') ||
        trimmed.startsWith('!')) {
      return null;
    }
    if (trimmed.startsWith('"')) {
      final end = _findClosingDoubleQuote(trimmed);
      if (end < 0) return null;
      final inner = _unquotePo(trimmed.substring(0, end + 1));
      if (inner.trim().isEmpty) return null;
      return (text: inner, quote: '"', suffix: trimmed.substring(end + 1));
    }
    if (trimmed.startsWith("'")) {
      final end = _findClosingSingleQuote(trimmed);
      if (end < 0) return null;
      final inner = trimmed.substring(1, end).replaceAll("''", "'");
      if (inner.trim().isEmpty) return null;
      return (text: inner, quote: "'", suffix: trimmed.substring(end + 1));
    }
    // Unquoted scalar: separate trailing inline comment (` # ...`).
    final commentIdx = trimmed.indexOf(RegExp(r'\s+#'));
    final valuePart = commentIdx < 0
        ? trimmed
        : trimmed.substring(0, commentIdx).trimRight();
    final suffix = commentIdx < 0 ? '' : trimmed.substring(commentIdx);
    if (valuePart.isEmpty || _yamlNonString.hasMatch(valuePart)) return null;
    return (text: valuePart, quote: null, suffix: suffix);
  }

  static int _findClosingDoubleQuote(String s) {
    for (var i = 1; i < s.length; i++) {
      if (s[i] == r'\') {
        i++;
      } else if (s[i] == '"') {
        return i;
      }
    }
    return -1;
  }

  static int _findClosingSingleQuote(String s) {
    for (var i = 1; i < s.length; i++) {
      if (s[i] == "'") {
        if (i + 1 < s.length && s[i + 1] == "'") {
          i++;
        } else {
          return i;
        }
      }
    }
    return -1;
  }

  static String _formatYamlScalar(String value, {String? quote}) {
    if (quote == '"') return _quotePo(value);
    if (quote == "'") return "'${value.replaceAll("'", "''")}'";
    final needsQuoting =
        value.contains('\n') ||
        value.contains(': ') ||
        value.contains(' #') ||
        value.startsWith('"') ||
        value.startsWith("'") ||
        value.startsWith('[') ||
        value.startsWith('{') ||
        value.startsWith('#') ||
        value.startsWith('&') ||
        value.startsWith('*') ||
        value.startsWith('!') ||
        _yamlNonString.hasMatch(value);
    return needsQuoting ? _quotePo(value) : value;
  }

  // ---------------------------------------------------------------------------
  // CSV / TSV (.csv, .tsv)
  // ---------------------------------------------------------------------------

  static final _numericOrBool = RegExp(
    r'^(?:true|false|[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)$',
    caseSensitive: false,
  );

  static ParsedDocument _parseDelimited(
    String content, {
    required String delimiter,
    required String format,
  }) {
    final eol = _eolOf(content);
    final trailingNewline = content.endsWith('\n');
    final rows = _readCsvRows(content, delimiter);
    final segments = <DocumentSegment>[];
    final cellCoords = <(int, int)>[];

    for (var r = 0; r < rows.length; r++) {
      for (var c = 0; c < rows[r].length; c++) {
        final cell = rows[r][c];
        final trimmed = cell.trim();
        if (trimmed.isEmpty || _numericOrBool.hasMatch(trimmed)) continue;
        segments.add(DocumentSegment(id: 'r${r + 1}:c${c + 1}', text: cell));
        cellCoords.add((r, c));
      }
    }

    return ParsedDocument(
      format: format,
      segments: segments,
      rebuild: (translations) {
        final rebuilt = [for (final row in rows) List<String>.of(row)];
        for (var i = 0; i < cellCoords.length; i++) {
          final (r, c) = cellCoords[i];
          rebuilt[r][c] = translations[i];
        }
        final out = [
          for (final row in rebuilt)
            row.map((cell) => _quoteCsvCell(cell, delimiter)).join(delimiter),
        ].join(eol);
        return trailingNewline ? '$out$eol' : out;
      },
    );
  }

  static List<List<String>> _readCsvRows(String content, String delimiter) {
    final rows = <List<String>>[];
    if (content.isEmpty) return rows;
    final delimUnit = delimiter.codeUnitAt(0);
    var currentRow = <String>[];
    final field = StringBuffer();
    var inQuotes = false;
    var i = 0;

    while (i < content.length) {
      final unit = content.codeUnitAt(i);
      if (inQuotes) {
        if (unit == 0x22) {
          if (i + 1 < content.length && content.codeUnitAt(i + 1) == 0x22) {
            field.write('"');
            i += 2;
          } else {
            inQuotes = false;
            i++;
          }
        } else {
          field.writeCharCode(unit);
          i++;
        }
        continue;
      }
      if (unit == 0x22 && field.isEmpty) {
        inQuotes = true;
        i++;
      } else if (unit == delimUnit) {
        currentRow.add(field.toString());
        field.clear();
        i++;
      } else if (unit == 0x0D || unit == 0x0A) {
        currentRow.add(field.toString());
        field.clear();
        rows.add(currentRow);
        currentRow = <String>[];
        if (unit == 0x0D &&
            i + 1 < content.length &&
            content.codeUnitAt(i + 1) == 0x0A) {
          i += 2;
        } else {
          i++;
        }
      } else {
        field.writeCharCode(unit);
        i++;
      }
    }
    if (field.isNotEmpty || currentRow.isNotEmpty) {
      currentRow.add(field.toString());
      rows.add(currentRow);
    }
    return rows;
  }

  static String _quoteCsvCell(String cell, String delimiter) {
    final needsQuotes =
        cell.contains(delimiter) ||
        cell.contains('"') ||
        cell.contains('\n') ||
        cell.contains('\r');
    if (!needsQuotes) return cell;
    return '"${cell.replaceAll('"', '""')}"';
  }
}

class _TextPart {
  const new literal(this.literal)
    : segmentIndex = null,
      prefix = null,
      suffix = null,
      quote = null,
      yamlBlockIndent = null;

  const new segment(this.segmentIndex)
    : literal = null,
      prefix = null,
      suffix = null,
      quote = null,
      yamlBlockIndent = null;

  const new prefixedSegment(this.prefix, this.segmentIndex)
    : literal = null,
      suffix = null,
      quote = null,
      yamlBlockIndent = null;

  const new poSegment(this.prefix, this.segmentIndex)
    : literal = null,
      suffix = null,
      quote = null,
      yamlBlockIndent = null;

  const new propertiesSegment(this.prefix, this.segmentIndex)
    : literal = null,
      suffix = null,
      quote = null,
      yamlBlockIndent = null;

  const new yamlScalar({
    required this.prefix,
    required this.segmentIndex,
    this.quote,
    this.suffix,
  }) : literal = null,
       yamlBlockIndent = null;

  const new yamlBlock(this.yamlBlockIndent, this.segmentIndex)
    : literal = null,
      prefix = null,
      suffix = null,
      quote = null;

  final String? literal;
  final int? segmentIndex;
  final String? prefix;
  final String? suffix;
  final String? quote;
  final String? yamlBlockIndent;
}
