import 'dart:io' show FileSystemException;

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:llama_engine/llama_engine.dart';
import 'package:mozhi/on_device_ai/data/on_device_models.dart';
import 'package:mozhi/platform/free_space.dart';

enum OnDeviceAiSettingsStatus { initial, loading, ready }

enum OnDeviceModelOperation { download, delete }

/// Why downloading or deleting an on-device model failed.
enum OnDeviceModelErrorKind {
  /// A Wi-Fi-only download on a metered network: nothing was downloaded
  /// (the page offers to download anyway).
  metered,

  /// This device has too little memory for the model.
  tooBig,

  /// The user stopped the download (what was downloaded is kept).
  cancelled,

  /// The file did not match the catalogue's size or SHA-256 and was
  /// discarded.
  checksum,

  /// The model server answered with an HTTP error.
  server,

  /// The connection failed (offline, timeout, proxy).
  network,

  /// The model could not be written (usually a full disk).
  storage,

  /// The free space was checked first and is too little for the model
  /// ([OnDeviceModelError.space] says how much it needs): nothing was
  /// downloaded.
  space,

  /// Anything else.
  unknown,
}

/// A failed model operation, classified for the user.
@immutable
class OnDeviceModelError extends Equatable {
  const new(this.kind, {this.statusCode, this.mirror, this.space});

  /// Classifies [error] (thrown by [OnDeviceModels.download] or
  /// [OnDeviceModels.delete]).
  factory of(Object error) => switch (error) {
    OnDeviceModelMeteredException() => const OnDeviceModelError(
      OnDeviceModelErrorKind.metered,
    ),
    OnDeviceModelTooBigException() => const OnDeviceModelError(
      OnDeviceModelErrorKind.tooBig,
    ),
    LlamaInsufficientSpaceException(:final mirror) => OnDeviceModelError(
      OnDeviceModelErrorKind.space,
      mirror: mirror?.host,
      space: SpaceShortfall.of(error),
    ),
    LlamaDownloadCancelledException(:final mirror) => OnDeviceModelError(
      OnDeviceModelErrorKind.cancelled,
      mirror: mirror?.host,
    ),
    LlamaChecksumException(:final mirror) => OnDeviceModelError(
      OnDeviceModelErrorKind.checksum,
      mirror: mirror?.host,
    ),
    LlamaDownloadException(:final int statusCode, :final mirror) =>
      OnDeviceModelError(
        OnDeviceModelErrorKind.server,
        statusCode: statusCode,
        mirror: mirror?.host,
      ),
    LlamaDownloadException(:final mirror) => OnDeviceModelError(
      OnDeviceModelErrorKind.network,
      mirror: mirror?.host,
    ),
    FileSystemException() => const OnDeviceModelError(
      OnDeviceModelErrorKind.storage,
    ),
    _ => const OnDeviceModelError(OnDeviceModelErrorKind.unknown),
  };

  final OnDeviceModelErrorKind kind;

  /// The HTTP status of an [OnDeviceModelErrorKind.server] error.
  final int? statusCode;

  /// The host of the model mirror the failed download came from (the
  /// model source setting); null for the default host.
  final String? mirror;

  /// What an [OnDeviceModelErrorKind.space] failure needs and has.
  final SpaceShortfall? space;

  @override
  List<Object?> get props => [kind, statusCode, mirror, space];
}

/// Result of a finished download or deletion, shown once by the view.
@immutable
class OnDeviceModelOutcome extends Equatable {
  const new({
    required this.model,
    required this.operation,
    required this.succeeded,
    this.error,
  });

  /// [LlamaCatalogModel.id].
  final String model;
  final OnDeviceModelOperation operation;
  final bool succeeded;

  /// Why it failed (null on success).
  final OnDeviceModelError? error;

  /// Whether a Wi-Fi-only download stopped because the network is metered.
  bool get needsMeteredConsent => error?.kind == OnDeviceModelErrorKind.metered;

  @override
  List<Object?> get props => [model, operation, succeeded, error];
}

/// Result of a finished import from files, shown once by the view.
@immutable
class OnDeviceImportOutcome extends Equatable {
  const new({
    this.models = const {},
    this.unmatchedFiles = 0,
    this.tooBig = const {},
    this.failed = false,
    this.space,
  });

  /// What happened per model id that a picked file belongs to.
  final Map<String, LlamaImportStatus> models;

  /// Picked files that are no on-device model.
  final int unmatchedFiles;

  /// Installed models this device lacks the memory for (a warning).
  final Set<String> tooBig;

  /// The import as a whole failed (the files could not be read).
  final bool failed;

  /// Too little free space for a model of the import (it failed): how
  /// much it needs and has.
  final SpaceShortfall? space;

  @override
  List<Object?> get props => [models, unmatchedFiles, tooBig, failed, space];
}

class OnDeviceAiSettingsState extends Equatable {
  const new({
    this.status = OnDeviceAiSettingsStatus.initial,
    this.supported = false,
    this.models = const [],
    this.translationModel,
    this.assistantModel,
    this.pending = const {},
    this.progress = const {},
    this.importing = false,
    this.outcome,
    this.importOutcome,
    this.engineBuild,
  });

  final OnDeviceAiSettingsStatus status;

  /// Which build of the engine library runs on this processor (for
  /// support); null when not known.

  /// Whether on-device AI runs on this device (the Android app on a 64-bit
  /// CPU).
  final bool supported;

  /// The catalogue's models with their state, in catalogue order.
  final List<OnDeviceModel> models;

  /// Id of the installed model that translates, if any.
  final String? translationModel;

  /// Id of the installed model that does the AI extras, if any.
  final String? assistantModel;

  /// Downloads and deletions in progress, by model id.
  final Map<String, OnDeviceModelOperation> pending;

  /// Fraction (0 to 1) of each running download.
  final Map<String, double> progress;

  /// An import from files is running.
  final bool importing;

  /// The latest finished download or deletion (null once another starts).
  final OnDeviceModelOutcome? outcome;

  /// The latest finished import (null once another starts).
  final OnDeviceImportOutcome? importOutcome;

  final LlamaEngineBuild? engineBuild;

  /// The model [id], if listed.
  OnDeviceModel? model(String id) =>
      models.where((model) => model.id == id).firstOrNull;

  /// The models of [role], in catalogue order.
  List<OnDeviceModel> ofRole(LlamaModelRole role) => [
    for (final model in models)
      if (model.role == role) model,
  ];

  /// Whether model [id] is the one in use for its role.
  bool inUse(String id) => id == translationModel || id == assistantModel;

  OnDeviceAiSettingsState copyWith({
    OnDeviceAiSettingsStatus? status,
    bool? supported,
    List<OnDeviceModel>? models,
    ValueGetter<String?>? translationModel,
    ValueGetter<String?>? assistantModel,
    Map<String, OnDeviceModelOperation>? pending,
    Map<String, double>? progress,
    bool? importing,
    ValueGetter<OnDeviceModelOutcome?>? outcome,
    ValueGetter<OnDeviceImportOutcome?>? importOutcome,
    ValueGetter<LlamaEngineBuild?>? engineBuild,
  }) => OnDeviceAiSettingsState(
    status: status ?? this.status,
    supported: supported ?? this.supported,
    models: models ?? this.models,
    translationModel: translationModel != null
        ? translationModel()
        : this.translationModel,
    assistantModel: assistantModel != null
        ? assistantModel()
        : this.assistantModel,
    pending: pending ?? this.pending,
    progress: progress ?? this.progress,
    importing: importing ?? this.importing,
    outcome: outcome != null ? outcome() : this.outcome,
    importOutcome: importOutcome != null ? importOutcome() : this.importOutcome,
    engineBuild: engineBuild != null ? engineBuild() : this.engineBuild,
  );

  @override
  List<Object?> get props => [
    status,
    supported,
    models,
    translationModel,
    assistantModel,
    pending,
    progress,
    importing,
    outcome,
    importOutcome,
    engineBuild,
  ];
}
