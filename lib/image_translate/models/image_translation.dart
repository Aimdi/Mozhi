import 'package:flutter/foundation.dart';

/// The outcome of translating an image (possibly still streaming the text
/// translation of on-device recognised text).
@immutable
class ImageTranslation {
  const new({
    this.translatedImage,
    this.sourceText = '',
    this.translatedText = '',
    this.notes = '',
    this.detectedSource,
    this.isComplete = true,
  });

  /// Re-rendered image with the text replaced (Mozhi / Google Lens only).
  final Uint8List? translatedImage;

  /// Text found in the image (Mozhi and on-device recognition).
  final String sourceText;
  final String translatedText;

  /// Extra context a vision model gave about the image.
  final String notes;

  /// Detected source language code, when known.
  final String? detectedSource;

  /// False while the translation of the recognised text is streaming.
  final bool isComplete;

  bool get hasImage => translatedImage != null;

  ImageTranslation copyWith({
    String? sourceText,
    String? translatedText,
    String? detectedSource,
    bool? isComplete,
  }) => ImageTranslation(
    translatedImage: translatedImage,
    sourceText: sourceText ?? this.sourceText,
    translatedText: translatedText ?? this.translatedText,
    notes: notes,
    detectedSource: detectedSource ?? this.detectedSource,
    isComplete: isComplete ?? this.isComplete,
  );

  /// The image bytes are compared by identity (they never change in
  /// place).
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ImageTranslation &&
          identical(other.translatedImage, translatedImage) &&
          other.sourceText == sourceText &&
          other.translatedText == translatedText &&
          other.notes == notes &&
          other.detectedSource == detectedSource &&
          other.isComplete == isComplete;

  @override
  int get hashCode => Object.hash(
    identityHashCode(translatedImage),
    sourceText,
    translatedText,
    notes,
    detectedSource,
    isComplete,
  );

  @override
  String toString() =>
      'ImageTranslation(image: $hasImage, complete: $isComplete, '
      'source: $sourceText, translation: $translatedText)';
}
