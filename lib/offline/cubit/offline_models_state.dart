import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';

enum OfflineModelsStatus { initial, loading, ready, failure }

enum OfflineModelOperation { download, delete }

/// A language the offline engine has a model for.
@immutable
class OfflineLanguage extends Equatable {
  const OfflineLanguage({
    required this.code,
    required this.name,
    this.nativeName,
  });

  /// Offline engine code (e.g. `de`, `zh`).
  final String code;

  /// English name (or [code] when unknown).
  final String name;
  final String? nativeName;

  bool matches(String needle) =>
      needle.isEmpty ||
      name.toLowerCase().contains(needle) ||
      (nativeName?.toLowerCase().contains(needle) ?? false) ||
      code.toLowerCase() == needle;

  @override
  List<Object?> get props => [code, name, nativeName];
}

/// Result of a finished download or deletion, shown once by the view.
@immutable
class OfflineModelOutcome extends Equatable {
  const OfflineModelOutcome({
    required this.language,
    required this.operation,
    required this.succeeded,
  });

  final OfflineLanguage language;
  final OfflineModelOperation operation;
  final bool succeeded;

  @override
  List<Object?> get props => [language, operation, succeeded];
}

class OfflineModelsState extends Equatable {
  const OfflineModelsState({
    this.status = OfflineModelsStatus.initial,
    this.isAvailable = true,
    this.languages = const [],
    this.downloaded = const {},
    this.pending = const {},
    this.wifiOnly = true,
    this.query = '',
    this.outcome,
  });

  final OfflineModelsStatus status;

  /// False on platforms without an offline engine (web, desktop).
  final bool isAvailable;

  /// Every supported language, sorted by name.
  final List<OfflineLanguage> languages;

  /// Codes of the languages whose models are on the device.
  final Set<String> downloaded;

  /// Downloads and deletions in progress, by language code.
  final Map<String, OfflineModelOperation> pending;

  /// Downloads wait for Wi-Fi (persisted).
  final bool wifiOnly;
  final String query;

  /// The latest finished operation (null once a new one starts).
  final OfflineModelOutcome? outcome;

  int get downloadedCount => downloaded.length;

  bool isDownloaded(String code) => downloaded.contains(code);

  /// [languages] matching [query] (name, native name or exact code).
  List<OfflineLanguage> get visible {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return languages;
    return [
      for (final language in languages)
        if (language.matches(needle)) language,
    ];
  }

  List<OfflineLanguage> get visibleDownloaded => [
    for (final language in visible)
      if (downloaded.contains(language.code)) language,
  ];

  List<OfflineLanguage> get visibleAvailable => [
    for (final language in visible)
      if (!downloaded.contains(language.code)) language,
  ];

  OfflineModelsState copyWith({
    OfflineModelsStatus? status,
    bool? isAvailable,
    List<OfflineLanguage>? languages,
    Set<String>? downloaded,
    Map<String, OfflineModelOperation>? pending,
    bool? wifiOnly,
    String? query,
    ValueGetter<OfflineModelOutcome?>? outcome,
  }) => OfflineModelsState(
    status: status ?? this.status,
    isAvailable: isAvailable ?? this.isAvailable,
    languages: languages ?? this.languages,
    downloaded: downloaded ?? this.downloaded,
    pending: pending ?? this.pending,
    wifiOnly: wifiOnly ?? this.wifiOnly,
    query: query ?? this.query,
    outcome: outcome != null ? outcome() : this.outcome,
  );

  @override
  List<Object?> get props => [
    status,
    isAvailable,
    languages,
    downloaded,
    pending,
    wifiOnly,
    query,
    outcome,
  ];
}
