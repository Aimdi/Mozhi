import 'dart:async';

import 'package:bloc/bloc.dart';
// compute() runs long diffs off the UI isolate.
// ignore: avoid_flutter_imports
import 'package:flutter/foundation.dart';
import 'package:mozhi/proofread/cubit/proofread_state.dart';
import 'package:mozhi/proofread/models/proofread_diff.dart';
import 'package:mozhi/proofread/models/proofread_rephrasing.dart';
import 'package:mozhi/proofread/models/sentence_segmenter.dart';
import 'package:mozhi/usage/usage.dart';
import 'package:translation_repository/translation_repository.dart';

export 'proofread_state.dart';

/// Drives the proofreading screen (Kagi-style): sends the input to an AI
/// engine and lets the user accept or reject each suggested edit, and
/// replace any sentence of the result with an alternative phrasing (DeepL
/// Write-style).
///
/// The corrected text ([ProofreadState.outputText]) comes from the
/// accepted edits alone; the rephrasings ([ProofreadState.rephrasings])
/// replace whole sentences of it, and the text the user copies, shares or
/// keeps is [ProofreadState.finalText], the corrected text with them. A
/// new result drops the rephrasings; accepting or rejecting an edit keeps
/// those of the sentences it does not touch ([ProofreadRephrasings.remap]).
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

  /// Incremented per alternatives request (and when the alternatives are
  /// closed) so stale ones are ignored.
  int _alternativesRequest = 0;

  /// How many alternatives [loadAlternatives] asks for.
  static const alternativesCount = 3;

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
    // Proofreading needs the general prompt profile: dedicated translation
    // models (Hy-MT, TranslateGemma) can't do it.
    final ai = engines.where((e) => e.supportsExtras).toList(growable: false);
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

  /// Updates the AI engines (non-AI engines, and AI engines without
  /// [TranslationEngine.supportsExtras] such as dedicated translation
  /// models, are ignored), refreshing their
  /// details (e.g. an edited model). An engine the user picked is kept while
  /// it is still available; otherwise [preferred] is used, else the current
  /// engine, else the first one.
  void setEngines(
    List<TranslationEngine> engines, {
    TranslationEngine? preferred,
  }) {
    final keepCurrent =
        _engineChosen &&
        engines.any((e) => e.supportsExtras && e.id == state.engine?.id);
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
    if (!engine.supportsExtras) return;
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

  /// Rewrites toward a [tone]; [WritingTone.automatic] keeps the author's.
  void setTone(WritingTone tone) => emit(state.copyWith(tone: tone));

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
        tone: state.tone,
      );
      // The provider billed the request even when its result is no longer
      // shown (the page closed or a newer proofread started).
      _recordUsage(engine, input: text, result: result);
      if (isClosed || request != _request) return;
      final reconciled = await _reconcile(text, result);
      if (isClosed || request != _request) return;
      _alternativesRequest++;
      emit(
        state.copyWith(
          status: ProofreadStatus.success,
          result: () => reconciled,
          proofreadInput: text,
          acceptedEdits: {for (var i = 0; i < reconciled.edits.length; i++) i},
          rephrasings: const [],
          alternatives: () => null,
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
    final output = [
      result.correctedText,
      result.summary,
      for (final edit in result.edits) edit.explanation,
    ].where((part) => part.isNotEmpty).join('\n');
    _recordText(engine, input: input, output: output);
  }

  /// Counts [input] and [output] of a request to a bring-your-own-key
  /// provider.
  void _recordText(
    TranslationEngine engine, {
    required String input,
    required String output,
  }) {
    final tracker = _usageTracker;
    final providerId = engine.providerId;
    if (tracker == null || providerId == null || providerId.isEmpty) return;
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
    _emitAccepted(accepted);
  }

  /// Applies every edit again (the result as it arrived).
  void acceptAll() =>
      _emitAccepted({for (var i = 0; i < state.edits.length; i++) i});

  void rejectAll() => _emitAccepted(const {});

  /// Emits [accepted] as the accepted edits, keeping the rephrasings of the
  /// sentences the change does not touch. Open alternatives are dropped
  /// when the corrected text changes (their sentence may have moved).
  void _emitAccepted(Set<int> accepted) {
    final next = state.copyWith(acceptedEdits: accepted);
    final before = state.outputText;
    final after = next.outputText;
    if (before == after) {
      emit(next);
      return;
    }
    _alternativesRequest++;
    emit(
      next.copyWith(
        rephrasings: ProofreadRephrasings.remap(
          before,
          after,
          state.rephrasings,
        ),
        alternatives: () => null,
      ),
    );
  }

  /// Asks the engine for [alternativesCount] alternative phrasings of
  /// [sentence] (one of [ProofreadState.sentences]) as it is shown (its
  /// rephrasing, if any), with the whole [ProofreadState.finalText] as
  /// context and the chosen style, tone and formality; the outcome is in
  /// [ProofreadState.alternatives]. Also retries.
  Future<void> loadAlternatives(SentenceRange sentence) async {
    final engine = state.engine;
    final base = state.outputText;
    if (engine == null ||
        state.result == null ||
        !state.sentences.contains(sentence)) {
      return;
    }
    final span = state.rephrasingOf(sentence)?.replacement ?? sentence.of(base);
    final text = state.finalText;
    final request = ++_alternativesRequest;
    emit(
      state.copyWith(
        alternatives: () =>
            ProofreadAlternatives(base: base, sentence: sentence, span: span),
      ),
    );
    try {
      final alternatives = await _repository.rephrase(
        engine,
        text,
        span,
        style: state.writingStyle,
        tone: state.tone,
        formality: state.formality,
        uiLanguage: _uiLanguage,
      );
      _recordText(
        engine,
        input: '$text\n$span',
        output: alternatives.join('\n'),
      );
      if (isClosed || request != _alternativesRequest) return;
      emit(
        state.copyWith(
          alternatives: () => state.alternatives?.copyWith(
            status: ProofreadAlternativesStatus.success,
            alternatives: alternatives,
          ),
        ),
      );
    } on Object catch (error, stackTrace) {
      if (isClosed || request != _alternativesRequest) return;
      addError(error, stackTrace);
      emit(
        state.copyWith(
          alternatives: () => state.alternatives?.copyWith(
            status: ProofreadAlternativesStatus.failure,
            error: () => error,
          ),
        ),
      );
    }
  }

  /// Forgets the alternatives of [sentence] (their sheet closed); a pending
  /// request for them is ignored.
  void closeAlternatives(SentenceRange sentence) {
    if (isClosed || state.alternatives?.sentence != sentence) return;
    _alternativesRequest++;
    emit(state.copyWith(alternatives: () => null));
  }

  /// Replaces [sentence] (one of [ProofreadState.sentences]) with
  /// [replacement] in [ProofreadState.finalText]; the sentence itself (or a
  /// blank one) restores it. Closes its alternatives.
  void rephraseSentence(SentenceRange sentence, String replacement) {
    if (state.result == null) return;
    final rephrasings = ProofreadRephrasings.replace(
      state.outputText,
      state.rephrasings,
      sentence,
      replacement,
    );
    final closing = state.alternatives?.sentence == sentence;
    if (closing) _alternativesRequest++;
    emit(
      state.copyWith(
        rephrasings: rephrasings,
        alternatives: closing ? () => null : null,
      ),
    );
  }

  /// Puts [sentence] back as the corrected text has it.
  void restoreSentence(SentenceRange sentence) =>
      rephraseSentence(sentence, '');

  /// Moves the output (with the rephrasings) into the input and clears the
  /// result.
  void useOutputAsInput() {
    final output = state.finalText;
    if (state.result == null) return;
    _request++;
    emit(_cleared(output));
  }

  /// Clears input and result (cancels a pending request).
  void clear() {
    _request++;
    emit(_cleared(''));
  }

  ProofreadState _cleared(String input) {
    _alternativesRequest++;
    return state.copyWith(
      input: input,
      status: ProofreadStatus.idle,
      result: () => null,
      proofreadInput: '',
      acceptedEdits: const {},
      rephrasings: const [],
      alternatives: () => null,
      error: () => null,
    );
  }
}
