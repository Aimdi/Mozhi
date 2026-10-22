import 'package:equatable/equatable.dart';
import 'package:mozhi/phrasebook/models/phrase.dart';

/// A named collection of phrases ("Trip to Lisbon", "Pharmacy"): the ids
/// of its [Phrase]s, in the order they were added.
///
/// Two kinds are built in and cannot be renamed:
/// * [favoritesId]: the history favourites (its phrases are read from the
///   history, nothing is copied);
/// * [starter] collections (`starter:<pack id>`): an installed starter
///   phrasebook, read-only (phrases can be copied out of it).
///
/// [sourceCode] and [targetCode] are the collection's language pair when it
/// has one (the languages a CSV import suggests); null when it mixes
/// languages or none was chosen.
class PhraseCollection extends Equatable {
  const new({
    required this.id,
    required this.name,
    required this.phraseIds,
    required this.createdAt,
    required this.updatedAt,
    this.sourceCode,
    this.targetCode,
    this.starter = false,
  });

  /// Parses a collection written by [toJson]. Throws [FormatException]
  /// when a required field is missing or invalid.
  factory fromJson(Map<String, dynamic> json) {
    if (json
        case {
          'id': final String id,
          'name': final String name,
          'phraseIds': final List<dynamic> phraseIds,
        }
        when id.isNotEmpty) {
      final createdAt = Phrase.parseTime(json['createdAt']);
      if (createdAt == null) {
        throw FormatException('Invalid collection createdAt', json);
      }
      String? code(Object? value) =>
          value is String && value.isNotEmpty ? value : null;
      return PhraseCollection(
        id: id,
        name: name,
        sourceCode: code(json['sourceCode']),
        targetCode: code(json['targetCode']),
        phraseIds: List.unmodifiable({
          for (final id in phraseIds)
            if (id is String && id.isNotEmpty) id,
        }),
        createdAt: createdAt,
        updatedAt: Phrase.parseTime(json['updatedAt']) ?? createdAt,
        starter: json['starter'] == true,
      );
    }
    throw FormatException('Invalid phrase collection', json);
  }

  /// Id of the built-in collection of the history favourites.
  static const favoritesId = 'favorites';

  /// Id prefix of the starter phrasebooks' collections.
  static const starterIdPrefix = 'starter:';

  /// Id prefix of the user's collections.
  static const storedIdPrefix = 'c:';

  /// The collection id of the starter pack [packId].
  static String starterId(String packId) => '$starterIdPrefix$packId';

  /// The pack id of the starter collection [collectionId], or null.
  static String? starterPackOf(String collectionId) =>
      collectionId.startsWith(starterIdPrefix)
      ? collectionId.substring(starterIdPrefix.length)
      : null;

  final String id;

  /// The user's name for it; empty for [favoritesId] (the app shows
  /// "Favorites" in its language).
  final String name;

  /// The source language of its phrases, when it has one.
  final String? sourceCode;

  /// The target language of its phrases, when it has one.
  final String? targetCode;

  /// Its phrases' ids, oldest first, without duplicates.
  final List<String> phraseIds;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Whether this is an installed starter phrasebook (read-only).
  final bool starter;

  /// Whether this is the built-in Favorites collection.
  bool get isFavorites => id == favoritesId;

  /// Whether the user can rename it and add phrases to it or remove them
  /// (the Favorites collection only takes phrases out: it un-stars them).
  bool get isEditable => !starter && !isFavorites;

  /// How many phrases it has.
  int get length => phraseIds.length;

  PhraseCollection copyWith({
    String? name,
    String? Function()? sourceCode,
    String? Function()? targetCode,
    List<String>? phraseIds,
    DateTime? updatedAt,
  }) => PhraseCollection(
    id: id,
    name: name ?? this.name,
    sourceCode: sourceCode != null ? sourceCode() : this.sourceCode,
    targetCode: targetCode != null ? targetCode() : this.targetCode,
    phraseIds: phraseIds != null
        ? List.unmodifiable(phraseIds.toSet())
        : this.phraseIds,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    starter: starter,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (sourceCode != null) 'sourceCode': sourceCode,
    if (targetCode != null) 'targetCode': targetCode,
    'phraseIds': phraseIds,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    if (starter) 'starter': true,
  };

  @override
  List<Object?> get props => [
    id,
    name,
    sourceCode,
    targetCode,
    phraseIds,
    createdAt,
    updatedAt,
    starter,
  ];
}
