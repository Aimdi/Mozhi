import 'package:mozhi/core/widgets/decimal_format.dart';
import 'package:mozhi/image_translate/widgets/image_translate_labels.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/live_camera/cubit/live_camera_cubit.dart';
import 'package:mozhi/live_camera/data/live_camera_controller.dart';
import 'package:mozhi/platform/device_conditions.dart';

/// The live camera's status line: what it does now, in a few words. It
/// changes with the status only (never with what a frame shows), so a
/// screen reader announces it only then.
String liveCameraStatusText(AppLocalizations l10n, LiveCameraState state) =>
    switch (state.status) {
      LiveCameraStatus.initial ||
      LiveCameraStatus.requestingAccess ||
      LiveCameraStatus.starting => l10n.liveCameraStatusStarting,
      LiveCameraStatus.running => switch (state.strain) {
        DeviceStrain.heat => l10n.liveCameraStatusSlowHeat,
        DeviceStrain.batterySaver => l10n.liveCameraStatusSlowBattery,
        null => l10n.liveCameraStatusLive(state.engine.name),
      },
      LiveCameraStatus.paused => switch (state.pauseReason) {
        LivePauseReason.locked => l10n.liveCameraStatusPausedLocked,
        LivePauseReason.heat => l10n.liveCameraStatusPausedHeat,
        LivePauseReason.background || null => l10n.liveCameraStatusPaused,
      },
      LiveCameraStatus.freezing ||
      LiveCameraStatus.frozen => l10n.liveCameraStatusFreezing,
      LiveCameraStatus.denied => l10n.liveCameraPermissionDenied,
      LiveCameraStatus.blocked => l10n.liveCameraBlockedBody,
      LiveCameraStatus.unsupported => l10n.liveCameraUnsupported,
      LiveCameraStatus.failed => liveCameraErrorText(l10n, state.cameraError),
    };

/// What went wrong with the camera.
String liveCameraErrorText(AppLocalizations l10n, LiveCameraErrorKind? kind) =>
    switch (kind) {
      LiveCameraErrorKind.noCamera => l10n.liveCameraErrorNoCamera,
      LiveCameraErrorKind.inUse => l10n.liveCameraErrorInUse,
      LiveCameraErrorKind.disabled => l10n.liveCameraErrorDisabled,
      LiveCameraErrorKind.stalled => l10n.liveCameraErrorStalled,
      LiveCameraErrorKind.permission => l10n.liveCameraPermissionDenied,
      LiveCameraErrorKind.background ||
      LiveCameraErrorKind.failed ||
      null => l10n.liveCameraErrorFailed,
    };

/// Why the live engine failed, in a sentence.
String liveCameraTranslationErrorText(AppLocalizations l10n, Object error) =>
    l10n.liveCameraTranslationError(
      describeImageTranslateError(l10n, error).message,
    );

/// A zoom ratio for people: `1`, `2`, `2.5` (`2,5` in German: the number
/// format of [locale], `AppLocalizations.localeName`).
String liveCameraZoomLabel(double ratio, {String locale = 'en'}) =>
    formatDecimal((ratio * 10).round() / 10, locale, trimZero: true);

/// The zoom after [current] in the zoom button's cycle (1×, 2×, 4×, …
/// within [min] to [max], then back to [min]).
double nextLiveCameraZoom(
  double current, {
  required double min,
  required double max,
}) {
  for (final step in const [1.0, 2.0, 4.0, 8.0]) {
    if (step > current + 0.05 && step <= max + 0.001 && step >= min) {
      return step;
    }
  }
  return min;
}
