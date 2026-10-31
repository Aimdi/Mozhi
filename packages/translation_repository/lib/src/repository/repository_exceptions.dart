import 'package:mozhi_api/mozhi_api.dart';
import 'package:translation_repository/src/models/data_destination.dart';
import 'package:translation_repository/src/models/mozhi_instance.dart';
import 'package:translation_repository/src/models/translation_engine.dart';

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

/// The Mozhi instance answered `TranslationRepository.pingInstance`, but
/// its [engine] did not translate the test word: the instance answered
/// with an HTTP 5xx error (Mozhi reports an engine that failed upstream,
/// or one it doesn't offer, as 500), or without a translation.
///
/// A [MozhiApiException], so code that handles those keeps working; its
/// [message], [statusCode] and [uri] are the instance's answer (sanitised
/// like every Mozhi error).
final class InstanceDoesNotTranslateException extends MozhiApiException {
  const new(super.message, {required this.engine, super.statusCode, super.uri});

  /// The Mozhi engine that was tested (`google`, ...).
  final String engine;

  /// Whether the instance doesn't offer [engine] at all (Mozhi's `Engine
  /// does not exist or has been disabled`): it is a working Mozhi server
  /// that translates with other engines only.
  bool get engineUnavailable =>
      statusCode != null && _unavailable.hasMatch(message);

  static final _unavailable = RegExp(
    'engine does not exist|not supported or implemented',
    caseSensitive: false,
  );
}

/// Every Mozhi server the request was allowed to go to failed for
/// [engine], each in a way another server might not have repeated (it was
/// down, overloaded, or its engine failed upstream; see
/// `MozhiPool.canFailOver`).
///
/// Thrown (as a stream error of `TranslationRepository.translate`) for
/// translations with a Mozhi engine, and by the other requests that go to
/// the Mozhi servers: `TranslationRepository.translateImage` (naming the
/// Google engine Mozhi translates photos with), `detectLanguage` (Google;
/// as the `SourceLanguageRequiredException.cause` when a translation had to
/// detect the source language) and `textToSpeech` (the engine reading
/// aloud). A [MozhiApiException], so code that
/// handles those keeps working: its [message], [statusCode] and [uri] are
/// those of the last failure ([cause] when that was a
/// [MozhiApiException], sanitised like every Mozhi error). The app should
/// offer a way on that needs no Mozhi server: the device's own engine,
/// another engine (never switched to on its own: another engine sends the
/// text somewhere else; the app's opt-in "If Google fails, use DuckDuckGo"
/// is the user's permission for that one case), or another server.
/// [rateLimited] tells when the engine is limiting the servers' requests.
final class AllInstancesFailedException extends MozhiApiException {
  const new(
    super.message, {
    required this.engine,
    required this.instances,
    this.cause,
    this.failures = const [],
    super.statusCode,
    super.uri,
  });

  /// Wraps the last failure [cause] of a request that failed on every
  /// server of [instances] (in the order they were tried); [failures] are
  /// every server's failures in that order (sanitised like [cause]).
  factory from(
    Object cause, {
    required TranslationEngine engine,
    required List<MozhiInstance> instances,
    List<Object> failures = const [],
  }) => switch (cause) {
    MozhiApiException(:final message, :final statusCode, :final uri) =>
      AllInstancesFailedException(
        message,
        engine: engine,
        instances: List.unmodifiable(instances),
        cause: cause,
        failures: List.unmodifiable(failures),
        statusCode: statusCode,
        uri: uri,
      ),
    _ => AllInstancesFailedException(
      '$cause',
      engine: engine,
      instances: List.unmodifiable(instances),
      cause: cause,
      failures: List.unmodifiable(failures),
    ),
  };

  /// The engine the servers were asked to translate with.
  final TranslationEngine engine;

  /// The servers that were tried, in order (none was skipped by the
  /// privacy settings: those are not tried at all).
  final List<MozhiInstance> instances;

  /// The last server's failure.
  final Object? cause;

  /// Every server's failure, in the order the servers were tried (the last
  /// one is [cause]); empty when only [cause] is known.
  final List<Object> failures;

  /// The failures this exception knows of: [failures], else [cause] (or
  /// this exception itself, which carries the last failure's message).
  List<Object> get _known => failures.isNotEmpty ? failures : [cause ?? this];

  /// Whether [engine] is rate-limiting the servers: at least one of them
  /// reported that its upstream engine (or the server itself) limits its
  /// requests ([isRateLimit]), e.g. Google answering the servers with HTTP
  /// 429 (`request failed with status code: 429`) or Mozhi's `instance has
  /// been rate limited`.
  bool get rateLimited => _known.any(isRateLimit);

  /// Whether at least one server answered (with an HTTP error), as opposed
  /// to none being reachable (no connection, a timeout): only then can
  /// another engine on the same servers be worth a try.
  bool get serverAnswered => _known.any(
    (failure) => failure is MozhiApiException && failure.statusCode != null,
  );

  /// Whether [failure] says the server or its upstream engine is limiting
  /// requests: HTTP 429 from the server, or a message such as `request
  /// failed with status code: 429`, `instance has been rate limited` or
  /// `Too Many Requests`. Only the kind of failure is read; its text is
  /// never shown.
  static bool isRateLimit(Object failure) {
    if (failure is! MozhiApiException) return false;
    return failure.statusCode == 429 || _rateLimit.hasMatch(failure.message);
  }

  static final _rateLimit = RegExp(
    r'rate.?limit|status code:?\s*429\b|too many requests',
    caseSensitive: false,
  );

  @override
  String toString() =>
      'AllInstancesFailedException(${engine.id}, '
      '${instances.length} server${instances.length == 1 ? '' : 's'}): '
      '${cause ?? message}';
}
