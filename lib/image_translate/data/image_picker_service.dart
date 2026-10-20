import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:mozhi/platform/android_device.dart';

/// Lets the user choose an image (injectable for tests).
abstract interface class ImagePickerService {
  /// Whether [pick] supports [ImagePickSource.camera] on this platform.
  bool get supportsCamera;

  /// Resolves to null when the user dismisses the picker. Throws an
  /// [ImageTranslateException] (`permissionDenied` / `pickFailed`) on
  /// failure.
  Future<PickedImage?> pick(ImagePickSource source);

  /// The image of a [pick] that Android could not deliver because it ended
  /// the app meanwhile (the camera app needs a lot of memory), once: null
  /// when there is none, and on other platforms. Throws like [pick] when
  /// that pick had failed.
  Future<PickedImage?> retrieveLost();
}

/// [ImagePickerService] backed by `image_picker`.
///
/// Images are downscaled by the plugin to [maxDimension] (long side) and
/// re-compressed with [imageQuality] where the platform supports it.
class PluginImagePickerService implements ImagePickerService {
  new({ImagePicker? picker, this._isWeb = kIsWeb, bool? isAndroid})
    : _picker = picker ?? ImagePicker(),
      _isAndroid = isAndroid ?? runsOnAndroid;

  static const maxDimension = 2048.0;
  static const imageQuality = 92;

  /// Platform error codes `image_picker` uses for denied access.
  static const _deniedCodes = {
    'camera_access_denied',
    'photo_access_denied',
    'camera_access_restricted',
    'photo_access_restricted',
  };

  final ImagePicker _picker;
  final bool _isWeb;

  /// Whether lost picks can be retrieved (`retrieveLostData` is Android
  /// only).
  final bool _isAndroid;

  @override
  bool get supportsCamera {
    try {
      return _picker.supportsImageSource(ImageSource.camera);
    } on Object {
      return false;
    }
  }

  @override
  Future<PickedImage?> pick(ImagePickSource source) async {
    final XFile? file;
    try {
      file = await _picker.pickImage(
        source: switch (source) {
          ImagePickSource.gallery => ImageSource.gallery,
          ImagePickSource.camera => ImageSource.camera,
        },
        maxWidth: maxDimension,
        maxHeight: maxDimension,
        imageQuality: imageQuality,
        requestFullMetadata: false,
      );
    } on PlatformException catch (error) {
      throw _pickFailure(error);
    } on Object catch (error) {
      throw ImageTranslateException(
        ImageTranslateErrorKind.pickFailed,
        cause: error,
      );
    }
    if (file == null) return null;
    return await _read(file);
  }

  @override
  Future<PickedImage?> retrieveLost() async {
    if (_isWeb || !_isAndroid) return null;
    final LostDataResponse response;
    try {
      response = await _picker.retrieveLostData();
    } on Object catch (error) {
      throw ImageTranslateException(
        ImageTranslateErrorKind.pickFailed,
        cause: error,
      );
    }
    if (response.isEmpty) return null;
    final exception = response.exception;
    if (exception != null) throw _pickFailure(exception);
    final file = response.file ?? response.files?.lastOrNull;
    if (file == null || response.type == RetrieveType.video) return null;
    return await _read(file);
  }

  ImageTranslateException _pickFailure(PlatformException error) =>
      ImageTranslateException(
        _deniedCodes.contains(error.code)
            ? ImageTranslateErrorKind.permissionDenied
            : ImageTranslateErrorKind.pickFailed,
        cause: error,
      );

  Future<PickedImage> _read(XFile file) async {
    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } on Object catch (error) {
      throw ImageTranslateException(
        ImageTranslateErrorKind.pickFailed,
        cause: error,
      );
    }
    return PickedImage(
      bytes: bytes,
      mimeType: detectImageMimeType(
        bytes,
        name: file.name,
        reported: file.mimeType,
      ),
      name: file.name,
      path: _isWeb || file.path.isEmpty ? null : file.path,
    );
  }
}
