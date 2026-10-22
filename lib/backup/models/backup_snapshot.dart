import 'package:equatable/equatable.dart';

/// The data of one [BackupSnapshot.sections] entry: what a `BackupSection`
/// exported, and the version it wrote.
class BackupSectionData extends Equatable {
  const new({required this.version, required this.data});

  /// Parses [toJson] output. Throws a [FormatException] without an integer
  /// `version` of at least 1.
  factory fromJson(Map<String, Object?> json) {
    final version = json['version'];
    if (version is! int || version < 1) {
      throw FormatException('Invalid backup section version', json);
    }
    return BackupSectionData(version: version, data: json['data']);
  }

  /// The `BackupSection.version` [data] was written at.
  final int version;

  /// JSON-encodable data (maps, lists, strings, numbers, bools, null).
  final Object? data;

  Map<String, Object?> toJson() => {'version': version, 'data': data};

  @override
  List<Object?> get props => [version, data];
}

/// Everything a backup holds: the data of each section by id, when it was
/// made and by which version of the app.
///
/// JSON ([toJson]): `{"format": "mozhi-backup", "formatVersion": 1,
/// "createdAt": "…Z", "appVersion": "…", "sections": {"history":
/// {"version": 1, "data": …}}}`.
class BackupSnapshot extends Equatable {
  const new({
    required this.createdAt,
    required this.appVersion,
    required this.sections,
  });

  /// Parses [toJson] output.
  ///
  /// Throws a [FormatException] when [json] is not a Mozhi snapshot or a
  /// field is missing or invalid, and a [BackupSnapshotVersionException]
  /// (a [FormatException] too) when it was written in a newer
  /// [formatVersion].
  factory fromJson(Map<String, Object?> json) {
    if (json['format'] != format) {
      throw FormatException('Not a Mozhi backup snapshot', json['format']);
    }
    final version = json['formatVersion'];
    if (version is! int || version < 1) {
      throw FormatException('Invalid snapshot formatVersion', version);
    }
    if (version > formatVersion) {
      throw BackupSnapshotVersionException(version);
    }
    final createdAt = switch (json['createdAt']) {
      final String iso => DateTime.tryParse(iso),
      _ => null,
    };
    if (createdAt == null) {
      throw FormatException('Invalid snapshot createdAt', json['createdAt']);
    }
    final appVersion = json['appVersion'];
    if (appVersion is! String) {
      throw FormatException('Invalid snapshot appVersion', appVersion);
    }
    final sections = json['sections'];
    if (sections is! Map) {
      throw FormatException('Invalid snapshot sections', sections);
    }
    final parsed = <String, BackupSectionData>{};
    for (final MapEntry(:key, :value) in sections.entries) {
      if (key is! String || value is! Map) {
        throw FormatException('Invalid snapshot section', key);
      }
      parsed[key] = BackupSectionData.fromJson(
        Map<String, Object?>.from(value),
      );
    }
    return BackupSnapshot(
      createdAt: createdAt,
      appVersion: appVersion,
      sections: Map.unmodifiable(parsed),
    );
  }

  /// The value of `format` in [toJson].
  static const format = 'mozhi-backup';

  /// The layout version [toJson] writes; [BackupSnapshot.fromJson] reads
  /// every version up to it.
  static const formatVersion = 1;

  /// When the snapshot was taken (written in UTC).
  final DateTime createdAt;

  /// The app version that took it (e.g. `1.4.0+12`).
  final String appVersion;

  /// The data of each section, by `BackupSection.id`.
  final Map<String, BackupSectionData> sections;

  Map<String, Object?> toJson() => {
    'format': format,
    'formatVersion': formatVersion,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'appVersion': appVersion,
    'sections': {
      for (final MapEntry(:key, :value) in sections.entries)
        key: value.toJson(),
    },
  };

  @override
  List<Object?> get props => [createdAt, appVersion, sections];
}

/// A [BackupSnapshot] written by a newer version of the app
/// ([BackupSnapshot.formatVersion] is older than [version]).
class BackupSnapshotVersionException extends FormatException {
  const new(this.version) : super('Backup snapshot written in a newer format');

  /// The snapshot's `formatVersion`.
  final int version;
}
