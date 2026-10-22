import 'dart:async';

import 'package:bloc/bloc.dart';
// Only kIsWeb; no widgets.
// ignore: avoid_flutter_imports
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/transcribe/cubit/transcribe_state.dart';
import 'package:mozhi/transcribe/data/screen_awake.dart';
import 'package:mozhi/transcribe/data/transcriber.dart';
import 'package:mozhi/transcribe/data/transcript_export.dart';
import 'package:mozhi/transcribe/models/transcript_entry.dart';
import 'package:mozhi/usage/data/usage_tracker.dart';
import 'package:mozhi/voice/cubit/voice_settings_state.dart'
    show VoiceModelError, VoiceModelErrorKind;
import 'package:mozhi/voice/offline/offline_speech.dart';
import 'package:mozhi/voice/offline/phrase_transcriber.dart';
import 'package:mozhi/voice/speech_input_service.dart';
import 'package:translation_repository/translation_repository.dart';

export 'transcribe_state.dart';

/// Put into an entry whose translation found no engine to use.
class TranscribeNoEngineException implements Exception {
  const new();

  @override
  String toString() => 'TranscribeNoEngineException';
}

/// Drives Transcribe: listens for a long time ([start], [pause], [stop])
/// and keeps a rolling transcript, one [TranscriptEntry] per phrase with
/// its time, and, once the user turns it on ([setTranslate]), a
/// translation of each phrase into [TranscribeState.target].
///
/// * What listens ([TranscribeMode], [load]): on-device Whisper where a
///   speech model is installed ([WhisperTranscriber]; also when voice
///   input is set to the system recogniser, which stops after every
///   pause), else the browser's continuous recognition in the web app
///   ([SystemTranscriber]; never in Offline only). Without either, the
///   mode says why ([TranscribeMode.needsModel], ...).
/// * Translations follow the user's engine (`engine`, the translate
///   screen's) and the consent rules of [TranslationRepository.translate]
///   exactly: an entry that needs consent waits for it
///   ([TranscribeState.awaitingConsent], [retryTranslations]). In Offline
///   only the on-device engine translates (from `engines`). Nothing is
///   translated until the user turns translation on, one phrase at a
///   time, in order.
/// * The screen stays on while listening ([ScreenAwake]); a voice input
///   session elsewhere is cancelled first, so the microphone is free.
/// * [saveToHistory] saves the transcript as one history entry, only when
///   asked (as a favourite while history is paused).
class TranscribeCubit extends Cubit<TranscribeState> {
  new({
    required this._repository,
    required this._engine,
    required Language source,
    required Language target,
    this._engines,
    this._options,
    this._offline,
    this._speechInput,
    this._history,
    this._usageTracker,
    ScreenAwake? screenAwake,
    bool? isWeb,
    Transcriber Function(TranscribeMode mode)? transcriber,
    DateTime Function()? clock,
  }) : _screenAwake = screenAwake ?? ScreenAwake(),
       _isWeb = isWeb ?? kIsWeb,
       _createTranscriber = transcriber,
       _clock = clock ?? DateTime.now,
       super(TranscribeState(source: source, target: target));

  final TranslationRepository _repository;
  final TranslationEngine? Function() _engine;
  final List<TranslationEngine> Function()? _engines;
  final TranslationOptions Function()? _options;
  final OfflineSpeech? _offline;
  final SpeechInputService? _speechInput;
  final HistoryCubit? _history;
  final UsageTracker? _usageTracker;
  final ScreenAwake _screenAwake;
  final bool _isWeb;
  final Transcriber Function(TranscribeMode mode)? _createTranscriber;
  final DateTime Function() _clock;

  Transcriber? _transcriber;
  StreamSubscription<TranscriberEvent>? _events;

  /// Completes when the last recording delivered its phrases.
  Future<void> _recordingDone = Future.value();
  Completer<void>? _recording;
  DateTime? _recordingStart;

  /// The transcript's time line: the length of the recordings so far.
  Duration _offset = Duration.zero;
  TranscribePauseReason? _pausing;
  int _nextId = 0;
  bool _awake = false;

  /// Translations run one at a time, in order.
  Future<void> _translations = Future.value();
  final Set<int> _queued = {};
  StreamSubscription<TranslationResult>? _translation;

  /// The history entry this transcript is saved as (saving again updates
  /// it).
  String? _historyId;

  /// Finds out what can transcribe here.
  Future<void> load() async {
    final mode = await _resolveMode();
    final vadMissing =
        mode == TranscribeMode.whisper &&
        _offline?.vadModel != null &&
        !await _offline!.isVadReady();
    if (isClosed) return;
    emit(
      state.copyWith(
        mode: mode,
        status: state.status == TranscribeStatus.loading
            ? TranscribeStatus.idle
            : null,
        voiceDetectionMissing: vadMissing,
      ),
    );
  }

  Future<TranscribeMode> _resolveMode() async {
    final offline = _offline;
    if (offline != null && offline.isAvailable) {
      try {
        return await offline.isReady()
            ? TranscribeMode.whisper
            : TranscribeMode.needsModel;
      } on Object {
        return TranscribeMode.needsModel;
      }
    }
    final speech = _speechInput;
    if (_isWeb && speech != null && speech.isPlatformSupported) {
      return _repository.privacyMode == PrivacyMode.offlineOnly
          ? TranscribeMode.offlineOnly
          : TranscribeMode.system;
    }
    return TranscribeMode.unavailable;
  }

  Transcriber _transcriberFor(TranscribeMode mode) =>
      _createTranscriber?.call(mode) ??
      (mode == TranscribeMode.whisper
          ? WhisperTranscriber(speech: _offline!)
          : SystemTranscriber(_speechInput!));

  /// Starts (or resumes) listening; phrases are added to the transcript.
  Future<void> start() async {
    if (!state.mode.canListen || state.isRecording || isClosed) return;
    emit(
      state.copyWith(
        status: TranscribeStatus.starting,
        pauseReason: () => null,
        failure: () => null,
        partial: '',
        level: 0,
        heardSpeech: false,
      ),
    );
    // The last recording's phrases first.
    await _recordingDone;
    try {
      await _speechInput?.cancel();
    } on Object {
      // Nothing else was listening.
    }
    if (isClosed || state.status != TranscribeStatus.starting) return;
    final transcriber = _transcriber ??= _transcriberFor(state.mode);
    await _keepAwake(enabled: true);
    final recording = _recording = Completer<void>();
    _recordingDone = recording.future;
    _recordingStart = _clock();
    _pausing = null;
    final offset = _offset;
    final language = state.source.isAuto ? null : state.source.code;
    _events = transcriber
        .listen(language: language)
        .listen(
          (event) => _onEvent(event, offset),
          onDone: () => _onRecordingEnded(recording),
        );
  }

  /// Stops listening for now; [start] resumes. The phrases already heard
  /// are still transcribed.
  Future<void> pause({
    TranscribePauseReason reason = TranscribePauseReason.user,
  }) async {
    if (!state.isRecording) return;
    _pausing = reason;
    emit(
      state.copyWith(
        status: TranscribeStatus.paused,
        pauseReason: () => reason,
        level: 0,
      ),
    );
    await _keepAwake(enabled: false);
    await _transcriber?.stop();
  }

  /// Stops listening; the transcript stays ([start] adds to it).
  Future<void> stop() async {
    if (!state.isRecording && state.status != TranscribeStatus.paused) {
      return;
    }
    _pausing = null;
    emit(
      state.copyWith(
        status: TranscribeStatus.idle,
        pauseReason: () => null,
        level: 0,
      ),
    );
    await _keepAwake(enabled: false);
    await _transcriber?.stop();
  }

  void _onEvent(TranscriberEvent event, Duration offset) {
    if (isClosed) return;
    switch (event) {
      case TranscriberListening():
        if (state.status == TranscribeStatus.starting) {
          emit(state.copyWith(status: TranscribeStatus.listening));
        }
      case TranscriberLevel(:final level, :final heardSpeech):
        if (state.isListening) {
          emit(state.copyWith(level: level, heardSpeech: heardSpeech));
        }
      case TranscriberPending(:final pending):
        emit(state.copyWith(pending: pending));
      case TranscriberPartial(:final text):
        emit(state.copyWith(partial: text));
      case TranscriberHeard(:final phrase, :final pending):
        _onPhrase(phrase, offset, pending);
      case TranscriberFailed(:final failure):
        _pausing = null;
        emit(
          state.copyWith(
            status: TranscribeStatus.idle,
            failure: () => failure,
            failures: state.failures + 1,
            level: 0,
          ),
        );
        unawaited(_keepAwake(enabled: false));
    }
  }

  void _onPhrase(TranscribedPhrase phrase, Duration offset, int pending) {
    // A phrase without words (noise Whisper heard nothing in) is left out.
    if (phrase.status == PhraseStatus.transcribed && phrase.text.isEmpty) {
      emit(state.copyWith(pending: pending));
      return;
    }
    final entry = TranscriptEntry(
      id: _nextId++,
      start: offset + phrase.start,
      end: offset + phrase.end,
      text: phrase.text,
      language: phrase.language,
      status: phrase.status,
      translationStatus: state.translate && phrase.hasText
          ? TranscriptTranslationStatus.translating
          : null,
    );
    emit(
      state.copyWith(
        entries: [...state.entries, entry],
        partial: '',
        pending: pending,
      ),
    );
    if (entry.translationStatus != null) _enqueue(entry.id);
  }

  void _onRecordingEnded(Completer<void> recording) {
    _events = null;
    final started = _recordingStart;
    if (started != null) {
      final length = _clock().difference(started);
      final lastEnd = state.entries.lastOrNull?.end ?? Duration.zero;
      final end = _offset + length;
      _offset = end > lastEnd ? end : lastEnd;
    }
    _recordingStart = null;
    if (!recording.isCompleted) recording.complete();
    if (isClosed) return;
    final pausing = _pausing;
    _pausing = null;
    unawaited(_keepAwake(enabled: false));
    // A start that waited for this recording goes on.
    final TranscribeStatus? status;
    if (state.status == TranscribeStatus.starting) {
      status = null;
    } else if (pausing != null || state.status == TranscribeStatus.paused) {
      status = TranscribeStatus.paused;
    } else {
      status = TranscribeStatus.idle;
    }
    emit(state.copyWith(status: status, pending: 0, partial: '', level: 0));
  }

  /// The app went to the background: it can only listen on screen.
  Future<void> onHidden() => pause(reason: TranscribePauseReason.background);

  /// Sets the spoken language (not while listening).
  void setSource(Language language) {
    if (state.isRecording || language.isCustom) return;
    emit(state.copyWith(source: language));
  }

  /// Sets the language of the translations; with translation on, the
  /// transcript is translated again into it.
  void setTarget(Language language) {
    if (language.isAuto || language == state.target) return;
    emit(state.copyWith(target: language));
    if (state.translate) _translateAll(force: true);
  }

  /// Turns translation on (the transcript so far is translated too, and
  /// every new phrase) or off (nothing more is translated).
  void setTranslate({required bool enabled}) {
    if (enabled == state.translate) return;
    emit(state.copyWith(translate: enabled));
    if (enabled) {
      _translateAll(force: false);
    } else {
      _cancelTranslations();
    }
  }

  /// Translates again the entries whose translation failed or waits for
  /// consent (after the user gave it).
  void retryTranslations() {
    if (!state.translate) return;
    final failed = [
      for (final entry in state.entries)
        if (entry.translationStatus == TranscriptTranslationStatus.failed)
          entry.id,
    ];
    _markTranslating(failed);
    failed.forEach(_enqueue);
  }

  void _translateAll({required bool force}) {
    final ids = [
      for (final entry in state.entries)
        if (entry.hasText &&
            (force ||
                entry.translationStatus == null ||
                entry.translationStatus == TranscriptTranslationStatus.failed))
          entry.id,
    ];
    if (force) _cancelTranslations();
    _markTranslating(ids, clear: force);
    ids.forEach(_enqueue);
  }

  void _markTranslating(List<int> ids, {bool clear = false}) {
    if (ids.isEmpty) return;
    final set = ids.toSet();
    emit(
      state.copyWith(
        entries: [
          for (final entry in state.entries)
            if (set.contains(entry.id))
              entry.copyWith(
                translation: clear ? '' : null,
                translationStatus: () =>
                    TranscriptTranslationStatus.translating,
                translationError: () => null,
              )
            else
              entry,
        ],
      ),
    );
  }

  void _cancelTranslations() {
    _queued.clear();
    unawaited(_translation?.cancel());
    _translation = null;
    _translations = Future.value();
    // What was waiting is not translated now.
    TranscriptEntry untranslated(TranscriptEntry entry) =>
        entry.translationStatus == TranscriptTranslationStatus.translating
        ? entry.copyWith(translation: '', translationStatus: () => null)
        : entry;
    emit(state.copyWith(entries: state.entries.map(untranslated).toList()));
  }

  void _enqueue(int id) {
    if (!_queued.add(id)) return;
    final generation = _translations;
    _translations = generation.then((_) => _translateEntry(id));
  }

  /// The engine translations use: the user's, or the on-device one in
  /// Offline only.
  TranslationEngine? _translationEngine() {
    final engine = _engine();
    if (_repository.privacyMode != PrivacyMode.offlineOnly ||
        (engine?.isOffline ?? false)) {
      return engine;
    }
    return _engines?.call().where((e) => e.isOffline).firstOrNull ?? engine;
  }

  Future<void> _translateEntry(int id) async {
    if (!_queued.remove(id) || isClosed || !state.translate) return;
    final entry = state.entries.where((e) => e.id == id).firstOrNull;
    if (entry == null || !entry.hasText) return;
    final engine = _translationEngine();
    if (engine == null) {
      _update(
        id,
        (current) => current.copyWith(
          translationStatus: () => TranscriptTranslationStatus.failed,
          translationError: () => const TranscribeNoEngineException(),
        ),
      );
      return;
    }
    final code = entry.language;
    final source = state.source.isAuto && code != null
        ? LanguageCatalog.byCode(code) ??
              Language(code: code, name: LanguageCatalog.nameOf(code))
        : state.source;
    final request = TranslationRequest(
      text: entry.text,
      source: source,
      target: state.target,
      options: engine.supportsOptions
          ? (_options?.call() ?? const TranslationOptions())
          : const TranslationOptions(),
    );
    final done = Completer<void>();
    TranslationResult? last;
    _translation = _repository
        .translate(engine, request)
        .listen(
          (result) {
            last = result;
            _update(
              id,
              (current) => current.copyWith(
                translation: result.text,
                engineId: () => engine.id,
                engineName: () => result.engineName,
              ),
            );
          },
          onError: (Object error) {
            _update(
              id,
              (current) => current.copyWith(
                translationStatus: () => TranscriptTranslationStatus.failed,
                translationError: () => error,
              ),
            );
            if (!done.isCompleted) done.complete();
          },
          onDone: () {
            if (last case final answer?) _recordUsage(engine, request, answer);
            _update(
              id,
              (current) => current.copyWith(
                translationStatus: () => TranscriptTranslationStatus.done,
              ),
            );
            if (!done.isCompleted) done.complete();
          },
          cancelOnError: true,
        );
    await done.future;
    _translation = null;
  }

  /// Counts an answered request to a bring-your-own-key provider, like the
  /// translate screen does. Never throws.
  void _recordUsage(
    TranslationEngine engine,
    TranslationRequest request,
    TranslationResult result,
  ) {
    final tracker = _usageTracker;
    final providerId = engine.providerId;
    if (tracker == null || providerId == null || providerId.isEmpty) return;
    if (!result.isComplete || result.fromCache) return;
    try {
      unawaited(
        tracker
            .recordText(providerId, input: request.text, output: result.text)
            .then((_) {}, onError: (Object _) {}),
      );
    } on Object {
      // Usage counting must never break the transcript.
    }
  }

  void _update(int id, TranscriptEntry Function(TranscriptEntry) change) {
    if (isClosed) return;
    emit(
      state.copyWith(
        entries: state.entries
            .map((entry) => entry.id == id ? change(entry) : entry)
            .toList(),
      ),
    );
  }

  /// Saves the transcript (and its translations) as one history entry;
  /// saving again updates that entry. While history is paused it is saved
  /// as a favourite (this is an explicit save).
  Future<void> saveToHistory() async {
    final history = _history;
    if (history == null || !state.hasTranscript) return;
    final paused = history.state.paused;
    final translated = state.entries
        .where((entry) => entry.isTranslated && entry.engineId != null)
        .lastOrNull;
    final now = _clock();
    final detected = _dominantLanguage();
    final entry = HistoryEntry(
      id: _historyId ??= now.microsecondsSinceEpoch.toString(),
      text: TranscriptExport.plain(state.entries),
      translation: TranscriptExport.plainTranslation(state.entries),
      source: state.source,
      target: state.target,
      engineId: translated?.engineId ?? TranslationEngine.offlineId,
      engineName: translated?.engineName ?? 'Whisper',
      createdAt: now,
      detectedSource: state.source.isAuto ? detected : null,
      isFavorite: paused,
    );
    final outcome = await _addToHistory(history, entry);
    if (isClosed) return;
    emit(
      state.copyWith(
        historyOutcome: () => outcome,
        historySaves: state.historySaves + 1,
      ),
    );
  }

  Future<TranscribeHistoryOutcome> _addToHistory(
    HistoryCubit history,
    HistoryEntry entry,
  ) async {
    try {
      await history.add(entry);
      return entry.isFavorite
          ? TranscribeHistoryOutcome.savedAsFavorite
          : TranscribeHistoryOutcome.saved;
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
      return TranscribeHistoryOutcome.failed;
    }
  }

  String? _dominantLanguage() {
    final durations = <String, Duration>{};
    for (final entry in state.entries) {
      final code = entry.language;
      if (code == null || !entry.hasText) continue;
      durations[code] =
          (durations[code] ?? Duration.zero) + (entry.end - entry.start);
    }
    String? best;
    for (final MapEntry(key: code, value: length) in durations.entries) {
      if (best == null || length > durations[best]!) best = code;
    }
    return best;
  }

  /// Deletes the transcript (not while listening); a later save is a new
  /// history entry.
  void clear() {
    if (state.isRecording) return;
    _cancelTranslations();
    _offset = Duration.zero;
    _historyId = null;
    emit(
      state.copyWith(
        entries: const [],
        partial: '',
        pending: 0,
        status: TranscribeStatus.idle,
        pauseReason: () => null,
      ),
    );
  }

  /// Downloads the voice activity model (0.9 MB; the voice input settings'
  /// rules: Wi-Fi only unless [overMeteredNetwork]); the next recording
  /// cuts phrases with it.
  Future<void> downloadVoiceDetection({bool overMeteredNetwork = false}) async {
    final offline = _offline;
    if (offline == null || state.voiceDetectionProgress != null) return;
    emit(
      state.copyWith(
        voiceDetectionProgress: () => 0,
        voiceDetectionError: () => null,
      ),
    );
    final failure = await _attempt(
      () => offline.downloadVoiceDetection(
        overMeteredNetwork: overMeteredNetwork,
        onProgress: (fraction) {
          if (!isClosed) {
            emit(state.copyWith(voiceDetectionProgress: () => fraction));
          }
        },
      ),
    );
    if (isClosed) return;
    emit(
      state.copyWith(
        voiceDetectionProgress: () => null,
        voiceDetectionError: () => failure,
        voiceDetectionMissing: failure != null,
      ),
    );
  }

  /// Runs [action]; why it failed, or null. Errors other than a metered
  /// network go to `addError`. (A helper, not a local assigned in a
  /// `catch` and read by a closure: dart2js gets that wrong.)
  Future<VoiceModelError?> _attempt(Future<void> Function() action) async {
    try {
      await action();
      return null;
    } on Object catch (error, stackTrace) {
      final failure = VoiceModelError.of(error);
      if (failure.kind != VoiceModelErrorKind.metered) {
        addError(error, stackTrace);
      }
      return failure;
    }
  }

  Future<void> _keepAwake({required bool enabled}) async {
    if (_awake == enabled) return;
    _awake = enabled;
    await _screenAwake.setEnabled(enabled: enabled);
  }

  @override
  Future<void> close() async {
    // The microphone and the screen first: nothing may stay on.
    final keepAwake = _keepAwake(enabled: false);
    final transcriber = _transcriber;
    final cancelled = transcriber?.cancel();
    final events = _events?.cancel();
    _events = null;
    final recording = _recording;
    if (recording != null && !recording.isCompleted) recording.complete();
    final translation = _translation;
    _translation = null;
    await Future.wait<void>([
      keepAwake,
      ?cancelled,
      ?events,
      ?translation?.cancel(),
    ]);
    if (transcriber case final WhisperTranscriber whisper) {
      await whisper.dispose();
    }
    await super.close();
  }
}
