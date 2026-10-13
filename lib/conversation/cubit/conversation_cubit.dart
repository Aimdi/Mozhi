import 'dart:async';
import 'dart:math' as math;

import 'package:bloc/bloc.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:mozhi/conversation/cubit/conversation_state.dart';
import 'package:mozhi/conversation/models/conversation_turn.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/translate/cubit/translate_state.dart';
import 'package:translation_repository/translation_repository.dart';

export 'conversation_state.dart';

/// Thrown into a turn when there is no translation engine to use.
class ConversationNoEngineException implements Exception {
  const new();

  @override
  String toString() => 'ConversationNoEngineException';
}

/// Drives conversation mode: two people speaking [ConversationState.languageA]
/// and [ConversationState.languageB] take turns; each message is translated
/// for the other side and appended to the transcript.
///
/// * Every [submit] creates a turn and translates it with the engine
///   returned by `engine` (the app-wide `TranslateCubit` engine) through
///   [TranslationRepository.translate]; AI engines stream, so the turn's
///   translation grows until it is complete. Several turns may translate at
///   the same time.
/// * For AI engines the last [contextTurns] completed turns are passed as
///   context so pronouns and tone carry over between messages.
/// * With [ConversationState.autoSpeak] on, each completed translation is
///   read aloud with [SpeechService] in the target language.
class ConversationCubit extends Cubit<ConversationState> {
  new({
    required this._repository,
    required this._speech,
    required this._engine,
    required Language languageA,
    required Language languageB,
    this._options,
    this._availableLanguages,
    bool autoSpeak = false,
    this.contextTurns = 4,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       _session = ++_sessions,
       super(
         ConversationState(
           languageA: languageA,
           languageB: languageB,
           autoSpeak: autoSpeak,
         ),
       ) {
    // Speech ids are unique per conversation, so nothing of this one can
    // be playing yet.
    _speaking = _speech.speaking.listen(_onSpeaking);
  }

  /// Distinguishes the speech ids of different conversations.
  static int _sessions = 0;

  final TranslationRepository _repository;
  final SpeechService _speech;
  final TranslationEngine? Function() _engine;
  final TranslationOptions Function()? _options;
  final List<Language> Function()? _availableLanguages;
  final DateTime Function() _clock;
  final int _session;

  /// Number of previous turns given to AI engines as context (0 = none).
  final int contextTurns;

  final Map<int, _TranslationJob> _jobs = {};
  late final StreamSubscription<String?> _speaking;
  int _nextId = 0;

  /// Default languages for a new conversation: side A speaks the translate
  /// screen's source language (or the detected one when it is "Detect
  /// language"; else the device language, else English or Spanish) and
  /// side B its target language (English when the target is a custom
  /// style). The two always differ.
  static ({Language a, Language b}) defaultLanguages(
    TranslateState translate, {
    String? deviceLanguageCode,
  }) {
    final available = translate.targetLanguages;
    Language? concrete(Language? language) =>
        language == null || language.isAuto || language.isCustom
        ? null
        : language;
    Language resolve(String code) {
      final wanted =
          LanguageCatalog.byCode(code) ??
          Language(code: code, name: LanguageCatalog.nameOf(code));
      return concrete(LanguageMatcher.match(wanted, available)) ?? wanted;
    }

    Language? byCode(String? code) {
      if (code == null || code.trim().isEmpty) return null;
      return concrete(resolve(code.trim()));
    }

    final b = concrete(translate.target) ?? resolve('en');
    final bKey = LanguageMatcher.normalize(b.code);
    final a =
        [
          ?concrete(translate.source),
          ?byCode(translate.effectiveSourceCode),
          ?byCode(deviceLanguageCode),
          resolve('en'),
          resolve('es'),
        ].firstWhere(
          (language) => LanguageMatcher.normalize(language.code) != bKey,
        );
    return (a: a, b: b);
  }

  /// Id passed to [SpeechService.toggle] for [turnId]'s translation.
  @visibleForTesting
  String speechIdOf(int turnId) => 'conversation:$_session:$turnId';

  int? _turnIdOf(String? speechId) {
    final prefix = 'conversation:$_session:';
    if (speechId == null || !speechId.startsWith(prefix)) return null;
    return int.tryParse(speechId.substring(prefix.length));
  }

  void _onSpeaking(String? speechId) {
    final turnId = _turnIdOf(speechId);
    if (turnId == state.speakingTurnId) return;
    emit(state.copyWith(speakingTurnId: () => turnId));
  }

  /// Translates [text] said by [side] for the other side and appends it to
  /// the transcript. Blank text is ignored. Without an engine the turn is
  /// added as failed ([ConversationNoEngineException]). Completes when the
  /// translation finished, failed or was cancelled.
  Future<void> submit(ConversationSide side, String text) {
    final original = text.trim();
    if (original.isEmpty || isClosed) return Future.value();
    final engine = _engine();
    final turn = ConversationTurn(
      id: _nextId++,
      side: side,
      original: original,
      source: state.languageOf(side),
      target: state.languageOf(side.other),
      createdAt: _clock(),
      engineId: engine?.id,
      engineName: engine?.name,
      status: engine == null
          ? ConversationTurnStatus.failed
          : ConversationTurnStatus.translating,
      error: engine == null ? const ConversationNoEngineException() : null,
    );
    emit(state.copyWith(turns: [...state.turns, turn]));
    if (engine == null) return Future.value();
    return _translate(turn, engine);
  }

  /// Translates a failed turn again with the current engine.
  Future<void> retry(int turnId) {
    final turn = state.turnById(turnId);
    if (turn == null || !turn.isFailed || isClosed) return Future.value();
    final engine = _engine();
    final reset = _updateTurn(
      turnId,
      (current) => engine == null
          ? current.copyWith(error: () => const ConversationNoEngineException())
          : current.copyWith(
              translation: '',
              engineId: () => engine.id,
              engineName: () => engine.name,
              status: ConversationTurnStatus.translating,
              error: () => null,
            ),
    );
    if (engine == null || reset == null) return Future.value();
    return _translate(reset, engine);
  }

  Future<void> _translate(ConversationTurn turn, TranslationEngine engine) {
    final request = TranslationRequest(
      text: turn.original,
      source: _resolve(turn.source),
      target: _resolve(turn.target),
      options: _optionsFor(engine, turn),
    );
    final job = _TranslationJob();
    _jobs[turn.id] = job;
    job.subscription = _repository
        .translate(engine, request)
        .listen(
          (result) => _updateTurn(
            turn.id,
            (current) => current.copyWith(
              translation: result.text,
              engineName: () => result.engineName,
            ),
          ),
          onError: (Object error) {
            _jobs.remove(turn.id);
            _updateTurn(
              turn.id,
              (current) => current.copyWith(
                status: ConversationTurnStatus.failed,
                error: () => error,
              ),
            );
            job.finish();
          },
          onDone: () {
            _jobs.remove(turn.id);
            final done = _updateTurn(
              turn.id,
              (current) =>
                  current.copyWith(status: ConversationTurnStatus.complete),
            );
            job.finish();
            if (done != null && state.autoSpeak) unawaited(speak(done.id));
          },
          cancelOnError: true,
        );
    return job.done;
  }

  /// Maps [language] onto the current engine's language list so codes stay
  /// valid after an engine switch.
  Language _resolve(Language language) {
    final available = _availableLanguages?.call() ?? const <Language>[];
    if (available.isEmpty) return language;
    return LanguageMatcher.match(language, available) ?? language;
  }

  TranslationOptions _optionsFor(
    TranslationEngine engine,
    ConversationTurn turn,
  ) {
    final base = (_options?.call() ?? const TranslationOptions()).copyWith(
      instructions: '',
    );
    if (!engine.isAi || contextTurns <= 0) return base;
    final previous = [
      for (final other in state.turns)
        if (other.id < turn.id && other.isComplete) other,
    ];
    final recent = previous.skip(math.max(0, previous.length - contextTurns));
    final setting =
        'This is a live spoken conversation between two people: one '
        'speaks ${state.languageA.name}, the other '
        '${state.languageB.name}. Translate it as natural speech.';
    final lines = [
      if (base.context.trim().isNotEmpty) base.context.trim(),
      setting,
      if (recent.isNotEmpty) 'Previous messages:',
      for (final other in recent)
        '${other.source.name} speaker: ${other.original}',
    ];
    return base.copyWith(context: lines.join('\n'));
  }

  /// Reads [turnId]'s translation aloud in its target language, or stops it
  /// when it is already playing. Failures increment
  /// [ConversationState.speechFailures].
  Future<void> speak(int turnId) async {
    final turn = state.turnById(turnId);
    if (turn == null || turn.translation.trim().isEmpty || isClosed) return;
    try {
      await _speech.toggle(
        id: speechIdOf(turnId),
        text: turn.translation,
        languageCode: turn.target.code,
      );
    } on Object {
      if (!isClosed) {
        emit(state.copyWith(speechFailures: state.speechFailures + 1));
      }
    }
  }

  /// Removes one turn (cancelling its translation and playback).
  Future<void> removeTurn(int turnId) async {
    if (state.turnById(turnId) == null) return;
    final speaking = state.speakingTurnId == turnId;
    emit(
      state.copyWith(
        turns: [
          for (final turn in state.turns)
            if (turn.id != turnId) turn,
        ],
        speakingTurnId: speaking ? () => null : null,
      ),
    );
    await _jobs.remove(turnId)?.cancel();
    if (speaking) await _stopSpeech();
  }

  /// Removes every turn, cancelling translations in flight and playback.
  Future<void> clear() async {
    final jobs = _jobs.values.toList();
    _jobs.clear();
    final speaking = state.speakingTurnId != null;
    emit(state.copyWith(turns: const [], speakingTurnId: () => null));
    await Future.wait([for (final job in jobs) job.cancel()]);
    if (speaking) await _stopSpeech();
  }

  /// Sets the language spoken by [side]. Picking the other side's language
  /// swaps the two. Auto and custom languages are ignored.
  void setLanguage(ConversationSide side, Language language) {
    if (language.isAuto || language.isCustom) return;
    if (language == state.languageOf(side)) return;
    if (language == state.languageOf(side.other)) {
      swapLanguages();
      return;
    }
    emit(
      side == ConversationSide.a
          ? state.copyWith(languageA: language)
          : state.copyWith(languageB: language),
    );
  }

  void swapLanguages() => emit(
    state.copyWith(languageA: state.languageB, languageB: state.languageA),
  );

  void setAutoSpeak({required bool enabled}) =>
      emit(state.copyWith(autoSpeak: enabled));

  void setFaceToFace({required bool enabled}) =>
      emit(state.copyWith(faceToFace: enabled));

  ConversationTurn? _updateTurn(
    int turnId,
    ConversationTurn Function(ConversationTurn turn) change,
  ) {
    if (isClosed) return null;
    final index = state.turns.indexWhere((turn) => turn.id == turnId);
    if (index < 0) return null;
    final updated = change(state.turns[index]);
    emit(state.copyWith(turns: [...state.turns]..[index] = updated));
    return updated;
  }

  Future<void> _stopSpeech() async {
    try {
      await _speech.stop();
    } on Object {
      // Nothing is playing any more either way.
    }
  }

  @override
  Future<void> close() async {
    final jobs = _jobs.values.toList();
    _jobs.clear();
    final speaking = state.speakingTurnId != null;
    await _speaking.cancel();
    await Future.wait([for (final job in jobs) job.cancel()]);
    if (speaking) await _stopSpeech();
    await super.close();
  }
}

/// A translation in flight.
class _TranslationJob {
  final _completer = Completer<void>();
  StreamSubscription<TranslationResult>? subscription;

  Future<void> get done => _completer.future;

  void finish() {
    if (!_completer.isCompleted) _completer.complete();
  }

  Future<void> cancel() async {
    await subscription?.cancel();
    finish();
  }
}
