import 'package:bloc/bloc.dart';
import 'package:mozhi/proofread/cubit/proofread_state.dart';
import 'package:translation_repository/translation_repository.dart';

export 'proofread_state.dart';

/// Drives the proofreading screen (Kagi-style): sends the input to an AI
/// engine and lets the user accept or reject each suggested edit.
class ProofreadCubit extends Cubit<ProofreadState> {
  new({
    required this._repository,
    List<TranslationEngine> engines = const [],
    TranslationEngine? engine,
    this._uiLanguage = 'English',
  }) : super(_withEngines(const ProofreadState(), engines, engine));

  final TranslationRepository _repository;
  final String _uiLanguage;

  /// Incremented per request so stale responses are ignored.
  int _request = 0;

  /// Text with the accepted edits applied (see [ProofreadState.outputText]).
  String get outputText => state.outputText;

  static ProofreadState _withEngines(
    ProofreadState state,
    List<TranslationEngine> engines,
    TranslationEngine? preferred,
  ) {
    final ai = engines.where((e) => e.isAi).toList(growable: false);
    TranslationEngine? find(TranslationEngine? engine) {
      if (engine == null) return null;
      for (final candidate in ai) {
        if (candidate.id == engine.id) return candidate;
      }
      return null;
    }

    final selected =
        find(state.engine) ?? find(preferred) ?? (ai.isEmpty ? null : ai.first);
    return state.copyWith(availableEngines: ai, engine: () => selected);
  }

  /// Updates the AI engines (non-AI engines are ignored). Keeps the current
  /// engine when still available, else [preferred], else the first one.
  void setEngines(
    List<TranslationEngine> engines, {
    TranslationEngine? preferred,
  }) {
    emit(_withEngines(state, engines, preferred));
  }

  void setEngine(TranslationEngine engine) {
    if (!engine.isAi) return;
    emit(state.copyWith(engine: () => engine));
  }

  void setInput(String text) {
    if (text == state.input) return;
    emit(
      state.copyWith(
        input: text,
        status: state.status == ProofreadStatus.failure
            ? ProofreadStatus.idle
            : null,
        error: () => null,
      ),
    );
  }

  void setStyle(WritingStyle style) =>
      emit(state.copyWith(writingStyle: style));

  void setLevel(CorrectionLevel level) =>
      emit(state.copyWith(correctionLevel: level));

  void setFormality(Formality formality) =>
      emit(state.copyWith(formality: formality));

  void setContext(String context) => emit(state.copyWith(context: context));

  /// Proofreads the current input with the selected engine. All returned
  /// edits start accepted.
  Future<void> proofread() async {
    final engine = state.engine;
    final text = state.input;
    if (engine == null || text.trim().isEmpty) return;
    final request = ++_request;
    emit(state.copyWith(status: ProofreadStatus.loading, error: () => null));
    try {
      final result = await _repository.proofread(
        engine,
        text,
        style: state.writingStyle,
        level: state.correctionLevel,
        formality: state.formality,
        context: state.context.trim(),
        uiLanguage: _uiLanguage,
      );
      if (isClosed || request != _request) return;
      emit(
        state.copyWith(
          status: ProofreadStatus.success,
          result: () => result,
          proofreadInput: text,
          acceptedEdits: {for (var i = 0; i < result.edits.length; i++) i},
        ),
      );
    } on Object catch (error, stackTrace) {
      if (isClosed || request != _request) return;
      addError(error, stackTrace);
      emit(state.copyWith(status: ProofreadStatus.failure, error: () => error));
    }
  }

  /// Accepts or rejects the edit at [index].
  void toggleEdit(int index) {
    if (index < 0 || index >= state.edits.length) return;
    final accepted = {...state.acceptedEdits};
    if (!accepted.remove(index)) accepted.add(index);
    emit(state.copyWith(acceptedEdits: accepted));
  }

  void acceptAll() => emit(
    state.copyWith(
      acceptedEdits: {for (var i = 0; i < state.edits.length; i++) i},
    ),
  );

  void rejectAll() => emit(state.copyWith(acceptedEdits: const {}));

  /// Moves the output into the input and clears the result.
  void useOutputAsInput() {
    final output = outputText;
    if (state.result == null) return;
    _request++;
    emit(_cleared(output));
  }

  /// Clears input and result (cancels a pending request).
  void clear() {
    _request++;
    emit(_cleared(''));
  }

  ProofreadState _cleared(String input) => state.copyWith(
    input: input,
    status: ProofreadStatus.idle,
    result: () => null,
    proofreadInput: '',
    acceptedEdits: const {},
    error: () => null,
  );
}
