import 'dart:io' show FileSystemException;

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:mozhi/voice/offline/offline_speech.dart';
import 'package:mozhi/voice/speech_input_service.dart';
import 'package:whisper_speech/whisper_speech.dart';

enum VoiceSettingsStatus { initial, loading, ready }

enum VoiceModelOperation { download, delete }

/// Why downloading or deleting a speech model failed.
enum VoiceModelErrorKind {
  /// A Wi-Fi-only download on a metered network: nothing was downloaded
  /// (the settings offer to download anyway).
  metered,

  /// The file did not match the catalog's size or SHA-1 and was discarded.
  checksum,

  /// The model server answered with an HTTP error.
  server,

  /// The connection failed (offline, timeout, proxy).
  network,

  /// The model could not be written (usually a full disk).
  storage,

  /// Anything else.
  unknown,
}

/// A failed model operation, classified for the user.
@immutable
class VoiceModelError extends Equatable {
  const new(this.kind, {this.statusCode});

  /// Classifies [error] (thrown by [OfflineSpeech.download] or
  /// [OfflineSpeech.delete]).
  factory of(Object error) => switch (error) {
    VoiceModelMeteredException() => const VoiceModelError(
      VoiceModelErrorKind.metered,
    ),
    WhisperChecksumException() => const VoiceModelError(
      VoiceModelErrorKind.checksum,
    ),
    WhisperDownloadException(:final int statusCode) => VoiceModelError(
      VoiceModelErrorKind.server,
      statusCode: statusCode,
    ),
    WhisperDownloadException() => const VoiceModelError(
      VoiceModelErrorKind.network,
    ),
    FileSystemException() => const VoiceModelError(VoiceModelErrorKind.storage),
    _ => const VoiceModelError(VoiceModelErrorKind.unknown),
  };

  final VoiceModelErrorKind kind;

  /// The HTTP status of a [VoiceModelErrorKind.server] error.
  final int? statusCode;

  @override
  List<Object?> get props => [kind, statusCode];
}

/// A downloadable speech model as the settings show it.
@immutable
class VoiceModel extends Equatable {
  const new({required this.id, required this.sizeBytes, required this.url});

  /// [WhisperCatalogModel.id]: `tiny` (Fast) or `base` (Better).
  final String id;

  /// Bytes to download (and on disk).
  final int sizeBytes;

  /// Where it is downloaded from (to download it by hand and import it).
  final Uri url;

  @override
  List<Object?> get props => [id, sizeBytes, url];
}

/// Result of a finished download or deletion, shown once by the view.
@immutable
class VoiceModelOutcome extends Equatable {
  const new({
    required this.model,
    required this.operation,
    required this.succeeded,
    this.error,
  });

  /// [VoiceModel.id].
  final String model;
  final VoiceModelOperation operation;
  final bool succeeded;

  /// Why it failed (null on success).
  final VoiceModelError? error;

  /// Whether a Wi-Fi-only download stopped because the network is metered.
  bool get needsMeteredConsent => error?.kind == VoiceModelErrorKind.metered;

  @override
  List<Object?> get props => [model, operation, succeeded, error];
}

/// Result of a finished import from files, shown once by the view.
@immutable
class VoiceImportOutcome extends Equatable {
  const new({
    this.models = const {},
    this.unmatchedFiles = 0,
    this.failed = false,
  });

  /// What happened per model id that a picked file belongs to.
  final Map<String, WhisperImportStatus> models;

  /// Picked files that are no Whisper model.
  final int unmatchedFiles;

  /// The import as a whole failed (the files could not be read).
  final bool failed;

  @override
  List<Object?> get props => [models, unmatchedFiles, failed];
}

class VoiceSettingsState extends Equatable {
  const new({
    this.status = VoiceSettingsStatus.initial,
    this.engine = VoiceInputEngine.system,
    this.offlineSupported = false,
    this.models = const [],
    this.installed = const {},
    this.selected,
    this.pending = const {},
    this.progress = const {},
    this.importing = false,
    this.outcome,
    this.importOutcome,
  });

  final VoiceSettingsStatus status;

  /// The "Speech recognition" choice.
  final VoiceInputEngine engine;

  /// Whether offline speech recognition (Whisper) runs on this device.
  final bool offlineSupported;

  /// The downloadable models, fastest first.
  final List<VoiceModel> models;

  /// Ids of the installed models.
  final Set<String> installed;

  /// Id of the model in use, if any is installed.
  final String? selected;

  /// Downloads and deletions in progress, by model id.
  final Map<String, VoiceModelOperation> pending;

  /// Fraction (0 to 1) of each running download.
  final Map<String, double> progress;

  /// An import from files is running.
  final bool importing;

  /// The latest finished download or deletion (null once another starts).
  final VoiceModelOutcome? outcome;

  /// The latest finished import (null once another starts).
  final VoiceImportOutcome? importOutcome;

  bool isInstalled(String id) => installed.contains(id);

  /// The model [id], if listed.
  VoiceModel? model(String id) =>
      models.where((model) => model.id == id).firstOrNull;

  VoiceSettingsState copyWith({
    VoiceSettingsStatus? status,
    VoiceInputEngine? engine,
    bool? offlineSupported,
    List<VoiceModel>? models,
    Set<String>? installed,
    ValueGetter<String?>? selected,
    Map<String, VoiceModelOperation>? pending,
    Map<String, double>? progress,
    bool? importing,
    ValueGetter<VoiceModelOutcome?>? outcome,
    ValueGetter<VoiceImportOutcome?>? importOutcome,
  }) => VoiceSettingsState(
    status: status ?? this.status,
    engine: engine ?? this.engine,
    offlineSupported: offlineSupported ?? this.offlineSupported,
    models: models ?? this.models,
    installed: installed ?? this.installed,
    selected: selected != null ? selected() : this.selected,
    pending: pending ?? this.pending,
    progress: progress ?? this.progress,
    importing: importing ?? this.importing,
    outcome: outcome != null ? outcome() : this.outcome,
    importOutcome: importOutcome != null ? importOutcome() : this.importOutcome,
  );

  @override
  List<Object?> get props => [
    status,
    engine,
    offlineSupported,
    models,
    installed,
    selected,
    pending,
    progress,
    importing,
    outcome,
    importOutcome,
  ];
}
