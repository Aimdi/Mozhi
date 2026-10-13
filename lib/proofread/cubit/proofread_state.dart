import 'package:equatable/equatable.dart';
import 'package:mozhi/proofread/models/proofread_diff.dart';
import 'package:translation_repository/translation_repository.dart';

enum ProofreadStatus { idle, loading, success, failure }

class ProofreadState extends Equatable {
  const new({
    this.input = '',
    this.engine,
    this.availableEngines = const [],
    this.writingStyle = WritingStyle.general,
    this.correctionLevel = CorrectionLevel.standard,
    this.formality = Formality.automatic,
    this.context = '',
    this.status = ProofreadStatus.idle,
    this.result,
    this.proofreadInput = '',
    this.acceptedEdits = const {},
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

  /// Free-text context, e.g. "cover letter".
  final String context;
  final ProofreadStatus status;

  /// Latest proofreading result (kept while re-proofreading).
  final ProofreadResult? result;

  /// The exact text [result] was computed for.
  final String proofreadInput;

  /// Indices into `result.edits` that are applied to the output.
  final Set<int> acceptedEdits;

  /// Last proofreading error (`LlmApiException`, `LlmRefusalException`, ...).
  final Object? error;

  bool get isLoading => status == ProofreadStatus.loading;

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
  String get outputText {
    final result = this.result;
    if (result == null) return '';
    if (result.edits.isEmpty && result.correctedText.trim().isNotEmpty) {
      return result.correctedText;
    }
    return ProofreadDiff.apply(proofreadInput, edits, acceptedEdits);
  }

  /// Whether the input changed after [result] was computed, so the result
  /// no longer matches the text in the input field.
  bool get isStale => result != null && input != proofreadInput;

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
    String? context,
    ProofreadStatus? status,
    ProofreadResult? Function()? result,
    String? proofreadInput,
    Set<int>? acceptedEdits,
    Object? Function()? error,
  }) {
    return ProofreadState(
      input: input ?? this.input,
      engine: engine != null ? engine() : this.engine,
      availableEngines: availableEngines ?? this.availableEngines,
      writingStyle: writingStyle ?? this.writingStyle,
      correctionLevel: correctionLevel ?? this.correctionLevel,
      formality: formality ?? this.formality,
      context: context ?? this.context,
      status: status ?? this.status,
      result: result != null ? result() : this.result,
      proofreadInput: proofreadInput ?? this.proofreadInput,
      acceptedEdits: acceptedEdits ?? this.acceptedEdits,
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
    context,
    status,
    result,
    proofreadInput,
    acceptedEdits,
    error,
  ];
}
