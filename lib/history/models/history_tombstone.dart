import 'package:equatable/equatable.dart';

/// A record that the history entry [id] was deleted at [deletedAt] (by the
/// user: Delete, Clear history, un-starring an entry kept only as a
/// favourite, an entry replaced by a newer one).
///
/// Backups and sync carry tombstones so that merging another copy of the
/// history does not bring deleted entries back: an entry last changed
/// before its tombstone stays deleted (`HistoryRepository.mergeBackup`).
/// Entries removed by the size limits or "Delete history automatically"
/// leave none (each device applies its own limits).
class HistoryTombstone extends Equatable {
  const new({required this.id, required this.deletedAt});

  /// Parses [toJson] output. Throws a [FormatException] when a field is
  /// missing or invalid.
  factory fromJson(Map<String, dynamic> json) {
    if (json case {'id': final String id, 'deletedAt': final String iso}) {
      final deletedAt = DateTime.tryParse(iso);
      if (id.isNotEmpty && deletedAt != null) {
        return HistoryTombstone(id: id, deletedAt: deletedAt);
      }
    }
    throw FormatException('Invalid history tombstone', json);
  }

  /// The [id] of the deleted entry (`HistoryEntry.id`).
  final String id;

  /// When it was deleted.
  final DateTime deletedAt;

  /// `{"id": …, "deletedAt": "…Z"}` (UTC).
  Map<String, dynamic> toJson() => {
    'id': id,
    'deletedAt': deletedAt.toUtc().toIso8601String(),
  };

  @override
  List<Object?> get props => [id, deletedAt];
}
