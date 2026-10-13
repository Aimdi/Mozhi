/// The engine needs an explicit source language, and none could be
/// detected for the text.
///
/// Thrown (as a stream error of `TranslationRepository.translate`) for
/// translation-specialised AI models (`TranslationEngine.usesMtProfile`) and
/// the offline engine when the source is auto and neither on-device
/// identification nor (for non-local engines) a Mozhi instance could tell
/// the language. The app should ask the user to pick the source language.
final class SourceLanguageRequiredException implements Exception {
  const new({this.engineId, this.cause});

  /// The engine that needs the source language.
  final String? engineId;

  /// The detection failure, if detection was attempted and failed.
  final Object? cause;

  @override
  String toString() =>
      'SourceLanguageRequiredException('
      '${engineId ?? 'engine'} needs an explicit source language'
      '${cause == null ? '' : '; detection failed: $cause'})';
}
