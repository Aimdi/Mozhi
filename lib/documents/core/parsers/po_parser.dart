import 'package:mozhi/documents/core/document_builder.dart';
import 'package:mozhi/documents/core/document_format.dart';
import 'package:mozhi/documents/core/parsed_document.dart';
import 'package:mozhi/documents/core/parsers/json_parser.dart'
    show DocumentParseException, looksLikeNaturalLanguage;
import 'package:mozhi/documents/core/parsers/locale_rules.dart';
import 'package:mozhi/documents/core/parsers/markup_content.dart'
    show NodeList, hasSegment, replacePrefixWhenTranslated;
import 'package:mozhi/documents/core/parsers/xml_tree.dart'
    show checkDocumentLength;
import 'package:mozhi/documents/core/source_line.dart';
import 'package:translation_repository/translation_repository.dart'
    show ProtectedPatterns;

/// Parses gettext catalogues ([DocumentFormat.po]); [targetLanguage] becomes
/// the `Language` header.
///
/// Every entry whose `msgstr` is empty is translated from its `msgid`
/// (plural entries from `msgid` and `msgid_plural`); entries that already
/// have a translation are kept, unless the catalogue's `Language` is
/// another language than [targetLanguage]: then they are translated again.
/// The header entry, obsolete (`#~`) entries, comments, references,
/// `msgctxt` and flags are kept. A `fuzzy` flag is removed from entries
/// that were untranslated and are translated now. printf (`%s`, `%1$d`,
/// `%(name)s`), brace (`{0}`, `{name}`), Qt (`%1`) placeholders, HTML tags,
/// URLs and e-mail addresses are protected; in format strings
/// (`c-format`, `python-format`, ...) a literal `%` is doubled.
///
/// Plurals: `msgstr[0..n-1]` are written, with `n` and the rule from the
/// target language's `Plural-Forms`. The form that `n = 1` selects gets
/// the translation of `msgid` (the singular) and all others that of
/// `msgid_plural`; languages with one form (Japanese, Chinese, Korean,
/// Vietnamese, Thai, Indonesian, ...) get a single `msgstr[0]` from
/// `msgid_plural`. Where that form also counts other numbers (Russian
/// "one" is 1, 21, 31, ...) and `msgid` lacks a placeholder `msgid_plural`
/// has (`"One file"` / `"%d files"`), it gets the plural text too.
/// Languages with several plural forms (few, many) get the same plural
/// text in each, as the source has only two: review them.
///
/// The target language's rule (a built-in table of the `Plural-Forms`
/// msginit writes; two forms for languages it does not know) is written
/// when the header has no usable `Plural-Forms` (a template), when the
/// language changes, and when the catalogue names no language and none of
/// its plural entries is translated yet. Otherwise the header's rule and
/// its existing translations are kept.
///
/// Once something is translated the header gets `Language`, a UTF-8
/// charset and (see above) `Plural-Forms`; a catalogue without a header
/// gets one.
///
/// Throws [DocumentParseException] for lines that are not PO syntax.
ParsedDocument parsePo(String text, {String? targetLanguage}) {
  checkDocumentLength(text, 'PO');
  return _PoParser(text, canonicalLanguageTag(targetLanguage)).parse();
}

final _keyword = RegExp(
  r'^[ \t]*(msgctxt|msgid_plural|msgid|msgstr(?:\[(\d+)\])?)[ \t]+(".*)$',
);
final _continuation = RegExp(r'^[ \t]*(".*)$');

/// Formats whose strings treat `%` as a conversion.
const _percentFormats = {
  'c-format',
  'objc-format',
  'python-format',
  'php-format',
  'perl-format',
  'sh-format',
  'awk-format',
  'object-pascal-format',
  'gcc-internal-format',
  'gfc-internal-format',
  'boost-format',
  'lua-format',
};

class _Field {
  new(this.keyword, this.index, this.start);

  final String keyword;
  final int? index;

  /// Line range [start, end).
  final int start;
  int end = 0;
  final StringBuffer value = StringBuffer();

  /// Written as `msgid ""` followed by continuation lines.
  bool multiLine = false;
}

class _Entry {
  new(this.start);

  final int start;
  int end = 0;
  int? flagsLine;
  final List<_Field> fields = [];

  _Field? field(String keyword) {
    for (final field in fields) {
      if (field.keyword == keyword) return field;
    }
    return null;
  }

  Iterable<_Field> get msgstrs => fields.where((f) => f.keyword == 'msgstr');
}

class _PoParser {
  new(this.text, this.target) : lines = splitLines(text);

  final String text;
  final String? target;
  final List<SourceLine> lines;
  final DocumentBuilder builder = DocumentBuilder();

  late final String _lineBreak = dominantLineBreak(lines);

  /// The placeholder pattern for entries with or without percent formats
  /// and Qt formats, compiled once each.
  static final _patterns = <(bool, bool), RegExp>{};

  ParsedDocument parse() {
    final entries = _entries();
    _Entry? header;
    for (final entry in entries) {
      if (entry.field('msgid')!.value.isEmpty &&
          entry.field('msgctxt') == null) {
        header = entry;
        break;
      }
    }
    final headers = header == null
        ? const <String, String>{}
        : _headerFields(header.msgstrs.first.value.toString());
    final existing = headers['Language'];
    final retranslate =
        target != null &&
        existing != null &&
        existing.trim().isNotEmpty &&
        !sameLanguage(existing, target!);

    final headerValue = headers['Plural-Forms'];
    final headerForms = PluralForms.parse(headerValue);
    String? newPluralForms;
    var forms = headerForms;
    if (target != null) {
      final known = gettextPluralForms(target) ?? defaultGettextPluralForms;
      final unnamed = existing == null || existing.trim().isEmpty;
      if (headerForms == null ||
          retranslate ||
          (unnamed &&
              _normalized(headerValue) != _normalized(known) &&
              !entries.any(_translatedPlural))) {
        newPluralForms = known;
        forms = PluralForms.parse(known);
      }
    }

    // Once per document, not per plural entry: it evaluates the rule for
    // a thousand numbers.
    final singularOnlyOne = forms != null && forms.isOnlyOne(forms.formFor(1));

    final nodes = NodeList();
    var line = 0;
    for (final entry in entries) {
      nodes
        ..text(joinLines(lines, line, entry.start))
        ..addAll(
          identical(entry, header)
              ? [TextNode(joinLines(lines, entry.start, entry.end))]
              : _entry(
                  entry,
                  retranslate: retranslate,
                  forms: forms,
                  singularOnlyOne: singularOnlyOne,
                ),
        );
      line = entry.end;
    }
    nodes.text(joinLines(lines, line, lines.length));

    final updated = _headerUpdate(header, newPluralForms);
    final all = updated == null
        ? nodes.nodes
        : hasSegment(nodes.nodes)
        ? [EncodedNode(raw: text, children: nodes.nodes, encode: updated)]
        : nodes.nodes;
    builder.add(all);
    return builder.build(DocumentFormat.po);
  }

  static String? _normalized(String? value) =>
      value?.replaceAll(RegExp(r'\s+'), '').replaceAll(RegExp(r';$'), '');

  static bool _translatedPlural(_Entry entry) =>
      entry.field('msgid_plural') != null &&
      entry.msgstrs.any((field) => field.value.isNotEmpty);

  // -------------------------------------------------------------------------
  // Reading
  // -------------------------------------------------------------------------

  List<_Entry> _entries() {
    final entries = <_Entry>[];
    _Entry? current;
    var hasKeywords = false;

    void finish(int end) {
      final entry = current;
      if (entry != null && hasKeywords) {
        entry.end = end;
        _check(entry);
        entries.add(entry);
      }
      current = null;
      hasKeywords = false;
    }

    for (var i = 0; i < lines.length; i++) {
      var content = lines[i].content;
      if (i == 0 && content.startsWith('\uFEFF')) {
        content = content.substring(1);
      }
      final trimmed = content.trimLeft();
      if (trimmed.isEmpty || trimmed.startsWith('#~')) {
        finish(i);
        continue;
      }
      if (trimmed.startsWith('#')) {
        if (hasKeywords) finish(i);
        current ??= _Entry(i);
        if (trimmed.startsWith('#,')) current!.flagsLine = i;
        continue;
      }
      final keyword = _keyword.firstMatch(content);
      if (keyword != null) {
        final name = keyword.group(1)!;
        final base = name.startsWith('msgstr') ? 'msgstr' : name;
        if ((base == 'msgctxt' || base == 'msgid') &&
            current != null &&
            current!.fields.any((field) => field.keyword == 'msgstr')) {
          finish(i);
        }
        current ??= _Entry(i);
        final index = keyword.group(2);
        final field = _Field(base, index == null ? null : int.parse(index), i);
        final value = _string(keyword.group(3)!, i);
        field
          ..value.write(value)
          ..end = i + 1;
        current!.fields.add(field);
        hasKeywords = true;
        continue;
      }
      final continuation = _continuation.firstMatch(content);
      if (continuation != null && hasKeywords) {
        final field = current!.fields.last
          ..value.write(_string(continuation.group(1)!, i))
          ..end = i + 1;
        if (field.end - field.start == 2 && _isEmptyLiteral(field.start)) {
          field.multiLine = true;
        }
        continue;
      }
      throw DocumentParseException(
        'PO: line ${i + 1} is not a comment, keyword or string',
      );
    }
    finish(lines.length);
    return entries;
  }

  bool _isEmptyLiteral(int line) {
    final match = _keyword.firstMatch(lines[line].content);
    return match != null && match.group(3)!.trim() == '""';
  }

  void _check(_Entry entry) {
    String where() => 'PO: the entry at line ${entry.start + 1}';
    final msgid = entry.field('msgid');
    if (msgid == null) throw DocumentParseException('${where()} has no msgid');
    final msgstrs = entry.msgstrs.toList();
    if (msgstrs.isEmpty) {
      throw DocumentParseException('${where()} has no msgstr');
    }
    final plural = entry.field('msgid_plural') != null;
    if (plural != msgstrs.every((field) => field.index != null) ||
        (!plural && msgstrs.length != 1)) {
      throw DocumentParseException('${where()} mixes up plural forms');
    }
    if (entry.fields.last.keyword != 'msgstr') {
      throw DocumentParseException('${where()} does not end with msgstr');
    }
  }

  /// Decodes a string literal (`"..."`, maybe followed by spaces).
  String _string(String literal, int line) {
    final trimmed = literal.trimRight();
    if (trimmed.length < 2 || !trimmed.endsWith('"')) {
      throw DocumentParseException('PO: line ${line + 1}: unterminated string');
    }
    final body = trimmed.substring(1, trimmed.length - 1);
    final out = StringBuffer();
    for (var i = 0; i < body.length; i++) {
      final char = body[i];
      if (char == '"') {
        throw DocumentParseException(
          'PO: line ${line + 1}: unescaped quote in a string',
        );
      }
      if (char != r'\') {
        out.write(char);
        continue;
      }
      if (i + 1 >= body.length) {
        throw DocumentParseException('PO: line ${line + 1}: bad escape');
      }
      final next = body[++i];
      switch (next) {
        case 'n':
          out.write('\n');
        case 't':
          out.write('\t');
        case 'r':
          out.write('\r');
        case 'a':
          out.write('\x07');
        case 'b':
          out.write('\b');
        case 'f':
          out.write('\f');
        case 'v':
          out.write('\v');
        case 'x':
          final hex = RegExp('[0-9a-fA-F]{1,2}').matchAsPrefix(body, i + 1);
          if (hex == null) {
            out.write('x');
          } else {
            out.writeCharCode(int.parse(hex.group(0)!, radix: 16));
            i = hex.end - 1;
          }
        default:
          final octal = RegExp('[0-7]{1,3}').matchAsPrefix(body, i);
          if (octal != null) {
            out.writeCharCode(int.parse(octal.group(0)!, radix: 8));
            i = octal.end - 1;
          } else {
            out.write(next);
          }
      }
    }
    return out.toString();
  }

  // -------------------------------------------------------------------------
  // Entries
  // -------------------------------------------------------------------------

  List<String> _flags(_Entry entry) {
    final line = entry.flagsLine;
    if (line == null) return const [];
    return [
      for (final flag in lines[line].content.trim().substring(2).split(','))
        if (flag.trim().isNotEmpty) flag.trim(),
    ];
  }

  List<DocNode> _entry(
    _Entry entry, {
    required bool retranslate,
    required PluralForms? forms,
    required bool singularOnlyOne,
  }) {
    final whole = [TextNode(joinLines(lines, entry.start, entry.end))];
    final msgstrs = entry.msgstrs.toList();
    final untranslated = msgstrs.every((field) => field.value.isEmpty);
    if (!untranslated && !retranslate) return whole;

    final flags = _flags(entry);
    final percent =
        flags.any(_percentFormats.contains) && !flags.contains('no-c-format');
    final braces = flags.contains('python-brace-format');
    final qt = flags.contains('qt-format') || flags.contains('kde-format');
    final pattern = _patterns[(percent, qt)] ??= ProtectedPatterns.combine([
      LocalisationPatterns.htmlTag,
      ProtectedPatterns.url,
      ProtectedPatterns.email,
      ProtectedPatterns.template,
      LocalisationPatterns.pythonNamed,
      LocalisationPatterns.braces,
      if (qt) LocalisationPatterns.qt,
      if (percent)
        LocalisationPatterns.printf
      else
        LocalisationPatterns.printfInText,
    ]);
    String escape(String text) {
      var value = text;
      if (percent) value = value.replaceAll('%', '%%');
      if (braces) value = value.replaceAll('{', '{{').replaceAll('}', '}}');
      return value;
    }

    final label = entry.field('msgctxt')?.value.toString();
    List<DocNode> segment(String value) {
      if (value.contains('\u0000')) return [TextNode(value)];
      return builder.content(
        protect(value, pattern),
        label: label,
        accept: looksLikeNaturalLanguage,
        escape: escape,
      );
    }

    final msgid = entry.field('msgid')!;
    final plural = entry.field('msgid_plural');
    var singularSource = msgid.value.toString();
    if (retranslate &&
        plural == null &&
        !looksLikeNaturalLanguage(singularSource) &&
        looksLikeNaturalLanguage(msgstrs.first.value.toString())) {
      // A catalogue keyed by identifiers: translate the existing text.
      singularSource = msgstrs.first.value.toString();
    }
    final children = <DocNode>[
      ...segment(singularSource),
      if (plural != null) ...[
        const TextNode('\u0000'),
        ...segment(plural.value.toString()),
      ],
    ];
    if (!hasSegment(children)) return whole;

    final first = msgstrs.first.start;
    final last = msgstrs.last.end;
    final ending = lines[last - 1].ending;
    final multiLine = msgid.multiLine;
    String field(String keyword, String value) =>
        _format(keyword, value, multiLine: multiLine);

    final String Function(String) encode;
    if (plural == null) {
      encode = (value) => '${field('msgstr', value)}$ending';
    } else {
      final count = forms?.count ?? msgstrs.length;
      final one = forms?.formFor(1) ?? 0;
      // "One file" / "%d files": a form that also counts 21 needs the
      // number.
      final singularForm =
          forms == null ||
              singularOnlyOne ||
              _tokens(
                plural.value.toString(),
                pattern,
              ).difference(_tokens(singularSource, pattern)).isEmpty
          ? one
          : -1;
      encode = (value) {
        final parts = value.split('\u0000');
        final singular = parts.first;
        final other = parts.length > 1 ? parts[1] : parts.first;
        final forms = [
          for (var k = 0; k < count; k++)
            field(
              'msgstr[$k]',
              count > 1 && k == singularForm ? singular : other,
            ),
        ];
        return '${forms.join(_lineBreak)}$ending';
      };
    }
    final msgstrNode = EncodedNode(
      raw: joinLines(lines, first, last),
      children: children,
      encode: encode,
    );

    final flagsLine = entry.flagsLine;
    if (untranslated && flags.contains('fuzzy') && flagsLine != null) {
      final rest = [
        for (final flag in flags)
          if (flag != 'fuzzy') flag,
      ];
      final oldLine = lines[flagsLine].full;
      final newLine = rest.isEmpty
          ? ''
          : '#, ${rest.join(', ')}${lines[flagsLine].ending}';
      return [
        TextNode(joinLines(lines, entry.start, flagsLine)),
        ...replacePrefixWhenTranslated(
          [
            TextNode(joinLines(lines, flagsLine, first)),
            msgstrNode,
            TextNode(joinLines(lines, last, entry.end)),
          ],
          oldLine,
          newLine,
        ),
      ];
    }
    return [
      TextNode(joinLines(lines, entry.start, first)),
      msgstrNode,
      TextNode(joinLines(lines, last, entry.end)),
    ];
  }

  /// The protected spans (placeholders) of [text].
  static Set<String> _tokens(String text, RegExp pattern) => {
    for (final match in pattern.allMatches(text)) match.group(0)!,
  };

  /// `keyword "value"`, or `keyword ""` with one line per `\n` when
  /// [multiLine] or the value has inner line breaks. No trailing break.
  String _format(String keyword, String value, {required bool multiLine}) {
    final inner = value.indexOf('\n');
    if (!multiLine && (inner < 0 || inner == value.length - 1)) {
      return '$keyword "${_escape(value)}"';
    }
    final parts = <String>[];
    var start = 0;
    while (start < value.length) {
      final newline = value.indexOf('\n', start);
      final end = newline < 0 ? value.length : newline + 1;
      parts.add(value.substring(start, end));
      start = end;
    }
    return [
      '$keyword ""',
      for (final part in parts) '"${_escape(part)}"',
    ].join(_lineBreak);
  }

  static String _escape(String value) {
    final out = StringBuffer();
    for (var i = 0; i < value.length; i++) {
      final char = value[i];
      out.write(switch (char) {
        r'\' => r'\\',
        '"' => r'\"',
        '\n' => r'\n',
        '\t' => r'\t',
        '\r' => r'\r',
        _ => char,
      });
    }
    return out.toString();
  }

  // -------------------------------------------------------------------------
  // Header
  // -------------------------------------------------------------------------

  static Map<String, String> _headerFields(String value) {
    final fields = <String, String>{};
    for (final line in value.split('\n')) {
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      fields.putIfAbsent(
        line.substring(0, colon).trim(),
        () => line.substring(colon + 1).trim(),
      );
    }
    return fields;
  }

  /// How the rendered catalogue is updated once something is translated
  /// (null when nothing changes).
  String Function(String rendered)? _headerUpdate(
    _Entry? header,
    String? pluralForms,
  ) {
    final language = target?.replaceAll('-', '_');
    if (header == null) {
      final fields = [
        if (language != null) 'Language: $language',
        'MIME-Version: 1.0',
        'Content-Type: text/plain; charset=UTF-8',
        'Content-Transfer-Encoding: 8bit',
        if (pluralForms != null) 'Plural-Forms: $pluralForms',
      ];
      final block = [
        'msgid ""',
        'msgstr ""',
        for (final field in fields) '"${_escape('$field\n')}"',
        '',
        '',
      ].join(_lineBreak);
      return (rendered) => rendered.startsWith('\uFEFF')
          ? '\uFEFF$block${rendered.substring(1)}'
          : '$block$rendered';
    }

    final msgstr = header.msgstrs.first;
    final raw = joinLines(lines, msgstr.start, msgstr.end);
    final ending = lines[msgstr.end - 1].ending;
    final physical = <String>[]; // raw continuation lines (no ending)
    final decoded = <String>[];
    final firstLiteral = _keyword.firstMatch(lines[msgstr.start].content)!;
    final firstValue = _string(firstLiteral.group(3)!, msgstr.start);
    var oneFieldPerLine = firstValue.isEmpty;
    for (var i = msgstr.start + 1; i < msgstr.end; i++) {
      physical.add(lines[i].content);
      final value = _string(
        _continuation.firstMatch(lines[i].content)!.group(1)!,
        i,
      );
      decoded.add(value);
      final breaks = '\n'.allMatches(value).length;
      final last = i == msgstr.end - 1;
      if (breaks > 1 ||
          (breaks == 1 && !value.endsWith('\n')) ||
          (breaks == 0 && !last)) {
        oneFieldPerLine = false;
      }
    }
    if (!oneFieldPerLine) {
      physical.clear();
      decoded
        ..clear()
        ..addAll(
          msgstr.value
              .toString()
              .split('\n')
              .where((field) => field.isNotEmpty)
              .map((field) => '$field\n'),
        );
      physical.addAll(decoded.map((field) => '"${_escape(field)}"'));
    }

    String name(String field) {
      final colon = field.indexOf(':');
      return colon < 0 ? '' : field.substring(0, colon).trim();
    }

    int indexOf(String field) =>
        decoded.indexWhere((line) => name(line) == field);
    void setField(String field, String value, {List<String> after = const []}) {
      final line = '$field: $value\n';
      final index = indexOf(field);
      if (index >= 0) {
        if (decoded[index] == line) return;
        decoded[index] = line;
        physical[index] = '"${_escape(line)}"';
        return;
      }
      var at = decoded.length;
      for (final anchor in after) {
        final position = indexOf(anchor);
        if (position >= 0) {
          at = position + 1;
          break;
        }
      }
      decoded.insert(at, line);
      physical.insert(at, '"${_escape(line)}"');
    }

    if (language != null) {
      setField('Language', language, after: const ['Language-Team']);
    }
    final contentType = indexOf('Content-Type');
    if (contentType >= 0) {
      final value = decoded[contentType];
      final charset = RegExp(r'charset=([^;\s\\]+)').firstMatch(value);
      if (charset != null && charset.group(1)!.toLowerCase() != 'utf-8') {
        setField(
          'Content-Type',
          value
              .substring(value.indexOf(':') + 1)
              .trim()
              .replaceFirst(charset.group(0)!, 'charset=UTF-8'),
        );
      }
    }
    if (pluralForms != null) setField('Plural-Forms', pluralForms);

    final block = ['msgstr ""', ...physical].join(_lineBreak);
    final updated = '$block$ending';
    if (updated == raw) return null;
    return (rendered) => rendered.replaceFirst(raw, updated);
  }
}
