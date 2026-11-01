import 'package:equatable/equatable.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

/// Whether the engines of [ImproveEngines] are known yet.
enum ImproveEnginesStatus { loading, ready, failure }

/// The AI engines that may proofread a quick improve request, picked the
/// way the Proofread tab picks them (`ProofreadPage`, `ProofreadCubit`):
/// the engines of the [TranslateCubit] that support the general prompt
/// profile ([TranslationEngine.supportsExtras]; dedicated translation
/// models cannot proofread), preferring its assist engine
/// ([TranslateState.assistEngine], which already respects Offline only),
/// else the first of them.
class ImproveEngines extends Equatable {
  const new({
    this.engines = const [],
    this.preferred,
    this.status = ImproveEnginesStatus.ready,
  });

  /// The engines and assist engine of [state] (non-AI engines and AI
  /// engines without extras are left out).
  factory fromTranslateState(TranslateState state) => ImproveEngines(
    engines: proofreadEngines(state.engines),
    preferred: state.assistEngine,
    status: switch (state.enginesStatus) {
      EnginesStatus.initial ||
      EnginesStatus.loading => ImproveEnginesStatus.loading,
      EnginesStatus.ready => ImproveEnginesStatus.ready,
      EnginesStatus.failure => ImproveEnginesStatus.failure,
    },
  );

  /// The engines that can proofread.
  final List<TranslationEngine> engines;

  /// The engine to use when it can proofread (the assist engine).
  final TranslationEngine? preferred;

  /// Whether the engine list is still loading or failed to load. Engines
  /// that are known are used whatever the status, as in the Proofread tab.
  final ImproveEnginesStatus status;

  /// The engine to proofread with (see [pickProofreadEngine]).
  TranslationEngine? get engine =>
      pickProofreadEngine(engines, preferred: preferred);

  @override
  List<Object?> get props => [
    [for (final engine in engines) improveEngineKey(engine)],
    improveEngineKey(preferred),
    status,
  ];
}

/// The engines of [engines] that can proofread: AI engines with the
/// general prompt profile ([TranslationEngine.supportsExtras]).
List<TranslationEngine> proofreadEngines(Iterable<TranslationEngine> engines) =>
    engines.where((engine) => engine.supportsExtras).toList(growable: false);

/// The engine of [engines] with the id of [preferred], else the first one;
/// null without engines.
TranslationEngine? pickProofreadEngine(
  List<TranslationEngine> engines, {
  TranslationEngine? preferred,
}) {
  if (preferred != null) {
    for (final engine in engines) {
      if (engine.id == preferred.id) return engine;
    }
  }
  return engines.isEmpty ? null : engines.first;
}

/// Every engine field shown in the UI: [TranslationEngine] equality only
/// compares id and name, which would hide an edited model or locality.
Object? improveEngineKey(TranslationEngine? engine) => engine == null
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
