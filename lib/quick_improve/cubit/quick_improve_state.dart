import 'package:equatable/equatable.dart';
import 'package:mozhi/proofread/models/proofread_diff.dart';
import 'package:mozhi/quick_improve/models/improve_engines.dart';
import 'package:translation_repository/translation_repository.dart';

enum QuickImproveStatus {
  /// The AI engines are not known yet.
  loadingEngines,

  /// No AI engine can proofread: the user has to add one.
  noEngine,

  /// The engine list could not be loaded (AI providers may well be
  /// configured).
  enginesFailed,

  /// The text is being proofread.
  improving,

  /// [QuickImproveState.result] holds the improved text.
  success,

  /// Proofreading failed ([QuickImproveState.error]; a
  /// `ConsentRequiredException` means nothing was sent).
  failure,
}

/// State of the quick improve sheet: one selection proofread with the
/// Proofread tab's engine, every suggested edit applied.
class QuickImproveState extends Equatable {
  const new({
    required this.text,
    this.status = QuickImproveStatus.loadingEngines,
    this.engine,
    this.engines = const [],
    this.level = CorrectionLevel.standard,
    this.style = WritingStyle.general,
    this.result,
    this.improvedText = '',
    this.segments = const [],
    this.error,
  });

  /// The selected text.
  final String text;
  final QuickImproveStatus status;

  /// The AI engine that proofreads (null while none is known).
  final TranslationEngine? engine;

  /// The AI engines that can proofread.
  final List<TranslationEngine> engines;
  final CorrectionLevel level;
  final WritingStyle style;

  /// The last result, its unlisted changes added as edits
  /// (`ProofreadDiff.reconcile`); null until one arrived.
  final ProofreadResult? result;

  /// [text] with every edit of [result] applied ('' without a result).
  final String improvedText;

  /// The changes from [text] to [improvedText], for highlighting.
  final List<DiffSegment> segments;

  /// The last error (`LlmApiException`, `ConsentRequiredException`, ...).
  final Object? error;

  bool get isImproving => status == QuickImproveStatus.improving;

  /// Whether an improved text is shown.
  bool get hasResult => status == QuickImproveStatus.success && result != null;

  /// Whether the result changes nothing.
  bool get isUnchanged => hasResult && improvedText.trim() == text.trim();

  /// Whether a proofread may start now (Retry, another level or style).
  bool get canImprove =>
      engine != null && text.trim().isNotEmpty && !isImproving;

  /// Items of personal data the shield kept on this device.
  int get maskedPersonalData => result?.maskedPersonalData ?? 0;

  QuickImproveState copyWith({
    QuickImproveStatus? status,
    TranslationEngine? Function()? engine,
    List<TranslationEngine>? engines,
    CorrectionLevel? level,
    WritingStyle? style,
    ProofreadResult? Function()? result,
    String? improvedText,
    List<DiffSegment>? segments,
    Object? Function()? error,
  }) {
    return QuickImproveState(
      text: text,
      status: status ?? this.status,
      engine: engine != null ? engine() : this.engine,
      engines: engines ?? this.engines,
      level: level ?? this.level,
      style: style ?? this.style,
      result: result != null ? result() : this.result,
      improvedText: improvedText ?? this.improvedText,
      segments: segments ?? this.segments,
      error: error != null ? error() : this.error,
    );
  }

  @override
  List<Object?> get props => [
    text,
    status,
    improveEngineKey(engine),
    [for (final engine in engines) improveEngineKey(engine)],
    level,
    style,
    result,
    improvedText,
    segments,
    error,
  ];
}
