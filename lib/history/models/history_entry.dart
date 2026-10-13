import 'package:equatable/equatable.dart';
import 'package:translation_repository/translation_repository.dart';

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
  });

  /// Parses an entry written by [toJson].
  ///
  /// Throws a [FormatException] when a required field is missing or has the
  /// wrong type. `engineName` falls back to `engineId`, and `createdAt` may
  /// also be given as milliseconds since the epoch.
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
      );
    }
    throw FormatException('Invalid history entry', json);
  }

  final String id;
  final String text;
  final String translation;
  final Language source;
  final Language target;
  final String engineId;
  final String engineName;
  final DateTime createdAt;
  final String? detectedSource;
  final bool isFavorite;

  HistoryEntry copyWith({
    bool? isFavorite,
    String? translation,
    String? text,
  }) => HistoryEntry(
    id: id,
    text: text ?? this.text,
    translation: translation ?? this.translation,
    source: source,
    target: target,
    engineId: engineId,
    engineName: engineName,
    createdAt: createdAt,
    detectedSource: detectedSource,
    isFavorite: isFavorite ?? this.isFavorite,
  );

  /// [createdAt] is written as a UTC ISO-8601 string.
  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'translation': translation,
    'source': source.toJson(),
    'target': target.toJson(),
    'engineId': engineId,
    'engineName': engineName,
    'createdAt': createdAt.toUtc().toIso8601String(),
    if (detectedSource != null) 'detectedSource': detectedSource,
    'isFavorite': isFavorite,
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
  ];
}

Language _language(Map<dynamic, dynamic> json, Object source) {
  try {
    return Language.fromJson(Map<String, dynamic>.from(json));
  } on Object {
    throw FormatException('Invalid history entry language', source);
  }
}
