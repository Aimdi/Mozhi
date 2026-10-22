import 'dart:async';
import 'dart:convert';

import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/presets/data/glossary_table.dart';
import 'package:mozhi/presets/data/id_generator.dart';
import 'package:mozhi/presets/data/merge_copies.dart';
import 'package:mozhi/presets/data/tombstone_store.dart';
import 'package:mozhi/presets/models/glossary.dart';
import 'package:mozhi/presets/models/tombstone.dart';

export '../models/tombstone.dart';

/// Persists glossaries as JSON under [storageKey]:
/// `{"version": 1, "orderUpdatedAt": "...", "glossaries": [...]}`
/// (`orderUpdatedAt` once the glossaries were reordered).
///
/// Unreadable data loads as an empty list (and is only overwritten by the
/// next [save]); invalid glossaries and duplicate ids are skipped. The last
/// loaded or saved list is cached for the synchronous [activeGlossary].
///
/// For backups and sync ([backupData], [replaceAll], [mergeBackup]):
/// glossaries carry their change time ([Glossary.updatedAt], stamped by the
/// `GlossaryCubit`), [save] stamps when the order changes (it decides
/// which of two equally specific glossaries wins) and records a
/// [Tombstone] for every glossary it is told was deleted. Tombstones are
/// stored under [tombstonesStorageKey] (plain JSON, like the glossaries),
/// kept for [tombstoneMaxAge] and at most [maxTombstones] of them; a
/// glossary that is saved again drops its tombstone. They are best effort:
/// when they can't be read or written, the glossaries still are.
class GlossaryRepository {
  new({
    KeyValueStore? store,
    IdGenerator? generateId,
    DateTime Function()? clock,
    this.maxTombstones = 10000,
    this.tombstoneMaxAge = const Duration(days: 180),
  }) : store = store ?? PreferencesStore(),
       _generateId = generateId ?? generateLocalId,
       _clock = clock ?? DateTime.now;

  /// Key of the glossaries JSON in [store].
  static const storageKey = 'glossaries.v1';

  /// Key of the glossaries' tombstones in [store].
  static const tombstonesStorageKey = 'glossaries.v1.tombstones';

  /// Storage format version.
  static const version = 1;

  final KeyValueStore store;
  final IdGenerator _generateId;
  final DateTime Function() _clock;

  /// At most this many tombstones are kept (the newest).
  final int maxTombstones;

  /// Tombstones older than this are dropped.
  final Duration tombstoneMaxAge;

  late final TombstoneStore _tombstones = TombstoneStore(
    store: store,
    key: tombstonesStorageKey,
    maxCount: maxTombstones,
    maxAge: tombstoneMaxAge,
    clock: _clock,
  );
  Future<void> _lock = Future.value();
  List<Glossary> _cache = const [];

  /// A new unique glossary id.
  String newId() => _generateId();

  /// The last loaded or saved glossaries.
  List<Glossary> get glossaries => _cache;

  Future<List<Glossary>> load() async =>
      _cache = (await _readDocument()).glossaries;

  /// Writes [glossaries]: the glossaries after a change in the app.
  ///
  /// The glossaries named in [deleted] (deleted by the change) leave a
  /// tombstone; those in [glossaries] drop theirs. When the order of the
  /// glossaries kept differs from the stored one, it is stamped as changed
  /// now (the document's `orderUpdatedAt`). Storage errors of the
  /// glossaries are thrown, those of the tombstones and the order's change
  /// time ignored.
  Future<void> save(
    List<Glossary> glossaries, {
    Iterable<String> deleted = const [],
  }) {
    final next = _cache = List.unmodifiable(glossaries);
    return _synchronized(() async {
      DateTime? orderUpdatedAt;
      try {
        final previous = await _readDocument();
        orderUpdatedAt =
            sameRelativeOrder(
              [for (final glossary in previous.glossaries) glossary.id],
              [for (final glossary in next) glossary.id],
            )
            ? previous.orderUpdatedAt
            : _clock();
      } on Object {
        orderUpdatedAt = null;
      }
      await _write(next, orderUpdatedAt: orderUpdatedAt);
      await _tombstones.update(
        deleted: deleted,
        present: [for (final glossary in next) glossary.id],
      );
    });
  }

  /// The glossaries, when they were last reordered and their tombstones,
  /// for a backup.
  Future<
    ({
      List<Glossary> glossaries,
      DateTime? orderUpdatedAt,
      List<Tombstone> tombstones,
    })
  >
  backupData() => _synchronized(() async {
    final (:glossaries, :orderUpdatedAt) = await _readDocument();
    final tombstones = await _tombstones.read();
    return (
      glossaries: glossaries,
      orderUpdatedAt: orderUpdatedAt,
      tombstones: TombstoneStore.toList(tombstones),
    );
  });

  /// Makes [glossaries] (last reordered at [orderUpdatedAt]) the
  /// glossaries and [tombstones] their tombstones: a backup restored with
  /// "Replace my data". What was here before leaves no tombstones.
  Future<void> replaceAll(
    List<Glossary> glossaries, {
    DateTime? orderUpdatedAt,
    List<Tombstone> tombstones = const [],
  }) {
    final next = _cache = List.unmodifiable(glossaries);
    return _synchronized(() async {
      await _write(next, orderUpdatedAt: orderUpdatedAt);
      await _tombstones.replace(
        TombstoneStore.toMap(tombstones),
        present: [for (final glossary in next) glossary.id],
      );
    });
  }

  /// Merges a backup's [glossaries] (last reordered at [orderUpdatedAt])
  /// and [tombstones] into the stored ones (a backup restored with "Merge
  /// with my data", and sync), and returns the result.
  ///
  /// Per id the newer copy wins ([Glossary.modifiedAt]; this device's on a
  /// tie). A tombstone in either copy at least as new as a glossary deletes
  /// it; a glossary changed after its tombstone stays. Glossaries only in
  /// one copy are kept otherwise. The order is that of the copy reordered
  /// last (this device's on a tie), with the other copy's glossaries after
  /// the glossary before them there. Both copies' tombstones are kept
  /// (bounded).
  Future<List<Glossary>> mergeBackup(
    List<Glossary> glossaries, {
    DateTime? orderUpdatedAt,
    List<Tombstone> tombstones = const [],
  }) => _synchronized(() async {
    final local = await _readDocument();
    final merged = mergeCopies(
      local: local.glossaries,
      other: glossaries,
      idOf: (glossary) => glossary.id,
      modifiedAt: (glossary) => glossary.modifiedAt,
      localTombstones: await _tombstones.read(),
      otherTombstones: TombstoneStore.toMap(tombstones),
      otherOrder: isLaterChange(orderUpdatedAt, local.orderUpdatedAt),
    );
    final next = _cache = merged.items;
    await _write(
      next,
      orderUpdatedAt: laterOf(local.orderUpdatedAt, orderUpdatedAt),
    );
    await _tombstones.replace(merged.tombstones);
    return next;
  });

  /// The stored glossaries and when they were last reordered (none when
  /// nothing or something unreadable is stored). Throws when the store
  /// fails.
  Future<({List<Glossary> glossaries, DateTime? orderUpdatedAt})>
  _readDocument() async {
    final raw = await store.read(storageKey);
    if (raw == null)
      return (glossaries: const <Glossary>[], orderUpdatedAt: null);
    try {
      final json = jsonDecode(raw);
      return (
        glossaries: parseGlossaries(json) ?? const <Glossary>[],
        orderUpdatedAt: parseOrderUpdatedAt(json),
      );
    } on FormatException {
      return (glossaries: const <Glossary>[], orderUpdatedAt: null);
    }
  }

  Future<void> _write(
    List<Glossary> glossaries, {
    required DateTime? orderUpdatedAt,
  }) => store.write(
    storageKey,
    jsonEncode(encode(glossaries, orderUpdatedAt: orderUpdatedAt)),
  );

  Future<T> _synchronized<T>(Future<T> Function() action) {
    final result = _lock.then((_) => action());
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

  /// The storage document for [glossaries], last reordered at
  /// [orderUpdatedAt] (written, UTC, only when given).
  static Map<String, dynamic> encode(
    Iterable<Glossary> glossaries, {
    DateTime? orderUpdatedAt,
  }) => {
    'version': version,
    if (orderUpdatedAt != null)
      'orderUpdatedAt': orderUpdatedAt.toUtc().toIso8601String(),
    'glossaries': [for (final glossary in glossaries) glossary.toJson()],
  };

  /// When the glossaries of an [encode] document were last reordered
  /// (null when not given or invalid, and for other shapes).
  static DateTime? parseOrderUpdatedAt(Object? json) =>
      json is Map ? parseChangeTime(json['orderUpdatedAt']) : null;

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

  /// Pretty JSON document of [glossaries]. Change times are left out: the
  /// export is for sharing, and an import gets new ones.
  static String exportJson(Iterable<Glossary> glossaries) =>
      const JsonEncoder.withIndent('  ').convert(
        encode([
          for (final glossary in glossaries) glossary.withoutChangeTime(),
        ]),
      );

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

  new(this.extension, this.mimeType);

  final String extension;
  final String mimeType;
}
