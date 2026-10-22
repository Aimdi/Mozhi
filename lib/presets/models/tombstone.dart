import 'package:equatable/equatable.dart';

/// A record that the preset or glossary [id] was deleted at [deletedAt].
///
/// Backups and sync carry them so that merging another copy of the
/// presets or glossaries does not bring deleted ones back: a preset or
/// glossary last changed before its tombstone stays deleted, one changed
/// after it (edited on another device, or put back) stays. See
/// `PresetsRepository.mergeBackup` and `GlossaryRepository.mergeBackup`.
class Tombstone extends Equatable {
  const new({required this.id, required this.deletedAt});

  /// Parses [toJson] output. Throws a [FormatException] when a field is
  /// missing or invalid.
  factory fromJson(Map<String, dynamic> json) {
    if (json case {'id': final String id, 'deletedAt': final String iso}) {
      final deletedAt = DateTime.tryParse(iso);
      if (id.isNotEmpty && deletedAt != null) {
        return Tombstone(id: id, deletedAt: deletedAt);
      }
    }
    throw FormatException('Invalid tombstone', json);
  }

  /// The id of the deleted preset or glossary.
  final String id;

  /// When it was deleted.
  final DateTime deletedAt;

  /// `{"id": …, "deletedAt": "…Z"}` (UTC).
  Map<String, dynamic> toJson() => {
    'id': id,
    'deletedAt': deletedAt.toUtc().toIso8601String(),
  };

  /// Tombstones parsed from a JSON list (anything else: none); invalid
  /// elements are skipped.
  static List<Tombstone> parseList(Object? json) => [
    if (json is List)
      for (final element in json)
        if (element is Map) ?_tryParse(element),
  ];

  static Tombstone? _tryParse(Map<dynamic, dynamic> json) {
    try {
      return Tombstone.fromJson(Map<String, dynamic>.from(json));
    } on FormatException {
      return null;
    }
  }

  @override
  List<Object?> get props => [id, deletedAt];
}

/// The change time of data stored before it had one (the epoch, UTC):
/// older than every recorded change and deletion.
final DateTime unknownChangeTime = DateTime.utc(1970);

/// The later of [a] and [b] (null when both are).
DateTime? laterOf(DateTime? a, DateTime? b) {
  if (a == null) return b;
  if (b == null) return a;
  return b.isAfter(a) ? b : a;
}

/// A change time written as an ISO-8601 string, in UTC; null for anything
/// else.
DateTime? parseChangeTime(Object? value) => switch (value) {
  final String iso => DateTime.tryParse(iso)?.toUtc(),
  _ => null,
};
