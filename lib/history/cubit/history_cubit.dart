import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:mozhi/history/cubit/history_state.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/history/models/history_entry.dart';

export 'history_state.dart';

/// Exposes the local history of translations and dictionary look-ups
/// ([HistoryEntry.kind]). `repository` defaults to a [HistoryRepository]
/// backed by the platform preferences.
///
/// Retention (history auto-delete): `maxAge` is the initial maximum age of
/// non-favourite entries (null keeps them forever). It is applied by
/// [load], [add] and [importJson]; [applyRetention] changes it and deletes
/// expired entries right away. Favourites are always kept.
///
/// Paused history ([HistoryState.paused]: incognito, [setIncognito], or
/// "Save history" off, [setSaveHistory]; both kept in step with the
/// settings by `HistoryRetentionListener`): [add] ignores entries that are
/// not favourites, so no automatic history is written whichever screen
/// translates or looks a word up. Starring a translation (or a dictionary
/// entry) is an explicit save and still works, but only as a favourite
/// ([HistoryEntry.favoriteOnly]): un-starring it later deletes it rather
/// than leaving an ordinary entry made while history was paused.
///
/// Storage errors of [load] switch to [HistoryStatus.failure], history that
/// cannot be decrypted to [HistoryStatus.unreadable] (see
/// [discardUnreadable]); errors of the other mutations keep the current
/// state. Storage errors are reported via `addError` and never thrown,
/// except by [exportJson] / [importJson] / [deleteAll] whose callers need to
/// show the outcome.
class HistoryCubit extends Cubit<HistoryState> {
  new({
    HistoryRepository? repository,
    this._maxAge,
    bool incognito = false,
    bool saveHistory = true,
  }) : _repository = repository ?? HistoryRepository(),
       super(HistoryState(incognito: incognito, saveHistory: saveHistory));

  final HistoryRepository _repository;

  /// Maximum age of non-favourite entries; null keeps them forever.
  Duration? _maxAge;

  /// Whether the entries are dropped from memory while the app is locked
  /// ([forgetForLock]).
  bool _forgotten = false;

  Future<void> load() async {
    // Read again once the app is unlocked (reloadAfterLock).
    if (_forgotten) return;
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

  /// Reads the history again without the loading state, e.g. when the app
  /// comes back to the front: another window of the app (Android's quick
  /// translate window, another browser tab) may have saved entries
  /// meanwhile. Only once the history is shown ([HistoryStatus.ready]) and
  /// not while the app is locked ([forgetForLock]). Errors keep the shown
  /// history.
  Future<void> refresh() async {
    if (_forgotten || isClosed || state.status != HistoryStatus.ready) return;
    try {
      _emitEntries(await _repository.load(maxAge: _maxAge));
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
    }
  }

  /// Saves [entry] (see [HistoryRepository.add]). While history is
  /// [HistoryState.paused] only a favourite is saved, as kept only as a
  /// favourite ([HistoryEntry.favoriteOnly]).
  Future<void> add(HistoryEntry entry) async {
    var saved = entry;
    if (state.paused) {
      if (!entry.isFavorite) return;
      saved = entry.copyWith(favoriteOnly: true);
    }
    await _run(() => _repository.add(saved, maxAge: _maxAge));
  }

  /// The app lock engaged: the entries leave memory, here and in the
  /// repository's decrypted copy ([HistoryRepository.forgetCache]); the
  /// history stays on disk. Until [reloadAfterLock], [HistoryState.entries]
  /// is empty and what is saved meanwhile ([add], ...) is written without
  /// coming back into memory; [load] waits for the unlock.
  Future<void> forgetForLock() async {
    if (isClosed) return;
    _forgotten = true;
    if (state.entries.isNotEmpty) emit(state.copyWith(entries: const []));
    await _forgetCache();
  }

  /// The app was unlocked after [forgetForLock]: reads the history again.
  Future<void> reloadAfterLock() async {
    if (!_forgotten || isClosed) return;
    _forgotten = false;
    await load();
  }

  Future<void> _forgetCache() async {
    try {
      await _repository.forgetCache();
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
    }
  }

  /// Turns incognito on or off: while on, [add] only saves favourites.
  void setIncognito({required bool enabled}) =>
      emit(state.copyWith(incognito: enabled));

  /// Follows "Save history": while off, [add] only saves favourites (as
  /// in incognito).
  void setSaveHistory({required bool enabled}) =>
      emit(state.copyWith(saveHistory: enabled));

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
  /// now on, and deletes the ones that are already older. While the app is
  /// locked ([forgetForLock]) the history is not read for it: the reload
  /// after the unlock deletes them ([load] applies [maxAge]).
  Future<void> applyRetention(Duration? maxAge) async {
    _maxAge = maxAge;
    if (maxAge == null || _forgotten) return;
    await _run(() => _repository.prune(maxAge));
  }

  /// Puts a deleted [entry] back at its original position (use this to
  /// undo [delete]; see [HistoryRepository.restore]).
  Future<void> restore(HistoryEntry entry) =>
      _run(() => _repository.restore(entry));

  /// Undoes taking [entry] out of the favourites: stars the entry as it is
  /// now, or puts [entry] back when it is gone (see
  /// [HistoryRepository.restoreFavorite]).
  Future<void> restoreFavorite(HistoryEntry entry) =>
      _run(() => _repository.restoreFavorite(entry));

  /// Stars or un-stars the entry [id] (un-starring an entry kept only as a
  /// favourite deletes it, see [HistoryRepository.toggleFavorite]).

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
    if (_forgotten) {
      // Written while locked: kept on disk only.
      unawaited(_forgetCache());
      return;
    }
    emit(state.copyWith(status: HistoryStatus.ready, entries: entries));
  }
}
