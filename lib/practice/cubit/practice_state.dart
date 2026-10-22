import 'package:equatable/equatable.dart';
import 'package:mozhi/practice/data/answer_check.dart';
import 'package:mozhi/practice/data/fsrs.dart';
import 'package:mozhi/practice/data/practice_repository.dart';
import 'package:mozhi/practice/models/practice_item.dart';
import 'package:mozhi/practice/models/practice_settings.dart';

/// Where practice is.
enum PracticeStatus {
  /// Reading the phrasebook and the progress.
  loading,

  /// The overview: what is due, the collections and settings, Start.
  ready,

  /// A review session ([PracticeState.current]).
  reviewing,

  /// The session is over ([PracticeState.stats]).
  finished,

  /// The stored progress cannot be decrypted (start over or wait).
  unreadable,

  /// Reading failed.
  failure,
}

/// What a session did: the cards reviewed by rating, and the new ones.
final class PracticeStats extends Equatable {
  const new({this.ratings = const {}, this.newCards = 0});

  /// How many reviews got each rating.
  final Map<FsrsRating, int> ratings;

  /// How many of them were new cards.
  final int newCards;

  /// How many reviews there were.
  int get reviewed => ratings.values.fold(0, (sum, count) => sum + count);

  /// How many reviews were not Again.
  int get remembered => reviewed - (ratings[FsrsRating.again] ?? 0);

  PracticeStats add(FsrsRating rating, {required bool wasNew}) => PracticeStats(
    ratings: {...ratings, rating: (ratings[rating] ?? 0) + 1},
    newCards: newCards + (wasNew ? 1 : 0),
  );

  @override
  List<Object?> get props => [ratings, newCards];
}

/// The state of `PracticeCubit`: the [deck] and, in a session, the cards
/// left ([queue], [current] first), whether the answer shows and what
/// each rating would schedule.
final class PracticeState extends Equatable {
  const new({
    this.status = PracticeStatus.loading,
    this.deck,
    this.settings = const PracticeSettings(),
    this.queue = const [],
    this.revealed = false,
    this.intervals = const {},
    this.typedCheck,
    this.canUndo = false,
    this.stats = const PracticeStats(),
    this.saveFailed = false,
  });

  final PracticeStatus status;

  /// The phrasebook as practice sees it (null while loading).
  final PracticeDeck? deck;
  final PracticeSettings settings;

  /// The session's cards still to review, [current] first.
  final List<PracticeItem> queue;

  /// Whether the answer of [current] shows.
  final bool revealed;

  /// What each rating would schedule [current] in.
  final Map<FsrsRating, Duration> intervals;

  /// The typed answer compared with the expected one.
  final AnswerCheck? typedCheck;

  /// Whether the last rating can be undone.
  final bool canUndo;

  /// What the session did so far.
  final PracticeStats stats;

  /// Whether storing a review failed (it counts for the session only).
  final bool saveFailed;

  /// The card shown, in a session.
  PracticeItem? get current => queue.firstOrNull;

  PracticeState copyWith({
    PracticeStatus? status,
    PracticeDeck? deck,
    PracticeSettings? settings,
    List<PracticeItem>? queue,
    bool? revealed,
    Map<FsrsRating, Duration>? intervals,
    AnswerCheck? Function()? typedCheck,
    bool? canUndo,
    PracticeStats? stats,
    bool? saveFailed,
  }) => PracticeState(
    status: status ?? this.status,
    deck: deck ?? this.deck,
    settings: settings ?? this.settings,
    queue: queue ?? this.queue,
    revealed: revealed ?? this.revealed,
    intervals: intervals ?? this.intervals,
    typedCheck: typedCheck != null ? typedCheck() : this.typedCheck,
    canUndo: canUndo ?? this.canUndo,
    stats: stats ?? this.stats,
    saveFailed: saveFailed ?? this.saveFailed,
  );

  @override
  List<Object?> get props => [
    status,
    deck,
    settings,
    queue,
    revealed,
    intervals,
    typedCheck,
    canUndo,
    stats,
    saveFailed,
  ];
}
