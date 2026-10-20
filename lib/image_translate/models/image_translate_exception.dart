import 'package:flutter/foundation.dart';

/// Image translation specific failures (other errors, such as
/// `MozhiApiException` or `LlmApiException`, are reported as they are).
enum ImageTranslateErrorKind {
  /// HTTP 413: the server rejected the upload size.
  tooLarge,

  /// HTTP 400: the server could not process the image or language pair.
  unsupported,

  /// The bytes could not be decoded as an image.
  invalidImage,

  /// No text was found in the image.
  noText,

  /// Camera / photo library access was denied.
  permissionDenied,

  /// The picker failed for another reason.
  pickFailed,

  /// No translation engine is available for the recognised text.
  noEngine,

  /// The method cannot translate between the selected languages (e.g. a
  /// custom target language with Mozhi).
  unsupportedLanguage,

  /// On-device text recognition failed.
  recognitionFailed,

  /// On-device text recognition has no data for the source language (e.g.
  /// Xhosa, or Malay in Jawi script with Tesseract).
  recognitionLanguageUnsupported,

  /// The server took too long (Mozhi's relay to Google Translate can be
  /// slow on large images, see `TranslationRepository.mozhiImageTimeout`).
  timeout,

  /// Mozhi answered without an image and without text: it passes Google
  /// Translate's answer on unchecked, so Google refused the request (often
  /// for that instance's address) or found no text. On-device recognition
  /// does not depend on it.
  serviceRefused,
}

@immutable
class ImageTranslateException implements Exception {
  const new(this.kind, {this.cause});

  final ImageTranslateErrorKind kind;

  /// The underlying error, if any.
  final Object? cause;

  @override
  bool operator ==(Object other) =>
      other is ImageTranslateException && other.kind == kind;

  @override
  int get hashCode => kind.hashCode;

  @override
  String toString() =>
      'ImageTranslateException(${kind.name}${cause == null ? '' : ': $cause'})';
}
