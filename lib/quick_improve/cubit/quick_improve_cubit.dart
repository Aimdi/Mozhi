import 'dart:async';

import 'package:bloc/bloc.dart';
// compute() runs long diffs off the UI isolate.
// ignore: avoid_flutter_imports
import 'package:flutter/foundation.dart';
import 'package:mozhi/proofread/models/proofread_diff.dart';
import 'package:mozhi/quick_improve/cubit/quick_improve_state.dart';
import 'package:mozhi/quick_improve/models/improve_engines.dart';
import 'package:mozhi/usage/usage.dart';
import 'package:translation_repository/translation_repository.dart';

export 'quick_improve_state.dart';

/// Proofreads one piece of text selected in another app ("Improve with
/// Mozhi" in Android's text selection toolbar), independently of the
/// Proofread tab but like it:
///
/// * The engine is the Proofread tab's ([ImproveEngines]: the assist
///   engine when it can proofread, else the first AI engine that can).
///   [updateEngines] follows the app's engine list; an engine the user
///   picked here ([selectEngine]) is kept while it is still there.
/// * [start] proofreads as soon as an engine is known (the user asked for
///   it by choosing "Improve with Mozhi"); without one the state says why
///   ([QuickImproveStatus.loadingEngines], [QuickImproveStatus.noEngine],
///   [QuickImproveStatus.enginesFailed]).
/// * The privacy settings apply as everywhere: the repository enforces
///   them (Offline only, consent for cloud providers and new
///   destinations, the personal data shield). When they stop the
///   proofread, the state is a [QuickImproveStatus.failure] with a
///   `ConsentRequiredException` (nothing was sent); [retry] proofreads
///   once consent is given.
/// * Every suggested edit is applied ([QuickImproveState.improvedText]);
///   changes the corrected text makes without listing them count too
///   (`ProofreadDiff.reconcile`, as in the Proofread tab).
/// * [setLevel] / [setStyle] proofread again with the new option (not
///   persisted: the Proofread tab does not remember them either).
/// * What a bring-your-own-key provider was sent and answered is counted
///   in the [UsageTracker], if one is given. Nothing goes to the history.
class QuickImproveCubit extends Cubit<QuickImproveState> {
  /// `engines`: the engines known when the sheet opens (default: none
  /// yet, still loading). `uiLanguage`: English name of the UI language,
  /// for the edits' explanations.
  new({
    required this._repository,
    required String text,
    ImproveEngines engines = const ImproveEngines(
      status: ImproveEnginesStatus.loading,
    ),
    this._uiLanguage = 'English',
    this._usageTracker,
    CorrectionLevel level = CorrectionLevel.standard,
    WritingStyle style = WritingStyle.general,
  }) : _engines = engines,
       super(
         QuickImproveState(
           text: text,
           engine: engines.engine,
           engines: engines.engines,
           level: level,
           style: style,
         ),
       );

  /// Combined length of input and corrected text from which reconciling a
  /// result runs in a background isolate (where available).
  static const backgroundDiffLength = 8000;

  final TranslationRepository _repository;
  final String _uiLanguage;
  final UsageTracker? _usageTracker;

  ImproveEngines _engines;

  /// [start] was called: proofread once an engine is known.
  bool _wanted = false;

  /// A proofread has started (the first one is not repeated by
  /// [updateEngines]).
  bool _proofreadStarted = false;

  /// The user picked the engine: keep it while it is available.
  bool _engineChosen = false;

  /// Incremented per request so stale responses are ignored.
  int _request = 0;

  /// Proofreads right away when an engine is known, else waits for
  /// [updateEngines].
  Future<void> start() {
    _wanted = true;
    if (state.engine != null) return improve();
    final waiting = _waiting(state);
    if (waiting != state) emit(waiting);
    return Future.value();
  }

  /// Follows the app's AI engines. The first proofread starts once an
  /// engine is known (after [start]).
  Future<void> updateEngines(ImproveEngines engines) {
    if (isClosed) return Future.value();
    _engines = engines;
    final current = state.engine;
    final keep =
        _engineChosen &&
        current != null &&
        engines.engines.any((engine) => engine.id == current.id);
    _engineChosen = keep;
    final engine = keep
        ? pickProofreadEngine(engines.engines, preferred: current)
        : engines.engine;
    var next = state.copyWith(engines: engines.engines, engine: () => engine);
    if (!_proofreadStarted) next = _waiting(next);
    if (next != state) emit(next);
    if (_wanted && !_proofreadStarted && engine != null) return improve();
    return Future.value();
  }

  /// Proofreads the text with the current engine, level and style.
  Future<void> improve() async {
    final engine = state.engine;
    final text = state.text;
    if (isClosed || engine == null || text.trim().isEmpty) return;
    _proofreadStarted = true;
    final request = ++_request;
    emit(
      state.copyWith(
        status: QuickImproveStatus.improving,
        result: () => null,
        improvedText: '',
        segments: const [],
        error: () => null,
      ),
    );
    try {
      final result = await _repository.proofread(
        engine,
        text,
        style: state.style,
        level: state.level,
        uiLanguage: _uiLanguage,
      );
      // The provider billed the request even when its result is no longer
      // shown (the sheet closed or a newer proofread started).
      _recordUsage(engine, input: text, result: result);
      if (!_isCurrent(request)) return;
      final improved = await _improvedOf(text, result);
      if (!_isCurrent(request)) return;
      emit(
        state.copyWith(
          status: QuickImproveStatus.success,
          result: () => improved.result,
          improvedText: improved.text,
          segments: improved.segments,
        ),
      );
    } on Object catch (error) {
      if (!_isCurrent(request)) return;
      emit(
        state.copyWith(status: QuickImproveStatus.failure, error: () => error),
      );
    }
  }

  /// Proofreads again (after an error, a consent or to get another
  /// version). Does nothing without an engine: the engine list is
  /// reloaded by the app ([updateEngines] follows).
  Future<void> retry() => improve();

  /// Proofreads again with [level].
  Future<void> setLevel(CorrectionLevel level) {
    if (level == state.level) return Future.value();
    emit(state.copyWith(level: level));
    return _proofreadStarted ? improve() : Future.value();
  }

  /// Proofreads again in [style].
  Future<void> setStyle(WritingStyle style) {
    if (style == state.style) return Future.value();
    emit(state.copyWith(style: style));
    return _proofreadStarted ? improve() : Future.value();
  }

  /// Proofreads with [engine] (kept while it is available); AI engines
  /// that cannot proofread are ignored.
  Future<void> selectEngine(TranslationEngine engine) {
    if (!engine.supportsExtras) return Future.value();
    if (engine.id == state.engine?.id &&
        state.status != QuickImproveStatus.failure) {
      return Future.value();
    }
    _engineChosen = true;
    emit(state.copyWith(engine: () => engine));
    return improve();
  }

  // ---------------------------------------------------------------------

  /// [state] with the status of an engine list that has not let anything
  /// be proofread yet.
  QuickImproveState _waiting(QuickImproveState state) {
    // About to proofread (once started).
    if (state.engine != null) {
      return state.copyWith(status: QuickImproveStatus.loadingEngines);
    }
    return state.copyWith(
      status: switch (_engines.status) {
        ImproveEnginesStatus.loading => QuickImproveStatus.loadingEngines,
        ImproveEnginesStatus.ready => QuickImproveStatus.noEngine,
        ImproveEnginesStatus.failure => QuickImproveStatus.enginesFailed,
      },
    );
  }

  bool _isCurrent(int request) => !isClosed && request == _request;

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

  /// [result] for [text] with its unlisted changes added as edits, the
  /// text with all of them applied and the changes to highlight; long
  /// texts are compared in a background isolate.
  static Future<_Improved> _improvedOf(
    String text,
    ProofreadResult result,
  ) async {
    final request = (text, result.edits, result.correctedText);
    final (
      edits,
      improved,
      segments,
    ) = text.length + result.correctedText.length >= backgroundDiffLength
        ? await compute(_diff, request)
        : _diff(request);
    return (
      result: identical(edits, result.edits)
          ? result
          : ProofreadResult(
              correctedText: result.correctedText,
              edits: edits,
              detectedLanguage: result.detectedLanguage,
              summary: result.summary,
              maskedPersonalData: result.maskedPersonalData,
            ),
      text: improved,
      segments: segments,
    );
  }

  /// The reconciled edits, the improved text and its diff segments for
  /// `(text, edits, correctedText)` (see `ProofreadState.outputText`: the
  /// edits are applied; a result without edits uses its non-blank
  /// corrected text).
  static (List<ProofreadEdit>, String, List<DiffSegment>) _diff(
    (String, List<ProofreadEdit>, String) request,
  ) {
    final (text, listed, corrected) = request;
    final edits = ProofreadDiff.reconcile(text, listed, corrected);
    if (edits.isEmpty) {
      final improved = corrected.trim().isEmpty ? text : corrected;
      return (edits, improved, ProofreadDiff.wordDiff(text, improved));
    }
    final all = {for (var i = 0; i < edits.length; i++) i};
    return (
      edits,
      ProofreadDiff.apply(text, edits, all),
      ProofreadDiff.editSegments(text, edits, all),
    );
  }

  @override
  Future<void> close() {
    _request++;
    return super.close();
  }
}

typedef _Improved = ({
  ProofreadResult result,
  String text,
  List<DiffSegment> segments,
});
