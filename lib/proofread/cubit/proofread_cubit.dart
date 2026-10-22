import 'dart:async';

import 'package:bloc/bloc.dart';
// compute() runs long diffs off the UI isolate.
// ignore: avoid_flutter_imports
import 'package:flutter/foundation.dart';
import 'package:mozhi/proofread/cubit/proofread_state.dart';
import 'package:mozhi/proofread/models/proofread_diff.dart';
import 'package:mozhi/usage/usage.dart';
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
    this._usageTracker,
  }) : super(_withEngines(const ProofreadState(), engines, engine));

  final TranslationRepository _repository;
  final String _uiLanguage;

  /// Counts what each finished proofread sends to and receives from a
  /// bring-your-own-key provider.
  final UsageTracker? _usageTracker;

  /// Incremented per request so stale responses are ignored.
  int _request = 0;

  /// Whether the user picked the engine. Until then the engine follows the
  /// preferred (assist) engine passed to [setEngines].
  bool _engineChosen = false;

  /// Combined length of input and corrected text from which reconciling a
  /// result runs in a background isolate (where available).
  static const backgroundDiffLength = 8000;

  /// Text with the accepted edits applied (see [ProofreadState.outputText]).
  // Read-only query derived from state; it changes nothing.
  // ignore: prefer_void_public_cubit_methods
  String get outputText => state.outputText;

  static ProofreadState _withEngines(
    ProofreadState state,
    List<TranslationEngine> engines,
    TranslationEngine? preferred, {
    bool keepCurrent = false,
  }) {
    final ai = engines.where((e) => e.isAi).toList(growable: false);
    TranslationEngine? find(TranslationEngine? engine) {
      if (engine == null) return null;
      for (final candidate in ai) {
        if (candidate.id == engine.id) return candidate;
      }
      return null;
    }

    final selected = keepCurrent
        ? find(state.engine) ?? find(preferred)
        : find(preferred) ?? find(state.engine);
    return state.copyWith(
      availableEngines: ai,
      engine: () => selected ?? (ai.isEmpty ? null : ai.first),
    );
  }

  /// Updates the AI engines (non-AI engines are ignored), refreshing their
  /// details (e.g. an edited model). An engine the user picked is kept while
  /// it is still available; otherwise [preferred] is used, else the current
  /// engine, else the first one.
  void setEngines(
    List<TranslationEngine> engines, {
    TranslationEngine? preferred,
  }) {
    final keepCurrent =
        _engineChosen && engines.any((e) => e.isAi && e.id == state.engine?.id);
    _engineChosen = keepCurrent;
    final next = _withEngines(
      state,
      engines,
      preferred,
      keepCurrent: keepCurrent,
    );
    if (next != state) emit(next);
  }

  void setEngine(TranslationEngine engine) {
    if (!engine.isAi) return;
    _engineChosen = true;
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

  /// Rewords for a CEFR [level]; [ReadingLevel.standard] keeps the author's.
  void setReadingLevel(ReadingLevel level) =>
      emit(state.copyWith(readingLevel: level));

  /// Converts to a regional [variety]; null keeps the author's.
  void setVariety(ProofreadVariety? variety) =>
      emit(state.copyWith(variety: () => variety));

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
        readingLevel: state.readingLevel,
        variety: state.variety,
        context: state.context.trim(),
        uiLanguage: _uiLanguage,
      );
      // The provider billed the request even when its result is no longer
      // shown (the page closed or a newer proofread started).
      _recordUsage(engine, input: text, result: result);
      if (isClosed || request != _request) return;
      final reconciled = await _reconcile(text, result);
      if (isClosed || request != _request) return;
      emit(
        state.copyWith(
          status: ProofreadStatus.success,
          result: () => reconciled,
          proofreadInput: text,
          acceptedEdits: {for (var i = 0; i < reconciled.edits.length; i++) i},
        ),
      );
    } on Object catch (error, stackTrace) {
      if (isClosed || request != _request) return;
      addError(error, stackTrace);
      emit(state.copyWith(status: ProofreadStatus.failure, error: () => error));
    }
  }

  void _recordUsage(
    TranslationEngine engine, {
    required String input,
    required ProofreadResult result,
  }) {
    final tracker = _usageTracker;
    final providerId = engine.providerId;
    if (tracker == null || providerId == null || providerId.isEmpty) return;
    final output = [
      result.correctedText,
      result.summary,
      for (final edit in result.edits) edit.explanation,
    ].where((part) => part.isNotEmpty).join('\n');
    try {
      unawaited(
        tracker
            .recordText(providerId, input: input, output: output)
            .then((_) {}, onError: (Object _) {}),
      );
    } on Object {
      // Usage counting must never break proofreading.
    }
  }

  /// Adds the changes that [result]'s corrected text makes without listing
  /// them as edits (see [ProofreadDiff.reconcile]).
  static Future<ProofreadResult> _reconcile(
    String text,
    ProofreadResult result,
  ) async {
    final request = (text, result.edits, result.correctedText);
    final edits =
        text.length + result.correctedText.length >= backgroundDiffLength
        ? await compute(_reconcileEdits, request)
        : _reconcileEdits(request);
    if (edits.length == result.edits.length) return result;
    return ProofreadResult(
      correctedText: result.correctedText,
      edits: edits,
      detectedLanguage: result.detectedLanguage,
      summary: result.summary,
      maskedPersonalData: result.maskedPersonalData,
    );
  }

  static List<ProofreadEdit> _reconcileEdits(
    (String, List<ProofreadEdit>, String) request,
  ) => ProofreadDiff.reconcile(request.$1, request.$2, request.$3);

  /// Accepts or rejects the edit at [index].
  void toggleEdit(int index) {
    if (index < 0 || index >= state.edits.length) return;
    final accepted = {...state.acceptedEdits};
    if (!accepted.remove(index)) accepted.add(index);
    emit(state.copyWith(acceptedEdits: accepted));
  }

  /// Applies every edit again (the result as it arrived).
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
