import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:mozhi/phrasebook/cubit/phrasebook_state.dart';
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';

export 'phrasebook_state.dart';

/// The phrasebook screen: every collection and phrase of the
/// [PhrasebookRepository] (read again whenever it changes), the collection
/// shown ([select]) and how its phrases are searched, filtered and sorted.
///
/// Changes go to the repository (the screen calls it); its `changes`
/// bring them here. [reorder] also moves the collection in the state right
/// away, so the list does not jump back while it is saved.
class PhrasebookCubit extends Cubit<PhrasebookState> {
  new({required this._repository, String? initialCollectionId})
    : super(PhrasebookState(selectedId: initialCollectionId)) {
    _subscription = _repository.changes.listen((_) => unawaited(load()));
  }

  final PhrasebookRepository _repository;
  late final StreamSubscription<void> _subscription;

  /// Loads in progress: only the newest one's result is shown.
  int _loads = 0;

  /// Reads every collection and phrase.
  Future<void> load() async {
    final load = ++_loads;
    try {
      final collections = await _repository.collections();
      final phrases = await _repository.phrases();
      if (isClosed || load != _loads) return;
      final selected = state.selectedId;
      emit(
        state.copyWith(
          status: PhrasebookStatus.ready,
          collections: collections,
          phrases: {for (final phrase in phrases) phrase.id: phrase},
          // A collection deleted elsewhere is no longer shown.
          selectedId:
              selected == null || collections.any((c) => c.id == selected)
              ? null
              : () => null,
        ),
      );
    } on PhrasebookUnreadableException {
      if (isClosed || load != _loads) return;
      emit(
        state.copyWith(
          status: PhrasebookStatus.unreadable,
          collections: const [],
          phrases: const {},
        ),
      );
    } on Object catch (error, stackTrace) {
      if (isClosed || load != _loads) return;
      emit(state.copyWith(status: PhrasebookStatus.failure));
      addError(error, stackTrace);
    }
  }

  /// Shows the collection [id] (null: the list of collections), with no
  /// search or filter.
  void select(String? id) => emit(
    state.copyWith(
      selectedId: () => id,
      query: '',
      pair: () => null,
      sort: PhraseSort.recent,
    ),
  );

  /// Filters the shown collection's phrases.
  void search(String query) => emit(state.copyWith(query: query));

  /// Shows only the phrases of [pair] (null: every pair).
  void filterByPair(PhrasePair? pair) => emit(state.copyWith(pair: () => pair));

  void sortBy(PhraseSort sort) => emit(state.copyWith(sort: sort));

  /// Moves the user's collection at [from] to [to] (indexes among
  /// [PhrasebookState.userCollections], [to] after the removal) and saves
  /// the order.
  Future<void> reorder(int from, int to) async {
    final user = [...state.userCollections];
    if (from < 0 || from >= user.length) return;
    final moved = user.removeAt(from);
    user.insert(to.clamp(0, user.length), moved);
    final others = state.collections.where((c) => !c.isEditable).toList();
    emit(
      state.copyWith(
        collections: [
          ...others.where((c) => c.isFavorites),
          ...user,
          ...others.where((c) => !c.isFavorites),
        ],
      ),
    );
    try {
      await _repository.reorderCollections([for (final c in user) c.id]);
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
      await load();
    }
  }

  /// Sets the phrasebook that cannot be decrypted aside and starts a new
  /// one.
  Future<void> discardUnreadable() async {
    try {
      await _repository.discardUnreadable();
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
    }
    await load();
  }

  @override
  Future<void> close() async {
    await _subscription.cancel();
    await super.close();
  }
}
