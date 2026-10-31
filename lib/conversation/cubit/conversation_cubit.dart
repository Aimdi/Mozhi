import 'dart:async';
import 'dart:math' as math;

import 'package:bloc/bloc.dart';
// Only visibleForTesting is used; no widgets.
// ignore: avoid_flutter_imports
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:mozhi/conversation/cubit/conversation_state.dart';
import 'package:mozhi/conversation/models/conversation_turn.dart';
import 'package:mozhi/conversation/recognizer/conversation_recognizer.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/translate/cubit/translate_state.dart';
import 'package:mozhi/usage/data/usage_tracker.dart';
import 'package:mozhi/voice/speech_input_state.dart' show SpeechInputFailure;
import 'package:translation_repository/translation_repository.dart';

export 'conversation_state.dart';

/// Thrown into a turn when there is no translation engine to use.
class ConversationNoEngineException implements Exception {
  const new();

  @override
  String toString() => 'ConversationNoEngineException';
}

/// Put into a turn whose translation was stopped together with the
/// hands-free conversation ([ConversationCubit.stopSession]); it can be
/// retried.
class ConversationStoppedException implements Exception {
  const new();

  @override
  String toString() => 'ConversationStoppedException';
}

/// Creates the timers of a hands-free conversation (default [Timer.new]);
/// tests pass fake ones.
typedef ConversationTimerFactory = Timer Function(
  Duration duration,
  void Function() callback,
);

/// Drives conversation mode: two people speaking [ConversationState.languageA]
/// and [ConversationState.languageB] take turns; each message is translated
/// for the other side and appended to the transcript.
///
/// * Every [submit] creates a turn and translates it with the engine
///   returned by `engine` (the app-wide `TranslateCubit` engine) through
///   [TranslationRepository.translate]; AI engines stream, so the turn's
///   translation grows until it is complete. Several turns may translate at
///   the same time.
/// * For AI engines that take options (not translation-only models such as
///   TranslateGemma) the last [contextTurns] completed turns are passed as
///   context so pronouns and tone carry over between messages.
/// * With [ConversationState.autoSpeak] on, each completed translation is
///   read aloud with [SpeechService] in the target language.
/// * With a `usageTracker`, every answered translation by a
///   bring-your-own-key provider (engines with a `providerId`) is counted
///   once: the message and, for AI engines that take options (not
///   translation-only models), the conversation context sent with it as
///   input, the translation as output. Results served from the translation
///   cache and failed or cancelled translations are not counted.
///
/// With a `recognizer` ([ConversationState.handsFree]) the two sides can
/// also talk hands-free ([ConversationState.session], see
/// [ConversationSession] for the state machine): [toggleSession] listens
/// for side A (or whoever's turn it is), submits what was heard as that
/// side's turn, reads the translation aloud (with
/// [ConversationState.autoSpeak], which a session turns on unless the user
/// chose otherwise) and then listens for the other side, until it is
/// stopped ([toggleSession], [stopSession]).
///
/// * The microphone is never open while anything is read aloud: reading
///   aloud closes it, and it opens again `echoDelay` after the reading
///   ended, so the app does not hear itself. A reading whose end is never
///   reported is stopped after [speakingTimeout] plus
///   [speakingTimeoutPerCharacter] per character. A translation that is
///   not read aloud is also followed by `echoDelay`, and an announcement
///   by a screen reader ([announced]) keeps the microphone closed until
///   it was probably said.
/// * With "Detect the speaker" ([ConversationState.detectSpeaker], on by
///   default, [setDetectSpeaker]) recognisers that detect the spoken
///   language (on-device Whisper) assign the turn to the side whose
///   language was heard; any other language, or a recogniser that cannot
///   detect, keeps the side whose turn it is. Off, the side whose turn it
///   is is listened for in its own language.
/// * A turn ends at a real pause: [ConversationState.turnPause] (0.8 s by
///   default, 0.5 to 2 s, [setTurnPause]) of silence after speech, measured
///   by on-device Whisper's voice activity detection, or as that long
///   without new words from the system recogniser.
/// * Without speech for `silenceTimeout` the session pauses; silence or
///   unintelligible speech before that listens again. Speech is what the
///   recogniser recognised or detected ([ConversationHeardPartial],
///   [ConversationHeardSpeech]), not loudness: background noise does not
///   keep the microphone open. Voice input errors stop it as
///   [ConversationSessionFailed].
/// * A translation that needs consent or fails pauses the session at that
///   turn; [retry] (after consent) continues it.
/// * The one-time approval ("Once") the user gave for a turn's text is
///   used by the retry that follows it. When that retry then fails in
///   another way (a server down), the next [retry] of the same turn may use
///   that approval once more, so the user is not asked again for the same
///   text going to the same place: only for the same text, engine and
///   destination, only while no other translation runs, only once, and
///   only within `TranslationRepository.consentOnceLifetime` of the retry
///   it was given for (as long as the approval itself lasts; a retry later
///   asks again). It is withdrawn (`TranslationRepository.revokeOnce`) as
///   soon as that retry ends or another translation starts, so it never
///   lets other text through.
/// * The cubit owns the recogniser and disposes it in [close].
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
    this._usageTracker,
    ConversationRecognizer? recognizer,
    ConversationTimerFactory? timer,
    this._silenceTimeout = defaultSilenceTimeout,
    this._echoDelay = defaultEchoDelay,
  }) : _clock = clock ?? DateTime.now,
       _session = ++_sessions,
       _recognizer = recognizer,
       _timer = timer ?? Timer.new,
       super(
         ConversationState(
           languageA: languageA,
           languageB: languageB,
           autoSpeak: autoSpeak,
           handsFree: recognizer != null,
         ),
       ) {
    // Speech ids are unique per conversation, so nothing of this one can
    // be playing yet.
    _speaking = _speech.speaking.listen(_onSpeaking);
  }

  /// Distinguishes the speech ids of different conversations.
  static int _sessions = 0;

  /// How long a hands-free conversation waits for speech before it pauses.
  static const defaultSilenceTimeout = Duration(seconds: 8);

  /// How long after reading aloud the microphone opens again, so the end
  /// of the speech (or its echo) is not heard.
  static const defaultEchoDelay = Duration(milliseconds: 600);

  /// How many utterances in a row may come out empty (silence, noise)
  /// before a hands-free conversation pauses.
  static const maxEmptyUtterances = 4;

  /// How long reading aloud may take in a hands-free conversation, plus
  /// [speakingTimeoutPerCharacter] for each character, before it is
  /// stopped and the next side is listened for: some players never report
  /// the end (Chrome's speech synthesis drops long texts without an `end`
  /// event, an audio player may miss the completion).
  static const speakingTimeout = Duration(seconds: 10);

  /// See [speakingTimeout]; twice as much when read slowly.
  static const speakingTimeoutPerCharacter = Duration(milliseconds: 100);

  /// How long a screen reader takes per character of an announcement, on
  /// top of the echo delay (see [announced]).
  static const announcementPerCharacter = Duration(milliseconds: 80);

  final TranslationRepository _repository;
  final SpeechService _speech;
  final TranslationEngine? Function() _engine;
  final TranslationOptions Function()? _options;
  final List<Language> Function()? _availableLanguages;
  final DateTime Function() _clock;
  final int _session;

  /// Counts what answered translations send to and receive from a
  /// bring-your-own-key provider; optional.
  final UsageTracker? _usageTracker;

  /// Number of previous turns given to AI engines as context (0 = none).
  // Immutable configuration passed to the constructor, not state.
  // ignore: avoid_public_fields
  final int contextTurns;

  final Map<int, _TranslationJob> _jobs = {};

  /// Per turn, the one-time approval of a retry that then failed in
  /// another way: the turn's next [retry] may use it once more.
  final Map<int, _OnceConsent> _onceConsents = {};

  /// The approval left in the repository for the retry of a turn in
  /// flight; withdrawn once that ends or another translation starts.
  ({int turnId, ConsentRequiredException consent})? _retryGrant;

  late final StreamSubscription<String?> _speaking;
  int _nextId = 0;

  final ConversationRecognizer? _recognizer;
  final ConversationTimerFactory _timer;
  final Duration _silenceTimeout;
  final Duration _echoDelay;

  /// The utterance being listened to (cancelled by `_dropHearing`).
  // ignore: cancel_subscriptions
  StreamSubscription<ConversationHearing>? _hearing;

  /// Bumped whenever listening stops or starts over; events of older
  /// utterances are ignored.
  int _listenToken = 0;

  /// Runs while waiting for speech (see `silenceTimeout`).
  Timer? _silence;

  /// Delays opening the microphone after reading aloud (or while a
  /// screen reader announces something).
  Timer? _echo;

  /// Gives up a reading aloud whose end is never reported (see
  /// [speakingTimeout]).
  Timer? _speakingWatchdog;

  /// [close] was called: nothing may read aloud or open the microphone.
  bool _closing = false;

  /// Someone was heard in the current utterance.
  bool _heardVoice = false;

  /// Utterances in a row that came out empty.
  int _emptyUtterances = 0;

  /// Bumped by every read-aloud of the session (and by stopping it).
  int _speakToken = 0;

  /// The session's read-aloud call has not returned yet.
  bool _speakPending = false;

  /// The user chose whether translations are read aloud.
  bool _autoSpeakChosen = false;

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
  // Read-only query derived from state; it changes nothing.
  // ignore: prefer_void_public_cubit_methods
  String speechIdOf(int turnId) => 'conversation:$_session:$turnId';

  int? _turnIdOf(String? speechId) {
    final prefix = 'conversation:$_session:';
    if (speechId == null || !speechId.startsWith(prefix)) return null;
    return int.tryParse(speechId.substring(prefix.length));
  }

  void _onSpeaking(String? speechId) {
    if (isClosed) return;
    final turnId = _turnIdOf(speechId);
    if (turnId != state.speakingTurnId) {
      emit(state.copyWith(speakingTurnId: () => turnId));
    }
    final session = state.session;
    if (speechId != null && session is ConversationSessionListening) {
      // Something is read aloud (a listen button, auto-speak): the
      // microphone must not hear it. Listen again once it ended.
      _closeMicrophone();
      _cancelSilence();
      _enterSpeaking(
        ConversationSessionSpeaking(turnId: turnId, next: session.side),
      );
    } else if (speechId == null &&
        session is ConversationSessionSpeaking &&
        !_speakPending) {
      _listen(session.next, afterSpeech: true);
    }
  }

  /// Translates [text] said by [side] for the other side and appends it to
  /// the transcript. Blank text is ignored. Without an engine the turn is
  /// added as failed ([ConversationNoEngineException]). Completes when the
  /// translation finished, failed or was cancelled.
  ///
  /// While a hands-free conversation listens, the text is that
  /// conversation's turn of [side] (the microphone closes; after the
  /// translation the other side is listened for).
  Future<void> submit(ConversationSide side, String text) {
    if (text.trim().isEmpty || isClosed) return Future.value();
    if (state.session is ConversationSessionListening) {
      _closeMicrophone();
      _cancelSilence();
      return _sessionTurn(side, text);
    }
    final (turn, engine) = _newTurn(side, text);
    emit(state.copyWith(turns: [...state.turns, turn]));
    if (engine == null) return Future.value();
    return _translate(turn, engine);
  }

  /// Adds what [guest] of a conversation shared on the local network
  /// (`ConversationShareCubit`) typed in [language] as a turn of side B,
  /// translated into side A's language (side B's when the guest writes
  /// side A's language), and translates it like [submit]: read aloud with
  /// [ConversationState.autoSpeak]. A hands-free conversation goes on as
  /// it was (a reading aloud closes its microphone meanwhile). Blank text
  /// is ignored.
  Future<void> submitGuest(
    String text, {
    required Language language,
    required int guest,
  }) {
    if (text.trim().isEmpty || isClosed) return Future.value();
    final target =
        _primaryLanguage(language) == _primaryLanguage(state.languageA)
        ? state.languageB
        : state.languageA;
    final (turn, engine) = _newTurn(
      ConversationSide.b,
      text,
      source: language,
      target: target,
      guest: guest,
    );
    emit(state.copyWith(turns: [...state.turns, turn]));
    if (engine == null) return Future.value();
    return _translate(turn, engine);
  }

  /// A new turn of [side] saying [text] (in [source], for [target]: by
  /// default the two sides' languages) and the engine to translate it
  /// with (none: the turn failed with [ConversationNoEngineException]).
  (ConversationTurn, TranslationEngine?) _newTurn(
    ConversationSide side,
    String text, {
    Language? source,
    Language? target,
    int? guest,
  }) {
    final original = text.trim();
    final engine = _engine();
    final turn = ConversationTurn(
      id: _nextId++,
      side: side,
      original: original,
      source: source ?? state.languageOf(side),
      target: target ?? state.languageOf(side.other),
      createdAt: _clock(),
      engineId: engine?.id,
      engineName: engine?.name,
      status: engine == null
          ? ConversationTurnStatus.failed
          : ConversationTurnStatus.translating,
      error: engine == null ? const ConversationNoEngineException() : null,
      guest: guest,
    );
    return (turn, engine);
  }

  /// Translates a failed turn again with the current engine. When the
  /// hands-free conversation paused at this turn (consent, a failed
  /// translation), it continues with it.
  ///
  /// A turn stopped for consent is retried once the user gave it (the
  /// prompt records it in the repository, e.g. "Once"). When that retry
  /// fails in another way, the next retry of the turn uses the same
  /// one-time approval again, once (see the class documentation).
  Future<void> retry(int turnId) {
    final turn = state.turnById(turnId);
    if (turn == null || !turn.isFailed || isClosed) return Future.value();
    final asked = switch (turn.error) {
      final ConsentRequiredException consent => consent,
      _ => null,
    };
    // Used at most once more, by this retry.
    final kept = _onceConsents.remove(turnId);
    final givenAt = _clock();
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
    if (state.session
        case ConversationSessionPaused(
          :final next,
          turnId: final paused?,
          reason: ConversationPauseReason.consent ||
              ConversationPauseReason.translationFailed,
        )
        when paused == turnId) {
      emit(
        state.copyWith(
          session: ConversationSessionTranslating(
            turnId: turnId,
            speaker: reset.side,
            next: next,
          ),
        ),
      );
    }
    _withdrawRetryGrant();
    final ConsentRequiredException? grant;
    if (asked != null) {
      // Given by the user just now.
      grant = asked;
    } else if (kept != null && _mayReuse(kept, reset, engine)) {
      _repository.allowOnce(kept.consent);
      grant = kept.consent;
    } else {
      grant = null;
    }
    if (grant == null) return _translate(reset, engine);
    final retryGrant = (turnId: turnId, consent: grant);
    _retryGrant = retryGrant;
    return _translate(reset, engine).then((_) {
      if (identical(_retryGrant, retryGrant)) _withdrawRetryGrant();
      // Only an approval the user just gave is kept, so it is used at
      // most twice (this retry and one more) and never more.
      if (asked == null || isClosed) return;
      final after = state.turnById(turnId);
      if (after == null ||
          !after.isFailed ||
          after.error is ConsentRequiredException ||
          after.original != reset.original) {
        return;
      }
      _onceConsents[turnId] = _OnceConsent(
        consent: asked,
        engineId: engine.id,
        text: reset.original,
        givenAt: givenAt,
      );
    });
  }

  /// Whether the approval [kept] for [turn] may be used again for its
  /// retry with [engine]: the same text and engine, the same destination
  /// as when the user gave it (e.g. not another Mozhi instance), no other
  /// translation running that could take it first, and less than
  /// [TranslationRepository.consentOnceLifetime] since it was given.
  bool _mayReuse(
    _OnceConsent kept,
    ConversationTurn turn,
    TranslationEngine engine,
  ) {
    final consent = kept.consent;
    final age = _clock().difference(kept.givenAt);
    if (consent.kind == ConsentKind.offlineOnly ||
        age.isNegative ||
        age >= TranslationRepository.consentOnceLifetime ||
        _jobs.isNotEmpty ||
        turn.original != kept.text ||
        engine.id != kept.engineId) {
      return false;
    }
    try {
      return _repository.destinationOf(consent.engineId) == consent.destination;
    } on Object {
      // Unknown now: ask again.
      return false;
    }
  }

  /// Withdraws the approval of the retry in flight ([_retryGrant]), if
  /// any; nothing happens when its request used it.
  void _withdrawRetryGrant() {
    final grant = _retryGrant;
    _retryGrant = null;
    if (grant == null) return;
    try {
      _repository.revokeOnce(grant.consent);
    } on Object {
      // A repository test double without privacy settings.
    }
  }

  Future<void> _translate(ConversationTurn turn, TranslationEngine engine) {
    // Another translation must not take the approval of a retry.
    if (_retryGrant case (:final turnId, consent: _) when turnId != turn.id) {
      _withdrawRetryGrant();
    }
    final request = TranslationRequest(
      text: turn.original,
      source: _resolve(turn.source),
      target: _resolve(turn.target),
      options: _optionsFor(engine, turn),
    );
    final job = _TranslationJob();
    _jobs[turn.id] = job;
    TranslationResult? last;
    job.subscription = _repository
        .translate(engine, request)
        .listen(
          (result) {
            last = result;
            _updateTurn(
              turn.id,
              (current) => current.copyWith(
                translation: result.text,
                engineName: () => result.engineName,
              ),
            );
          },
          onError: (Object error) {
            _jobs.remove(turn.id);
            final failed = _updateTurn(
              turn.id,
              (current) => current.copyWith(
                status: ConversationTurnStatus.failed,
                error: () => error,
              ),
            );
            job.finish();
            if (failed != null) _onSessionTurnFailed(failed);
          },
          onDone: () {
            _jobs.remove(turn.id);
            final answer = last;
            if (answer != null) _recordUsage(engine, request, answer);
            final done = _updateTurn(
              turn.id,
              (current) =>
                  current.copyWith(status: ConversationTurnStatus.complete),
            );
            job.finish();
            if (done == null) return;
            if (_isSessionTranslating(done.id)) {
              _onSessionTurnTranslated(done);
            } else if (state.autoSpeak) {
              unawaited(speak(done.id));
            }
          },
          cancelOnError: true,
        );
    return job.done;
  }

  /// Counts the answered [request] to [engine]'s provider (engines with a
  /// `providerId`) when a usage tracker is set, unless [result] is
  /// incomplete or came from the cache. AI engines that take options also
  /// receive the conversation context, which is counted as input
  /// (translation-only models get the message alone). Never throws; tracker
  /// errors are ignored.
  void _recordUsage(
    TranslationEngine engine,
    TranslationRequest request,
    TranslationResult result,
  ) {
    final tracker = _usageTracker;
    final providerId = engine.providerId;
    if (tracker == null || providerId == null || providerId.isEmpty) return;
    if (!result.isComplete || result.fromCache) return;
    final context = engine.supportsOptions
        ? request.options.context.trim()
        : '';
    final input = [request.text, context].where((part) => part.isNotEmpty);
    try {
      unawaited(
        tracker
            .recordText(
              providerId,
              input: input.join('\n'),
              output: result.text,
            )
            .then((_) {}, onError: (Object _) {}),
      );
    } on Object {
      // Usage counting must never break the conversation.
    }
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
    // Translation-only AI models (TranslateGemma, Hy-MT) get the message
    // alone, so no context is built for them.
    if (!engine.supportsOptions || contextTurns <= 0) return base;
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
  /// when it is already playing. With [slow] it is read slowly from the
  /// start instead, also while it plays. [allowOnline] is the consent the
  /// user gave for a Mozhi instance to read it (see
  /// `SpeechUnavailableException.onlineConsent`). Failures increment
  /// [ConversationState.speechFailures] and are kept in
  /// [ConversationState.lastSpeechFailure].
  ///
  /// When the hands-free conversation paused because this turn may only be
  /// read aloud online ([ConversationPauseReason.speechConsent]), it
  /// continues with it.
  Future<void> speak(
    int turnId, {
    bool slow = false,
    ConsentRequiredException? allowOnline,
  }) async {
    if (isClosed || _closing) return;
    final turn = state.turnById(turnId);
    if (turn == null || turn.translation.trim().isEmpty) return;
    if (state.session
        case ConversationSessionPaused(
          :final next,
          reason: ConversationPauseReason.speechConsent,
          turnId: final paused?,
        )
        when paused == turnId) {
      await _speakForSession(turn, next, slow: slow, allowOnline: allowOnline);
      return;
    }
    try {
      if (slow) {
        await _speech.speak(
          id: speechIdOf(turnId),
          text: turn.translation,
          languageCode: turn.target.code,
          slow: true,
          allowOnline: allowOnline,
        );
      } else {
        await _speech.toggle(
          id: speechIdOf(turnId),
          text: turn.translation,
          languageCode: turn.target.code,
          allowOnline: allowOnline,
        );
      }
    } on Object catch (error) {
      _speechFailed(turnId, error, slow: slow, asked: allowOnline != null);
    }
  }

  void _speechFailed(
    int turnId,
    Object error, {
    required bool slow,
    required bool asked,
  }) {
    if (isClosed) return;
    emit(
      state.copyWith(
        speechFailures: state.speechFailures + 1,
        lastSpeechFailure: (
          turnId: turnId,
          slow: slow,
          error: error,
          asked: asked,
        ),
      ),
    );
  }

  /// Removes one turn (cancelling its translation and playback). A
  /// hands-free conversation translating it listens for the next side.
  Future<void> removeTurn(int turnId) async {
    if (state.turnById(turnId) == null) return;
    final session = state.session;
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
    _onceConsents.remove(turnId);
    await _jobs.remove(turnId)?.cancel();
    if (session is ConversationSessionTranslating &&
        session.turnId == turnId &&
        state.session == session) {
      _listen(session.next);
    }
    if (speaking) await _stopSpeech();
  }

  /// Removes every turn, cancelling translations in flight and playback;
  /// stops the hands-free conversation.
  Future<void> clear() async {
    await stopSession();
    _onceConsents.clear();
    _withdrawRetryGrant();
    final jobs = _jobs.values.toList();
    _jobs.clear();
    final speaking = state.speakingTurnId != null;
    emit(state.copyWith(turns: const [], speakingTurnId: () => null));
    await Future.wait([for (final job in jobs) job.cancel()]);
    if (speaking) await _stopSpeech();
  }

  /// Sets the language spoken by [side]. Picking the other side's language
  /// swaps the two. Auto and custom languages are ignored. A hands-free
  /// conversation that is listening starts over in the new language.
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
    _relistenAfterLanguageChange();
  }

  /// Swaps the two languages (a listening hands-free conversation starts
  /// over in the new language).
  void swapLanguages() {
    emit(
      state.copyWith(languageA: state.languageB, languageB: state.languageA),
    );
    _relistenAfterLanguageChange();
  }

  void _relistenAfterLanguageChange() {
    if (state.session case ConversationSessionListening(:final side)) {
      _listen(side, fresh: false);
    }
  }

  /// Whether completed translations are read aloud; also the user's choice
  /// for hands-free conversations.
  void setAutoSpeak({required bool enabled}) {
    _autoSpeakChosen = true;
    emit(state.copyWith(autoSpeak: enabled));
  }

  /// "Detect the speaker" (see [ConversationState.detectSpeaker]). A
  /// hands-free conversation that is listening starts over with it.
  void setDetectSpeaker({required bool enabled}) {
    if (enabled == state.detectSpeaker) return;
    emit(state.copyWith(detectSpeaker: enabled));
    _relistenAfterLanguageChange();
  }

  /// The silence that ends a turn ([ConversationState.turnPause]), kept
  /// within [ConversationState.minTurnPause] and
  /// [ConversationState.maxTurnPause]; from the next utterance on.
  void setTurnPause(Duration pause) {
    final kept = pause < ConversationState.minTurnPause
        ? ConversationState.minTurnPause
        : pause > ConversationState.maxTurnPause
        ? ConversationState.maxTurnPause
        : pause;
    if (kept != state.turnPause) emit(state.copyWith(turnPause: kept));
  }

  /// Face-to-face mode stops a hands-free conversation.
  void setFaceToFace({required bool enabled}) {
    if (enabled) unawaited(stopSession());
    emit(state.copyWith(faceToFace: enabled));
  }

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

  // ---------------------------------------------------------------------
  // Hands-free conversation
  // ---------------------------------------------------------------------

  /// The large microphone: starts a hands-free conversation (listening for
  /// whoever's turn it is: side A, or the side after the last message),
  /// stops a running one at once (listening, translating, reading aloud),
  /// or continues a paused or failed one. Does nothing without a
  /// recogniser.
  Future<void> toggleSession() async {
    switch (state.session) {
      case ConversationSessionIdle():
        startSession();
      case ConversationSessionPaused(:final next) ||
          ConversationSessionFailed(:final next):
        _listen(next);
      case ConversationSessionListening() ||
          ConversationSessionTranslating() ||
          ConversationSessionSpeaking():
        await stopSession();
    }
  }

  /// Starts a hands-free conversation with [side] (default: whoever's turn
  /// it is) unless one is active. Turns reading aloud on unless the user
  /// chose otherwise ([setAutoSpeak]).
  void startSession({ConversationSide? side}) {
    if (_recognizer == null || isClosed || _closing) return;
    if (state.session.isActive) return;
    if (!_autoSpeakChosen && !state.autoSpeak) {
      emit(state.copyWith(autoSpeak: true));
    }
    final turns = state.turns;
    _listen(
      side ?? (turns.isEmpty ? ConversationSide.a : turns.last.side.other),
    );
  }

  /// Stops the hands-free conversation at once: closes the microphone,
  /// stops the translation in flight (its turn fails with
  /// [ConversationStoppedException] and can be retried) and the reading
  /// aloud. Called when the app goes to the background or the tab changes.
  Future<void> stopSession() async {
    final session = state.session;
    if (!session.isActive || isClosed) return;
    _speakToken++;
    _speakPending = false;
    _cancelSilence();
    _cancelSpeakingWatchdog();
    _dropHearing();
    final stopped = <Future<void>>[?_recognizer?.cancel()];
    var turns = state.turns;
    if (session is ConversationSessionTranslating) {
      final job = _jobs.remove(session.turnId);
      if (job != null) {
        stopped.add(job.cancel());
        turns = [
          for (final turn in turns)
            if (turn.id == session.turnId)
              turn.copyWith(
                status: ConversationTurnStatus.failed,
                error: () => const ConversationStoppedException(),
              )
            else
              turn,
        ];
      }
    }
    emit(state.copyWith(turns: turns, session: ConversationSession.idle));
    if (session is ConversationSessionSpeaking) stopped.add(_stopSpeech());
    await Future.wait(stopped);
  }

  /// Lets [side] speak next (the language pill during a hands-free
  /// conversation): listening starts over for it, or it is listened for
  /// after the translation in progress; a paused or failed conversation
  /// continues with it.
  void switchTurn(ConversationSide side) {
    switch (state.session) {
      case ConversationSessionIdle():
        return;
      case final ConversationSessionListening listening:
        if (listening.side != side) _listen(side);
      case final ConversationSessionTranslating translating:
        emit(
          state.copyWith(
            session: ConversationSessionTranslating(
              turnId: translating.turnId,
              speaker: translating.speaker,
              next: side,
            ),
          ),
        );
      case final ConversationSessionSpeaking speaking:
        emit(
          state.copyWith(
            session: ConversationSessionSpeaking(
              turnId: speaking.turnId,
              next: side,
            ),
          ),
        );
      case ConversationSessionPaused() || ConversationSessionFailed():
        _listen(side);
    }
  }

  /// Tells a hands-free conversation that a screen reader announces
  /// [message] (a translation that is not read aloud): like after reading
  /// aloud, the microphone opens only once the announcement was probably
  /// said (the echo delay plus [announcementPerCharacter] for each
  /// character), so it does not hear it; an open microphone closes until
  /// then. Does nothing unless the conversation is listening.
  void announced(String message) {
    final text = message.trim();
    if (text.isEmpty || isClosed || _closing) return;
    final session = state.session;
    if (session is! ConversationSessionListening) return;
    final side = session.side;
    _closeMicrophone();
    _cancelSilence();
    final token = _listenToken;
    emit(state.copyWith(session: ConversationSessionListening(side: side)));
    _echo = _timer(_echoDelay + announcementPerCharacter * text.length, () {
      if (token == _listenToken) _openMicrophone(side, token);
    });
  }

  /// Listens for [side]: at once, or [_echoDelay] after reading aloud or
  /// showing a translation ([afterSpeech]); while something is read aloud
  /// only once it ended (unless [ignoreSpeech]: it was stopped). [fresh]
  /// starts a new turn (the silence timeout starts over).
  void _listen(
    ConversationSide side, {
    bool fresh = true,
    bool afterSpeech = false,
    bool ignoreSpeech = false,
  }) {
    final recognizer = _recognizer;
    if (recognizer == null || isClosed || _closing) return;
    _cancelSpeakingWatchdog();
    if (fresh) {
      _cancelSilence();
      _emptyUtterances = 0;
    }
    final current = ignoreSpeech ? null : _speech.current;
    if (current != null) {
      // Never while something is read aloud (_onSpeaking continues).
      _closeMicrophone();
      _enterSpeaking(
        ConversationSessionSpeaking(turnId: _turnIdOf(current), next: side),
      );
      return;
    }
    final delay = afterSpeech && _echoDelay > Duration.zero;
    if (delay) {
      _closeMicrophone();
    } else {
      // Listening again cancels the previous utterance.
      _dropHearing();
    }
    final token = _listenToken;
    emit(state.copyWith(session: ConversationSessionListening(side: side)));
    if (delay) {
      _echo = _timer(_echoDelay, () {
        if (token == _listenToken) _openMicrophone(side, token);
      });
    } else {
      _openMicrophone(side, token);
    }
  }

  void _openMicrophone(ConversationSide side, int token) {
    if (isClosed || _closing) return;
    _heardVoice = false;
    final a = _primaryLanguage(state.languageA);
    final b = _primaryLanguage(state.languageB);
    _hearing = _recognizer!
        .listen(
          state.languageOf(side),
          detectLanguage: state.detectSpeaker && a != b,
          pause: state.turnPause,
        )
        .listen((event) => _onHearing(token, side, event));
  }

  void _onHearing(int token, ConversationSide side, ConversationHearing event) {
    if (token != _listenToken || isClosed) return;
    final session = state.session;
    if (session is! ConversationSessionListening) return;
    switch (event) {
      case ConversationHeardStart(:final detectsLanguage):
        emit(
          state.copyWith(
            session: session.copyWith(
              stage: ConversationListenStage.listening,
              detectsLanguage: detectsLanguage,
            ),
          ),
        );
        if (!_heardVoice) _silence ??= _timer(_silenceTimeout, _onSilence);
      case ConversationHeardLevel():
        // Loudness alone is not speech: the level is relative to the
        // quietest moment, so background noise is loud too.
        break;
      case ConversationHeardSpeech():
        _onVoice();
      case ConversationHeardPartial(:final text):
        if (text.trim().isNotEmpty) _onVoice();
        emit(state.copyWith(session: session.copyWith(heard: text)));
      case ConversationHeardTranscribing():
        _onVoice();
        emit(
          state.copyWith(
            session: session.copyWith(
              stage: ConversationListenStage.transcribing,
            ),
          ),
        );
      case ConversationHeardFinal(:final text, :final language):
        _hearing = null;
        if (text.trim().isEmpty) {
          _onNothingHeard(side);
        } else {
          _cancelSilence();
          _emptyUtterances = 0;
          final speaker = state.detectSpeaker
              ? _speakerOf(language, side)
              : side;
          unawaited(_sessionTurn(speaker, text));
        }
      case ConversationHeardFailure(failure: SpeechInputFailure.noMatch):
        _hearing = null;
        _onNothingHeard(side);
      case ConversationHeardFailure(
        :final failure,
        :final onDevice,
        :final offlineSupported,
      ):
        _hearing = null;
        _cancelSilence();
        emit(
          state.copyWith(
            session: ConversationSessionFailed(
              next: side,
              failure: failure,
              onDevice: onDevice,
              offlineSupported: offlineSupported,
            ),
          ),
        );
      case ConversationHeardEnd(interrupted: true):
        _hearing = null;
        _pause(side, ConversationPauseReason.interrupted);
      case ConversationHeardEnd():
        _hearing = null;
        _onNothingHeard(side);
    }
  }

  /// Someone is speaking (words, or the recogniser's voice activity
  /// detection; not just a loud room): the silence timeout stops counting.
  void _onVoice() {
    _heardVoice = true;
    _cancelSilence();
  }

  /// Nobody spoke for the silence timeout.
  void _onSilence() {
    _silence = null;
    if (isClosed || _heardVoice) return;
    if (state.session case ConversationSessionListening(:final side)) {
      _closeMicrophone();
      _pause(side, ConversationPauseReason.silence);
    }
  }

  /// An utterance ended without words: listen again while the silence
  /// timeout runs (or after unintelligible speech), else pause.
  void _onNothingHeard(ConversationSide side) {
    _emptyUtterances++;
    final waiting = _silence != null;
    if (_emptyUtterances < maxEmptyUtterances && (waiting || _heardVoice)) {
      _listen(side, fresh: false);
    } else {
      _pause(side, ConversationPauseReason.silence);
    }
  }

  void _pause(
    ConversationSide next,
    ConversationPauseReason reason, {
    int? turnId,
  }) {
    _cancelSilence();
    _cancelSpeakingWatchdog();
    emit(
      state.copyWith(
        session: ConversationSessionPaused(
          next: next,
          reason: reason,
          turnId: turnId,
        ),
      ),
    );
  }

  /// The side whose language [language] (a detected app code) is, or
  /// [expected] when it is unknown, another language, or both sides speak
  /// variants of the same language.
  ConversationSide _speakerOf(String? language, ConversationSide expected) {
    if (language == null || language.trim().isEmpty) return expected;
    final heard = _primaryCode(language);
    final a = _primaryLanguage(state.languageA);
    final b = _primaryLanguage(state.languageB);
    if (a == b) return expected;
    if (heard == a) return ConversationSide.a;
    if (heard == b) return ConversationSide.b;
    return expected;
  }

  static String _primaryLanguage(Language language) =>
      _primaryCode(language.code);

  static String _primaryCode(String code) =>
      LanguageMatcher.normalize(code.trim()).toLowerCase().split('-').first;

  /// Adds [text] as [speaker]'s turn of the hands-free conversation and
  /// translates it; then the other side is listened for.
  Future<void> _sessionTurn(ConversationSide speaker, String text) {
    final (turn, engine) = _newTurn(speaker, text);
    final next = speaker.other;
    emit(
      state.copyWith(
        turns: [...state.turns, turn],
        session: engine == null
            ? ConversationSessionPaused(
                next: next,
                reason: ConversationPauseReason.translationFailed,
                turnId: turn.id,
              )
            : ConversationSessionTranslating(
                turnId: turn.id,
                speaker: speaker,
                next: next,
              ),
      ),
    );
    if (engine == null) return Future.value();
    return _translate(turn, engine);
  }

  bool _isSessionTranslating(int turnId) => switch (state.session) {
    ConversationSessionTranslating(turnId: final id) => id == turnId,
    _ => false,
  };

  void _onSessionTurnTranslated(ConversationTurn turn) {
    final session = state.session;
    if (session is! ConversationSessionTranslating) return;
    if (turn.translation.trim().isEmpty) {
      _listen(session.next);
    } else if (!state.autoSpeak) {
      // Shown, not read aloud: a screen reader may announce it, so the
      // microphone waits as after reading aloud (and [announced] can keep
      // it closed for longer).
      _listen(session.next, afterSpeech: true);
    } else {
      unawaited(_speakForSession(turn, session.next));
    }
  }

  void _onSessionTurnFailed(ConversationTurn turn) {
    final session = state.session;
    if (session is! ConversationSessionTranslating ||
        session.turnId != turn.id) {
      return;
    }
    _pause(
      session.next,
      turn.error is ConsentRequiredException
          ? ConversationPauseReason.consent
          : ConversationPauseReason.translationFailed,
      turnId: turn.id,
    );
  }

  /// Reads [turn]'s translation aloud for the hands-free conversation,
  /// then listens for [next] once it ended. A translation that may only be
  /// read online pauses the conversation until the user decides; other
  /// failures go on listening (they are reported like [speak]'s).
  Future<void> _speakForSession(
    ConversationTurn turn,
    ConversationSide next, {
    bool slow = false,
    ConsentRequiredException? allowOnline,
  }) async {
    if (isClosed || _closing) return;
    final token = ++_speakToken;
    _closeMicrophone();
    _enterSpeaking(
      ConversationSessionSpeaking(turnId: turn.id, next: next),
      text: turn.translation,
      slow: slow,
    );
    _speakPending = true;
    Object? failure;
    try {
      await _speech.speak(
        id: speechIdOf(turn.id),
        text: turn.translation,
        languageCode: turn.target.code,
        slow: slow,
        allowOnline: allowOnline,
      );
    } on Object catch (error) {
      failure = error;
    }
    if (token != _speakToken || isClosed) return;
    _speakPending = false;
    if (failure != null) {
      final asked = allowOnline != null;
      _speechFailed(turn.id, failure, slow: slow, asked: asked);
      if (!asked &&
          failure is SpeechUnavailableException &&
          failure.onlineConsent != null) {
        _pause(next, ConversationPauseReason.speechConsent, turnId: turn.id);
        return;
      }
    }
    // Still reading aloud: _onSpeaking listens once it ended.
    if (state.session is ConversationSessionSpeaking &&
        _speech.current == null) {
      _listen(next, afterSpeech: failure == null);
    }
  }

  /// Moves the session to [session] (reading [text] aloud; null when it is
  /// unknown, e.g. something else is read aloud) and starts the watchdog
  /// that gives the reading up should its end never be reported.
  void _enterSpeaking(
    ConversationSessionSpeaking session, {
    String? text,
    bool slow = false,
  }) {
    final turnId = session.turnId;
    final read =
        text ?? (turnId == null ? null : state.turnById(turnId)?.translation);
    final characters = read?.length ?? 0;
    emit(state.copyWith(session: session));
    _cancelSpeakingWatchdog();
    _speakingWatchdog = _timer(
      speakingTimeout +
          speakingTimeoutPerCharacter * (characters * (slow ? 2 : 1)),
      _onSpeakingTimeout,
    );
  }

  /// Reading aloud took too long: its end was never reported (or the
  /// read-aloud call never returned). It is stopped, then the next side is
  /// listened for.
  void _onSpeakingTimeout() {
    _speakingWatchdog = null;
    if (isClosed || _closing) return;
    if (state.session is! ConversationSessionSpeaking) return;
    // A read-aloud call that returns after all changes nothing any more.
    _speakToken++;
    _speakPending = false;
    unawaited(_giveUpSpeaking());
  }

  Future<void> _giveUpSpeaking() async {
    await _stopSpeech();
    // Stopping usually reports the end (_onSpeaking listened already); a
    // player that still says it is speaking is not believed any more.
    if (state.session case ConversationSessionSpeaking(:final next)) {
      _listen(next, afterSpeech: true, ignoreSpeech: true);
    }
  }

  void _cancelSpeakingWatchdog() {
    _speakingWatchdog?.cancel();
    _speakingWatchdog = null;
  }

  /// Stops listening to the current utterance (its events are ignored)
  /// without closing the microphone, e.g. because it is opened again.
  void _dropHearing() {
    _listenToken++;
    _echo?.cancel();
    _echo = null;
    final hearing = _hearing;
    _hearing = null;
    if (hearing != null) unawaited(hearing.cancel());
  }

  /// Stops listening and closes the microphone.
  void _closeMicrophone() {
    final listening = _hearing != null;
    _dropHearing();
    if (listening) unawaited(_recognizer?.cancel());
  }

  void _cancelSilence() {
    _silence?.cancel();
    _silence = null;
  }

  @override
  Future<void> close() async {
    // Nothing may read aloud or open the microphone from now on, though
    // the cubit is only closed at the end.
    _closing = true;
    _speakToken++;
    _cancelSilence();
    _cancelSpeakingWatchdog();
    _dropHearing();
    // Cancelled before the first await, so a translation cannot finish
    // (and be read aloud) while closing.
    final cancelled = [for (final job in _jobs.values) job.cancel()];
    _jobs.clear();
    _onceConsents.clear();
    _withdrawRetryGrant();
    final speaking =
        state.speakingTurnId != null ||
        _speakPending ||
        _turnIdOf(_speech.current) != null;
    _speakPending = false;
    await _speaking.cancel();
    await Future.wait([...cancelled, ?_recognizer?.dispose()]);
    if (speaking) await _stopSpeech();
    await super.close();
  }
}

/// A one-time approval the user gave for [text] going to the engine
/// [engineId] (see [ConversationCubit.retry]).
class _OnceConsent {
  const new({
    required this.consent,
    required this.engineId,
    required this.text,
    required this.givenAt,
  });

  final ConsentRequiredException consent;
  final String engineId;
  final String text;

  /// When the user gave it (the retry it was given for started).
  final DateTime givenAt;
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
