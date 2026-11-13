import 'package:equatable/equatable.dart';
import 'package:mozhi/proofread/models/proofread_diff.dart';
import 'package:mozhi/proofread/models/proofread_rephrasing.dart';
import 'package:mozhi/proofread/models/sentence_segmenter.dart';
import 'package:mozhi/settings/models/proofread_preferences.dart';
import 'package:translation_repository/translation_repository.dart';

enum ProofreadStatus { idle, loading, success, failure }

enum ProofreadAlternativesStatus { loading, success, failure }

/// The alternative phrasings asked for one sentence of the corrected text
/// (see `ProofreadCubit.loadAlternatives`).
class ProofreadAlternatives extends Equatable {
  const new({
    required this.base,
    required this.sentence,
    required this.span,
    this.status = ProofreadAlternativesStatus.loading,
    this.alternatives = const [],
    this.error,
  });

  /// The corrected text ([ProofreadState.outputText]) [sentence] is in.
  final String base;

  /// The sentence of [base] they are for.
  final SentenceRange sentence;

  /// The sentence as it was shown (its rephrasing, if any), which the
  /// alternatives replace.
  final String span;
  final ProofreadAlternativesStatus status;
  final List<String> alternatives;

  /// Why loading them failed.
  final Object? error;

  bool get isLoading => status == ProofreadAlternativesStatus.loading;

  ProofreadAlternatives copyWith({
    ProofreadAlternativesStatus? status,
    List<String>? alternatives,
    Object? Function()? error,
  }) => ProofreadAlternatives(
    base: base,
    sentence: sentence,
    span: span,
    status: status ?? this.status,
    alternatives: alternatives ?? this.alternatives,
    error: error != null ? error() : this.error,
  );

  @override
  List<Object?> get props => [
    base,
    sentence,
    span,
    status,
    alternatives,
    error,
  ];
}

class ProofreadState extends Equatable {
  const new({
    this.input = '',
    this.engine,
    this.availableEngines = const [],
    this.writingStyle = WritingStyle.general,
    this.correctionLevel = CorrectionLevel.standard,
    this.formality = Formality.automatic,
    this.tone = WritingTone.automatic,
    this.readingLevel = ReadingLevel.standard,
    this.variety,
    this.context = '',
    this.status = ProofreadStatus.idle,
    this.result,
    this.proofreadInput = '',
    this.proofreadPreferences = const ProofreadPreferences(),
    this.proofreadContext = '',
    this.acceptedEdits = const {},
    this.rephrasings = const [],
    this.droppedRephrasings = 0,
    this.alternatives,
    this.error,
  });

  /// Text in the input field.
  final String input;

  /// AI engine used for proofreading (null when none is configured).
  final TranslationEngine? engine;

  /// Enabled AI engines.
  final List<TranslationEngine> availableEngines;
  final WritingStyle writingStyle;
  final CorrectionLevel correctionLevel;
  final Formality formality;

  /// Tone to rewrite toward; [WritingTone.automatic] keeps the author's.
  final WritingTone tone;

  /// CEFR level to reword the text for; [ReadingLevel.standard] keeps the
  /// author's level.
  final ReadingLevel readingLevel;

  /// Regional variety to convert to; null keeps the author's variety.
  final ProofreadVariety? variety;

  /// Free-text context, e.g. "cover letter".
  final String context;
  final ProofreadStatus status;

  /// Latest proofreading result (kept while re-proofreading).
  final ProofreadResult? result;

  /// The exact text [result] was computed for.
  final String proofreadInput;

  /// The options [result] was computed with (see [preferences]).
  final ProofreadPreferences proofreadPreferences;

  /// The context [result] was computed with (trimmed).
  final String proofreadContext;

  /// Indices into `result.edits` that are applied to the output.
  final Set<int> acceptedEdits;

  /// Sentences of [outputText] the user replaced with an alternative
  /// phrasing, in order (see [ProofreadRephrasings]); [finalText] has them.
  final List<ProofreadRephrasing> rephrasings;

  /// How many rephrasings the last accepted or rejected edit dropped
  /// (their sentence changed); the user is told and can undo it
  /// (`ProofreadCubit.undoDroppedRephrasings`). 0 otherwise.
  final int droppedRephrasings;

  /// The alternatives asked for a sentence (while their sheet is open).
  final ProofreadAlternatives? alternatives;

  /// Last proofreading error (`LlmApiException`, `LlmRefusalException`, ...).
  final Object? error;

  bool get isLoading => status == ProofreadStatus.loading;

  /// The chosen options (style, level, formality, tone, reading level,
  /// region), as they are kept across app starts.
  ProofreadPreferences get preferences => ProofreadPreferences(
    writingStyle: writingStyle,
    correctionLevel: correctionLevel,
    formality: formality,
    tone: tone,
    readingLevel: readingLevel,
    variety: variety,
  );

  bool get canProofread =>
      engine != null && input.trim().isNotEmpty && !isLoading;

  List<ProofreadEdit> get edits => result?.edits ?? const [];

  bool get allEditsAccepted =>
      Iterable<int>.generate(edits.length).every(acceptedEdits.contains);

  int get acceptedCount =>
      Iterable<int>.generate(edits.length).where(acceptedEdits.contains).length;

  /// Text produced by applying the accepted edits to [proofreadInput] (see
  /// [ProofreadDiff.locate]).
  ///
  /// The edits are the only source of the output, so toggling one edit
  /// changes exactly that edit. Changes that `correctedText` makes without
  /// listing them are turned into edits by [ProofreadDiff.reconcile] when
  /// the result arrives. Only a result without edits uses its non-blank
  /// `correctedText` directly.
  ///
  /// Computed once per result, input and set of accepted edits (rebuilds
  /// read it many times).
  String get outputText {
    final result = this.result;
    if (result == null) return '';
    if (result.edits.isEmpty && result.correctedText.trim().isNotEmpty) {
      return result.correctedText;
    }
    final memo = _memos[result] ??= _Memo();
    if (memo.output case final output?
        when memo.outputInput == proofreadInput &&
            identical(memo.outputAccepted, acceptedEdits)) {
      return output;
    }
    final output = ProofreadDiff.apply(proofreadInput, edits, acceptedEdits);
    memo
      ..outputInput = proofreadInput
      ..outputAccepted = acceptedEdits
      ..output = output;
    return output;
  }

  /// Where each of [edits] is in [proofreadInput] (null: not found),
  /// located once per result and input.
  List<EditLocation?> get editLocations {
    final result = this.result;
    if (result == null) return const [];
    final memo = _memos[result] ??= _Memo();
    if (memo.locations case final locations?
        when memo.locationsInput == proofreadInput) {
      return locations;
    }
    final locations = ProofreadDiff.locate(proofreadInput, result.edits);
    memo
      ..locationsInput = proofreadInput
      ..locations = locations;
    return locations;
  }

  /// Values derived from a result, computed once (see [outputText]).
  static final Expando<_Memo> _memos = Expando('ProofreadState');

  /// The sentences of [outputText] the user can tap for alternatives.
  List<SentenceRange> get sentences => SentenceSegmenter.split(outputText);

  /// The text the user gets: [outputText] with the [rephrasings].
  String get finalText => ProofreadRephrasings.apply(outputText, rephrasings);

  /// The rephrasing of [sentence] (of [outputText]), if any.
  ProofreadRephrasing? rephrasingOf(SentenceRange sentence) {
    for (final rephrasing in rephrasings) {
      if (rephrasing.sentence == sentence) return rephrasing;
    }
    return null;
  }

  /// Whether the input changed after [result] was computed, so the result
  /// no longer matches the text in the input field.
  bool get inputChanged => result != null && input != proofreadInput;

  /// Whether the options (style, level, formality, tone, reading level,
  /// region) or the context changed after [result] was computed, so
  /// proofreading again would give another result.
  bool get optionsChanged =>
      result != null &&
      (preferences != proofreadPreferences ||
          context.trim() != proofreadContext);

  /// Whether [result] no longer matches the input or the options
  /// ([inputChanged], [optionsChanged]): it is shown with a notice and
  /// "Proofread again".
  bool get isStale => inputChanged || optionsChanged;

  /// Language of the proofread text for the writing statistics: the one
  /// the model detected, else null.
  ///
  /// The chosen [variety] is no fallback: it only applies to text in its
  /// language (text in other languages may be proofread with it set), and
  /// it can change after the result arrived.
  String? get textLanguage => result?.detectedLanguage;

  /// Whether the result found nothing to change.
  bool get isClean {
    final result = this.result;
    if (result == null) return false;
    final corrected = result.correctedText.trim();
    return result.edits.isEmpty &&
        (corrected.isEmpty || corrected == proofreadInput.trim());
  }

  ProofreadState copyWith({
    String? input,
    TranslationEngine? Function()? engine,
    List<TranslationEngine>? availableEngines,
    WritingStyle? writingStyle,
    CorrectionLevel? correctionLevel,
    Formality? formality,
    WritingTone? tone,
    ReadingLevel? readingLevel,
    ProofreadVariety? Function()? variety,
    String? context,
    ProofreadStatus? status,
    ProofreadResult? Function()? result,
    String? proofreadInput,
    ProofreadPreferences? proofreadPreferences,
    String? proofreadContext,
    Set<int>? acceptedEdits,
    List<ProofreadRephrasing>? rephrasings,
    int? droppedRephrasings,
    ProofreadAlternatives? Function()? alternatives,
    Object? Function()? error,
  }) {
    return ProofreadState(
      input: input ?? this.input,
      engine: engine != null ? engine() : this.engine,
      availableEngines: availableEngines ?? this.availableEngines,
      writingStyle: writingStyle ?? this.writingStyle,
      correctionLevel: correctionLevel ?? this.correctionLevel,
      formality: formality ?? this.formality,
      tone: tone ?? this.tone,
      readingLevel: readingLevel ?? this.readingLevel,
      variety: variety != null ? variety() : this.variety,
      context: context ?? this.context,
      status: status ?? this.status,
      result: result != null ? result() : this.result,
      proofreadInput: proofreadInput ?? this.proofreadInput,
      proofreadPreferences: proofreadPreferences ?? this.proofreadPreferences,
      proofreadContext: proofreadContext ?? this.proofreadContext,
      acceptedEdits: acceptedEdits ?? this.acceptedEdits,
      rephrasings: rephrasings ?? this.rephrasings,
      droppedRephrasings: droppedRephrasings ?? this.droppedRephrasings,
      alternatives: alternatives != null ? alternatives() : this.alternatives,
      error: error != null ? error() : this.error,
    );
  }

  /// Every engine field shown in the UI: [TranslationEngine] equality only
  /// compares id and name, which would hide an edited model or locality.
  static Object? _engineKey(TranslationEngine? engine) => engine == null
      ? null
      : (
          engine.id,
          engine.kind,
          engine.name,
          engine.subtitle,
          engine.providerId,
          engine.mozhiEngine,
          engine.isLocal,
        );

  @override
  List<Object?> get props => [
    input,
    _engineKey(engine),
    [for (final engine in availableEngines) _engineKey(engine)],
    writingStyle,
    correctionLevel,
    formality,
    tone,
    readingLevel,
    variety,
    context,
    status,
    result,
    proofreadInput,
    proofreadPreferences,
    proofreadContext,
    acceptedEdits,
    rephrasings,
    droppedRephrasings,
    alternatives,
    error,
  ];
}

/// Values derived from one result ([ProofreadState.outputText],
/// [ProofreadState.editLocations]) with what they were computed for.
class _Memo {
  String? outputInput;
  Set<int>? outputAccepted;
  String? output;
  String? locationsInput;
  List<EditLocation?>? locations;
}
