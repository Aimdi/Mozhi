import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:mozhi/dictionary/data/dictionary_packs.dart';
import 'package:mozhi/offline/cubit/offline_models_state.dart';
import 'package:mozhi/offline/data/offline_model_error.dart';
import 'package:translation_repository/translation_repository.dart';

/// One downloadable dictionary, named for display.
@immutable
class DictionaryPackItem extends Equatable {
  const new({required this.pack, required this.display});

  final DictionaryPackInfo pack;

  /// Its language, named (the code is the pack's id).
  final OfflineLanguage display;

  String get id => pack.id;

  bool matches(String needle, {String? locale}) =>
      display.matches(needle, locale: locale) ||
      pack.language.toLowerCase() == needle.trim().toLowerCase();

  @override
  List<Object?> get props => [pack, display];
}

/// The dictionaries screen: the catalogue's packs, those on the device and
/// the downloads and deletions in progress.
class DictionaryPacksState extends Equatable {
  const new({
    this.status = OfflineModelsStatus.initial,
    this.isAvailable = true,
    this.packs = const [],
    this.installed = const {},
    this.pending = const {},
    this.progress = const {},
    this.wifiOnly = true,
    this.query = '',
    this.outcome,
    this.importing = false,
    this.importOutcome,
    this.cancelling = const {},
  });

  final OfflineModelsStatus status;

  /// False where packs cannot be stored (a browser without OPFS).
  final bool isAvailable;

  /// Every pack of the catalogue, sorted by name.
  final List<DictionaryPackItem> packs;

  /// The installed packs by id.
  final Map<String, StoredDictionaryPack> installed;

  /// Downloads, updates and deletions in progress, by pack id.
  final Map<String, OfflineModelOperation> pending;

  /// Fraction (0 to 1) of each running download received so far.
  final Map<String, double> progress;

  /// Downloads on a metered network ask first (shared with the offline
  /// translation models).
  final bool wifiOnly;
  final String query;

  /// The latest finished operation (null once a new one starts).
  final OfflineModelOutcome? outcome;

  /// An import from files is running.
  final bool importing;

  /// The latest finished import from files (null once a new one starts).
  final DictionaryImportOutcome? importOutcome;

  /// Downloads and updates being cancelled, by pack id (still in [pending]
  /// until they have stopped).
  final Set<String> cancelling;

  /// Whether [id]'s running download or update can be cancelled now (every
  /// pack download can be).
  bool canCancelDownload(String id) =>
      !cancelling.contains(id) &&
      switch (pending[id]) {
        OfflineModelOperation.download || OfflineModelOperation.update => true,
        _ => false,
      };

  /// Whether packs can be imported from files (stored here, and a
  /// catalogue to check them against).
  bool get canImport => isAvailable && packs.isNotEmpty;

  bool isInstalled(String id) => installed.containsKey(id);

  /// Whether the installed version of [id] differs from the catalogue's.
  bool isOutdated(String id) {
    final stored = installed[id];
    final pack = item(id)?.pack;
    return stored != null && pack != null && stored.sha256 != pack.sha256;
  }

  /// Bytes used by every installed pack.
  int get totalBytes =>
      installed.values.fold(0, (sum, pack) => sum + pack.size);

  /// [packs] matching [query] (name, native name or exact code).
  List<DictionaryPackItem> get visible {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return packs;
    return [
      for (final pack in packs)
        if (pack.matches(needle)) pack,
    ];
  }

  List<DictionaryPackItem> get visibleInstalled => [
    for (final pack in visible)
      if (isInstalled(pack.id)) pack,
  ];

  List<DictionaryPackItem> get visibleAvailable => [
    for (final pack in visible)
      if (!isInstalled(pack.id)) pack,
  ];

  /// [visible] as the UI language [locale] shows it: also matching the
  /// names shown in it, sorted by them.
  List<DictionaryPackItem> visibleIn(String locale) => [
    for (final pack in offlineLanguagesFor(
      packs,
      (pack) => pack.display,
      query: '',
      locale: locale,
    ))
      if (pack.matches(query, locale: locale)) pack,
  ];

  /// [visibleInstalled] in [locale] (see [visibleIn]).
  List<DictionaryPackItem> visibleInstalledIn(String locale) => [
    for (final pack in visibleIn(locale))
      if (isInstalled(pack.id)) pack,
  ];

  /// [visibleAvailable] in [locale] (see [visibleIn]).
  List<DictionaryPackItem> visibleAvailableIn(String locale) => [
    for (final pack in visibleIn(locale))
      if (!isInstalled(pack.id)) pack,
  ];

  /// The item with [id], if any.
  DictionaryPackItem? item(String id) {
    for (final pack in packs) {
      if (pack.id == id) return pack;
    }
    return null;
  }

  DictionaryPacksState copyWith({
    OfflineModelsStatus? status,
    bool? isAvailable,
    List<DictionaryPackItem>? packs,
    Map<String, StoredDictionaryPack>? installed,
    Map<String, OfflineModelOperation>? pending,
    Map<String, double>? progress,
    bool? wifiOnly,
    String? query,
    ValueGetter<OfflineModelOutcome?>? outcome,
    bool? importing,
    ValueGetter<DictionaryImportOutcome?>? importOutcome,
    Set<String>? cancelling,
  }) => DictionaryPacksState(
    status: status ?? this.status,
    isAvailable: isAvailable ?? this.isAvailable,
    packs: packs ?? this.packs,
    installed: installed ?? this.installed,
    pending: pending ?? this.pending,
    progress: progress ?? this.progress,
    wifiOnly: wifiOnly ?? this.wifiOnly,
    query: query ?? this.query,
    outcome: outcome != null ? outcome() : this.outcome,
    importing: importing ?? this.importing,
    importOutcome: importOutcome != null ? importOutcome() : this.importOutcome,
    cancelling: cancelling ?? this.cancelling,
  );

  @override
  List<Object?> get props => [
    status,
    isAvailable,
    packs,
    installed,
    pending,
    progress,
    wifiOnly,
    query,
    outcome,
    importing,
    importOutcome,
    cancelling,
  ];
}

/// What an import of dictionary packs from files did, shown once by the
/// view: [report], or the [error] that stopped it.
@immutable
class DictionaryImportOutcome extends Equatable {
  const new({this.report = const DictionaryImportReport(), this.error});

  final DictionaryImportReport report;

  /// Why the import as a whole failed (null when it ran).
  final OfflineModelError? error;

  @override
  List<Object?> get props => [report.packs, report.unmatchedFiles, error];
}
