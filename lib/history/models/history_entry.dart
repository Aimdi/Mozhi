import 'package:equatable/equatable.dart';
import 'package:translation_repository/translation_repository.dart';

/// What a [HistoryEntry] records.
enum HistoryEntryKind {
  /// A translation of [HistoryEntry.text] into [HistoryEntry.translation].
  /// Entries stored or exported before kinds existed are translations.
  translation,

  /// A dictionary look-up of the word or phrase [HistoryEntry.text]
  /// (`HistoryEntry.source`: its language, [HistoryEntry.target]: the
  /// language of the translations). [HistoryEntry.translation] holds a
  /// short summary of the entry (part of speech and first definition, or
  /// the first translation), not the entry itself: opening it looks the
  /// word up again.
  dictionary,
}

/// One entry of the on-device history: a translation or, with
/// [HistoryEntryKind.dictionary], a dictionary look-up (see [kind]).
class HistoryEntry extends Equatable {
  const new({
    required this.id,
    required this.text,
    required this.translation,
    required this.source,
    required this.target,
    required this.engineId,
    required this.engineName,
    required this.createdAt,
    this.detectedSource,
    this.isFavorite = false,
    this.kind = HistoryEntryKind.translation,
    this.verbosity,
    this.favoriteOnly = false,
    this.updatedAt,
  });

  /// Parses an entry written by [toJson].
  ///
  /// Throws a [FormatException] when a required field is missing or has the
  /// wrong type, or when `kind` names an unknown kind. `engineName` falls
  /// back to `engineId`, and `createdAt` may also be given as milliseconds
  /// since the epoch. Without `kind` (entries written before kinds
  /// existed) the entry is a [HistoryEntryKind.translation]; `verbosity` is
  /// read only for dictionary look-ups (unknown values are ignored). An
  /// invalid `updatedAt` is ignored.
  factory fromJson(Map<String, dynamic> json) {
    if (json case {
      'id': final String id,
      'text': final String text,
      'translation': final String translation,
      'source': final Map<dynamic, dynamic> source,
      'target': final Map<dynamic, dynamic> target,
      'engineId': final String engineId,
    }) {
      final createdAt = switch (json['createdAt']) {
        final String iso => DateTime.tryParse(iso)?.toLocal(),
        final int millis => DateTime.fromMillisecondsSinceEpoch(millis),
        _ => null,
      };
      if (createdAt == null) {
        throw FormatException('Invalid history entry createdAt', json);
      }
      final kind = switch (json['kind']) {
        null => HistoryEntryKind.translation,
        final String name => HistoryEntryKind.values.asNameMap()[name],
        _ => null,
      };
      if (kind == null) {
        throw FormatException('Unknown history entry kind', json);
      }
      return HistoryEntry(
        id: id,
        text: text,
        translation: translation,
        source: _language(source, json),
        target: _language(target, json),
        engineId: engineId,
        engineName: switch (json['engineName']) {
          final String name when name.isNotEmpty => name,
          _ => engineId,
        },
        createdAt: createdAt,
        detectedSource: switch (json['detectedSource']) {
          final String code when code.isNotEmpty => code,
          _ => null,
        },
        isFavorite: json['isFavorite'] == true,
        kind: kind,
        verbosity: switch (json['verbosity']) {
          final String name when kind == HistoryEntryKind.dictionary =>
            DictionaryVerbosity.values.asNameMap()[name],
          _ => null,
        },
        favoriteOnly: json['favoriteOnly'] == true,
        updatedAt: switch (json['updatedAt']) {
          final String iso => DateTime.tryParse(iso)?.toLocal(),
          _ => null,
        },
      );
    }
    throw FormatException('Invalid history entry', json);
  }

  final String id;

  /// The translated text, or the looked-up word ([kind]).
  final String text;

  /// The translation, or the summary of a dictionary entry ([kind]).
  final String translation;
  final Language source;
  final Language target;
  final String engineId;
  final String engineName;
  final DateTime createdAt;
  final String? detectedSource;
  final bool isFavorite;

  /// Whether the entry is in the history only as a favourite: it was
  /// starred while history was paused (incognito, or "Save history" off),
  /// when nothing else is saved. Taking it out of the favourites deletes it
  /// (`HistoryRepository.toggleFavorite`), as nothing else would keep it. A
  /// look-up or translation saved while history is on that updates the
  /// entry makes it an ordinary one.
  final bool favoriteOnly;

  /// A translation or a dictionary look-up.
  final HistoryEntryKind kind;

  /// The detail level of a dictionary look-up (null for translations, and
  /// when unknown).
  final DictionaryVerbosity? verbosity;

  /// When the entry last changed after [createdAt] (starred or un-starred,
  /// for example); null when it hasn't. Backups and sync keep the newer
  /// copy of an entry by [modifiedAt].
  ///
  /// Bookkeeping only: entries that differ only here are equal (`==`).
  final DateTime? updatedAt;

  /// [updatedAt], else [createdAt]: when the entry last changed.
  DateTime get modifiedAt => updatedAt ?? createdAt;

  /// Whether this is a dictionary look-up ([HistoryEntryKind.dictionary]).
  bool get isDictionary => kind == HistoryEntryKind.dictionary;

  /// Whether this is a dictionary look-up of [word] from [source] into
  /// [target]: the entry another look-up of the same word updates instead
  /// of adding one (see `HistoryRepository.add`).
  ///
  /// Words are compared trimmed and with runs of whitespace as one space.
  /// Case matters (German "Weg" and "weg" are different words); languages
  /// compare by code ([Language.==]).
  bool isLookUpOf(
    String word, {
    required Language source,
    required Language target,
  }) =>
      isDictionary &&
      this.source == source &&
      this.target == target &&
      lookUpKey(text) == lookUpKey(word);

  /// Whether this and [other] are dictionary look-ups of the same word
  /// and languages ([isLookUpOf]).
  bool isSameLookUp(HistoryEntry other) =>
      other.isDictionary &&
      isLookUpOf(other.text, source: other.source, target: other.target);

  static final _spaces = RegExp(r'\s+');

  /// [word] as dictionary look-ups compare it (see [isLookUpOf]).
  static String lookUpKey(String word) => word.trim().replaceAll(_spaces, ' ');

  HistoryEntry copyWith({
    String? id,
    bool? isFavorite,
    String? translation,
    String? text,
    bool? favoriteOnly,
    DateTime? updatedAt,
  }) => HistoryEntry(
    id: id ?? this.id,
    text: text ?? this.text,
    translation: translation ?? this.translation,
    source: source,
    target: target,
    engineId: engineId,
    engineName: engineName,
    createdAt: createdAt,
    detectedSource: detectedSource,
    isFavorite: isFavorite ?? this.isFavorite,
    kind: kind,
    verbosity: verbosity,
    favoriteOnly: favoriteOnly ?? this.favoriteOnly,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  /// [createdAt] is written as a UTC ISO-8601 string. Translations are
  /// written exactly as before kinds existed (no `kind`); dictionary
  /// look-ups add `"kind": "dictionary"` and their `verbosity`, entries
  /// kept only as favourites `"favoriteOnly": true`, and entries changed
  /// since they were made their `updatedAt` (UTC).
  Map<String, dynamic> toJson() => {
    'id': id,
    if (isDictionary) 'kind': kind.name,
    'text': text,
    'translation': translation,
    'source': source.toJson(),
    'target': target.toJson(),
    'engineId': engineId,
    'engineName': engineName,
    'createdAt': createdAt.toUtc().toIso8601String(),
    if (detectedSource != null) 'detectedSource': detectedSource,
    if (isDictionary && verbosity != null) 'verbosity': verbosity!.name,
    'isFavorite': isFavorite,
    if (favoriteOnly) 'favoriteOnly': true,
    if (updatedAt case final updatedAt?)
      'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  @override
  List<Object?> get props => [
    id,
    text,
    translation,
    source,
    target,
    engineId,
    engineName,
    createdAt,
    detectedSource,
    isFavorite,
    kind,
    verbosity,
    favoriteOnly,
    // Not updatedAt: see there.
  ];
}

Language _language(Map<dynamic, dynamic> json, Object source) {
  try {
    return Language.fromJson(Map<String, dynamic>.from(json));
  } on Object {
    throw FormatException('Invalid history entry language', source);
  }
}
