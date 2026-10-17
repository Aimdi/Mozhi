import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:mozhi/offline/data/offline_model_details.dart';
import 'package:mozhi/offline/data/offline_model_error.dart';
import 'package:mozhi/offline/data/offline_model_import.dart';

enum OfflineModelsStatus { initial, loading, ready, failure }

enum OfflineModelOperation { download, update, delete }

/// A language the offline engine has a model for.
@immutable
class OfflineLanguage extends Equatable {
  const new({required this.code, required this.name, this.nativeName});

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

/// Result of a finished download, update or deletion, shown once by the
/// view.
@immutable
class OfflineModelOutcome extends Equatable {
  const new({
    required this.language,
    required this.operation,
    required this.succeeded,
    this.error,
  });

  final OfflineLanguage language;
  final OfflineModelOperation operation;
  final bool succeeded;

  /// Why it failed (null on success).
  final OfflineModelError? error;

  /// Whether a Wi-Fi-only download stopped because the network is metered
  /// (the view asks whether to download anyway).
  bool get needsMeteredConsent => error?.kind == OfflineModelErrorKind.metered;

  @override
  List<Object?> get props => [language, operation, succeeded, error];
}

/// One translation direction of an import, with its languages named.
@immutable
class OfflineImportEntry extends Equatable {
  const new({
    required this.source,
    required this.target,
    required this.status,
    this.missingFiles = const [],
    this.error,
  });

  final OfflineLanguage source;
  final OfflineLanguage target;
  final OfflineImportStatus status;

  /// Names of the files still needed (see
  /// [OfflineImportedModel.missingFiles]).
  final List<String> missingFiles;

  /// Why it was not installed, when known.
  final OfflineModelError? error;

  @override
  List<Object?> get props => [source, target, status, missingFiles, error];
}

/// Result of a finished import from files, shown once by the view.
@immutable
class OfflineImportOutcome extends Equatable {
  const new({
    this.entries = const [],
    this.unmatchedFiles = const [],
    this.error,
  });

  /// The directions the files belong to.
  final List<OfflineImportEntry> entries;

  /// Names of the selected files that belong to no model.
  final List<String> unmatchedFiles;

  /// Why the import as a whole failed (null when it ran).
  final OfflineModelError? error;

  /// Whether at least one model was installed.
  bool get installedAny =>
      entries.any((entry) => entry.status == OfflineImportStatus.installed);

  @override
  List<Object?> get props => [entries, unmatchedFiles, error];
}

/// The files of one translation direction to download by hand.
@immutable
class OfflineManualDirection extends Equatable {
  const new({required this.source, required this.target, required this.files});

  final OfflineLanguage source;
  final OfflineLanguage target;
  final List<OfflineModelFile> files;

  @override
  List<Object?> get props => [source, target, files];
}

class OfflineModelsState extends Equatable {
  const new({
    this.status = OfflineModelsStatus.initial,
    this.isAvailable = true,
    this.languages = const [],
    this.downloaded = const {},
    this.pending = const {},
    this.wifiOnly = true,
    this.query = '',
    this.outcome,
    this.downloadSizes = const {},
    this.storage,
    this.progress = const {},
    this.canImport = false,
    this.importing = false,
    this.importOutcome,
    this.manualDownloads = const {},
  });

  final OfflineModelsStatus status;

  /// False where the offline engine cannot run (web, desktop, an
  /// unsupported CPU).
  final bool isAvailable;

  /// Every supported language, sorted by name.
  final List<OfflineLanguage> languages;

  /// Codes of the languages whose models are on the device.
  final Set<String> downloaded;

  /// Downloads, updates and deletions in progress, by language code.
  final Map<String, OfflineModelOperation> pending;

  /// Downloads on a metered network ask first (persisted).
  final bool wifiOnly;
  final String query;

  /// The latest finished operation (null once a new one starts).
  final OfflineModelOutcome? outcome;

  /// Bytes to download per language (both directions), when the engine
  /// reports sizes ([hasDetails]); 0 for languages that need no download.
  final Map<String, int> downloadSizes;

  /// Disk usage and updates of the installed models, when known.
  final OfflineStorage? storage;

  /// Fraction (0 to 1) of each running download received so far.
  final Map<String, double> progress;

  /// Whether models can be imported from files (the engine supports it and
  /// runs here).
  final bool canImport;

  /// An import from files is running (from picking the files on).
  final bool importing;

  /// The latest finished import (null once a new one starts).
  final OfflineImportOutcome? importOutcome;

  /// Per language, the files to download by hand for an import, when the
  /// engine supports imports.
  final Map<String, List<OfflineManualDirection>> manualDownloads;

  /// Whether the engine reports sizes (and with them which languages are
  /// built in).
  bool get hasDetails => downloadSizes.isNotEmpty;

  /// Whether [code] works without any download (English with Mozilla's
  /// models, which all translate to or from English).
  bool isBuiltIn(String code) => hasDetails && downloadSizes[code] == 0;

  /// Downloaded languages, not counting built-in ones.
  int get downloadedCount => downloaded.where((c) => !isBuiltIn(c)).length;

  bool isDownloaded(String code) => downloaded.contains(code);

  /// Whether a newer model exists for downloaded [code].
  bool isOutdated(String code) =>
      isDownloaded(code) && (storage?.outdated.contains(code) ?? false);

  /// Bytes to download for [code], or null when unknown.
  int? downloadSizeOf(String code) => downloadSizes[code];

  /// Bytes [code]'s models use on this device, or null when unknown.
  int? installedSizeOf(String code) => storage?.installedBytes[code];

  /// The files to download by hand for [code] (empty when none or
  /// unknown).
  List<OfflineManualDirection> manualDownloadsOf(String code) =>
      manualDownloads[code] ?? const [];

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
    Map<String, int>? downloadSizes,
    ValueGetter<OfflineStorage?>? storage,
    Map<String, double>? progress,
    bool? canImport,
    bool? importing,
    ValueGetter<OfflineImportOutcome?>? importOutcome,
    Map<String, List<OfflineManualDirection>>? manualDownloads,
  }) => OfflineModelsState(
    status: status ?? this.status,
    isAvailable: isAvailable ?? this.isAvailable,
    languages: languages ?? this.languages,
    downloaded: downloaded ?? this.downloaded,
    pending: pending ?? this.pending,
    wifiOnly: wifiOnly ?? this.wifiOnly,
    query: query ?? this.query,
    outcome: outcome != null ? outcome() : this.outcome,
    downloadSizes: downloadSizes ?? this.downloadSizes,
    storage: storage != null ? storage() : this.storage,
    progress: progress ?? this.progress,
    canImport: canImport ?? this.canImport,
    importing: importing ?? this.importing,
    importOutcome: importOutcome != null ? importOutcome() : this.importOutcome,
    manualDownloads: manualDownloads ?? this.manualDownloads,
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
    downloadSizes,
    storage,
    progress,
    canImport,
    importing,
    importOutcome,
    manualDownloads,
  ];
}
