import 'package:flutter/foundation.dart';

/// Where a new image comes from.
enum ImagePickSource {
  gallery,
  camera;

  /// Parses a route query value (`gallery` / `camera`); null when unknown.
  static ImagePickSource? tryParse(String? value) => switch (value) {
    'gallery' => ImagePickSource.gallery,
    'camera' => ImagePickSource.camera,
    _ => null,
  };
}

/// An image chosen by the user.
///
/// Equality is identity based on purpose: comparing megabytes of pixels on
/// every state change would be wasteful.
@immutable
class PickedImage {
  const new({
    required this.bytes,
    required this.mimeType,
    this.name = 'image',
    this.path,
  });

  /// Encoded image (JPEG/PNG/WebP/...).
  final Uint8List bytes;

  /// Sniffed MIME type, see [detectImageMimeType].
  final String mimeType;

  /// File name, for display.
  final String name;

  /// Local file path, when there is one (not on web). Needed by on-device
  /// text recognition.
  final String? path;

  @override
  String toString() =>
      'PickedImage($name, $mimeType, ${bytes.lengthInBytes} bytes)';
}

/// MIME types every vision API accepts.
const visionMimeTypes = {'image/jpeg', 'image/png', 'image/webp', 'image/gif'};

/// Detects the MIME type from the file signature, falling back to
/// [reported] and then to the extension of [name] (`image/jpeg` if all
/// else fails).
String detectImageMimeType(Uint8List bytes, {String? name, String? reported}) {
  bool startsWith(List<int> signature, [int offset = 0]) {
    if (bytes.length < offset + signature.length) return false;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[offset + i] != signature[i]) return false;
    }
    return true;
  }

  if (startsWith(const [0x89, 0x50, 0x4E, 0x47])) return 'image/png';
  if (startsWith(const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (startsWith(const [0x47, 0x49, 0x46, 0x38])) return 'image/gif';
  if (startsWith(const [0x52, 0x49, 0x46, 0x46]) &&
      startsWith(const [0x57, 0x45, 0x42, 0x50], 8)) {
    return 'image/webp';
  }
  if (startsWith(const [0x42, 0x4D])) return 'image/bmp';
  if (startsWith('ftyp'.codeUnits, 4)) {
    final brand = bytes.length >= 12
        ? String.fromCharCodes(bytes.sublist(8, 12))
        : '';
    if (brand.startsWith('avif')) return 'image/avif';
    return 'image/heic';
  }

  final type = reported?.trim().toLowerCase();
  if (type != null && type.startsWith('image/')) return type;

  final dot = name?.lastIndexOf('.') ?? -1;
  final extension = dot == -1 ? '' : name!.substring(dot + 1).toLowerCase();
  return switch (extension) {
    'png' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'bmp' => 'image/bmp',
    'heic' || 'heif' => 'image/heic',
    'avif' => 'image/avif',
    _ => 'image/jpeg',
  };
}
