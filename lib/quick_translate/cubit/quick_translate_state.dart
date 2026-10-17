import 'package:equatable/equatable.dart';
import 'package:mozhi/translate/widgets/offline_offer.dart'
    show OfflineDownload;
import 'package:translation_repository/translation_repository.dart';

/// Lifecycle of a quick translation.
enum QuickTranslateStatus {
  /// Engines / language lists are loading.
  loading,

  /// A translation is running (AI engines stream partial results).
  translating,

  /// The translation finished (the result may be null when the engine
  /// returned nothing).
  success,

  /// Loading engines or translating failed; see [QuickTranslateState.error].
  failure,

  /// No Mozhi instance is reachable and no AI provider is enabled.
  noEngines,

  /// Engines are available, but the one in settings is not, and the text
  /// is never sent to another destination by itself: the user picks one.
  chooseEngine,

  /// [QuickTranslateState.offlineOnly]: this device has no on-device
  /// engine (e.g. the web). Nothing was translated or sent.
  offlineUnavailable,

  /// [QuickTranslateState.offlineOnly]: the models of the language pair
  /// are not all on the device; [QuickTranslateState.offlineDownloads]
  /// lists the languages to download. Nothing was translated or sent.
  offlineModelsMissing,

  /// [QuickTranslateState.offlineOnly]: the on-device engine cannot
  /// translate the identified language into the target, or could not
  /// identify the text's language ([QuickTranslateState.identifiedSource]
  /// is null then). Nothing was translated or sent.
  offlineUnsupported,
}

/// State of `QuickTranslateCubit`: one incoming text, always translated
/// from an auto-detected source language into [target].
class QuickTranslateState extends Equatable {
  const new({
    required this.text,
    this.target = const Language(code: 'en', name: 'English'),
    this.status = QuickTranslateStatus.loading,
    this.engines = const [],
    this.engine,
    this.targetLanguages = const [],
    this.result,
    this.error,
    this.offlineOnly = false,
    this.identifiedSource,
    this.offlineDownloads = const [],
  });

  /// The text handed to the app (selection / share).
  final String text;

  /// "Translate offline": only the on-device engine translates, whatever
  /// the privacy mode, and the text never goes to a network engine. Fixed
  /// for the lifetime of the cubit.
  final bool offlineOnly;

  /// [offlineOnly]: the language the on-device engine identified the text
  /// as (normalised code), known before (or without) a translation.
  final String? identifiedSource;

  /// [QuickTranslateStatus.offlineModelsMissing]: the languages to
  /// download (with their download sizes when known), else empty.
  final List<OfflineDownload> offlineDownloads;

  /// Language the text is translated into.
  final Language target;
  final QuickTranslateStatus status;

  /// Mozhi engines of the active instance + enabled AI providers.
  final List<TranslationEngine> engines;

  /// Selected engine (null until engines load / none available).
  final TranslationEngine? engine;

  /// Targets offered by [engine].
  final List<Language> targetLanguages;

  /// Latest (possibly partial, while streaming) translation.
  final TranslationResult? result;

  /// Last error (`MozhiApiException`, `LlmApiException`, ...). A
  /// `ConsentRequiredException` means nothing was sent: the privacy
  /// settings want the user's say first.
  final Object? error;

  /// The translated text so far ('' when none).
  String get translation => result?.text ?? '';

  /// Code of the auto-detected source language, when the engine reported
  /// one (or, offline only, the on-device engine identified it).
  String? get detectedSource {
    for (final detected in [result?.detectedSource, identifiedSource]) {
      if (detected != null && detected.trim().isNotEmpty) return detected;
    }
    return null;
  }

  bool get isLoading => status == QuickTranslateStatus.loading;
  bool get isTranslating => status == QuickTranslateStatus.translating;

  /// A partial result is being streamed.
  bool get isStreaming => isTranslating && result != null;

  /// The translation finished with non-empty text, so it can be copied,
  /// read aloud, or replace the selection.
  bool get hasTranslation =>
      status == QuickTranslateStatus.success &&
      (result?.isComplete ?? false) &&
      translation.trim().isNotEmpty;

  /// Whether the engine accepts free-form custom target "languages".
  bool get allowsCustomTarget => engine?.supportsCustomLanguages ?? false;

  QuickTranslateState copyWith({
    Language? target,
    QuickTranslateStatus? status,
    List<TranslationEngine>? engines,
    TranslationEngine? Function()? engine,
    List<Language>? targetLanguages,
    TranslationResult? Function()? result,
    Object? Function()? error,
    String? Function()? identifiedSource,
    List<OfflineDownload>? offlineDownloads,
  }) {
    return QuickTranslateState(
      text: text,
      target: target ?? this.target,
      status: status ?? this.status,
      engines: engines ?? this.engines,
      engine: engine != null ? engine() : this.engine,
      targetLanguages: targetLanguages ?? this.targetLanguages,
      result: result != null ? result() : this.result,
      error: error != null ? error() : this.error,
      offlineOnly: offlineOnly,
      identifiedSource: identifiedSource != null
          ? identifiedSource()
          : this.identifiedSource,
      offlineDownloads: offlineDownloads ?? this.offlineDownloads,
    );
  }

  @override
  List<Object?> get props => [
    text,
    target,
    status,
    engines,
    engine,
    targetLanguages,
    result,
    error,
    offlineOnly,
    identifiedSource,
    offlineDownloads,
  ];
}
