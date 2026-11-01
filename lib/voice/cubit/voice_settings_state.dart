import 'dart:io' show FileSystemException;

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:mozhi/platform/free_space.dart';
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

  /// The free space was checked first and is too little for the model
  /// ([VoiceModelError.space] says how much it needs): nothing was
  /// downloaded.
  space,

  /// The user cancelled the download (`VoiceSettingsCubit.cancel`):
  /// nothing to explain.
  cancelled,

  /// Anything else.
  unknown,
}

/// A failed model operation, classified for the user.
@immutable
class VoiceModelError extends Equatable {
  const new(this.kind, {this.statusCode, this.mirror, this.space});

  /// Classifies [error] (thrown by [OfflineSpeech.download] or
  /// [OfflineSpeech.delete]).
  factory of(Object error) => switch (error) {
    VoiceModelMeteredException() => const VoiceModelError(
      VoiceModelErrorKind.metered,
    ),
    WhisperDownloadCancelledException() => const VoiceModelError(
      VoiceModelErrorKind.cancelled,
    ),
    WhisperInsufficientSpaceException(:final mirror) => VoiceModelError(
      VoiceModelErrorKind.space,
      mirror: mirror?.host,
      space: SpaceShortfall.of(error),
    ),
    WhisperChecksumException(:final mirror) => VoiceModelError(
      VoiceModelErrorKind.checksum,
      mirror: mirror?.host,
    ),
    WhisperDownloadException(:final int statusCode, :final mirror) =>
      VoiceModelError(
        VoiceModelErrorKind.server,
        statusCode: statusCode,
        mirror: mirror?.host,
      ),
    WhisperDownloadException(:final mirror) => VoiceModelError(
      VoiceModelErrorKind.network,
      mirror: mirror?.host,
    ),
    FileSystemException() => const VoiceModelError(VoiceModelErrorKind.storage),
    _ => const VoiceModelError(VoiceModelErrorKind.unknown),
  };

  final VoiceModelErrorKind kind;

  /// The HTTP status of a [VoiceModelErrorKind.server] error.
  final int? statusCode;

  /// The host of the model mirror the failed download came from (the
  /// model source setting); null for the default host.
  final String? mirror;

  /// What a [VoiceModelErrorKind.space] failure needs and has.
  final SpaceShortfall? space;

  @override
  List<Object?> get props => [kind, statusCode, mirror, space];
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
    this.space,
  });

  /// What happened per model id that a picked file belongs to.
  final Map<String, WhisperImportStatus> models;

  /// Too little free space for a model of the import (it failed): how
  /// much it needs and has.
  final SpaceShortfall? space;

  /// Picked files that are no Whisper model.
  final int unmatchedFiles;

  /// The import as a whole failed (the files could not be read).
  final bool failed;

  @override
  List<Object?> get props => [models, unmatchedFiles, failed, space];
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
    this.voiceDetection,
    this.voiceDetectionInstalled = false,
    this.engineBuild,
  });

  final VoiceSettingsStatus status;

  /// Which build of the Whisper engine library runs on this processor
  /// (for support); null when not known or Whisper does not run here.
  final WhisperEngineBuild? engineBuild;

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

  /// The voice activity detection model (Silero VAD, about 0.9 MB), which
  /// lets Whisper transcribe phrase by phrase: downloaded with every speech
  /// model, imported with them, deleted with the last one. Null without
  /// one (or where Whisper does not run).
  final VoiceModel? voiceDetection;

  /// Whether [voiceDetection] is installed.
  final bool voiceDetectionInstalled;

  /// A speech model is installed but not the voice activity model (it was
  /// installed before the app had one): offer to download it.
  bool get voiceDetectionMissing =>
      voiceDetection != null &&
      !voiceDetectionInstalled &&
      installed.isNotEmpty;

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
    ValueGetter<VoiceModel?>? voiceDetection,
    bool? voiceDetectionInstalled,
    ValueGetter<WhisperEngineBuild?>? engineBuild,
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
    voiceDetection: voiceDetection != null
        ? voiceDetection()
        : this.voiceDetection,
    voiceDetectionInstalled:
        voiceDetectionInstalled ?? this.voiceDetectionInstalled,
    engineBuild: engineBuild != null ? engineBuild() : this.engineBuild,
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
    voiceDetection,
    voiceDetectionInstalled,
    engineBuild,
  ];
}
