import 'package:flutter/foundation.dart';
import 'package:translation_repository/translation_repository.dart'
    show DataDestination;

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
    this.destination,
    this.recognitionConfidence,
  });

  /// Where the image (or its recognised text) was sent, when known.
  final DataDestination? destination;

  /// Re-rendered image with the text replaced (Mozhi via Google Translate
  /// only).
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

  /// How sure on-device recognition is of [sourceText], 0 to 100
  /// (Tesseract's mean word confidence); null when unknown (other methods,
  /// ML Kit, edited text).
  final int? recognitionConfidence;

  bool get hasImage => translatedImage != null;

  ImageTranslation copyWith({
    String? sourceText,
    String? translatedText,
    String? detectedSource,
    bool? isComplete,
    DataDestination? destination,
  }) => ImageTranslation(
    translatedImage: translatedImage,
    sourceText: sourceText ?? this.sourceText,
    translatedText: translatedText ?? this.translatedText,
    notes: notes,
    detectedSource: detectedSource ?? this.detectedSource,
    isComplete: isComplete ?? this.isComplete,
    destination: destination ?? this.destination,
    recognitionConfidence: recognitionConfidence,
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
          other.isComplete == isComplete &&
          other.destination == destination &&
          other.recognitionConfidence == recognitionConfidence;

  @override
  int get hashCode => Object.hash(
    identityHashCode(translatedImage),
    sourceText,
    translatedText,
    notes,
    detectedSource,
    isComplete,
    destination,
    recognitionConfidence,
  );

  @override
  String toString() =>
      'ImageTranslation(image: $hasImage, complete: $isComplete, '
      'source: $sourceText, translation: $translatedText)';
}
