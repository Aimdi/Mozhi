import 'package:equatable/equatable.dart';
import 'package:mozhi/practice/data/fsrs.dart';

/// One completed review of a practice card, kept for personalized FSRS weight
/// optimization.
final class PracticeReviewLog extends Equatable {
  const new({
    required this.cardKey,
    required this.rating,
    required this.elapsedDays,
    required this.state,
    required this.reviewedAt,
  });

  /// Reads [toJson]'s output; throws [FormatException] when invalid.
  factory fromJson(Map<String, Object?> json) {
    final cardKey = json['cardKey'];
    final rating = FsrsRating.fromGrade(json['rating']);
    final elapsedDays = json['elapsedDays'];
    final state = FsrsState.fromKey(json['state']);
    final reviewedAt = switch (json['reviewedAt']) {
      final String value => DateTime.tryParse(value)?.toUtc(),
      _ => null,
    };
    if (cardKey is! String ||
        cardKey.isEmpty ||
        rating == null ||
        elapsedDays is! num ||
        !elapsedDays.isFinite ||
        elapsedDays < 0 ||
        state == null ||
        reviewedAt == null) {
      throw FormatException('Not a practice review log', json);
    }
    return PracticeReviewLog(
      cardKey: cardKey,
      rating: rating,
      elapsedDays: elapsedDays.toDouble(),
      state: state,
      reviewedAt: reviewedAt,
    );
  }

  /// The card id (`PracticeCard.id`).
  final String cardKey;

  /// The rating given at this review.
  final FsrsRating rating;

  /// Days elapsed since the card's previous review (0 on the first review).
  final double elapsedDays;

  /// The card's FSRS state just before this review.
  final FsrsState state;

  /// When the review happened (UTC).
  final DateTime reviewedAt;

  Map<String, Object?> toJson() => {
    'cardKey': cardKey,
    'rating': rating.grade,
    'elapsedDays': elapsedDays,
    'state': state.key,
    'reviewedAt': reviewedAt.toUtc().toIso8601String(),
  };

  @override
  List<Object?> get props => [cardKey, rating, elapsedDays, state, reviewedAt];
}
