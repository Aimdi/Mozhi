import 'package:equatable/equatable.dart';
import 'package:translation_repository/translation_repository.dart';

enum EnginesStatus { initial, loading, ready, failure }

enum TranslateStatus { idle, translating, success, failure }

/// Status of an optional AI extra (alternatives, insights, ...).
enum ExtraStatus { idle, loading, ready, failure }

class TranslateState extends Equatable {
  const new({
    this.enginesStatus = EnginesStatus.initial,
    this.engines = const [],
    this.engine,
    this.assistEngine,
    this.sourceLanguages = const [Language.auto],
    this.targetLanguages = const [],
    this.source = Language.auto,
    this.target = const Language(code: 'en', name: 'English'),
    this.input = '',
    this.options = const TranslationOptions(),
    this.status = TranslateStatus.idle,
    this.result,
    this.resultInput,
    this.inputTruncated = false,
    this.error,
    this.compareMode = false,
    this.compareEntries = const [],
    this.comparing = false,
    this.alternativesStatus = ExtraStatus.idle,
    this.alternatives,
    this.alternativesSpan,
    this.alternativesSpanStart,
    this.insightsStatus = ExtraStatus.idle,
    this.insights = const [],
    this.suggestionsStatus = ExtraStatus.idle,
    this.suggestions = RefinementSuggestion.defaults,
    this.explainStatus = ExtraStatus.idle,
    this.explanation = '',
    this.dictionaryStatus = ExtraStatus.idle,
    this.dictionary,
    this.extraError,
  });

  final EnginesStatus enginesStatus;

  /// Mozhi engines of the active instance + enabled AI providers.
  final List<TranslationEngine> engines;

  /// Currently selected engine (null until engines load / none available).
  final TranslationEngine? engine;

  /// AI engine used for extras: [engine] itself when it is AI, else the
  /// configured/first enabled AI engine, else null (extras hidden).
  final TranslationEngine? assistEngine;
  final List<Language> sourceLanguages;
  final List<Language> targetLanguages;
  final Language source;
  final Language target;
  final String input;
  final TranslationOptions options;

  final TranslateStatus status;

  /// Latest (possibly streaming) translation of [input].
  final TranslationResult? result;

  /// The input text [result] was produced for (null when unknown or there
  /// is no result). It differs from [input] after an edit until the next
  /// translation lands, see [isResultStale].
  final String? resultInput;

  /// Whether [input] was cut to the maximum length (text from outside the
  /// app is cut to `TranslateCubit.maxExternalInputLength`, anything else to
  /// `TranslateCubit.maxInputLength`). The UI can show a notice.
  final bool inputTruncated;

  /// Last translation error (MozhiApiException / LlmApiException / ...).
  final Object? error;

  /// Compare mode: run all (or the configured) engines side by side.
  final bool compareMode;
  final List<CompareEntry> compareEntries;
  final bool comparing;

  final ExtraStatus alternativesStatus;
  final AlternativeTranslations? alternatives;

  /// Non-null when [alternatives] are for a selected span of the output:
  /// the text of that span as it currently appears in the output (it
  /// becomes the applied alternative after `useAlternative`).
  final String? alternativesSpan;

  /// Start offset of [alternativesSpan] in the output when known (the
  /// selection the alternatives were requested for).
  final int? alternativesSpanStart;
  final ExtraStatus insightsStatus;
  final List<WordInsight> insights;
  final ExtraStatus suggestionsStatus;
  final List<RefinementSuggestion> suggestions;
  final ExtraStatus explainStatus;

  /// Markdown, grows while streaming.
  final String explanation;
  final ExtraStatus dictionaryStatus;
  final DictionaryEntry? dictionary;
  final Object? extraError;

  String get output => result?.text ?? '';
  bool get isAiEngine => engine?.isAi ?? false;
  bool get hasExtras => assistEngine != null;
  bool get canSwap => !target.isCustom;

  /// True when [result] belongs to an older input (the user edited the text
  /// after it was translated, or a translation of the old text landed after
  /// an edit). The UI can dim the output; extras are not offered for it.
  bool get isResultStale =>
      result != null && resultInput != null && resultInput != input;

  /// Source language actually used: the detected one when [source] is auto.
  String? get effectiveSourceCode =>
      source.isAuto ? result?.detectedSource : source.code;

  /// 1-3 words -> dictionary card is offered.
  bool get isShortInput {
    final words = input.trim().split(RegExp(r'\s+'));
    return input.trim().isNotEmpty && words.length <= 3;
  }

  TranslateState copyWith({
    EnginesStatus? enginesStatus,
    List<TranslationEngine>? engines,
    TranslationEngine? Function()? engine,
    TranslationEngine? Function()? assistEngine,
    List<Language>? sourceLanguages,
    List<Language>? targetLanguages,
    Language? source,
    Language? target,
    String? input,
    TranslationOptions? options,
    TranslateStatus? status,
    TranslationResult? Function()? result,
    String? Function()? resultInput,
    bool? inputTruncated,
    Object? Function()? error,
    bool? compareMode,
    List<CompareEntry>? compareEntries,
    bool? comparing,
    ExtraStatus? alternativesStatus,
    AlternativeTranslations? Function()? alternatives,
    String? Function()? alternativesSpan,
    int? Function()? alternativesSpanStart,
    ExtraStatus? insightsStatus,
    List<WordInsight>? insights,
    ExtraStatus? suggestionsStatus,
    List<RefinementSuggestion>? suggestions,
    ExtraStatus? explainStatus,
    String? explanation,
    ExtraStatus? dictionaryStatus,
    DictionaryEntry? Function()? dictionary,
    Object? Function()? extraError,
  }) {
    final nextResult = result != null ? result() : this.result;
    return TranslateState(
      enginesStatus: enginesStatus ?? this.enginesStatus,
      engines: engines ?? this.engines,
      engine: engine != null ? engine() : this.engine,
      assistEngine: assistEngine != null ? assistEngine() : this.assistEngine,
      sourceLanguages: sourceLanguages ?? this.sourceLanguages,
      targetLanguages: targetLanguages ?? this.targetLanguages,
      source: source ?? this.source,
      target: target ?? this.target,
      input: input ?? this.input,
      options: options ?? this.options,
      status: status ?? this.status,
      result: nextResult,
      // Dropping the result also drops the text it was made for.
      resultInput: resultInput != null
          ? resultInput()
          : nextResult == null
          ? null
          : this.resultInput,
      inputTruncated: inputTruncated ?? this.inputTruncated,
      error: error != null ? error() : this.error,
      compareMode: compareMode ?? this.compareMode,
      compareEntries: compareEntries ?? this.compareEntries,
      comparing: comparing ?? this.comparing,
      alternativesStatus: alternativesStatus ?? this.alternativesStatus,
      alternatives: alternatives != null ? alternatives() : this.alternatives,
      alternativesSpan: alternativesSpan != null
          ? alternativesSpan()
          : this.alternativesSpan,
      alternativesSpanStart: alternativesSpanStart != null
          ? alternativesSpanStart()
          : this.alternativesSpanStart,
      insightsStatus: insightsStatus ?? this.insightsStatus,
      insights: insights ?? this.insights,
      suggestionsStatus: suggestionsStatus ?? this.suggestionsStatus,
      suggestions: suggestions ?? this.suggestions,
      explainStatus: explainStatus ?? this.explainStatus,
      explanation: explanation ?? this.explanation,
      dictionaryStatus: dictionaryStatus ?? this.dictionaryStatus,
      dictionary: dictionary != null ? dictionary() : this.dictionary,
      extraError: extraError != null ? extraError() : this.extraError,
    );
  }

  @override
  List<Object?> get props => [
    enginesStatus,
    engines,
    engine,
    assistEngine,
    sourceLanguages,
    targetLanguages,
    source,
    target,
    input,
    options,
    status,
    result,
    resultInput,
    inputTruncated,
    error,
    compareMode,
    compareEntries,
    comparing,
    alternativesStatus,
    alternatives,
    alternativesSpan,
    alternativesSpanStart,
    insightsStatus,
    insights,
    suggestionsStatus,
    suggestions,
    explainStatus,
    explanation,
    dictionaryStatus,
    dictionary,
    extraError,
  ];
}
