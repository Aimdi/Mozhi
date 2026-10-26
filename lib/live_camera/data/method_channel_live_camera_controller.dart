import 'dart:ui' show Size;

import 'package:flutter/services.dart';
import 'package:mozhi/image_translate/models/picked_image.dart';
import 'package:mozhi/live_camera/data/live_camera_controller.dart';
import 'package:mozhi/platform/android_device.dart';

/// [LiveCameraController] over the method channel [channelName] of
/// `LiveCameraPlugin.kt` (Camera2, Android only; [isSupported] is false
/// elsewhere, default [runsOnAndroid]).
///
/// What the platform answers is checked before use: a frame must fit its
/// own size (at most [maxFrameSide] pixels a side, one byte per pixel,
/// rows of at least its width) and turn by a quarter, a still must be a
/// JPEG of at most [maxStillBytes]; anything else fails as
/// [LiveCameraErrorKind.failed].
class MethodChannelLiveCameraController
    implements LiveCameraController, LiveCameraPlatform {
  MethodChannelLiveCameraController({MethodChannel? channel, bool? isAndroid})
    : _channel = channel ?? const MethodChannel(channelName),
      _isAndroid = isAndroid ?? runsOnAndroid;

  /// The plugin's channel.
  static const channelName = 'mozhi/live_camera';

  /// Longest frame side accepted.
  static const maxFrameSide = 4096;

  /// Largest still accepted (bytes).
  static const maxStillBytes = 32 * 1024 * 1024;

  final MethodChannel _channel;
  final bool _isAndroid;

  @override
  bool get isSupported => _isAndroid;

  @override
  Future<CameraAccess> requestAccess() async {
    if (!_isAndroid) return CameraAccess.denied;
    try {
      final answer = await _channel.invokeMethod<String>('requestAccess');
      return switch (answer) {
        'granted' => CameraAccess.granted,
        'blocked' => CameraAccess.blocked,
        _ => CameraAccess.denied,
      };
    } on PlatformException {
      return CameraAccess.denied;
    } on MissingPluginException {
      return CameraAccess.denied;
    }
  }

  @override
  Future<LivePreview> start() async {
    if (!_isAndroid) {
      throw const LiveCameraException(LiveCameraErrorKind.noCamera);
    }
    final Map<Object?, Object?>? answer;
    try {
      answer = await _channel.invokeMapMethod<Object?, Object?>('start');
    } on PlatformException catch (error) {
      throw _failure(error);
    } on MissingPluginException catch (error) {
      throw LiveCameraException(
        LiveCameraErrorKind.noCamera,
        message: error.message,
      );
    }
    final textureId = _int(answer?['textureId']);
    final width = _int(answer?['previewWidth']);
    final height = _int(answer?['previewHeight']);
    final rotation = _int(answer?['rotation']);
    if (textureId == null ||
        width == null ||
        height == null ||
        width <= 0 ||
        height <= 0 ||
        !_isQuarter(rotation)) {
      throw const LiveCameraException(
        LiveCameraErrorKind.failed,
        message: 'Unexpected start answer',
      );
    }
    final minZoom = _double(answer?['minZoom']) ?? 1;
    final maxZoom = _double(answer?['maxZoom']) ?? 1;
    return LivePreview(
      textureId: textureId,
      previewSize: Size(width.toDouble(), height.toDouble()),
      rotation: rotation!,
      hasTorch: answer?['hasTorch'] == true,
      minZoom: minZoom,
      maxZoom: maxZoom < minZoom ? minZoom : maxZoom,
    );
  }

  @override
  Future<CameraFrame?> nextFrame() async {
    if (!_isAndroid) return null;
    final Map<Object?, Object?>? answer;
    try {
      answer = await _channel.invokeMapMethod<Object?, Object?>('nextFrame');
    } on PlatformException catch (error) {
      throw _failure(error);
    } on MissingPluginException {
      return null;
    }
    if (answer == null) return null;
    final pixels = answer['pixels'];
    final width = _int(answer['width']);
    final height = _int(answer['height']);
    final bytesPerRow = _int(answer['bytesPerRow']);
    final rotation = _int(answer['rotationDegrees']);
    final timestamp = _int(answer['timestamp']) ?? 0;
    if (pixels is! Uint8List ||
        width == null ||
        height == null ||
        bytesPerRow == null ||
        width <= 0 ||
        height <= 0 ||
        width > maxFrameSide ||
        height > maxFrameSide ||
        bytesPerRow < width ||
        pixels.length < bytesPerRow * (height - 1) + width ||
        !_isQuarter(rotation)) {
      throw const LiveCameraException(
        LiveCameraErrorKind.failed,
        message: 'Unexpected frame',
      );
    }
    return CameraFrame(
      pixels: pixels,
      width: width,
      height: height,
      bytesPerRow: bytesPerRow,
      rotationDegrees: rotation!,
      timestamp: Duration(microseconds: timestamp),
    );
  }

  @override
  Future<void> setTorch({required bool on}) => _quietly('setTorch', {'on': on});

  @override
  Future<void> setZoom(double ratio) {
    if (ratio.isNaN || ratio.isInfinite) return Future.value();
    return _quietly('setZoom', {'ratio': ratio});
  }

  @override
  Future<PickedImage?> takePicture() async {
    if (!_isAndroid) return null;
    final Uint8List? bytes;
    try {
      bytes = await _channel.invokeMethod<Uint8List>('takePicture');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
    if (bytes == null ||
        bytes.isEmpty ||
        bytes.length > maxStillBytes ||
        detectImageMimeType(bytes) != 'image/jpeg') {
      return null;
    }
    return PickedImage(bytes: bytes, mimeType: 'image/jpeg', name: stillName);
  }

  /// The name of a still on the photo page.
  static const stillName = 'live-camera.jpg';

  @override
  Future<void> stop() => _quietly('stop');

  @override
  Future<bool> openAppSettings() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('openAppSettings') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<int> displayRotation() async {
    if (!_isAndroid) return 0;
    try {
      final degrees = await _channel.invokeMethod<int>('displayRotation');
      return _isQuarter(degrees) ? degrees! : 0;
    } on PlatformException {
      return 0;
    } on MissingPluginException {
      return 0;
    }
  }

  /// Calls [method], ignoring the platform's errors (the camera may have
  /// stopped meanwhile).
  Future<void> _quietly(String method, [Object? arguments]) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<Object?>(method, arguments);
    } on PlatformException {
      // Nothing to do: the camera is gone.
    } on MissingPluginException {
      // No platform side.
    }
  }

  static LiveCameraException _failure(PlatformException error) =>
      LiveCameraException(switch (error.code) {
        'no_camera' => LiveCameraErrorKind.noCamera,
        'permission' => LiveCameraErrorKind.permission,
        'in_use' => LiveCameraErrorKind.inUse,
        'disabled' => LiveCameraErrorKind.disabled,
        'background' => LiveCameraErrorKind.background,
        _ => LiveCameraErrorKind.failed,
      }, message: error.message);

  static int? _int(Object? value) => switch (value) {
    final int number => number,
    _ => null,
  };

  static double? _double(Object? value) => switch (value) {
    final num number when number.isFinite => number.toDouble(),
    _ => null,
  };

  static bool _isQuarter(int? degrees) =>
      degrees == 0 || degrees == 90 || degrees == 180 || degrees == 270;
}

/// The live camera where there is none (the web, desktop tests): never
/// supported, never opens.
class UnsupportedLiveCameraController implements LiveCameraController {
  const UnsupportedLiveCameraController();

  @override
  bool get isSupported => false;

  @override
  Future<CameraAccess> requestAccess() async => CameraAccess.denied;

  @override
  Future<LivePreview> start() =>
      Future.error(const LiveCameraException(LiveCameraErrorKind.noCamera));

  @override
  Future<CameraFrame?> nextFrame() async => null;

  @override
  Future<void> setTorch({required bool on}) async {}

  @override
  Future<void> setZoom(double ratio) async {}

  @override
  Future<PickedImage?> takePicture() async => null;

  @override
  Future<void> stop() async {}
}

/// The app's live camera: the Camera2 plugin on Android, else
/// [UnsupportedLiveCameraController].
LiveCameraController defaultLiveCameraController() => runsOnAndroid
    ? MethodChannelLiveCameraController()
    : const UnsupportedLiveCameraController();
