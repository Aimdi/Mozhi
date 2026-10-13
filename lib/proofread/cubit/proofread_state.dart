import 'package:equatable/equatable.dart';
import 'package:mozhi/proofread/models/proofread_diff.dart';
import 'package:translation_repository/translation_repository.dart';

enum ProofreadStatus { idle, loading, success, failure }

class ProofreadState extends Equatable {
  const ProofreadState({
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
  /// [ProofreadDiff.locate]). When every edit is accepted and the result has
  /// a non-empty `correctedText`, that is preferred.
  String get outputText {
    final result = this.result;
    if (result == null) return '';
    if (allEditsAccepted && result.correctedText.isNotEmpty) {
      return result.correctedText;
    }
    return ProofreadDiff.apply(proofreadInput, edits, acceptedEdits);
  }

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

  @override
  List<Object?> get props => [
    input,
    engine,
    availableEngines,
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
