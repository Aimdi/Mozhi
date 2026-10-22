import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/models/history_entry.dart';

/// Where the phrasebook reads the built-in Favorites collection from: the
/// favourites of the history. Nothing is copied: the phrasebook only reads
/// them, and taking a phrase out of Favorites un-stars it in the history.
abstract interface class PhrasebookFavorites {
  /// The favourites, newest first. Empty while the history cannot be read.
  Future<List<HistoryEntry>> favorites();

  /// Fires when the favourites change.
  Stream<void> get changes;

  /// Takes the history entry [historyId] out of the favourites.
  Future<void> remove(String historyId);

  /// Undoes [remove] of [historyId]: the entry is a favourite again (put
  /// back when un-starring deleted it). Does nothing for an id [remove]
  /// was not called with.
  Future<void> restore(String historyId);
}

/// [PhrasebookFavorites] of the app-wide [HistoryCubit]: its favourites
/// once the history is loaded (waiting at most [loadTimeout] for a load
/// in progress or not started yet), and its stream for [changes] (only
/// when the favourites change, not for every new translation).
class HistoryCubitFavorites implements PhrasebookFavorites {
  new(this._cubit, {this.loadTimeout = const Duration(seconds: 10)});

  final HistoryCubit _cubit;

  /// How long [favorites] waits for the history to load.
  final Duration loadTimeout;

  /// Entries taken out by [remove], for [restore].
  final Map<String, HistoryEntry> _removed = {};

  static List<HistoryEntry> _favoritesOf(HistoryState state) =>
      List.unmodifiable(state.entries.where((entry) => entry.isFavorite));

  static bool _loading(HistoryState state) =>
      state.status == HistoryStatus.initial ||
      state.status == HistoryStatus.loading;

  @override
  Future<List<HistoryEntry>> favorites() async {
    var state = _cubit.state;
    if (_loading(state) && !_cubit.isClosed) {
      try {
        state = await _cubit.stream
            .firstWhere((state) => !_loading(state))
            .timeout(loadTimeout);
      } on Object {
        state = _cubit.state;
      }
    }
    return _favoritesOf(state);
  }

  @override
  Stream<void> get changes {
    var last = _favoritesOf(_cubit.state);
    return _cubit.stream
        .where((state) {
          final next = _favoritesOf(state);
          if (listEquals(next, last)) return false;
          last = next;
          return true;
        })
        .map<void>((_) {});
  }

  @override
  Future<void> remove(String historyId) async {
    final entry = _cubit.state.entries
        .where((entry) => entry.id == historyId && entry.isFavorite)
        .firstOrNull;
    if (entry == null) return;
    _removed[historyId] = entry;
    await _cubit.toggleFavorite(historyId);
  }

  @override
  Future<void> restore(String historyId) async {
    final entry = _removed.remove(historyId);
    if (entry == null) return;
    await _cubit.restoreFavorite(entry);
  }
}
