import 'package:equatable/equatable.dart';
import 'package:mozhi/practice/data/fsrs.dart';
import 'package:mozhi/practice/models/practice_card.dart';

/// The user's practice choices.
final class PracticeSettings extends Equatable {
  const new({
    this.collectionIds,
    this.directions = const {CardDirection.recognize, CardDirection.produce},
    this.newCardsPerDay = defaultNewCardsPerDay,
    this.desiredRetention = FsrsScheduler.defaultDesiredRetention,
    this.typeAnswers = false,
    this.customWeights,
    this.updatedAt,
  });

  /// Reads [toJson]'s output; what is missing or invalid takes its
  /// default.
  factory fromJson(Map<String, Object?> json) {
    final collections = json['collections'];
    final directions = json['directions'];
    final parsed = directions is List<Object?>
        ? {for (final key in directions) ?CardDirection.fromKey(key)}
        : null;
    final perDay = json['newPerDay'];
    final retention = json['retention'];
    return PracticeSettings(
      collectionIds: collections is List<Object?>
          ? {
              for (final id in collections)
                if (id is String && id.isNotEmpty) id,
            }
          : null,
      directions: parsed == null || parsed.isEmpty
          ? const {CardDirection.recognize, CardDirection.produce}
          : parsed,
      newCardsPerDay: perDay is num
          ? perDay.toInt().clamp(0, maxNewCardsPerDay)
          : defaultNewCardsPerDay,
      desiredRetention: retention is num
          ? retention.toDouble().clamp(
              FsrsScheduler.minDesiredRetention,
              FsrsScheduler.maxDesiredRetention,
            )
          : FsrsScheduler.defaultDesiredRetention,
      typeAnswers: json['typeAnswers'] == true,
      customWeights: _parseWeights(json['fsrsWeights']),
      updatedAt: switch (json['updatedAt']) {
        final String value => DateTime.tryParse(value)?.toUtc(),
        _ => null,
      },
    );
  }

  static List<double>? _parseWeights(Object? value) {
    if (value is! List<Object?> ||
        value.length != FsrsScheduler.defaultWeights.length) {
      return null;
    }
    final weights = <double>[];
    for (final item in value) {
      if (item is! num) return null;
      final number = item.toDouble();
      if (!number.isFinite) return null;
      weights.add(number);
    }
    return List.unmodifiable(weights);
  }

  static const defaultNewCardsPerDay = 10;
  static const maxNewCardsPerDay = 100;

  /// The collections practised (`PhraseCollection.id`); null: all of them.
  final Set<String>? collectionIds;

  /// The directions every phrase is asked in (at least one).
  final Set<CardDirection> directions;

  /// How many new cards a day introduces (0 to [maxNewCardsPerDay]).
  final int newCardsPerDay;

  /// The probability of remembering a card when it is due (FSRS).
  final double desiredRetention;

  /// Whether produce cards offer an answer field.
  final bool typeAnswers;

  /// Personalized 19-element FSRS-5 weights; null uses
  /// [FsrsScheduler.defaultWeights].
  final List<double>? customWeights;

  /// When the settings last changed (the newer copy wins in a merge).
  final DateTime? updatedAt;

  /// Whether personalized FSRS weights are active.
  bool get hasCustomWeights => customWeights != null;

  /// The weights passed to [FsrsScheduler]: [customWeights] when valid, else
  /// [FsrsScheduler.defaultWeights].
  List<double> get effectiveWeights {
    final weights = customWeights;
    if (weights == null ||
        weights.length != FsrsScheduler.defaultWeights.length ||
        weights.any((value) => !value.isFinite)) {
      return FsrsScheduler.defaultWeights;
    }
    return weights;
  }

  /// Whether the collection [id] is practised.
  bool includes(String id) => collectionIds?.contains(id) ?? true;

  PracticeSettings copyWith({
    Set<String>? Function()? collectionIds,
    Set<CardDirection>? directions,
    int? newCardsPerDay,
    double? desiredRetention,
    bool? typeAnswers,
    List<double>? Function()? customWeights,
    DateTime? updatedAt,
  }) => PracticeSettings(
    collectionIds: collectionIds != null ? collectionIds() : this.collectionIds,
    directions: directions ?? this.directions,
    newCardsPerDay: newCardsPerDay ?? this.newCardsPerDay,
    desiredRetention: desiredRetention ?? this.desiredRetention,
    typeAnswers: typeAnswers ?? this.typeAnswers,
    customWeights: customWeights != null
        ? switch (customWeights()) {
            final List<double> next => List.unmodifiable(next),
            null => null,
          }
        : this.customWeights,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, Object?> toJson() => {
    if (collectionIds != null) 'collections': [...collectionIds!],
    'directions': [for (final direction in directions) direction.key],
    'newPerDay': newCardsPerDay,
    'retention': desiredRetention,
    if (typeAnswers) 'typeAnswers': true,
    if (customWeights != null) 'fsrsWeights': [...customWeights!],
    if (updatedAt != null) 'updatedAt': updatedAt!.toUtc().toIso8601String(),
  };

  @override
  List<Object?> get props => [
    collectionIds,
    directions,
    newCardsPerDay,
    desiredRetention,
    typeAnswers,
    customWeights,
    updatedAt,
  ];
}
