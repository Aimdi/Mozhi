import 'package:archive/archive.dart' show ArchiveFile;
import 'package:mozhi/documents/core/document_builder.dart' show containsLetter;
import 'package:mozhi/documents/core/office/package_errors.dart';
import 'package:mozhi/documents/core/office/part_template.dart';
import 'package:mozhi/documents/core/office/xml_source.dart';
import 'package:mozhi/documents/core/office/zip_package.dart';

/// A sheet of a workbook: its [name] and whether it may be renamed.
final class WorkbookSheet {
  new(this.name, {required this.renamable});

  final String name;
  final bool renamable;

  /// The segment of the name (once a part refers to it).
  int? segment;

  String get key => name.toLowerCase();
}

/// The sheet names of a workbook (`xl/workbook.xml`), translated as
/// segments, and the formulas that refer to them.
///
/// A sheet is renamed only when every reference to it can be rewritten:
/// formulas of cells, shared formulas, conditional formats and data
/// validations (`f`, `formula`, `formula1`, `formula2`, `xm:f`), defined
/// names (print areas, filters), chart series (`c:f`, `cx:f`) and
/// internal hyperlinks (`location`) get the new name. A sheet that is
/// named anywhere else keeps its name, because that reference would break
/// and cannot be rewritten safely: pivot table sources, form controls and
/// other parts, text in a formula (`INDIRECT("Data!A1")`,
/// `HYPERLINK("#Data!A1")`), or a part too large to read. Every sheet of
/// a workbook with macros or ActiveX controls keeps its name (code refers
/// to sheets by name). Other files that link to the workbook can't be
/// seen; their links need the new names.
///
/// New names follow Excel's rules: at most 31 characters, none of
/// `[]:*?/\`, no apostrophe at either end, not "History", and unique
/// (ignoring case; a number is added).
final class SheetNames implements ElementSites {
  new _(this.sheets, this.partsWithReferences)
    : _byKey = {for (final sheet in sheets) sheet.key: sheet};

  /// The sheets in workbook order.
  final List<WorkbookSheet> sheets;

  /// Entry names of parts (other than the workbook) whose formulas refer
  /// to a renamable sheet: they are rewritten when it is renamed.
  final Set<String> partsWithReferences;
  final Map<String, WorkbookSheet> _byKey;
  final Expando<Map<String, String>> _renames = Expando();

  /// Excel's limit on the length of sheet names.
  static const maxLength = 31;

  /// Reads the sheet names of [workbook] and decides which can be renamed
  /// by looking for references in the other parts of [zip]; null when
  /// none can. [read] reads a part's text once (it is kept for building
  /// the templates later); [typeOf] gives a part's content type.
  static SheetNames? read(
    ZipPackage zip,
    ArchiveFile workbook, {
    required String Function(ArchiveFile entry) read,
    required String? Function(ArchiveFile entry) typeOf,
  }) {
    if (!zip.canRead(workbook)) return null;
    final document = SourceDocument.parse(
      read(workbook),
      part: workbook.name,
      maxDepth: zip.limits.maxDepth,
    );
    final names = <String>[];
    for (final sheets in document.root.elements) {
      if (!sheets.isA(Ns.sheet, 'sheets')) continue;
      for (final sheet in sheets.elements) {
        final name = sheet.attribute('name');
        if (sheet.isA(Ns.sheet, 'sheet') && name != null) names.add(name);
      }
    }
    final candidates = {
      for (final name in names)
        if (containsLetter(name)) name.toLowerCase(): name,
    };
    if (candidates.isEmpty || zip.entries.any((e) => _hasCode(e.name))) {
      return null;
    }

    final scan = _ReferenceScan(candidates)
      ..structure(document.root, workbook: true);
    for (final entry in zip.entries) {
      if (!entry.isFile || identical(entry, workbook)) continue;
      final name = entry.name.toLowerCase();
      if (!name.startsWith('xl/') ||
          !(name.endsWith('.xml') || name.endsWith('.vml'))) {
        continue;
      }
      final type = typeOf(entry);
      if (_textOnly.contains(type)) continue;
      // A part that can't be read may name any sheet.
      if (!zip.canRead(entry)) return null;
      final text = read(entry);
      if (!scan.mentioned(_decodeEntities(text))) continue;
      if (_withFormulas.contains(type)) {
        final SourceDocument part;
        try {
          part = SourceDocument.parse(
            text,
            part: entry.name,
            maxDepth: zip.limits.maxDepth,
          );
        } on PackageParseException {
          // A damaged part may name any sheet.
          return null;
        }
        if (scan.structure(part.root, workbook: false)) {
          scan.withReferences.add(entry.name);
        }
      } else {
        scan.block(_decodeEntities(text));
      }
    }

    final sheets = [
      for (final name in names)
        WorkbookSheet(
          name,
          renamable:
              candidates.containsKey(name.toLowerCase()) &&
              !scan.blocked.contains(name.toLowerCase()),
        ),
    ];
    if (!sheets.any((sheet) => sheet.renamable)) return null;
    return SheetNames._(sheets, scan.withReferences);
  }

  static const _sheetTypes = 'application/vnd.openxmlformats-officedocument.';

  /// Parts that hold text, never references.
  static const _textOnly = {
    '${_sheetTypes}spreadsheetml.sharedStrings+xml',
    '${_sheetTypes}spreadsheetml.comments+xml',
    '${_sheetTypes}spreadsheetml.styles+xml',
    '${_sheetTypes}theme+xml',
    'application/vnd.ms-excel.threadedcomments+xml',
    'application/vnd.ms-excel.person+xml',
  };

  /// Parts whose formulas are rewritten (anything else in them that names
  /// a sheet keeps it).
  static const _withFormulas = {
    '${_sheetTypes}spreadsheetml.worksheet+xml',
    '${_sheetTypes}drawingml.chart+xml',
    'application/vnd.ms-office.chartex+xml',
  };

  static bool _hasCode(String name) {
    final path = '/${name.toLowerCase()}';
    return path.endsWith('/vbaproject.bin') ||
        path.contains('/activex/') ||
        path.contains('/macrosheets/');
  }

  /// The new names for [renderer]'s translations: lower-case old name to
  /// new name, only for sheets that are renamed.
  Map<String, String> renames(PartRenderer renderer) =>
      _renames[renderer] ??= _compute(renderer);

  Map<String, String> _compute(PartRenderer renderer) {
    final taken = <String>{};
    final wanted = <(WorkbookSheet, String)>[];
    for (final sheet in sheets) {
      final segment = sheet.segment;
      final translation = segment == null
          ? null
          : renderer.attributeTranslationOf(segment);
      final name = translation == null ? null : sheetNameFrom(translation);
      if (name == null || name == sheet.name) {
        taken.add(sheet.key);
      } else {
        wanted.add((sheet, name));
      }
    }
    final renames = <String, String>{};
    for (final (sheet, name) in wanted) {
      final unique = _unique(name, taken);
      taken.add(unique.toLowerCase());
      if (unique != sheet.name) renames[sheet.key] = unique;
    }
    return renames;
  }

  /// [translation] as a valid sheet name (see [SheetNames]), or null when
  /// nothing usable is left.
  static String? sheetNameFrom(String translation) {
    var name = translation
        .replaceAll('[', '(')
        .replaceAll(']', ')')
        .replaceAll(RegExp(r'[:/\\]'), '-')
        .replaceAll(RegExp('[*?]'), '')
        .replaceAll(RegExp('[\x00-\x1F\x7F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    name = name.replaceAll(RegExp(r"^'+|'+$"), '').trim();
    name = _truncate(name, maxLength).trimRight();
    if (name.isEmpty || name.toLowerCase() == 'history') return null;
    return name;
  }

  /// At most [length] UTF-16 units of [text], without splitting a
  /// surrogate pair.
  static String _truncate(String text, int length) {
    if (text.length <= length) return text;
    var end = length;
    final unit = text.codeUnitAt(end - 1);
    if (unit >= 0xD800 && unit <= 0xDBFF) end--;
    return text.substring(0, end);
  }

  static String _unique(String name, Set<String> taken) {
    if (!taken.contains(name.toLowerCase())) return name;
    for (var number = 2; ; number++) {
      final suffix = ' ($number)';
      final candidate =
          '${_truncate(name, maxLength - suffix.length).trimRight()}$suffix';
      if (!taken.contains(candidate.toLowerCase())) return candidate;
    }
  }

  WorkbookSheet? _renamable(String name) {
    final sheet = _byKey[name.toLowerCase()];
    return sheet != null && sheet.renamable ? sheet : null;
  }

  /// Makes [sheet]'s name a segment of the part being built.
  void _register(SegmentTable table, WorkbookSheet sheet) =>
      sheet.segment = table.add(sheet.name);

  /// The renamable sheets [formula] refers to.
  List<WorkbookSheet> _referenced(String formula) => [
    for (final reference in sheetReferences(formula).references)
      for (final name in reference.names) ?_renamable(name),
  ];

  @override
  List<PartNode>? site(PartBuilder builder, SourceElement element) {
    final source = builder.source;
    final table = builder.table;
    final startTag = source.substring(element.start, element.startTagEnd);
    List<PartNode> withAttribute(
      String attribute,
      String? Function(PartRenderer renderer) value,
    ) => [
      ComputedXml(startTag, (renderer) {
        final text = value(renderer);
        return text == null
            ? null
            : spliceAttributes(startTag, {attribute: text});
      }),
      if (!element.isSelfClosing)
        RawXml(source.substring(element.startTagEnd, element.end)),
    ];

    if (element.isA(Ns.sheet, 'sheet') &&
        (element.parent?.isA(Ns.sheet, 'sheets') ?? false)) {
      final sheet = _renamable(element.attribute('name') ?? '');
      if (sheet == null) return null;
      _register(table, sheet);
      return withAttribute('name', (renderer) => renames(renderer)[sheet.key]);
    }
    if (element.isA(Ns.sheet, 'hyperlink')) {
      final location = element.attribute('location');
      if (location == null) return null;
      final sheets = _referenced(location);
      if (sheets.isEmpty) return null;
      for (final sheet in sheets) {
        _register(table, sheet);
      }
      return withAttribute(
        'location',
        (renderer) => rewriteSheetReferences(location, renames(renderer)),
      );
    }
    if (!isFormulaSite(element) || element.isSelfClosing) return null;
    final formula = element.text;
    final sheets = _referenced(formula);
    if (sheets.isEmpty) return null;
    for (final sheet in sheets) {
      _register(table, sheet);
    }
    return [
      RawXml(startTag),
      ComputedXml(source.substring(element.startTagEnd, element.endTagStart), (
        renderer,
      ) {
        final rewritten = rewriteSheetReferences(formula, renames(renderer));
        return rewritten == null ? null : escapeXmlText(rewritten);
      }),
      RawXml(source.substring(element.endTagStart, element.end)),
    ];
  }
}

/// The workbook part (`xl/workbook.xml`) when sheets are renamed: its
/// sheet names and defined names, through [SheetNames] as its
/// [PartBuilder.sites].
final class WorkbookPartBuilder extends PartBuilder {
  new(super.document, super.table);
}

/// Whether [element] holds a formula whose sheet references are
/// rewritten.
bool isFormulaSite(SourceElement element) {
  if (element.elements.isNotEmpty) return false;
  if (element.inNamespace(Ns.sheet)) {
    return const {
      'f',
      'formula',
      'formula1',
      'formula2',
      'definedName',
    }.contains(element.localName);
  }
  return element.localName == 'f' &&
      (element.inNamespace(Ns.excel) ||
          element.inNamespace(Ns.chart) ||
          element.inNamespace(Ns.chartEx));
}

/// Finds which sheet names parts mention.
final class _ReferenceScan {
  new(this.candidates)
    : _reference = _pattern(candidates.values, reference: true),
      _word = _pattern(candidates.values, reference: false);

  /// Lower-case name to name.
  final Map<String, String> candidates;

  /// A name followed by `!`, `:` or a quote: written like a reference.
  final RegExp _reference;

  /// A name as a word (in text that formulas may turn into references).
  final RegExp _word;
  final Set<String> blocked = {};
  final Set<String> withReferences = {};

  static RegExp _pattern(Iterable<String> names, {required bool reference}) {
    final alternatives = {
      for (final name in names) ...[
        RegExp.escape(name),
        RegExp.escape(name.replaceAll("'", "''")),
      ],
    }.toList()..sort((a, b) => b.length.compareTo(a.length));
    final after = reference ? '(?=[!:\'"])' : r'(?![\p{L}\p{N}_])';
    return RegExp(
      '(?<![\\p{L}\\p{N}_.])(?:${alternatives.join('|')})$after',
      caseSensitive: false,
      unicode: true,
    );
  }

  bool mentioned(String text) => _reference.hasMatch(text);

  /// Blocks the names [text] mentions like references.
  void block(String text, {bool words = false}) {
    for (final match in (words ? _word : _reference).allMatches(text)) {
      final key = match.group(0)!.replaceAll("''", "'").toLowerCase();
      if (candidates.containsKey(key)) blocked.add(key);
    }
  }

  /// Scans [element]'s subtree: formula sites are read as formulas (names
  /// in their text block), anything else blocks the names it mentions.
  /// Returns whether a formula refers to a candidate.
  bool structure(SourceElement element, {required bool workbook}) {
    var found = false;
    void formula(String text) {
      final scan = sheetReferences(text);
      for (final reference in scan.references) {
        for (final name in reference.names) {
          if (candidates.containsKey(name.toLowerCase())) found = true;
        }
      }
      for (final literal in scan.literals) {
        block(literal, words: true);
      }
    }

    void visit(SourceElement e) {
      if (isFormulaSite(e)) {
        formula(e.text);
        return;
      }
      for (final attribute in e.attributes) {
        // Namespaced attributes (r:id, mc:Ignorable) name no sheets.
        if (attribute.namespace != null) continue;
        if (workbook &&
            attribute.localName == 'name' &&
            (e.isA(Ns.sheet, 'sheet') || e.isA(Ns.sheet, 'definedName'))) {
          continue;
        }
        if (e.isA(Ns.sheet, 'hyperlink') && attribute.localName == 'location') {
          formula(attribute.value);
          continue;
        }
        block(attribute.value);
      }
      for (final child in e.children) {
        switch (child) {
          case SourceText(:final value):
            block(value);
          case SourceElement():
            visit(child);
          case SourceMisc():
            break;
        }
      }
    }

    visit(element);
    return found;
  }
}

final _entity = RegExp('&(?:lt|gt|amp|quot|apos|#[0-9]+|#x[0-9A-Fa-f]+);');

/// [text] with the predefined XML entities and character references
/// decoded.
String _decodeEntities(String text) {
  if (!text.contains('&')) return text;
  return text.replaceAllMapped(_entity, (match) {
    final entity = match.group(0)!;
    switch (entity) {
      case '&lt;':
        return '<';
      case '&gt;':
        return '>';
      case '&amp;':
        return '&';
      case '&quot;':
        return '"';
      case '&apos;':
        return "'";
    }
    final hex = entity.startsWith('&#x');
    final code = int.tryParse(
      entity.substring(hex ? 3 : 2, entity.length - 1),
      radix: hex ? 16 : 10,
    );
    return code == null || code > 0x10FFFF ? entity : String.fromCharCode(code);
  });
}

// -------------------------------------------------------------------------
// Formulas
// -------------------------------------------------------------------------

/// A reference to sheets in a formula: `start` to `end` is the sheet part
/// before the `!` (with its quotes), `names` the sheet (two for a 3-D
/// reference `Jan:Mar!A1`).
typedef SheetReference = ({int start, int end, List<String> names});

final _nameCharacter = RegExp(r'[\p{L}\p{N}_.\\]', unicode: true);
final _nameStart = RegExp(r'[\p{L}_\\]', unicode: true);
final _errorCharacter = RegExp('[A-Za-z0-9/!?]');

/// The sheet references of [formula] (references to other workbooks,
/// `[1]Sheet1!A1`, are left out) and its string literals.
({List<SheetReference> references, List<String> literals}) sheetReferences(
  String formula,
) {
  final references = <SheetReference>[];
  final literals = <String>[];
  final length = formula.length;

  /// Reads a quoted run starting at [start] (`"` or `'`, doubled to
  /// escape); returns the content and the offset after the closing quote.
  (String, int) quoted(int start) {
    final quote = formula[start];
    final buffer = StringBuffer();
    var i = start + 1;
    while (i < length) {
      final char = formula[i];
      if (char == quote) {
        if (i + 1 < length && formula[i + 1] == quote) {
          buffer.write(quote);
          i += 2;
          continue;
        }
        return (buffer.toString(), i + 1);
      }
      buffer.write(char);
      i++;
    }
    return (buffer.toString(), length);
  }

  int name(int start) {
    var i = start;
    while (i < length && _nameCharacter.hasMatch(formula[i])) {
      i++;
    }
    return i;
  }

  var i = 0;
  var external = false;
  while (i < length) {
    final char = formula[i];
    if (char == '"') {
      final (text, next) = quoted(i);
      literals.add(text);
      i = next;
      external = false;
    } else if (char == "'") {
      final (text, next) = quoted(i);
      if (next < length && formula[next] == '!' && !text.contains('[')) {
        if (!external) {
          references.add((start: i, end: next, names: text.split(':')));
        }
      }
      i = next;
      external = false;
    } else if (char == '[') {
      // Another workbook (`[1]`) or a structured reference
      // (`Table1[[#This Row],[Amount]]`).
      var depth = 0;
      var j = i;
      while (j < length) {
        if (formula[j] == '[') depth++;
        if (formula[j] == ']') {
          depth--;
          if (depth == 0) break;
        }
        j++;
      }
      i = j + 1;
      external = true;
    } else if (char == '#') {
      i++;
      while (i < length && _errorCharacter.hasMatch(formula[i])) {
        i++;
      }
      external = false;
    } else if (_nameStart.hasMatch(char)) {
      final end = name(i);
      if (end < length && formula[end] == '!') {
        if (!external) {
          references.add((
            start: i,
            end: end,
            names: [formula.substring(i, end)],
          ));
        }
        i = end;
      } else if (end < length && formula[end] == ':') {
        final second = name(end + 1);
        if (second > end + 1 && second < length && formula[second] == '!') {
          if (!external) {
            references.add((
              start: i,
              end: second,
              names: [
                formula.substring(i, end),
                formula.substring(end + 1, second),
              ],
            ));
          }
          i = second;
        } else {
          i = end;
        }
      } else {
        i = end;
      }
      external = false;
    } else {
      i++;
      external = false;
    }
  }
  return (references: references, literals: literals);
}

/// [formula] with its references to the sheets in [renames] (lower-case
/// old name to new name) written with the new names (always quoted), or
/// null when it refers to none of them.
String? rewriteSheetReferences(String formula, Map<String, String> renames) {
  if (renames.isEmpty) return null;
  final out = StringBuffer();
  var last = 0;
  var changed = false;
  for (final reference in sheetReferences(formula).references) {
    if (!reference.names.any((name) => renames[name.toLowerCase()] != null)) {
      continue;
    }
    final names = [
      for (final name in reference.names) renames[name.toLowerCase()] ?? name,
    ];
    out
      ..write(formula.substring(last, reference.start))
      ..write("'${names.join(':').replaceAll("'", "''")}'");
    last = reference.end;
    changed = true;
  }
  if (!changed) return null;
  out.write(formula.substring(last));
  return out.toString();
}
