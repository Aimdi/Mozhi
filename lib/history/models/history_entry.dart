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

  factory fromJson() =>
      throw UnimplementedError('TODO(app-data)');

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

  HistoryEntry copyWith({bool? isFavorite, String? translation}) =>
      throw UnimplementedError('TODO(app-data)');

  Map<String, dynamic> toJson() => throw UnimplementedError('TODO(app-data)');

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
