import 'package:bloc/bloc.dart';
import 'package:mozhi/history/cubit/history_state.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/history/models/history_entry.dart';

export 'history_state.dart';

/// Exposes the local translation history. `repository` defaults to a
/// [HistoryRepository] backed by the platform preferences.
///
/// Storage errors of [load] switch to [HistoryStatus.failure]; errors of the
/// other mutations keep the current state. All of them are reported via
/// `addError` and never thrown, except [exportJson] / [importJson] whose
/// callers need to show the outcome.
class HistoryCubit extends Cubit<HistoryState> {
  new({HistoryRepository? repository})
    : _repository = repository ?? HistoryRepository(),
      super(const HistoryState());

  final HistoryRepository _repository;

  Future<void> load() async {
    emit(state.copyWith(status: HistoryStatus.loading));
    try {
      final entries = await _repository.load();
      _emitEntries(entries);
    } on Object catch (error, stackTrace) {
      if (!isClosed) emit(state.copyWith(status: HistoryStatus.failure));
      addError(error, stackTrace);
    }
  }

  Future<void> add(HistoryEntry entry) => _run(() => _repository.add(entry));

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

  /// Pretty JSON of all entries (see [HistoryRepository.exportJson]).
  // Returns the export for the caller to save or share; it is not state.
  // ignore: prefer_void_public_cubit_methods
  Future<String> exportJson() => _repository.exportJson();

  /// Merges [json] into the history. Throws [FormatException] on invalid
  /// input (the state is left unchanged).
  Future<void> importJson(String json) async {
    final entries = await _repository.importJson(json);
    _emitEntries(entries);
  }

  Future<void> _run(Future<List<HistoryEntry>> Function() action) async {
    try {
      _emitEntries(await action());
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
    }
  }

  void _emitEntries(List<HistoryEntry> entries) {
    if (isClosed) return;
    emit(state.copyWith(status: HistoryStatus.ready, entries: entries));
  }
}
