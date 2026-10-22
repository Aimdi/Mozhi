import 'package:equatable/equatable.dart';
import 'package:mozhi/practice/data/fsrs.dart';

/// Which way a card asks for a phrase.
enum CardDirection {
  /// See the foreign text, recall what it means.
  recognize('r'),

  /// See your language, say or type the foreign text.
  produce('p');

  new(this.key);

  /// How the direction is stored (and the end of [PracticeCard.id]).
  final String key;

  static CardDirection? fromKey(Object? key) {
    for (final direction in values) {
      if (direction.key == key) return direction;
    }
    return null;
  }
}

/// One flashcard: a phrase of the phrasebook ([phraseId]) asked in one
/// [direction], with its FSRS memory state ([fsrs]). The texts are read
/// from the phrase each time, so a card follows the phrase's edits.
final class PracticeCard extends Equatable {
  const new({
    required this.phraseId,
    required this.direction,
    required this.fsrs,
    required this.createdAt,
    required this.updatedAt,
    this.reps = 0,
    this.lapses = 0,
    this.firstReviewedAt,
  });

  /// A new card for [phraseId] asked in [direction], due at [now].
  new fresh(this.phraseId, this.direction, DateTime now)
    : fsrs = FsrsCard.fresh(now),
      createdAt = now.toUtc(),
      updatedAt = now.toUtc(),
      reps = 0,
      lapses = 0,
      firstReviewedAt = null;

  /// Reads [toJson]'s output. Throws [FormatException] when it is not a
  /// card.
  factory fromJson(Map<String, Object?> json) {
    final phraseId = json['phrase'];
    final direction = CardDirection.fromKey(json['direction']);
    final fsrs = json['fsrs'];
    final createdAt = _date(json['createdAt']);
    if (phraseId is! String ||
        phraseId.isEmpty ||
        direction == null ||
        fsrs is! Map<String, Object?> ||
        createdAt == null) {
      throw FormatException('Not a practice card', json);
    }
    return PracticeCard(
      phraseId: phraseId,
      direction: direction,
      fsrs: FsrsCard.fromJson(fsrs),
      createdAt: createdAt,
      updatedAt: _date(json['updatedAt']) ?? createdAt,
      reps: (json['reps'] as num?)?.toInt() ?? 0,
      lapses: (json['lapses'] as num?)?.toInt() ?? 0,
      firstReviewedAt: _date(json['firstReviewedAt']),
    );
  }

  /// The id of the card for [phraseId] in [direction].
  static String idOf(String phraseId, CardDirection direction) =>
      '$phraseId#${direction.key}';

  /// The phrase it asks for (`Phrase.id`).
  final String phraseId;
  final CardDirection direction;
  final FsrsCard fsrs;
  final DateTime createdAt;

  /// When it was last reviewed (or created): the newer copy wins when
  /// backups and devices are merged.
  final DateTime updatedAt;

  /// How many times it was reviewed.
  final int reps;

  /// How many times it was forgotten (Again) once learned.
  final int lapses;

  /// When it was first reviewed: new cards per day count by it.
  final DateTime? firstReviewedAt;

  /// Unique per phrase and direction.
  String get id => idOf(phraseId, direction);

  /// Whether it was never reviewed.
  bool get isNew => fsrs.isNew;

  /// Whether it is due for review at [now] (new cards are not: they are
  /// introduced up to the daily limit).
  bool isDue(DateTime now) => !isNew && !fsrs.due.isAfter(now);

  /// The card after a review with [rating] that gave it [next] at [now].
  PracticeCard reviewed(FsrsRating rating, FsrsCard next, DateTime now) =>
      PracticeCard(
        phraseId: phraseId,
        direction: direction,
        fsrs: next,
        createdAt: createdAt,
        updatedAt: now.toUtc(),
        reps: reps + 1,
        lapses: fsrs.state == FsrsState.review && rating == FsrsRating.again
            ? lapses + 1
            : lapses,
        firstReviewedAt: firstReviewedAt ?? now.toUtc(),
      );

  /// This card's content, changed at [time] (e.g. put back by undo).
  PracticeCard touched(DateTime time) => PracticeCard(
    phraseId: phraseId,
    direction: direction,
    fsrs: fsrs,
    createdAt: createdAt,
    updatedAt: time.toUtc(),
    reps: reps,
    lapses: lapses,
    firstReviewedAt: firstReviewedAt,
  );

  Map<String, Object?> toJson() => {
    'phrase': phraseId,
    'direction': direction.key,
    'fsrs': fsrs.toJson(),
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    if (reps != 0) 'reps': reps,
    if (lapses != 0) 'lapses': lapses,
    if (firstReviewedAt != null)
      'firstReviewedAt': firstReviewedAt!.toUtc().toIso8601String(),
  };

  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value)?.toUtc() : null;

  @override
  List<Object?> get props => [
    phraseId,
    direction,
    fsrs,
    createdAt,
    updatedAt,
    reps,
    lapses,
    firstReviewedAt,
  ];
}
