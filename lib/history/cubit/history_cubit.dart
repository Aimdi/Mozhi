import 'package:bloc/bloc.dart';
import 'package:mozhi/history/cubit/history_state.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/history/models/history_entry.dart';

export 'history_state.dart';

/// Exposes the local translation history. `repository` defaults to a
/// [HistoryRepository] backed by the platform preferences.
///
/// Retention (history auto-delete): `maxAge` is the initial maximum age of
/// non-favourite entries (null keeps them forever). It is applied by
/// [load], [add] and [importJson]; [applyRetention] changes it and deletes
/// expired entries right away. Favourites are always kept.
///
/// Incognito ([setIncognito], [HistoryState.incognito], kept in step with
/// the settings by `HistoryRetentionListener`): [add] ignores entries that
/// are not favourites, so no automatic history is written whichever screen
/// translates. Starring a translation is an explicit save and still works.
///
/// Storage errors of [load] switch to [HistoryStatus.failure], history that
/// cannot be decrypted to [HistoryStatus.unreadable] (see
/// [discardUnreadable]); errors of the other mutations keep the current
/// state. Storage errors are reported via `addError` and never thrown,
/// except by [exportJson] / [importJson] / [deleteAll] whose callers need to
/// show the outcome.
class HistoryCubit extends Cubit<HistoryState> {
  new({HistoryRepository? repository, this._maxAge, bool incognito = false})
    : _repository = repository ?? HistoryRepository(),
      super(HistoryState(incognito: incognito));

  final HistoryRepository _repository;

  /// Maximum age of non-favourite entries; null keeps them forever.
  Duration? _maxAge;

  Future<void> load() async {
    emit(state.copyWith(status: HistoryStatus.loading));
    try {
      final entries = await _repository.load(maxAge: _maxAge);
      _emitEntries(entries);
    } on HistoryUnreadableException {
      if (!isClosed) {
        emit(state.copyWith(status: HistoryStatus.unreadable, entries: []));
      }
    } on Object catch (error, stackTrace) {
      if (!isClosed) emit(state.copyWith(status: HistoryStatus.failure));
      addError(error, stackTrace);
    }
  }

  /// Saves [entry] (see [HistoryRepository.add]); ignored while
  /// [HistoryState.incognito] unless it is a favourite.
  Future<void> add(HistoryEntry entry) async {
    if (state.incognito && !entry.isFavorite) return;
    await _run(() => _repository.add(entry, maxAge: _maxAge));
  }

  /// Turns incognito on or off: while on, [add] only saves favourites.
  void setIncognito({required bool enabled}) =>
      emit(state.copyWith(incognito: enabled));

  /// Sets the history that cannot be decrypted aside and starts a new one
  /// (see [HistoryRepository.discardUnreadable]).
  Future<void> discardUnreadable() async {
    try {
      _emitEntries(await _repository.discardUnreadable());
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
    }
  }

  /// Deletes the history, any copy set aside and its encryption key
  /// ([HistoryRepository.deleteAll]). Throws storage errors: the caller
  /// reports them.
  Future<void> deleteAll() async {
    await _repository.deleteAll();
    if (!isClosed) {
      emit(state.copyWith(status: HistoryStatus.ready, entries: []));
    }
  }

  /// Keeps non-favourite entries for at most [maxAge] (null: forever) from
  /// now on, and deletes the ones that are already older.
  Future<void> applyRetention(Duration? maxAge) async {
    _maxAge = maxAge;
    if (maxAge == null) return;
    await _run(() => _repository.prune(maxAge));
  }

  /// Puts a deleted [entry] back at its original position (use this to
  /// undo [delete]; see [HistoryRepository.restore]).
  Future<void> restore(HistoryEntry entry) =>
      _run(() => _repository.restore(entry));

  Future<void> toggleFavorite(String id) =>
      _run(() => _repository.toggleFavorite(id));

  Future<void> delete(String id) => _run(() => _repository.delete(id));

  Future<void> clear({bool keepFavorites = false}) =>
      _run(() => _repository.clear(keepFavorites: keepFavorites));

  /// Filters [HistoryState.visible] (case-insensitive).
  void search(String query) => emit(state.copyWith(query: query));

  void setFavoritesOnly({required bool enabled}) =>
      emit(state.copyWith(favoritesOnly: enabled));

  /// Shows only the entries of [pair] (null: every pair).
  void filterByPair(HistoryPair? pair) =>
      emit(state.copyWith(pair: () => pair));

  /// Shows only the entries whose text went to [destination] (null:
  /// anywhere).
  void filterByDestination(HistoryDestination? destination) =>
      emit(state.copyWith(destination: () => destination));

  /// Clears the language pair and destination filters (not the search or
  /// the favourites tab).
  void clearFilters() =>
      emit(state.copyWith(pair: () => null, destination: () => null));

  /// Pretty JSON of all entries (see [HistoryRepository.exportJson]).
  // Returns the export for the caller to save or share; it is not state.
  // ignore: prefer_void_public_cubit_methods
  Future<String> exportJson() => _repository.exportJson();

  /// Merges [json] into the history and returns what was imported (e.g.
  /// how many entries the retention left out, see [HistoryImport]). Throws
  /// [FormatException] on invalid input (the state is left unchanged).
  // Returns the outcome for the caller to report; the entries are emitted.
  // ignore: prefer_void_public_cubit_methods
  Future<HistoryImport> importJson(String json) async {
    final result = await _repository.importJson(json, maxAge: _maxAge);
    _emitEntries(result.entries);
    return result;
  }

  Future<void> _run(Future<List<HistoryEntry>> Function() action) async {
    try {
      _emitEntries(await action());
    } on HistoryUnreadableException {
      // Nothing may overwrite it: the state says so already, or will once
      // the history is loaded.
      if (!isClosed && state.status != HistoryStatus.unreadable) {
        emit(state.copyWith(status: HistoryStatus.unreadable, entries: []));
      }
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
    }
  }

  void _emitEntries(List<HistoryEntry> entries) {
    if (isClosed) return;
    emit(state.copyWith(status: HistoryStatus.ready, entries: entries));
  }
}
