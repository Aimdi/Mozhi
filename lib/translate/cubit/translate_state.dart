import 'package:equatable/equatable.dart';
import 'package:mozhi/history/data/translation_memory.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

export 'package:mozhi/settings/models/app_settings.dart'
    show LanguagePair, QualityMode;

enum EnginesStatus { initial, loading, ready, failure }

enum TranslateStatus { idle, translating, success, failure }

/// Status of an optional AI extra (alternatives, insights, ...).
enum ExtraStatus { idle, loading, ready, failure }

/// The main translation stopped before its text left the device because
/// the privacy settings want the user's say ([exception]); nothing was
/// sent. The screen shows an inline prompt, and opens the consent dialog
/// only for a translation the user asked for (not [automatic]). Once
/// consent is recorded, `TranslateCubit.retryAfterConsent` translates
/// again.
class ConsentRequest extends Equatable {
  const new({
    required this.exception,
    required this.id,
    this.automatic = false,
  });

  final ConsentRequiredException exception;

  /// A new id for every stopped request (so the same exception twice is
  /// still a new request).
  final int id;

  /// The translation started by itself (instant translation, text from
  /// another app): never open a dialog for it.
  final bool automatic;

  @override
  List<Object?> get props => [exception, id, automatic];
}

/// A refinement chip applied to the translation with
/// `TranslateCubit.applySuggestion` (AI engines with the general prompt
/// profile revise the current translation instead of translating again).
class AppliedRefinement extends Equatable {
  const new({required this.suggestion, required this.previous});

  /// The chip that was applied.
  final RefinementSuggestion suggestion;

  /// The translation before [suggestion] was applied; it comes back when
  /// the chip is toggled off.
  final TranslationResult previous;

  @override
  List<Object?> get props => [suggestion, previous];
}

/// A one-shot notice that the target language was switched automatically
/// because the detected source language was the target (smart swap).
///
/// The UI shows it once (e.g. a snack bar "Translating into Spanish
/// instead · Undo"), then calls `TranslateCubit.consumeSmartSwapNotice`;
/// "Undo" calls `TranslateCubit.undoSmartSwap`. [id] grows with every swap,
/// so two swaps between the same languages are still told apart.
class SmartSwapNotice extends Equatable {
  const new({
    required this.id,
    required this.previousTarget,
    required this.newTarget,
  });

  /// Increments with every smart swap of the cubit.
  final int id;

  /// The target before the swap (the detected source language).
  final Language previousTarget;

  /// The target the input is translated into now.
  final Language newTarget;

  @override
  List<Object?> get props => [id, previousTarget, newTarget];
}

/// The translation of the input into one of the additional target
/// languages (`TranslateState.extraTargets`, "Also translate into…").
///
/// Each extra target is a request of its own with the main engine and
/// options; only the main result is saved in history.
class ExtraTranslation extends Equatable {
  const new({
    required this.target,
    this.status = TranslateStatus.idle,
    this.result,
    this.request,
    this.engineId,
    this.error,
  });

  /// The language translated into (as the engine lists it).
  final Language target;

  final TranslateStatus status;

  /// Latest (possibly streaming) translation, or null.
  final TranslationResult? result;

  /// The request [result] (or the request in flight) was made for: its text
  /// is the input the translation belongs to.
  final TranslationRequest? request;

  /// Id of the engine of [request].
  final String? engineId;

  /// Why the last request failed (the old [result] is dropped).
  final Object? error;

  String get output => result?.text ?? '';

  /// The input text [result] was produced for, or null.
  String? get resultInput => result == null ? null : request?.text;

  /// Whether [result] belongs to text other than [input] (the user edited
  /// it since); show it dimmed.
  bool isStaleFor(String input) {
    final made = resultInput;
    return made != null && made != input;
  }

  ExtraTranslation copyWith({
    TranslateStatus? status,
    TranslationResult? Function()? result,
    TranslationRequest? Function()? request,
    String? Function()? engineId,
    Object? Function()? error,
  }) => ExtraTranslation(
    target: target,
    status: status ?? this.status,
    result: result != null ? result() : this.result,
    request: request != null ? request() : this.request,
    engineId: engineId != null ? engineId() : this.engineId,
    error: error != null ? error() : this.error,
  );

  @override
  List<Object?> get props => [target, status, result, request, engineId, error];
}

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
    this.instantResult = false,
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
    this.appliedRefinements = const [],
    this.pendingRefinement,
    this.refinementError,
    this.romanizationStatus = ExtraStatus.idle,
    this.romanization,
    this.romanizationError,
    this.alignmentStatus = ExtraStatus.idle,
    this.alignment = const [],
    this.alignmentFocus,
    this.alignmentError,
    this.smartSwapNotice,
    this.dictionaryVerbosity = DictionaryVerbosity.standard,
    this.dictionaryQuery,
    this.qualityMode = QualityMode.off,
    this.fastEngine,
    this.bestEngine,
    this.meaningStatus = ExtraStatus.idle,
    this.meaningCheck,
    this.backTranslation,
    this.meaningFocus,
    this.meaningError,
    this.extraTargets = const [],
    this.extraTranslations = const [],
    this.memoryMatch,
    this.resultFromMemory = false,
    this.consent,
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

  /// May be a free-form custom language when [engine]
  /// `supportsCustomLanguages` (AI engines with the general profile).
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

  /// Whether [result] comes from a translation nobody asked for: an
  /// instant one (started by a typing pause, see
  /// `AppSettings.instantTranslate` / `instantTranslateAi`) or the
  /// automatic one of text from outside the app (links, shared text, see
  /// `TranslateCubit.setExternalInput`), rather than one the user asked for
  /// (Translate, a language or engine change, a refinement, ...). The UI
  /// does not start paid AI extras for such results on its own. False
  /// without a result.
  final bool instantResult;

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

  /// The refinement chips: [RefinementSuggestion.defaults], then fetched
  /// ones (and any applied chip a reload no longer lists).
  final List<RefinementSuggestion> suggestions;
  final ExtraStatus explainStatus;

  /// Markdown, grows while streaming.
  final String explanation;
  final ExtraStatus dictionaryStatus;
  final DictionaryEntry? dictionary;

  /// Error of the last failed alternatives / insights / suggestions /
  /// explain / dictionary request.
  final Object? extraError;

  // Refinements -------------------------------------------------------------

  /// The refinement chips whose effect is in the current output, in the
  /// order they were applied (each with the translation from before it).
  /// Only AI engines with the general prompt profile stack refinements;
  /// see `TranslateCubit.applySuggestion`. Empty after any change of
  /// input, options, languages or engine, and after a new translation.
  final List<AppliedRefinement> appliedRefinements;

  /// The chip whose refinement is being requested (show progress on it);
  /// the output keeps the current translation until the refined one is
  /// complete. Null when nothing is in flight.
  final RefinementSuggestion? pendingRefinement;

  /// Why the last refinement failed (the translation is kept); cleared
  /// when the next refinement starts or the result changes otherwise.
  final Object? refinementError;

  // Romanization ------------------------------------------------------------

  /// See `TranslateCubit.loadRomanization`. Reset whenever the result
  /// changes.
  final ExtraStatus romanizationStatus;

  /// The output in the Latin script (Mozhi's transliteration or an AI
  /// romanization), or null.
  final String? romanization;

  /// Why the last romanization failed.
  final Object? romanizationError;

  // Alignment ---------------------------------------------------------------

  /// See `TranslateCubit.loadAlignment`. Reset whenever the input or the
  /// result changes.
  final ExtraStatus alignmentStatus;

  /// Corresponding phrases of [input] and the output (UTF-16 offsets into
  /// both texts as they are now).
  final List<AlignedSpan> alignment;

  /// Index into [alignment] of the highlighted pair, or null.
  final int? alignmentFocus;

  /// Why the last alignment request failed.
  final Object? alignmentError;

  // Smart swap --------------------------------------------------------------

  /// Set when the target was switched automatically; shown once by the UI,
  /// then cleared with `TranslateCubit.consumeSmartSwapNotice`.
  final SmartSwapNotice? smartSwapNotice;

  // Dictionary --------------------------------------------------------------

  /// How much the dictionary card asks for.
  final DictionaryVerbosity dictionaryVerbosity;

  /// The word of the current (or loading) dictionary entry: the trimmed
  /// input, or a word followed with `TranslateCubit.lookUpWord`. Null
  /// when nothing was looked up.
  final String? dictionaryQuery;

  // Quality modes -----------------------------------------------------------

  /// The active quality mode: [QualityMode.fast] / [QualityMode.best] while
  /// [engine] is the engine chosen for it, else [QualityMode.off].
  final QualityMode qualityMode;

  /// The engine of [QualityMode.fast] when one is configured and available.
  final TranslationEngine? fastEngine;

  /// The engine of [QualityMode.best] when one is configured and available.
  final TranslationEngine? bestEngine;

  // Meaning check ------------------------------------------------------------

  /// See `TranslateCubit.checkMeaning`. Reset whenever the input or the
  /// result changes.
  final ExtraStatus meaningStatus;

  /// The AI meaning check (verdict, back-translation and differences) when
  /// [meaningUsesAi]; null otherwise.
  final MeaningCheck? meaningCheck;

  /// The back-translation of the output with the main engine (engines
  /// without AI extras: the user compares it with the input); null for an
  /// AI check.
  final String? backTranslation;

  /// Index into the [meaningCheck] issues of the highlighted one, or null.
  final int? meaningFocus;

  /// Why the last meaning check failed.
  final Object? meaningError;

  // Extra targets -----------------------------------------------------------

  /// Additional target languages ("Also translate into…", at most
  /// `TranslateCubit.maxExtraTargets`), as the user picked them, also the
  /// ones the engine does not offer ([unavailableExtraTargets]; only
  /// [activeExtraTargets] are translated). Loaded from
  /// `AppSettings.extraTargets` (and saved there).
  final List<Language> extraTargets;

  /// The translations into [activeExtraTargets] (in no particular order;
  /// look one up with [extraTranslationFor]).
  final List<ExtraTranslation> extraTranslations;

  // Translation memory ------------------------------------------------------

  /// An earlier translation of the same (or very similar) text into the
  /// same language from the local history (see `TranslationMemory`), found
  /// when the input or the languages changed; null when there is none,
  /// history is off (`AppSettings.saveHistory`) or it was dismissed. Show
  /// it with [visibleMemoryMatch].
  final MemoryMatch? memoryMatch;

  /// Whether [result] is the translation of [memoryMatch] the user chose
  /// with `TranslateCubit.useMemoryMatch` (no engine was asked). False
  /// once another result replaces it.
  final bool resultFromMemory;

  /// The main translation waits for the user's consent (nothing was sent);
  /// see [ConsentRequest].
  final ConsentRequest? consent;

  /// [memoryMatch] when it is worth showing: not in compare mode, and its
  /// translation is not what the output shows already (as the current
  /// translation, or because it was used).
  MemoryMatch? get visibleMemoryMatch {
    final match = memoryMatch;
    if (match == null || compareMode) return null;
    final shown = result;
    if (shown != null &&
        (resultFromMemory || !isResultStale) &&
        TranslationMemory.normalize(shown.text) ==
            TranslationMemory.normalize(match.entry.translation)) {
      return null;
    }
    return match;
  }

  String get output => result?.text ?? '';
  bool get isAiEngine => engine?.isAi ?? false;
  bool get hasExtras => assistEngine != null;
  bool get canSwap => !target.isCustom;

  /// Whether free-form custom languages can be picked (source and target):
  /// AI engines with the general prompt profile.
  bool get supportsCustomLanguages => engine?.supportsCustomLanguages ?? false;

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

  /// The finished, current (not stale), non-empty output, else null.
  String? get _finishedOutput {
    final result = this.result;
    if (result == null || !result.isComplete || isResultStale) return null;
    if (result.text.trim().isEmpty || input.trim().isEmpty) return null;
    return result.text;
  }

  // Refinements -------------------------------------------------------------

  /// The applied chips, in the order they were applied.
  List<RefinementSuggestion> get appliedSuggestions => [
    for (final applied in appliedRefinements) applied.suggestion,
  ];

  /// Whether [suggestion] is applied (show its chip as selected).
  bool isSuggestionApplied(RefinementSuggestion suggestion) =>
      appliedRefinements.any((applied) => applied.suggestion == suggestion);

  /// A refinement is being requested ([pendingRefinement]).
  bool get isRefining => pendingRefinement != null;

  /// Whether a chip revises the current output (and can be toggled off
  /// again) rather than translating the input again with its instruction:
  /// an AI [engine] with the general prompt profile and a finished output.
  bool get refinesOutput =>
      (engine?.supportsExtras ?? false) &&
      status != TranslateStatus.translating &&
      _finishedOutput != null;

  // Romanization ------------------------------------------------------------

  /// Whether a romanization of the output can be shown: the result carries
  /// a transliteration (Mozhi), or an AI [assistEngine] can romanize it and
  /// the target language uses a non-Latin script or the output has
  /// non-Latin letters.
  bool get canRomanize {
    final output = _finishedOutput;
    if (output == null || status == TranslateStatus.translating) return false;
    if (result!.targetTransliteration.trim().isNotEmpty) return true;
    if (!(assistEngine?.supportsExtras ?? false)) return false;
    return LanguageCatalog.usesNonLatinScript(target.code) ||
        LanguageCatalog.hasNonLatinLetters(output);
  }

  // Alignment ---------------------------------------------------------------

  /// Whether phrase alignment can be requested for the input and output.
  bool get canAlign =>
      (assistEngine?.supportsExtras ?? false) &&
      status != TranslateStatus.translating &&
      _finishedOutput != null;

  /// The highlighted pair ([alignmentFocus]), or null.
  AlignedSpan? get focusedAlignment {
    final index = alignmentFocus;
    if (index == null || index < 0 || index >= alignment.length) return null;
    return alignment[index];
  }

  /// Index of the first [alignment] pair whose source phrase covers the
  /// character at [offset] of [input], or null.
  int? alignmentIndexAtSource(int offset) {
    for (var i = 0; i < alignment.length; i++) {
      if (alignment[i].coversSource(offset)) return i;
    }
    return null;
  }

  /// Index of the first [alignment] pair whose target phrase covers the
  /// character at [offset] of the output, or null.
  int? alignmentIndexAtTarget(int offset) {
    for (var i = 0; i < alignment.length; i++) {
      if (alignment[i].coversTarget(offset)) return i;
    }
    return null;
  }

  // Detection ---------------------------------------------------------------

  /// The detected source language of short input may be wrong (auto
  /// source only); offer [detectedAlternativeLanguages].
  bool get detectionUncertain =>
      source.isAuto && (result?.detectionUncertain ?? false);

  /// Codes of other languages the input may be in (most likely first) when
  /// [detectionUncertain], else empty.
  List<String> get detectedAlternatives =>
      detectionUncertain ? result!.detectedAlternatives : const [];

  /// [detectedAlternatives] that are in [sourceLanguages] (as listed
  /// there), for `TranslateCubit.useDetectedAlternative`. The target
  /// language may be one of them: choosing it also switches the target
  /// (see there).
  List<Language> get detectedAlternativeLanguages {
    final languages = <Language>[];
    for (final code in detectedAlternatives) {
      final match = LanguageMatcher.match(
        Language(code: code, name: code),
        sourceLanguages,
      );
      if (match != null && !match.isAuto && !languages.contains(match)) {
        languages.add(match);
      }
    }
    return languages;
  }

  // Pinned languages --------------------------------------------------------

  /// [language] as this engine lists it among [targetLanguages] (matched
  /// with `LanguageMatcher`), a custom language while
  /// [supportsCustomLanguages]; null for auto and for languages the engine
  /// does not offer.
  Language? usableTarget(Language language) {
    if (language.isAuto) return null;
    if (language.isCustom) return supportsCustomLanguages ? language : null;
    return LanguageMatcher.match(language, targetLanguages);
  }

  /// The [pinned] languages (`AppSettings.pinnedLanguages`) this engine
  /// offers as targets, as it lists them ([usableTarget]), in pin order and
  /// without duplicates.
  ///
  /// This is the "Pinned" section of the target language picker, and pin
  /// `n` of it is what Alt+`n + 1` selects
  /// (`TranslateCubit.selectPinnedTarget`).
  List<Language> pinnedTargets(List<Language> pinned) {
    final languages = <Language>[];
    for (final pin in pinned) {
      final language = usableTarget(pin);
      if (language != null && !languages.contains(language)) {
        languages.add(language);
      }
    }
    return languages;
  }

  // Quality modes -----------------------------------------------------------

  /// Whether at least one quality mode engine is available (show the
  /// quality toggle).
  bool get hasQualityModes => fastEngine != null || bestEngine != null;

  /// The modes that can be selected: [QualityMode.off] always, fast/best
  /// when their engine is configured and available.
  List<QualityMode> get availableQualityModes => [
    QualityMode.off,
    if (fastEngine != null) QualityMode.fast,
    if (bestEngine != null) QualityMode.best,
  ];

  /// The engine [mode] translates with ([fastEngine] / [bestEngine]); null
  /// for [QualityMode.off] (the normal selection) or an unavailable mode.
  TranslationEngine? qualityEngine(QualityMode mode) => switch (mode) {
    QualityMode.off => null,
    QualityMode.fast => fastEngine,
    QualityMode.best => bestEngine,
  };

  // Meaning check ------------------------------------------------------------

  /// Whether the meaning check asks the AI [assistEngine]
  /// (`TranslationRepository.checkMeaning`: verdict, back-translation and
  /// differences); otherwise the output is translated back with [engine].
  bool get meaningUsesAi => assistEngine?.supportsExtras ?? false;

  /// Whether the meaning of the output can be checked: a finished, current
  /// output, and an AI [assistEngine] with extras, or (back-translation) an
  /// [engine] and a known source language (chosen or detected).
  bool get canCheckMeaning {
    if (_finishedOutput == null || status == TranslateStatus.translating) {
      return false;
    }
    if (meaningUsesAi) return true;
    if (engine == null) return false;
    return !source.isAuto ||
        (result?.detectedSource?.trim().isNotEmpty ?? false);
  }

  /// The meaning check issue at [meaningFocus], or null.
  MeaningIssue? get focusedMeaningIssue {
    final issues = meaningCheck?.issues ?? const <MeaningIssue>[];
    final index = meaningFocus;
    if (index == null || index < 0 || index >= issues.length) return null;
    return issues[index];
  }

  // Extra targets -----------------------------------------------------------

  /// The [extraTargets] translated now: each as the engine lists it
  /// ([usableTarget]), without the main [target], the [source] (a chosen
  /// one, or with auto the language [detectedInputLanguage] names) and
  /// duplicates; languages the engine does not offer are left out (and
  /// come back with an engine that offers them).
  List<Language> get activeExtraTargets {
    String key(Language language) => language.isCustom
        ? 'custom:${language.code}'
        : LanguageMatcher.normalize(language.code);
    final detected = detectedInputLanguage;
    final skip = {
      key(target),
      if (!source.isAuto) key(source),
      if (detected != null) LanguageMatcher.normalize(detected),
    };
    final languages = <Language>[];
    for (final language in extraTargets) {
      final usable = usableTarget(language);
      if (usable == null || !skip.add(key(usable))) continue;
      languages.add(usable);
    }
    return languages;
  }

  /// With an auto [source]: the language code the engine detected in the
  /// shown [result] when that detection is final (a complete result) and
  /// not marked as uncertain; else null. The result may belong to an
  /// earlier version of the input, which is usually in the same language
  /// (`TranslateCubit` translates an extra target left out for it once a
  /// new result says otherwise).
  String? get detectedInputLanguage {
    final result = this.result;
    final detected = result?.detectedSource?.trim();
    if (!source.isAuto ||
        result == null ||
        !result.isComplete ||
        result.detectionUncertain ||
        detected == null ||
        detected.isEmpty) {
      return null;
    }
    return detected;
  }

  /// The [extraTargets] the selected engine does not offer ([usableTarget]
  /// is null), in pick order: they stay picked for an engine that offers
  /// them, are not translated now and count towards the limit. Empty while
  /// no engine (or no target language list) is loaded.
  List<Language> get unavailableExtraTargets {
    if (engine == null || targetLanguages.isEmpty) return const [];
    return [
      for (final language in extraTargets)
        if (usableTarget(language) == null) language,
    ];
  }

  /// Whether [language] (as the engine lists it) is one of the
  /// [extraTargets]: picked as it is, or a pick the engine lists as
  /// [language] ([usableTarget]).
  bool isExtraTarget(Language language) => extraTargets.any(
    (chosen) => chosen == language || usableTarget(chosen) == language,
  );

  /// The translation into [language] (one of [activeExtraTargets]), or
  /// null when it has not been requested.
  ExtraTranslation? extraTranslationFor(Language language) {
    for (final translation in extraTranslations) {
      if (translation.target == language) return translation;
    }
    return null;
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
    bool? instantResult,
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
    List<AppliedRefinement>? appliedRefinements,
    RefinementSuggestion? Function()? pendingRefinement,
    Object? Function()? refinementError,
    ExtraStatus? romanizationStatus,
    String? Function()? romanization,
    Object? Function()? romanizationError,
    ExtraStatus? alignmentStatus,
    List<AlignedSpan>? alignment,
    int? Function()? alignmentFocus,
    Object? Function()? alignmentError,
    SmartSwapNotice? Function()? smartSwapNotice,
    DictionaryVerbosity? dictionaryVerbosity,
    String? Function()? dictionaryQuery,
    QualityMode? qualityMode,
    TranslationEngine? Function()? fastEngine,
    TranslationEngine? Function()? bestEngine,
    ExtraStatus? meaningStatus,
    MeaningCheck? Function()? meaningCheck,
    String? Function()? backTranslation,
    int? Function()? meaningFocus,
    Object? Function()? meaningError,
    List<Language>? extraTargets,
    List<ExtraTranslation>? extraTranslations,
    MemoryMatch? Function()? memoryMatch,
    bool? resultFromMemory,
    ConsentRequest? Function()? consent,
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
      instantResult:
          instantResult ?? (nextResult != null && this.instantResult),
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
      appliedRefinements: appliedRefinements ?? this.appliedRefinements,
      pendingRefinement: pendingRefinement != null
          ? pendingRefinement()
          : this.pendingRefinement,
      refinementError: refinementError != null
          ? refinementError()
          : this.refinementError,
      romanizationStatus: romanizationStatus ?? this.romanizationStatus,
      romanization: romanization != null ? romanization() : this.romanization,
      romanizationError: romanizationError != null
          ? romanizationError()
          : this.romanizationError,
      alignmentStatus: alignmentStatus ?? this.alignmentStatus,
      alignment: alignment ?? this.alignment,
      alignmentFocus: alignmentFocus != null
          ? alignmentFocus()
          : this.alignmentFocus,
      alignmentError: alignmentError != null
          ? alignmentError()
          : this.alignmentError,
      smartSwapNotice: smartSwapNotice != null
          ? smartSwapNotice()
          : this.smartSwapNotice,
      dictionaryVerbosity: dictionaryVerbosity ?? this.dictionaryVerbosity,
      dictionaryQuery: dictionaryQuery != null
          ? dictionaryQuery()
          : this.dictionaryQuery,
      qualityMode: qualityMode ?? this.qualityMode,
      fastEngine: fastEngine != null ? fastEngine() : this.fastEngine,
      bestEngine: bestEngine != null ? bestEngine() : this.bestEngine,
      meaningStatus: meaningStatus ?? this.meaningStatus,
      meaningCheck: meaningCheck != null ? meaningCheck() : this.meaningCheck,
      backTranslation: backTranslation != null
          ? backTranslation()
          : this.backTranslation,
      meaningFocus: meaningFocus != null ? meaningFocus() : this.meaningFocus,
      meaningError: meaningError != null ? meaningError() : this.meaningError,
      extraTargets: extraTargets ?? this.extraTargets,
      extraTranslations: extraTranslations ?? this.extraTranslations,
      memoryMatch: memoryMatch != null ? memoryMatch() : this.memoryMatch,
      // Any other result is not the one from history.
      resultFromMemory:
          resultFromMemory ?? (result == null && this.resultFromMemory),
      consent: consent != null ? consent() : this.consent,
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
    instantResult,
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
    appliedRefinements,
    pendingRefinement,
    refinementError,
    romanizationStatus,
    romanization,
    romanizationError,
    alignmentStatus,
    alignment,
    alignmentFocus,
    alignmentError,
    smartSwapNotice,
    dictionaryVerbosity,
    dictionaryQuery,
    qualityMode,
    fastEngine,
    bestEngine,
    meaningStatus,
    meaningCheck,
    backTranslation,
    meaningFocus,
    meaningError,
    extraTargets,
    extraTranslations,
    memoryMatch,
    resultFromMemory,
    consent,
  ];
}
