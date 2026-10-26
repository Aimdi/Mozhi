import 'dart:ui' show Size;

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:mozhi/image_translate/models/picked_image.dart';

/// Whether the app may use the camera.
enum CameraAccess {
  granted,

  /// Refused this time; asking again shows Android's dialog again.
  denied,

  /// Refused for good ("Don't ask again", or a policy): Android shows no
  /// dialog any more, only the app's settings can allow it.
  blocked,
}

/// Why the camera could not be used.
enum LiveCameraErrorKind {
  /// No back (or external) camera on this device.
  noCamera,

  /// The camera permission is missing.
  permission,

  /// Another app is using the camera (or took it away).
  inUse,

  /// A device policy or setting turned the camera off.
  disabled,

  /// The app is in the background: Android does not open the camera then.
  background,

  /// No frame arrived for a while.
  stalled,

  /// Anything else.
  failed,
}

/// The camera failed ([kind]).
@immutable
class LiveCameraException implements Exception {
  const LiveCameraException(this.kind, {this.message});

  final LiveCameraErrorKind kind;

  /// The platform's message, for logs and details.
  final String? message;

  @override
  bool operator ==(Object other) =>
      other is LiveCameraException && other.kind == kind;

  @override
  int get hashCode => kind.hashCode;

  @override
  String toString() =>
      'LiveCameraException(${kind.name}${message == null ? '' : ': $message'})';
}

/// The running camera's preview: the Flutter texture it is drawn on and
/// how to show it.
@immutable
class LivePreview extends Equatable {
  const LivePreview({
    required this.textureId,
    required this.previewSize,
    required this.rotation,
    this.hasTorch = false,
    this.minZoom = 1,
    this.maxZoom = 1,
  });

  /// For a `Texture` widget.
  final int textureId;

  /// The preview's size as the camera delivers it (usually landscape).
  final Size previewSize;

  /// Clockwise degrees (0, 90, 180 or 270) the camera image is turned from
  /// the device's natural orientation (the sensor orientation). The
  /// texture is drawn upright for that orientation: [sizeOnScreen] tells
  /// the size it has there, the preview turns it with the display.
  final int rotation;

  /// Whether the camera has a flashlight.
  final bool hasTorch;

  /// The zoom ratios the camera offers.
  final double minZoom;
  final double maxZoom;

  /// The texture's size in the device's natural orientation, turned for a
  /// display rotated [displayRotation] degrees (0, 90, 180 or 270) from it.
  Size sizeOnScreen(int displayRotation) {
    final natural = rotation % 180 == 0
        ? previewSize
        : Size(previewSize.height, previewSize.width);
    return displayRotation % 180 == 0
        ? natural
        : Size(natural.height, natural.width);
  }

  @override
  List<Object?> get props => [
    textureId,
    previewSize,
    rotation,
    hasTorch,
    minZoom,
    maxZoom,
  ];
}

/// One camera frame's grey (luma) pixels, one byte per pixel, rows
/// [bytesPerRow] bytes apart, as the camera delivers them: turn them
/// [rotationDegrees] clockwise to see them upright on the screen as it
/// was turned then. Only ever in memory.
///
/// Equality is identity based on purpose, like [PickedImage].
@immutable
class CameraFrame {
  const CameraFrame({
    required this.pixels,
    required this.width,
    required this.height,
    required this.bytesPerRow,
    required this.rotationDegrees,
    required this.timestamp,
  });

  final Uint8List pixels;
  final int width;
  final int height;
  final int bytesPerRow;

  /// 0, 90, 180 or 270.
  final int rotationDegrees;

  /// When the camera took it (the camera's clock).
  final Duration timestamp;

  @override
  String toString() =>
      'CameraFrame(${width}x$height, $rotationDegrees°, $timestamp)';
}

/// The live camera (contract W7-A): Android's back camera through the
/// app's Camera2 plugin (`LiveCameraPlugin.kt`), see
/// `MethodChannelLiveCameraController`; never on the web
/// (`UnsupportedLiveCameraController`).
///
/// Frames are pulled: none is copied unless [nextFrame] asks, and the
/// caller asks for at most a few a second. Frames and stills stay in
/// memory; nothing is saved or sent.
abstract interface class LiveCameraController {
  /// Android with a camera.
  bool get isSupported;

  /// Asks for the camera permission when it is missing: granted, denied or
  /// blocked.
  Future<CameraAccess> requestAccess();

  /// Opens the camera and its preview. Throws [LiveCameraException].
  Future<LivePreview> start();

  /// The latest grey (Y plane) frame; null once stopped. Throws
  /// [LiveCameraException] when the camera failed.
  Future<CameraFrame?> nextFrame();

  /// Turns the flashlight on or off (no-op without one).
  Future<void> setTorch({required bool on});

  /// Zooms to [ratio] (clamped to the camera's range).
  Future<void> setZoom(double ratio);

  /// A JPEG still for the photo page; null when the camera is not
  /// running or the picture failed.
  Future<PickedImage?> takePicture();

  /// Closes the camera and its preview.
  Future<void> stop();
}

/// What the Android camera can do besides [LiveCameraController] (found
/// with [liveCameraPlatformOf]).
abstract interface class LiveCameraPlatform {
  /// Opens the app's page in Android's settings (to allow the camera after
  /// "Don't ask again"). Whether it opened.
  Future<bool> openAppSettings();

  /// The display's rotation from its natural orientation, in degrees (0,
  /// 90, 180 or 270).
  Future<int> displayRotation();
}

/// [camera] as a [LiveCameraPlatform], when it is one.
LiveCameraPlatform? liveCameraPlatformOf(LiveCameraController camera) =>
    switch (camera) {
      final LiveCameraPlatform platform => platform,
      _ => null,
    };
