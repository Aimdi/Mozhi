import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:mozhi/offline/data/offline_model_error.dart';

enum OcrOfferStatus {
  /// Waiting for the user's choice.
  idle,

  /// Downloading the data ([OcrOfferState.progress]).
  downloading,

  /// Importing picked files.
  importing,

  /// The data is on the device now: recognition can run.
  installed,
}

class OcrOfferState extends Equatable {
  const new({
    this.status = OcrOfferStatus.idle,
    this.progress,
    this.error,
    this.importReport,
    this.canCancel = false,
    this.cancelling = false,
  });

  final OcrOfferStatus status;

  /// Fraction (0 to 1) of the running download, when known.
  final double? progress;

  /// Why the last download failed; [OfflineModelErrorKind.metered] asks
  /// whether to download over the metered network anyway.
  final OfflineModelError? error;

  /// The last import, when it did not install the offered language.
  final OcrImportReport? importReport;

  /// Whether a running download can be cancelled
  /// (see `CancellableOcrDownloads`).
  final bool canCancel;

  /// Whether a cancel request is in flight for the current download.
  final bool cancelling;

  bool get isBusy =>
      status == OcrOfferStatus.downloading ||
      status == OcrOfferStatus.importing;

  /// Whether the running download can be cancelled right now.
  bool get canCancelDownload =>
      canCancel && status == OcrOfferStatus.downloading && !cancelling;

  OcrOfferState copyWith({
    OcrOfferStatus? status,
    ValueGetter<double?>? progress,
    ValueGetter<OfflineModelError?>? error,
    ValueGetter<OcrImportReport?>? importReport,
    bool? canCancel,
    bool? cancelling,
  }) => OcrOfferState(
    status: status ?? this.status,
    progress: progress != null ? progress() : this.progress,
    error: error != null ? error() : this.error,
    importReport: importReport != null ? importReport() : this.importReport,
    canCancel: canCancel ?? this.canCancel,
    cancelling: cancelling ?? this.cancelling,
  );

  @override
  List<Object?> get props => [
    status,
    progress,
    error,
    importReport,
    canCancel,
    cancelling,
  ];
}
