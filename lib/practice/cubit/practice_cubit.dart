import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:mozhi/practice/cubit/practice_state.dart';
import 'package:mozhi/practice/data/answer_check.dart';
import 'package:mozhi/practice/data/fsrs.dart';
import 'package:mozhi/practice/data/practice_repository.dart';
import 'package:mozhi/practice/models/practice_card.dart';
import 'package:mozhi/practice/models/practice_item.dart';
import 'package:mozhi/practice/models/practice_settings.dart';

export 'practice_state.dart';

/// Practice: the overview of what is due ([load]), the settings, and
/// review sessions ([start]): each card's front, then the answer
/// ([reveal], or [checkTypedAnswer] for a typed one), then a rating
/// ([rate]) that the FSRS scheduler turns into the next due date, shown
/// on each rating button beforehand ([PracticeState.intervals]). [undo]
/// takes the last rating back.
///
/// A session holds the cards due at its start: learning cards first
/// (also those due within [learnAhead]), then reviews (oldest due first),
/// then the new cards the daily limit allows (one per phrase), at most
/// [sessionLimit] in all (more can follow in another session). A card
/// whose next step falls within [learnAhead] comes back later in the
/// session. Nothing is ever counted against the user: no streaks, no
/// overdue piles in red.
///
/// [appLanguage] is the app's language (which side of each phrase is the
/// user's, see `userLanguageOf`); [onlyCollection] practises one
/// collection whatever the settings say.
class PracticeCubit extends Cubit<PracticeState> {
  new({
    required this._repository,
    required this.appLanguage,
    this.onlyCollection,
    this.sessionLimit = 50,
    this.learnAhead = const Duration(minutes: 20),
    DateTime Function()? clock,
    FsrsScheduler Function(PracticeSettings settings)? scheduler,
  }) : _clock = clock ?? DateTime.now,
       _schedulerOf = scheduler ?? _defaultScheduler,
       super(const PracticeState());

  final PracticeRepository _repository;
  final String appLanguage;
  final String? onlyCollection;

  /// The most cards a session starts with.
  final int sessionLimit;

  /// How early learning cards may be shown again.
  final Duration learnAhead;
  final DateTime Function() _clock;
  final FsrsScheduler Function(PracticeSettings settings) _schedulerOf;
  final List<_Undo> _undo = [];
  StreamSubscription<void>? _phrasebookChanges;

  static FsrsScheduler _defaultScheduler(PracticeSettings settings) =>
      FsrsScheduler(desiredRetention: settings.desiredRetention);

  FsrsScheduler get _scheduler => _schedulerOf(state.settings);

  /// Reads the deck (and keeps the overview up to date with the
  /// phrasebook while it shows).
  Future<void> load() async {
    _phrasebookChanges ??= _repository.phrasebook.changes.listen((_) {
      if (state.status == PracticeStatus.ready) unawaited(_reload());
    });
    if (isClosed) return;
    emit(state.copyWith(status: PracticeStatus.loading));
    await _reload();
  }

  Future<void> _reload() async {
    try {
      final settings = await _repository.settings();
      final deck = await _repository.deck(
        appLanguage: appLanguage,
        settings: settings,
        onlyCollection: onlyCollection,
      );
      if (isClosed) return;
      emit(
        state.copyWith(
          status: state.status == PracticeStatus.reviewing
              ? PracticeStatus.reviewing
              : state.status == PracticeStatus.finished
              ? PracticeStatus.finished
              : PracticeStatus.ready,
          deck: deck,
          settings: settings,
        ),
      );
    } on PracticeUnreadableException {
      if (!isClosed) emit(state.copyWith(status: PracticeStatus.unreadable));
    } on Object catch (error, stackTrace) {
      if (!isClosed) emit(state.copyWith(status: PracticeStatus.failure));
      addError(error, stackTrace);
    }
  }

  /// Stores [settings] and reads the deck again.
  Future<void> updateSettings(PracticeSettings settings) async {
    if (isClosed) return;
    emit(state.copyWith(settings: settings));
    try {
      await _repository.saveSettings(settings);
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
    }
    await _reload();
  }

  /// Sets the unreadable progress aside and starts over.
  Future<void> startOver() async {
    try {
      await _repository.discardUnreadable();
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
    }
    await load();
  }

  /// Starts a session with the cards due now (see the class docs); with
  /// none, it is [PracticeStatus.finished] at once.
  Future<void> start() async {
    await _reload();
    final deck = state.deck;
    if (isClosed ||
        deck == null ||
        (state.status != PracticeStatus.ready &&
            state.status != PracticeStatus.finished)) {
      return;
    }
    final now = _clock();
    final soon = now.add(learnAhead);
    final learning = [
      for (final item in deck.items)
        if (!item.card.isNew &&
            item.card.fsrs.state != FsrsState.review &&
            !item.card.fsrs.due.isAfter(soon))
          item,
    ]..sort(_byDue);
    final reviews = [
      for (final item in deck.items)
        if (item.card.fsrs.state == FsrsState.review && item.card.isDue(now))
          item,
    ]..sort(_byDue);
    // A phrase is asked once a session: its new sibling waits.
    final fresh = deck.newCards(
      except: {
        for (final item in [...learning, ...reviews]) item.phrase.id,
      },
    );
    final queue = [
      ...learning,
      ...[
        ...reviews,
        ...fresh,
      ].take((sessionLimit - learning.length).clamp(0, sessionLimit)),
    ];
    _undo.clear();
    _show(
      queue,
      status: queue.isEmpty
          ? PracticeStatus.finished
          : PracticeStatus.reviewing,
      stats: const PracticeStats(),
    );
  }

  static int _byDue(PracticeItem a, PracticeItem b) =>
      a.card.fsrs.due.compareTo(b.card.fsrs.due);

  /// Shows the answer of the current card.
  void reveal() {
    if (state.status != PracticeStatus.reviewing || state.revealed) return;
    emit(state.copyWith(revealed: true));
  }

  /// Compares the typed [answer] with the current card's expected text and
  /// shows the answer.
  void checkTypedAnswer(String answer) {
    final item = state.current;
    if (state.status != PracticeStatus.reviewing || item == null) return;
    emit(
      state.copyWith(
        revealed: true,
        typedCheck: () => checkAnswer(
          expected: item.foreignText,
          answer: answer,
          languageCode: item.foreignCode,
        ),
      ),
    );
  }

  /// Rates the current card (also before its answer shows: a keyboard
  /// user who knows it) and moves on.
  Future<void> rate(FsrsRating rating) async {
    final item = state.current;
    if (state.status != PracticeStatus.reviewing || item == null) return;
    final now = _clock();
    final next = _scheduler.preview(
      item.card.fsrs,
      now,
      seed: _seedOf(item.card),
    )[rating]!;
    final card = item.card.reviewed(rating, next, now);
    _undo.add(_Undo(item: item, queue: state.queue, stats: state.stats));
    final rest = [...state.queue.skip(1)];
    if (!next.due.isAfter(now.add(learnAhead))) rest.add(item.withCard(card));
    _show(
      rest,
      status: rest.isEmpty ? PracticeStatus.finished : PracticeStatus.reviewing,
      stats: state.stats.add(rating, wasNew: item.card.isNew),
    );
    await _save(card);
    // The summary tells when the next cards are due.
    if (rest.isEmpty) await _reload();
  }

  /// Takes the last rating back: the card shows again as it was.
  Future<void> undo() async {
    if (_undo.isEmpty || isClosed) return;
    final last = _undo.removeLast();
    _show(last.queue, status: PracticeStatus.reviewing, stats: last.stats);
    final previous = last.item.card;
    await _save(previous.isNew ? previous : previous.touched(_clock()));
  }

  /// Ends the session early (its reviews are kept).
  void finish() {
    if (state.status != PracticeStatus.reviewing) return;
    _undo.clear();
    emit(state.copyWith(status: PracticeStatus.finished, canUndo: false));
    unawaited(_reload());
  }

  /// Back to the overview.
  Future<void> backToOverview() async {
    _undo.clear();
    if (isClosed) return;
    emit(
      state.copyWith(
        status: PracticeStatus.ready,
        queue: const [],
        revealed: false,
        canUndo: false,
      ),
    );
    await _reload();
  }

  void _show(
    List<PracticeItem> queue, {
    required PracticeStatus status,
    required PracticeStats stats,
  }) {
    if (isClosed) return;
    final current = queue.firstOrNull;
    emit(
      state.copyWith(
        status: status,
        queue: List.unmodifiable(queue),
        revealed: false,
        intervals: current == null ? const {} : _intervalsOf(current),
        typedCheck: () => null,
        canUndo: _undo.isNotEmpty,
        stats: stats,
      ),
    );
  }

  Map<FsrsRating, Duration> _intervalsOf(PracticeItem item) {
    final now = _clock();
    return {
      for (final MapEntry(:key, :value)
          in _scheduler
              .preview(item.card.fsrs, now, seed: _seedOf(item.card))
              .entries)
        key: value.due.difference(now),
    };
  }

  Future<void> _save(PracticeCard card) async {
    try {
      await _repository.saveCard(card);
    } on Object catch (error, stackTrace) {
      if (!isClosed && !state.saveFailed) {
        emit(state.copyWith(saveFailed: true));
      }
      addError(error, stackTrace);
    }
  }

  /// The fuzz seed of [card]'s next review: the same while it waits, so
  /// the interval shown is the one applied (FNV-1a of the id and the
  /// review count).
  static int _seedOf(PracticeCard card) {
    var hash = 0x811c9dc5;
    for (final unit in '${card.id}/${card.reps}'.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0x7fffffff;
    }
    return hash;
  }

  @override
  Future<void> close() async {
    await _phrasebookChanges?.cancel();
    await super.close();
  }
}

/// What [PracticeCubit.undo] puts back.
final class _Undo {
  const new({required this.item, required this.queue, required this.stats});

  /// The card as it was before the rating.
  final PracticeItem item;
  final List<PracticeItem> queue;
  final PracticeStats stats;
}
