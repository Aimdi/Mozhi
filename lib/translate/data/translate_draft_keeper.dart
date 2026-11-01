import 'dart:async';

import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';

/// Keeps the Translate input (the draft) across the app being ended in the
/// background (Android ends apps it needs the memory of; a web page may be
/// reloaded): [save] when the app goes to the background, [restore] on a
/// cold start. The languages are kept by the settings already.
///
/// The draft is stored like the history ([HistoryRepository.saveDraft]:
/// encrypted with its key) and follows its rules: while the history is
/// paused ([HistoryState.paused]: incognito, or "Save history" off) no
/// draft is kept, and one kept before is deleted. Clearing the input
/// deletes it right away. Text from outside the app (a share, a link)
/// wins over the draft ([TranslateCubit.restoreDraft]).
///
/// Storage errors are ignored: the draft is a convenience.
class TranslateDraftKeeper {
  new({required this.translate, required this.history, required this.store});

  final TranslateCubit translate;
  final HistoryCubit history;
  final HistoryRepository store;

  StreamSubscription<TranslateState>? _cleared;

  /// Deletes the draft whenever the input that had text is cleared (not
  /// for the empty input of the start, before [restore] put it back).
  void start() {
    if (_cleared != null) return;
    var empty = translate.state.input.trim().isEmpty;
    _cleared = translate.stream.listen((state) {
      final wasEmpty = empty;
      empty = state.input.trim().isEmpty;
      if (empty && !wasEmpty) unawaited(_quietly(store.deleteDraft));
    });
  }

  /// Keeps the current input as the draft (deletes it for a blank input or
  /// while the history is paused).
  Future<void> save() {
    final text = translate.state.input;
    return _quietly(
      () => text.trim().isEmpty || history.state.paused
          ? store.deleteDraft()
          : store.saveDraft(text),
    );
  }

  /// Puts the kept draft back into the empty input (see
  /// [TranslateCubit.restoreDraft]); while the history is paused it is
  /// deleted instead.
  Future<void> restore() => _quietly(() async {
    if (history.state.paused) return await store.deleteDraft();
    final text = await store.readDraft();
    if (text != null) translate.restoreDraft(text);
  });

  void dispose() {
    unawaited(_cleared?.cancel());
    _cleared = null;
  }

  static Future<void> _quietly(Future<void> Function() action) async {
    try {
      await action();
    } on Object {
      // Kept or not, the app goes on.
    }
  }
}
