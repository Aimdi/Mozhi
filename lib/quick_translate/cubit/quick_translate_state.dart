import 'package:equatable/equatable.dart';
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
  });

  /// The text handed to the app (selection / share).
  final String text;

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

  /// Last error (`MozhiApiException`, `LlmApiException`, ...).
  final Object? error;

  /// The translated text so far ('' when none).
  String get translation => result?.text ?? '';

  /// Code of the auto-detected source language, when the engine reported
  /// one.
  String? get detectedSource {
    final detected = result?.detectedSource;
    return detected == null || detected.trim().isEmpty ? null : detected;
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
  ];
}
