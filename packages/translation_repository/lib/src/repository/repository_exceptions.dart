import 'package:translation_repository/src/models/data_destination.dart';

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

/// Why a request needs the user's say before its text leaves the device.
enum ConsentKind {
  /// [PrivacyMode.offlineOnly]: network translation is off altogether.
  /// The user can only change the privacy mode (or install the pair).
  offlineOnly,

  /// [PrivacyMode.offlineFirst] and the language pair is not installed on
  /// the device and was not approved for the network yet.
  pair,

  /// A cloud provider ([CloudProviderDestination]) that the user has not
  /// agreed to send text to yet (asked once per provider, in every mode).
  cloudProvider,
}

/// The request would send text over the network, which the privacy
/// settings do not allow without the user's consent. Nothing was sent.
///
/// Thrown (as a stream error of `TranslationRepository.translate` and by
/// the other request methods) before any network call. The app asks the
/// user (showing [destination]) and retries after recording the consent in
/// the settings (pushed to the repository with
/// `TranslationRepository.updatePrivacy`).
final class ConsentRequiredException implements Exception {
  const new({
    required this.kind,
    required this.destination,
    required this.engineId,
    this.source,
    this.target,
  });

  final ConsentKind kind;

  /// Where the text would go.
  final DataDestination destination;

  /// The engine that would have handled the request.
  final String engineId;

  /// The language pair ([ConsentKind.pair]); `auto` when undetected.
  final String? source;
  final String? target;

  @override
  String toString() =>
      'ConsentRequiredException(${kind.name}, $engineId -> $destination'
      '${source == null ? '' : ', $source>$target'})';
}
