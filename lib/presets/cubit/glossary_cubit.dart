import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:mozhi/presets/cubit/glossary_state.dart';
import 'package:mozhi/presets/data/glossary_repository.dart';
import 'package:mozhi/presets/models/glossary.dart';

export 'glossary_state.dart';

/// Outcome of [GlossaryCubit.importTerms].
typedef TermImport = ({int added, int updated, int skipped});

/// Manages the user's glossaries. `repository` defaults to a
/// [GlossaryRepository] backed by the platform preferences.
///
/// Every change is emitted first and then written through; storage errors
/// are reported via `addError` and never thrown. The import methods throw
/// [FormatException] for invalid input (the state is unchanged then).
///
/// For backups and sync, every glossary created or changed (renamed,
/// scoped, turned on or off, its terms added, edited or removed, imported,
/// put back) is stamped with `clock` (default [DateTime.now]) as its
/// [Glossary.updatedAt], and the glossaries a change deletes are handed to
/// [GlossaryRepository.save] for their tombstones (which also stamps a new
/// order).
class GlossaryCubit extends Cubit<GlossaryState> {
  new({GlossaryRepository? repository, DateTime Function()? clock})
    : _repository = repository ?? GlossaryRepository(),
      _clock = clock ?? DateTime.now,
      super(const GlossaryState());

  final GlossaryRepository _repository;
  final DateTime Function() _clock;

  /// How many changes were committed (a load that a change overtook reads
  /// again, so the change is shown).
  int _commits = 0;

  /// Reads the glossaries (again when a change was made while reading:
  /// the glossaries read may not hold it yet).
  Future<void> load() async {
    if (isClosed) return;
    emit(state.copyWith(status: GlossaryStatus.loading));
    try {
      final commits = _commits;
      final glossaries = await _repository.load();
      if (isClosed) return;
      if (_commits != commits) return await load();
      emit(GlossaryState(status: GlossaryStatus.ready, glossaries: glossaries));
    } on Object catch (error, stackTrace) {
      if (!isClosed) emit(state.copyWith(status: GlossaryStatus.failure));
      addError(error, stackTrace);
    }
  }

  /// Terms of the enabled glossaries matching the pair, ready for
  /// `TranslationOptions.glossary` (see [mergeActiveGlossaries]).
  // Read-only query derived from state; it changes nothing.
  // ignore: prefer_void_public_cubit_methods
  Map<String, String> activeGlossary({
    required String sourceCode,
    required String targetCode,
  }) => state.activeGlossary(sourceCode: sourceCode, targetCode: targetCode);

  /// Appends a new, enabled glossary.
  // Returns the created item so the caller can open or select it.
  // ignore: prefer_void_public_cubit_methods
  Future<Glossary> create({
    required String name,
    String sourceCode = LanguageScope.any,
    String targetCode = LanguageScope.any,
    List<GlossaryTerm> terms = const [],
  }) async {
    final glossary = Glossary(
      id: _repository.newId(),
      name: name.trim(),
      sourceCode: LanguageScope.normalize(sourceCode),
      targetCode: LanguageScope.normalize(targetCode),
      terms: mergeTerms(const [], terms).terms,
      updatedAt: _clock(),
    );
    await _commit([...state.glossaries, glossary]);
    return glossary;
  }

  /// Replaces the glossary with the same id (no-op when it is unknown).
  Future<void> save(Glossary glossary) => _change(
    glossary.id,
    (_) => glossary.copyWith(name: glossary.name.trim()),
  );

  Future<void> rename(String id, String name) =>
      _change(id, (glossary) => glossary.copyWith(name: name.trim()));

  Future<void> setScope(
    String id, {
    required String sourceCode,
    required String targetCode,
  }) => _change(
    id,
    (glossary) =>
        glossary.copyWith(sourceCode: sourceCode, targetCode: targetCode),
  );

  Future<void> setEnabled(String id, {required bool enabled}) =>
      _change(id, (glossary) => glossary.copyWith(enabled: enabled));

  Future<void> delete(String id) async {
    if (state.byId(id) == null) return;
    await _commit([
      for (final glossary in state.glossaries)
        if (glossary.id != id) glossary,
    ]);
  }

  /// Puts a deleted [glossary] back at [index] (clamped), e.g. for undo. It
  /// is stamped as changed, so that it also comes back on devices that
  /// synced the delete.
  Future<void> restore(Glossary glossary, {required int index}) async {
    final glossaries = [
      for (final existing in state.glossaries)
        if (existing.id != glossary.id) existing,
    ];
    glossaries.insert(
      index.clamp(0, glossaries.length),
      glossary.copyWith(updatedAt: _clock()),
    );
    await _commit(glossaries);
  }

  /// Moves the glossary at [from] to index [to]
  /// (`ReorderableListView.onReorderItem` semantics).
  Future<void> move(int from, int to) async {
    final length = state.glossaries.length;
    if (from == to || from < 0 || to < 0 || from >= length || to >= length) {
      return;
    }
    final glossaries = [...state.glossaries];
    glossaries.insert(to, glossaries.removeAt(from));
    await _commit(glossaries);
  }

  /// Adds [term], replacing an existing term with the same source
  /// ([GlossaryTerm.sameSourceAs]). Invalid terms are ignored.
  Future<void> addTerm(String id, GlossaryTerm term) => _change(
    id,
    (glossary) =>
        glossary.copyWith(terms: mergeTerms(glossary.terms, [term]).terms),
  );

  /// Replaces the term at [index]. A term elsewhere with the same source is
  /// removed so sources stay unique. Invalid terms are ignored.
  Future<void> updateTerm(String id, int index, GlossaryTerm term) =>
      _change(id, (glossary) {
        if (!term.isValid || index < 0 || index >= glossary.terms.length) {
          return glossary;
        }
        final updated = term.trimmed();
        final terms = <GlossaryTerm>[];
        for (var i = 0; i < glossary.terms.length; i++) {
          if (i == index) {
            terms.add(updated);
          } else if (!glossary.terms[i].sameSourceAs(updated)) {
            terms.add(glossary.terms[i]);
          }
        }
        return glossary.copyWith(terms: terms);
      });

  Future<void> removeTerm(String id, int index) => _change(id, (glossary) {
    if (index < 0 || index >= glossary.terms.length) return glossary;
    return glossary.copyWith(terms: [...glossary.terms]..removeAt(index));
  });

  /// Inserts [term] at [index] (clamped), e.g. to undo [removeTerm].
  /// A term with the same source is replaced; invalid terms are ignored.
  Future<void> insertTerm(String id, int index, GlossaryTerm term) =>
      _change(id, (glossary) {
        if (!term.isValid) return glossary;
        final trimmed = term.trimmed();
        final terms = [
          for (final existing in glossary.terms)
            if (!existing.sameSourceAs(trimmed)) existing,
        ];
        terms.insert(index.clamp(0, terms.length), trimmed);
        return glossary.copyWith(terms: terms);
      });

  /// Adds the terms from pasted CSV / TSV / JSON text
  /// ([GlossaryRepository.parseTerms]) to glossary [id].
  ///
  /// Throws [FormatException] when no term is found or [id] is unknown.
  // Returns the import summary for the caller to report.
  // ignore: prefer_void_public_cubit_methods
  Future<TermImport> importTerms(String id, String text) async {
    final glossary = state.byId(id);
    if (glossary == null) throw FormatException('Unknown glossary $id');
    final parsed = GlossaryRepository.parseTerms(text);
    final merge = mergeTerms(glossary.terms, parsed.terms);
    await _change(id, (current) => current.copyWith(terms: merge.terms));
    return (
      added: merge.added,
      updated: merge.updated,
      skipped: parsed.skipped,
    );
  }

  /// Glossary [id] as CSV, TSV or JSON; `null` when it is unknown.
  // Returns the export for the caller to save or share; it is not state.
  // ignore: prefer_void_public_cubit_methods
  String? exportTerms(String id, GlossaryExportFormat format) {
    final glossary = state.byId(id);
    return glossary == null
        ? null
        : GlossaryRepository.exportTerms(glossary, format);
  }

  /// Pretty JSON of all glossaries, or only of [ids].
  // Returns the export for the caller to save or share; it is not state.
  // ignore: prefer_void_public_cubit_methods
  String exportJson({Set<String>? ids}) => GlossaryRepository.exportJson([
    for (final glossary in state.glossaries)
      if (ids == null || ids.contains(glossary.id)) glossary,
  ]);

  /// Appends the glossaries in [json] (with new ids); returns their count.
  /// Throws [FormatException] for invalid input.
  // Returns how many items were imported for the caller to report.
  // ignore: prefer_void_public_cubit_methods
  Future<int> importJson(String json) async {
    final imported = _repository.parseImport(json);
    if (imported.isEmpty) return 0;
    final now = _clock();
    await _commit([
      ...state.glossaries,
      for (final glossary in imported) glossary.copyWith(updatedAt: now),
    ]);
    return imported.length;
  }

  Future<void> _change(String id, Glossary Function(Glossary) change) async {
    final index = state.glossaries.indexWhere((g) => g.id == id);
    if (index < 0) return;
    final current = state.glossaries[index];
    final next = change(current);
    if (next == current) return;
    final glossaries = [...state.glossaries];
    glossaries[index] = next.copyWith(id: id, updatedAt: _clock());
    await _commit(glossaries);
  }

  Future<void> _commit(List<Glossary> glossaries) async {
    if (isClosed) return;
    final next = List<Glossary>.unmodifiable(glossaries);
    final kept = {for (final glossary in next) glossary.id};
    final deleted = [
      for (final glossary in state.glossaries)
        if (!kept.contains(glossary.id)) glossary.id,
    ];
    _commits++;
    emit(GlossaryState(status: GlossaryStatus.ready, glossaries: next));
    try {
      await _repository.save(next, deleted: deleted);
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
    }
  }
}
