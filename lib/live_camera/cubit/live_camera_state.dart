import 'dart:ui' show Size;

import 'package:equatable/equatable.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:mozhi/live_camera/data/live_camera_controller.dart';
import 'package:mozhi/live_camera/models/live_block.dart';
import 'package:mozhi/platform/device_conditions.dart';
import 'package:translation_repository/translation_repository.dart';

/// Where the live camera is.
enum LiveCameraStatus {
  /// Not started yet.
  initial,

  /// Asking for the camera permission.
  requestingAccess,

  /// The permission was refused this time (`LiveCameraCubit.retryAccess`).
  denied,

  /// The permission was refused for good: only the app's settings can
  /// allow it (`LiveCameraCubit.openSettings`).
  blocked,

  /// No live camera here (the web, no camera, no on-device recognition).
  unsupported,

  /// Opening the camera.
  starting,

  /// The preview shows and frames are read.
  running,

  /// Stopped for a while ([LiveCameraState.pauseReason]); starts again by
  /// itself.
  paused,

  /// Taking the still.
  freezing,

  /// The still was taken ([LiveCameraState.still]); the camera is closed.
  frozen,

  /// The camera failed ([LiveCameraState.cameraError]).
  failed,
}

/// Why the live camera is [LiveCameraStatus.paused], most important first.
enum LivePauseReason {
  /// Mozhi is locked (the app lock).
  locked,

  /// The app is not on the screen.
  background,

  /// The phone is critically hot.
  heat,
}

/// The live camera screen: the camera, what it reads and the translations.
class LiveCameraState extends Equatable {
  const new({
    required this.source,
    required this.target,
    required this.engine,
    this.status = LiveCameraStatus.initial,
    this.preview,
    this.displayRotation = 0,
    this.frameSize,
    this.blocks = const [],
    this.torchOn = false,
    this.zoom = 1,
    this.pauseReason,
    this.strain,
    this.ocrMissing,
    this.ocrUnsupported = false,
    this.recognitionFailed = false,
    this.translationError,
    this.consent,
    this.cameraError,
    this.still,
    this.freezeFailures = 0,
  });

  final LiveCameraStatus status;

  /// The language of the text (may be "Detect language").
  final Language source;
  final Language target;

  /// The live engine translating it (`resolveLiveEngine`).
  final TranslationEngine engine;

  /// The open camera's preview.
  final LivePreview? preview;

  /// The display's rotation from its natural orientation, in degrees, as
  /// the last frame was taken (turns the preview).
  final int displayRotation;

  /// The size of the upright frame the [blocks]' boxes are in.
  final Size? frameSize;

  /// The text the camera sees, tracked across frames, top to bottom.
  final List<LiveBlock> blocks;

  final bool torchOn;
  final double zoom;

  /// Why it is paused (while [LiveCameraStatus.paused]).
  final LivePauseReason? pauseReason;

  /// Heat or battery saver: the camera reads less often.
  final DeviceStrain? strain;

  /// Text recognition lacks the data for the source language: offered
  /// for download (nothing is read meanwhile).
  final OcrDataMissingException? ocrMissing;

  /// No recognition data reads the source language.
  final bool ocrUnsupported;

  /// Text recognition failed several frames in a row.
  final bool recognitionFailed;

  /// The live engine's last failure (retried after a while).
  final Object? translationError;

  /// The privacy settings stopped the live engine: nothing is translated
  /// until the user allows it (`LiveCameraCubit.consentGranted`).
  final ConsentRequiredException? consent;

  /// Why the camera failed (while [LiveCameraStatus.failed]).
  final LiveCameraErrorKind? cameraError;

  /// The frozen still for the photo page (while
  /// [LiveCameraStatus.frozen]).
  final PickedImage? still;

  /// How often a freeze failed (a new value shows a message).
  final int freezeFailures;

  /// Whether the preview shows and frames are read.
  bool get isLive => status == LiveCameraStatus.running;

  /// The blocks with a translation to show.
  List<LiveBlock> get translatedBlocks => [
    for (final block in blocks)
      if (block.hasTranslation) block,
  ];

  LiveCameraState copyWith({
    LiveCameraStatus? status,
    Language? source,
    Language? target,
    TranslationEngine? engine,
    LivePreview? Function()? preview,
    int? displayRotation,
    Size? Function()? frameSize,
    List<LiveBlock>? blocks,
    bool? torchOn,
    double? zoom,
    LivePauseReason? Function()? pauseReason,
    DeviceStrain? Function()? strain,
    OcrDataMissingException? Function()? ocrMissing,
    bool? ocrUnsupported,
    bool? recognitionFailed,
    Object? Function()? translationError,
    ConsentRequiredException? Function()? consent,
    LiveCameraErrorKind? Function()? cameraError,
    PickedImage? Function()? still,
    int? freezeFailures,
  }) => LiveCameraState(
    status: status ?? this.status,
    source: source ?? this.source,
    target: target ?? this.target,
    engine: engine ?? this.engine,
    preview: preview != null ? preview() : this.preview,
    displayRotation: displayRotation ?? this.displayRotation,
    frameSize: frameSize != null ? frameSize() : this.frameSize,
    blocks: blocks ?? this.blocks,
    torchOn: torchOn ?? this.torchOn,
    zoom: zoom ?? this.zoom,
    pauseReason: pauseReason != null ? pauseReason() : this.pauseReason,
    strain: strain != null ? strain() : this.strain,
    ocrMissing: ocrMissing != null ? ocrMissing() : this.ocrMissing,
    ocrUnsupported: ocrUnsupported ?? this.ocrUnsupported,
    recognitionFailed: recognitionFailed ?? this.recognitionFailed,
    translationError: translationError != null
        ? translationError()
        : this.translationError,
    consent: consent != null ? consent() : this.consent,
    cameraError: cameraError != null ? cameraError() : this.cameraError,
    still: still != null ? still() : this.still,
    freezeFailures: freezeFailures ?? this.freezeFailures,
  );

  @override
  List<Object?> get props => [
    status,
    source,
    target,
    engine.id,
    preview,
    displayRotation,
    frameSize,
    blocks,
    torchOn,
    zoom,
    pauseReason,
    strain,
    ocrMissing,
    ocrUnsupported,
    recognitionFailed,
    translationError,
    consent,
    cameraError,
    still,
    freezeFailures,
  ];
}
