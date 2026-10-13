import 'dart:async';
import 'dart:convert';

import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/presets/data/glossary_table.dart';
import 'package:mozhi/presets/data/id_generator.dart';
import 'package:mozhi/presets/models/glossary.dart';

/// Persists glossaries as JSON under [storageKey]:
/// `{"version": 1, "glossaries": [...]}`.
///
/// Unreadable data loads as an empty list (and is only overwritten by the
/// next [save]); invalid glossaries and duplicate ids are skipped. The last
/// loaded or saved list is cached for the synchronous [activeGlossary].
class GlossaryRepository {
  GlossaryRepository({KeyValueStore? store, IdGenerator? generateId})
    : store = store ?? PreferencesStore(),
      _generateId = generateId ?? generateLocalId;

  /// Key of the glossaries JSON in [store].
  static const storageKey = 'glossaries.v1';

  /// Storage format version.
  static const version = 1;

  final KeyValueStore store;
  final IdGenerator _generateId;
  Future<void> _lock = Future.value();
  List<Glossary> _cache = const [];

  /// A new unique glossary id.
  String newId() => _generateId();

  /// The last loaded or saved glossaries.
  List<Glossary> get glossaries => _cache;

  Future<List<Glossary>> load() async {
    final raw = await store.read(storageKey);
    var glossaries = const <Glossary>[];
    if (raw != null) {
      try {
        glossaries = parseGlossaries(jsonDecode(raw)) ?? const [];
      } on FormatException {
        glossaries = const [];
      }
    }
    return _cache = glossaries;
  }

  Future<void> save(List<Glossary> glossaries) {
    _cache = List.unmodifiable(glossaries);
    final json = jsonEncode(encode(glossaries));
    final result = _lock.then((_) => store.write(storageKey, json));
    _lock = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// Terms of the cached enabled glossaries for the pair; see
  /// [mergeActiveGlossaries].
  Map<String, String> activeGlossary({
    required String sourceCode,
    required String targetCode,
  }) => mergeActiveGlossaries(
    _cache,
    sourceCode: sourceCode,
    targetCode: targetCode,
  );

  /// The storage document for [glossaries].
  static Map<String, dynamic> encode(Iterable<Glossary> glossaries) => {
    'version': version,
    'glossaries': [for (final glossary in glossaries) glossary.toJson()],
  };

  /// Parses [encode] output (any version) or a bare list of glossaries.
  /// Invalid entries and duplicate ids are skipped. Returns `null` for other
  /// shapes.
  static List<Glossary>? parseGlossaries(Object? json) {
    final Object? list = json is Map ? json['glossaries'] : json;
    if (list is! List) return null;
    final ids = <String>{};
    return List.unmodifiable([
      for (final element in list)
        if (element is Map)
          if (_tryParse(element) case final glossary?)
            if (ids.add(glossary.id)) glossary,
    ]);
  }

  /// Pretty JSON document of [glossaries].
  static String exportJson(Iterable<Glossary> glossaries) =>
      const JsonEncoder.withIndent('  ').convert(encode(glossaries));

  /// Glossaries from an exported document, a list or a single glossary
  /// object, each with a fresh id. Throws [FormatException] for invalid JSON,
  /// other shapes, or when no valid glossary is found in a non-empty input.
  List<Glossary> parseImport(String json) {
    final decoded = jsonDecode(json);
    final Object? document = decoded is Map && decoded['glossaries'] is! List
        ? [decoded]
        : decoded;
    final glossaries = parseGlossaries(document);
    if (glossaries == null) {
      throw const FormatException('Expected exported glossaries');
    }
    final count = switch (document) {
      final List<dynamic> list => list.length,
      final Map<dynamic, dynamic> map => (map['glossaries'] as List).length,
      _ => 0,
    };
    if (glossaries.isEmpty && count > 0) {
      throw const FormatException('No valid glossaries found');
    }
    return [for (final glossary in glossaries) glossary.copyWith(id: newId())];
  }

  /// Terms from pasted text: a JSON glossary export / glossary / list of
  /// terms when [text] starts with `{` or `[`, otherwise CSV or TSV
  /// ([GlossaryTable.parse]).
  ///
  /// Throws [FormatException] when no valid term is found.
  static GlossaryTableParse parseTerms(String text) {
    final trimmed = text.trimLeft();
    final GlossaryTableParse result;
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      result = _parseJsonTerms(jsonDecode(trimmed));
    } else {
      result = GlossaryTable.parse(text);
    }
    if (result.terms.isEmpty) {
      throw const FormatException('No glossary terms found');
    }
    return result;
  }

  /// [glossary]'s terms as CSV, TSV or a JSON glossary document.
  static String exportTerms(Glossary glossary, GlossaryExportFormat format) =>
      switch (format) {
        GlossaryExportFormat.csv => GlossaryTable.format(glossary.terms),
        GlossaryExportFormat.tsv => GlossaryTable.format(
          glossary.terms,
          format: GlossaryTableFormat.tsv,
        ),
        GlossaryExportFormat.json => exportJson([glossary]),
      };

  static GlossaryTableParse _parseJsonTerms(Object? json) {
    final candidates = <Object?>[];
    void collect(Object? node) {
      if (node is List) {
        node.forEach(collect);
      } else if (node is Map && node['glossaries'] is List) {
        collect(node['glossaries']);
      } else if (node is Map && node['terms'] is List) {
        candidates.addAll(node['terms'] as List);
      } else {
        candidates.add(node);
      }
    }

    if (json is! List && json is! Map) {
      throw const FormatException('Expected glossary terms');
    }
    collect(json);
    final terms = <GlossaryTerm>[];
    var skipped = 0;
    for (final candidate in candidates) {
      final term = candidate is Map ? _tryParseTerm(candidate) : null;
      if (term == null) {
        skipped++;
      } else {
        terms.add(term);
      }
    }
    return (terms: List.unmodifiable(terms), skipped: skipped);
  }

  static Glossary? _tryParse(Map<dynamic, dynamic> json) {
    try {
      return Glossary.fromJson(Map<String, dynamic>.from(json));
    } on FormatException {
      return null;
    }
  }

  static GlossaryTerm? _tryParseTerm(Map<dynamic, dynamic> json) {
    try {
      final term = GlossaryTerm.fromJson(Map<String, dynamic>.from(json));
      return term.isValid ? term.trimmed() : null;
    } on FormatException {
      return null;
    }
  }
}

/// File formats for exporting one glossary.
enum GlossaryExportFormat {
  csv('csv', 'text/csv'),
  tsv('tsv', 'text/tab-separated-values'),
  json('json', 'application/json');

  const GlossaryExportFormat(this.extension, this.mimeType);

  final String extension;
  final String mimeType;
}
