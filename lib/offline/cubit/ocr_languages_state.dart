import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:mozhi/offline/cubit/offline_models_state.dart';

/// One language of on-device text recognition, named for display.
@immutable
class OcrLanguageItem extends Equatable {
  const new({required this.ocr, required this.display});

  /// The downloadable data (its [OcrLanguage.code] identifies the item).
  final OcrLanguage ocr;

  /// Its app language, named (the code is the app's, e.g. `de`).
  final OfflineLanguage display;

  String get code => ocr.code;

  bool matches(String needle) => display.matches(needle) || ocr.code == needle;

  @override
  List<Object?> get props => [ocr, display];
}

class OcrLanguagesState extends Equatable {
  const new({
    this.status = OfflineModelsStatus.initial,
    this.isAvailable = true,
    this.languages = const [],
    this.installed = const {},
    this.pending = const {},
    this.progress = const {},
    this.wifiOnly = true,
    this.query = '',
    this.outcome,
    this.importing = false,
    this.importOutcome,
    this.canCancel = false,
    this.cancelling = const {},
  });

  final OfflineModelsStatus status;

  /// False where text recognition cannot run (web, desktop, an old CPU).
  final bool isAvailable;

  /// Every language with data, sorted by name.
  final List<OcrLanguageItem> languages;

  /// Bytes on the device per installed language code.
  final Map<String, int> installed;

  /// Downloads and deletions in progress, by language code.
  final Map<String, OfflineModelOperation> pending;

  /// Fraction (0 to 1) of each running download received so far.
  final Map<String, double> progress;

  /// Downloads on a metered network ask first (shared with the offline
  /// translation models).
  final bool wifiOnly;
  final String query;

  /// The latest finished download or deletion (null once a new one
  /// starts).
  final OfflineModelOutcome? outcome;

  /// An import from files is running.
  final bool importing;

  /// The latest finished import (null once a new one starts).
  final OcrImportReport? importOutcome;

  /// Whether running downloads can be cancelled (the recognizer has
  /// `CancellableOcrDownloads`).
  final bool canCancel;

  /// Downloads being cancelled, by language code (still in [pending] until
  /// they have stopped).
  final Set<String> cancelling;

  /// Whether [code]'s running download can be cancelled now.
  bool canCancelDownload(String code) =>
      canCancel &&
      !cancelling.contains(code) &&
      switch (pending[code]) {
        OfflineModelOperation.download || OfflineModelOperation.update => true,
        _ => false,
      };

  bool isInstalled(String code) => installed.containsKey(code);

  /// Bytes used by every installed language.
  int get totalBytes => installed.values.fold(0, (sum, bytes) => sum + bytes);

  /// [languages] matching [query] (name, native name or exact code).
  List<OcrLanguageItem> get visible {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return languages;
    return [
      for (final language in languages)
        if (language.matches(needle)) language,
    ];
  }

  List<OcrLanguageItem> get visibleInstalled => [
    for (final language in visible)
      if (isInstalled(language.code)) language,
  ];

  List<OcrLanguageItem> get visibleAvailable => [
    for (final language in visible)
      if (!isInstalled(language.code)) language,
  ];

  /// The item with OCR [code], if any.
  OcrLanguageItem? item(String code) {
    for (final language in languages) {
      if (language.code == code) return language;
    }
    return null;
  }

  OcrLanguagesState copyWith({
    OfflineModelsStatus? status,
    bool? isAvailable,
    List<OcrLanguageItem>? languages,
    Map<String, int>? installed,
    Map<String, OfflineModelOperation>? pending,
    Map<String, double>? progress,
    bool? wifiOnly,
    String? query,
    ValueGetter<OfflineModelOutcome?>? outcome,
    bool? importing,
    ValueGetter<OcrImportReport?>? importOutcome,
    bool? canCancel,
    Set<String>? cancelling,
  }) => OcrLanguagesState(
    status: status ?? this.status,
    isAvailable: isAvailable ?? this.isAvailable,
    languages: languages ?? this.languages,
    installed: installed ?? this.installed,
    pending: pending ?? this.pending,
    progress: progress ?? this.progress,
    wifiOnly: wifiOnly ?? this.wifiOnly,
    query: query ?? this.query,
    outcome: outcome != null ? outcome() : this.outcome,
    importing: importing ?? this.importing,
    importOutcome: importOutcome != null ? importOutcome() : this.importOutcome,
    canCancel: canCancel ?? this.canCancel,
    cancelling: cancelling ?? this.cancelling,
  );

  @override
  List<Object?> get props => [
    status,
    isAvailable,
    languages,
    installed,
    pending,
    progress,
    wifiOnly,
    query,
    outcome,
    importing,
    importOutcome,
    canCancel,
    cancelling,
  ];
}
