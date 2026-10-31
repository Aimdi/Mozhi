import 'dart:async';
import 'dart:typed_data';

import 'package:bloc/bloc.dart';
import 'package:mozhi/app_lock/data/app_lock.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/live_captions/cubit/live_captions_state.dart';
import 'package:mozhi/live_captions/data/caption_recognizer.dart';
import 'package:mozhi/live_captions/data/captions_host.dart';
import 'package:mozhi/platform/device_conditions.dart';
import 'package:mozhi/screen_translate/data/screen_translate_controls.dart';
import 'package:mozhi/transcribe/data/transcript_export.dart';
import 'package:mozhi/transcribe/data/transcript_history.dart';
import 'package:mozhi/transcribe/models/transcript_entry.dart';
import 'package:mozhi/voice/offline/phrase_transcriber.dart';
import 'package:translation_repository/translation_repository.dart';
import 'package:whisper_speech/whisper_speech.dart' show rmsDbfs;

export 'live_captions_state.dart';

/// What the caption bar says when there is no caption to show
/// (`LiveCaptionsCubit`'s `describe` turns it into text).
enum LiveCaptionsBarText {
  /// Started, nothing heard yet.
  listening,

  /// No sound for [LiveCaptionsCubit.silenceHintAfter].
  silence,

  /// Paused: the phone is hot.
  hot,

  /// The app lock engaged: no caption shows until Mozhi is unlocked.
  appLocked,
}

/// Put into an entry that was not translated because newer phrases were
/// waiting ([LiveCaptionsCubit.maxWaitingTranslations]): captions keep up
/// rather than show old lines late.
final class LiveCaptionsBehindException implements Exception {
  const new();

  @override
  String toString() => 'LiveCaptionsBehindException';
}

/// Drives live captions: the sound other apps play ([CaptionsHost]) is cut
/// into phrases and transcribed on this device ([CaptionRecognizer],
/// Whisper), each phrase is translated with the live engine (`engine`,
/// `resolveLiveEngine`: the offline engine unless the user picked another
/// for live use) and shown in the caption bar and in a transcript on the
/// screen.
///
/// * [start] explains "Display over other apps" once when it is not
///   allowed ([LiveCaptionsState.overlayPrompt]; without it the captions
///   are only on the screen), asks for notifications once (for the Stop
///   of the notification), then the host asks for the microphone
///   permission and the capture consent.
/// * The language of the sound is [LiveCaptionsState.source], or Whisper's
///   detected one, phrase by phrase ("Detect"); a phrase already in the
///   target language is shown as it is.
/// * Translations run one at a time, in order; one that waits behind
///   [maxWaitingTranslations] newer phrases is skipped. One that needs the
///   user's consent waits for it ([LiveCaptionsState.consent],
///   [retryTranslations]).
/// * Nothing is stored: the audio only passes through, the transcript is
///   in memory ([maxEntries] phrases at most) and goes with the screen,
///   unless the user saves it ([saveToHistory]) or exports it.
/// * [silenceHintAfter] of silence (no sound at all, as from an app that
///   does not allow capturing it) shows a hint until sound comes.
/// * While the phone is locked no sound arrives (the host says so); while
///   it is hot ([DeviceConditions], severe or worse) the sound is not
///   transcribed until it cools down ([LiveCaptionsState.pause]).
/// * Captions go on while the app is in the background: that is what they
///   are for. They stop with [stop], from the caption bar or the
///   notification, when the capture ends by itself and in [close].
/// * While the app is locked (`lock`, [AppLock.isLocked]) the captions go
///   on into the transcript (hidden behind the lock), but the bar shows
///   only "Mozhi is locked" ([LiveCaptionsBarText.appLocked]): no caption
///   text goes to it. Once the phone is unlocked the app lock checks
///   again right away ([AppLockController.checkAway]: its timer may have
///   slept) before the bar shows a caption again.
class LiveCaptionsCubit extends Cubit<LiveCaptionsState> {
  new({
    required this._host,
    required this._repository,
    required this._engine,
    required Language source,
    required Language target,
    this._recognizer,
    this._overlay,
    this._conditions,
    this._history,
    this._lock,
    String Function(LiveCaptionsBarText text)? describe,
    DateTime Function()? clock,
  }) : _describe = describe ?? _english,
       _clock = clock ?? DateTime.now,
       super(LiveCaptionsState(source: source, target: target)) {
    _events = _host.events.listen(_onEvent);
    _lockChanges = _lock?.changes.listen(_onAppLock);
  }

  /// Sound below this level (dBFS) counts as silence for the hint.
  static const silentLevel = -75.0;

  /// How long silence lasts before the hint.
  static const silenceHintAfter = Duration(seconds: 20);

  /// The most phrases kept in the transcript (the oldest go first).
  static const maxEntries = 2000;

  /// A translation that waits behind this many newer phrases is skipped.
  static const maxWaitingTranslations = 3;

  static const _sampleRate = 16000;

  final CaptionsHost _host;
  final TranslationRepository _repository;
  final TranslationEngine Function() _engine;
  final CaptionRecognizer? _recognizer;
  final ScreenTranslateControls? _overlay;
  final DeviceConditions? _conditions;
  final HistoryCubit? _history;
  final AppLock? _lock;
  final String Function(LiveCaptionsBarText text) _describe;
  final DateTime Function() _clock;

  late final StreamSubscription<CaptionBarEvent> _events;
  StreamSubscription<bool>? _lockChanges;

  /// The bar shows "Mozhi is locked" since the app locked.
  bool _lockedLineShown = false;

  /// [requestStart] came while [load] was still finding out.
  bool _startWhenLoaded = false;
  StreamSubscription<Float32List>? _audio;
  StreamSubscription<DeviceConditionsSnapshot>? _heat;
  CaptionRecording? _recording;

  /// The bar's text was explained once ("Display over other apps") and
  /// notifications asked for once.
  bool _overlayHandled = false;
  bool _notificationsAsked = false;

  /// Samples of the current recording, and the time line of the
  /// transcript (earlier recordings).
  int _samples = 0;
  Duration _offset = Duration.zero;
  int _silentSamples = 0;
  int _nextId = 0;

  /// Translations run one at a time, in order.
  Future<void> _translations = Future.value();

  /// The consents the user gave for the phrases that waited for one (see
  /// [retryTranslations]): what such a one-time approval did not use is
  /// withdrawn once those phrases were sent, and when the captions stop
  /// or the screen closes.
  final _grants = <ConsentRequiredException>[];
  final List<int> _waiting = [];
  StreamSubscription<TranslationResult>? _translation;

  /// The history entry this transcript is saved as (saving again updates
  /// it).
  String? _historyId;

  /// How many parts the last save had ([TranscriptHistory.save]).
  int _historyParts = 0;

  static String _english(LiveCaptionsBarText text) => switch (text) {
    LiveCaptionsBarText.listening => 'Listening…',
    LiveCaptionsBarText.silence =>
      'No sound: this app may not allow '
          'capturing its sound',
    LiveCaptionsBarText.hot => 'Paused: the phone is hot',
    LiveCaptionsBarText.appLocked => 'Mozhi is locked',
  };

  /// Finds out whether captions can run here.
  Future<void> load() async {
    final LiveCaptionsStatus status;
    final recognizer = _recognizer;
    if (!_host.isSupported) {
      status = LiveCaptionsStatus.unsupported;
    } else if (recognizer == null || !await recognizer.isReady()) {
      status = LiveCaptionsStatus.needsModel;
    } else {
      status = LiveCaptionsStatus.idle;
    }
    if (isClosed || state.isActive) return;
    emit(state.copyWith(status: status));
    if (_startWhenLoaded) {
      _startWhenLoaded = false;
      await start();
    }
  }

  /// Starts the captions as [start] does, once [load] found out that they
  /// can run (the Quick Settings tile opens the screen with this): the
  /// microphone permission and the capture consent are asked as always.
  Future<void> requestStart() async {
    if (isClosed) return;
    if (state.status == LiveCaptionsStatus.loading) {
      _startWhenLoaded = true;
      return;
    }
    await start();
  }

  /// Starts the captions (see the class): asks what needs asking, then
  /// captures. Does nothing unless [LiveCaptionsState.canStart].
  Future<void> start() async {
    if (!state.canStart || isClosed) return;
    final overlay = _overlay;
    if (overlay != null && overlay.isSupported && !_overlayHandled) {
      final support = await overlay.status();
      if (isClosed) return;
      if (!support.canDrawOverlays) {
        emit(state.copyWith(overlayPrompt: true));
        return;
      }
      _overlayHandled = true;
    }
    await _capture();
  }

  /// The user wants the caption bar: Android's "Display over other apps"
  /// page opens, then the captions start (with or without it).
  Future<void> allowCaptionBar() async {
    if (!state.overlayPrompt) return;
    _overlayHandled = true;
    emit(state.copyWith(overlayPrompt: false));
    await _overlay?.requestOverlayPermission();
    if (isClosed) return;
    await _capture();
  }

  /// The user wants the captions on this screen only (not asked again).
  Future<void> skipCaptionBar() async {
    if (!state.overlayPrompt) return;
    _overlayHandled = true;
    emit(state.copyWith(overlayPrompt: false));
    await _capture();
  }

  /// The prompt was dismissed: nothing starts.
  void dismissCaptionBarPrompt() {
    if (state.overlayPrompt) emit(state.copyWith(overlayPrompt: false));
  }

  Future<void> _capture() async {
    if (!state.canStart || isClosed) return;
    final recognizer = _recognizer;
    if (recognizer == null) return;
    emit(state.copyWith(status: LiveCaptionsStatus.starting));
    await _askNotifications();
    if (isClosed || state.status != LiveCaptionsStatus.starting) return;
    // Listening first, so no block is lost.
    _audio ??= _host.audio.listen(_onAudio);
    final started = await _host.start();
    if (isClosed) return;
    if (state.status != LiveCaptionsStatus.starting) {
      // Stopped meanwhile.
      if (started is CaptureStarted) await _host.stop();
      return;
    }
    switch (started) {
      case CaptureStarted(:final captionBar):
        await _begin(recognizer, captionBar: captionBar);
      case CaptureDeclined():
        _idle(LiveCaptionsNotice.declined);
      case CaptureFailed(reason: CaptureFailure.permission):
        _idle(LiveCaptionsNotice.permissionDenied);
      case CaptureFailed():
        _idle(LiveCaptionsNotice.startFailed);
    }
  }

  Future<void> _askNotifications() async {
    final overlay = _overlay;
    if (overlay == null || !overlay.isSupported || _notificationsAsked) return;
    _notificationsAsked = true;
    try {
      if (!(await overlay.status()).notificationsAllowed) {
        await overlay.requestNotificationPermission();
      }
    } on Object {
      // The notification is a convenience: the bar and the screen stop too.
    }
  }

  Future<void> _begin(
    CaptionRecognizer recognizer, {
    required bool captionBar,
  }) async {
    final language = state.source.isAuto ? null : state.source.code;
    final CaptionRecording recording;
    try {
      recording = await recognizer.start(
        language: language,
        onPhrase: _onPhrase,
      );
    } on Object {
      await _host.stop();
      _idle(LiveCaptionsNotice.startFailed);
      return;
    }
    if (isClosed || state.status != LiveCaptionsStatus.starting) {
      await recording.cancel();
      return;
    }
    _recording = recording;
    _samples = 0;
    _silentSamples = 0;
    final hot = _conditions?.latest.thermal.isHot ?? false;
    emit(
      state.copyWith(
        status: LiveCaptionsStatus.running,
        captionBar: captionBar,
        silenceHint: false,
        pause: () => hot ? LiveCaptionsPause.hot : null,
      ),
    );
    _heat ??= _conditions?.changes.listen(_onConditions);
    _showNotice(hot ? LiveCaptionsBarText.hot : LiveCaptionsBarText.listening);
  }

  void _idle([LiveCaptionsNotice? notice]) {
    _revokeGrants();
    emit(
      state.copyWith(
        status: LiveCaptionsStatus.idle,
        pause: () => null,
        silenceHint: false,
        notice: notice,
        notices: notice == null ? null : state.notices + 1,
      ),
    );
  }

  /// Stops the captions; the transcript stays ([start] adds to it). The
  /// phrase being heard is still transcribed and translated.
  Future<void> stop() async {
    if (!state.isActive) return;
    final wasStarting = state.status == LiveCaptionsStatus.starting;
    _idle();
    await _host.stop();
    if (!wasStarting) await _endRecording();
  }

  Future<void> _endRecording() async {
    final recording = _recording;
    _recording = null;
    _offset += _durationOf(_samples);
    _samples = 0;
    await _heat?.cancel();
    _heat = null;
    await recording?.finish();
  }

  void _onEvent(CaptionBarEvent event) {
    if (isClosed) return;
    switch (event) {
      case CaptionBarEvent.stopTapped:
        if (!state.isRunning) return;
        _idle();
        unawaited(_endRecording());
      case CaptionBarEvent.captureEnded:
        if (!state.isRunning) return;
        _idle(LiveCaptionsNotice.captureEnded);
        unawaited(_endRecording());
      case CaptionBarEvent.deviceLocked:
        if (state.isRunning) {
          emit(state.copyWith(pause: () => LiveCaptionsPause.locked));
        }
      case CaptionBarEvent.deviceUnlocked:
        if (state.isRunning && state.pause == LiveCaptionsPause.locked) {
          final hot = _conditions?.latest.thermal.isHot ?? false;
          emit(state.copyWith(pause: () => hot ? LiveCaptionsPause.hot : null));
          // The bar cleared its text while the phone was locked.
          unawaited(_afterDeviceUnlock());
        }
      case CaptionBarEvent.openTapped:
        // Mozhi is in front: the transcript shows.
        break;
    }
  }

  void _onConditions(DeviceConditionsSnapshot conditions) {
    if (isClosed || !state.isRunning) return;
    final hot = conditions.thermal.isHot;
    final pause = state.pause;
    if (hot && pause == null) {
      emit(state.copyWith(pause: () => LiveCaptionsPause.hot));
      _showNotice(LiveCaptionsBarText.hot);
    } else if (!hot && pause == LiveCaptionsPause.hot) {
      emit(state.copyWith(pause: () => null));
      _restoreBar();
    }
  }

  void _onAudio(Float32List samples) {
    final recording = _recording;
    if (isClosed || recording == null || !state.isRunning) return;
    if (state.pause != null) return;
    _samples += samples.length;
    recording.add(samples);
    _trackSilence(samples);
    if (recording.pending != state.pending) {
      emit(state.copyWith(pending: recording.pending));
    }
  }

  /// Counts silence for the hint; any sound clears it.
  void _trackSilence(Float32List samples) {
    if (rmsDbfs(samples) >= silentLevel) {
      _silentSamples = 0;
      if (state.silenceHint) {
        emit(state.copyWith(silenceHint: false));
        _restoreBar();
      }
      return;
    }
    _silentSamples += samples.length;
    final limit = silenceHintAfter.inMilliseconds * _sampleRate ~/ 1000;
    if (!state.silenceHint && _silentSamples >= limit) {
      emit(state.copyWith(silenceHint: true));
      _showNotice(LiveCaptionsBarText.silence);
    }
  }

  void _showNotice(LiveCaptionsBarText text) =>
      _showOnBar(CaptionLine.notice(_describe(text)));

  /// Whether the app is locked: the bar shows no captions.
  bool get _appLocked => _lock?.isLocked ?? false;

  /// [line] on the bar; "Mozhi is locked" instead while the app is locked.
  void _showOnBar(CaptionLine line) {
    if (_appLocked) {
      _showLockedLine();
      return;
    }
    _lockedLineShown = false;
    unawaited(_host.show(line));
  }

  /// "Mozhi is locked" on the bar, once per lock.
  void _showLockedLine() {
    if (_lockedLineShown) return;
    _lockedLineShown = true;
    unawaited(
      _host.show(CaptionLine.notice(_describe(LiveCaptionsBarText.appLocked))),
    );
  }

  void _onAppLock(bool locked) {
    if (isClosed || !state.isActive) return;
    if (locked) {
      _showLockedLine();
    } else {
      _refreshBar();
    }
  }

  /// The phone was unlocked: the app lock checks first (its timer does
  /// not count while the phone sleeps), then the bar shows what it would.
  Future<void> _afterDeviceUnlock() async {
    if (_lock case final AppLockController lock) await lock.checkAway();
    if (isClosed || !state.isRunning) return;
    _refreshBar();
  }

  /// What the bar shows now: the pause or silence notice, else the last
  /// caption (or "Listening…").
  void _refreshBar() {
    if (state.pause == LiveCaptionsPause.hot) {
      _showNotice(LiveCaptionsBarText.hot);
    } else if (state.silenceHint) {
      _showNotice(LiveCaptionsBarText.silence);
    } else {
      _restoreBar();
    }
  }

  /// After a notice: the last caption again, or "Listening…".
  void _restoreBar() {
    final last = state.entries.where((entry) => entry.isTranslated).lastOrNull;
    if (last == null) {
      _showNotice(LiveCaptionsBarText.listening);
    } else {
      _showCaption(last.id, force: true);
    }
  }

  void _onPhrase(TranscribedPhrase phrase) {
    if (isClosed) return;
    final recording = _recording;
    final pending = recording?.pending ?? 0;
    // Noise in which nothing was heard is left out.
    if (phrase.status == PhraseStatus.transcribed && !phrase.hasText) {
      if (pending != state.pending) emit(state.copyWith(pending: pending));
      return;
    }
    final translate = phrase.hasText;
    final entry = TranscriptEntry(
      id: _nextId++,
      start: _offset + phrase.start,
      end: _offset + phrase.end,
      text: phrase.text,
      language: phrase.language,
      status: phrase.status,
      translationStatus: translate
          ? TranscriptTranslationStatus.translating
          : null,
    );
    final entries = [...state.entries, entry];
    if (entries.length > maxEntries) {
      entries.removeRange(0, entries.length - maxEntries);
    }
    emit(
      state.copyWith(
        entries: entries,
        pending: pending,
        detectedLanguage: phrase.language == null
            ? null
            : () => phrase.language,
      ),
    );
    if (!translate) return;
    // Heard, not translated yet: the original for now.
    _showOnBar(CaptionLine(translation: entry.text, isFinal: false));
    _enqueue(entry.id);
  }

  // ---------------------------------------------------------------------
  // Translation
  // ---------------------------------------------------------------------

  void _enqueue(int id) {
    if (_waiting.contains(id)) return;
    _waiting.add(id);
    _translations = _translations.then((_) => _translateEntry(id));
  }

  Future<void> _translateEntry(int id) async {
    if (!_waiting.remove(id) || isClosed) return;
    final entry = _entry(id);
    if (entry == null || !entry.hasText) return;
    final newer = _waiting.where((other) => other > id).length;
    if (newer >= maxWaitingTranslations) {
      _update(
        id,
        (current) => current.copyWith(
          translationStatus: () => TranscriptTranslationStatus.failed,
          translationError: () => const LiveCaptionsBehindException(),
        ),
      );
      return;
    }
    final source = _sourceOf(entry);
    final target = state.target;
    final engine = _engine();
    if (_primary(source.code) == _primary(target.code)) {
      // Already in the target language: shown as it is.
      _update(
        id,
        (current) => current.copyWith(
          translation: current.text,
          translationStatus: () => TranscriptTranslationStatus.done,
        ),
      );
      _showCaption(id);
      return;
    }
    final request = TranslationRequest(
      text: entry.text,
      source: source,
      target: target,
    );
    final done = Completer<void>();
    _translation = _repository
        .translate(engine, request)
        .listen(
          (result) => _update(
            id,
            (current) => current.copyWith(
              translation: result.text,
              engineId: () => engine.id,
              engineName: () => result.engineName,
            ),
          ),
          onError: (Object error) {
            _update(
              id,
              (current) => current.copyWith(
                translationStatus: () => TranscriptTranslationStatus.failed,
                translationError: () => error,
              ),
            );
            if (error is ConsentRequiredException && !isClosed) {
              emit(state.copyWith(consent: () => error));
            }
            if (!done.isCompleted) done.complete();
          },
          onDone: () {
            _update(
              id,
              (current) => current.copyWith(
                translationStatus: () => TranscriptTranslationStatus.done,
              ),
            );
            _showCaption(id);
            if (!done.isCompleted) done.complete();
          },
          cancelOnError: true,
        );
    await done.future;
    _translation = null;
  }

  /// The final caption of entry [id] on the bar, unless a newer phrase is
  /// shown already.
  void _showCaption(int id, {bool force = false}) {
    final entry = _entry(id);
    if (entry == null || isClosed || !state.isRunning) return;
    final newest = state.entries.where((other) => other.hasText).lastOrNull;
    if (newest?.id != id && !force) return;
    _showOnBar(
      CaptionLine(
        original: state.showOriginal && entry.translation != entry.text
            ? entry.text
            : '',
        translation: entry.translation,
      ),
    );
  }

  /// The language entry [entry] was said in: the chosen one, or the one
  /// Whisper heard ("Detect").
  Language _sourceOf(TranscriptEntry entry) {
    final code = entry.language;
    if (!state.source.isAuto || code == null) return state.source;
    return LanguageCatalog.byCode(code) ??
        Language(code: code, name: LanguageCatalog.nameOf(code));
  }

  static String _primary(String code) =>
      LanguageMatcher.normalize(code.trim()).toLowerCase().split('-').first;

  /// Translates again what failed or waited for consent (after the user
  /// gave it).
  void retryTranslations() {
    final failed = [
      for (final entry in state.entries)
        if (entry.hasText &&
            entry.translationStatus == TranscriptTranslationStatus.failed &&
            entry.translationError is! LiveCaptionsBehindException)
          entry.id,
    ];
    final grants = <ConsentRequiredException>{
      ?state.consent,
      for (final entry in state.entries)
        if (entry.translationError case final ConsentRequiredException consent)
          consent,
    }.toList();
    emit(state.copyWith(consent: () => null));
    if (grants.isNotEmpty) {
      _grants.addAll(grants);
      // Once the phrases were sent, nothing is left for the approval.
      _translations = _translations.then((_) => _revokeGrants(grants));
    }
    if (failed.isEmpty) return;
    final ids = failed.toSet();
    emit(
      state.copyWith(
        entries: [
          for (final entry in state.entries)
            if (ids.contains(entry.id))
              entry.copyWith(
                translation: '',
                translationStatus: () =>
                    TranscriptTranslationStatus.translating,
                translationError: () => null,
              )
            else
              entry,
        ],
      ),
    );
    failed.forEach(_enqueue);
  }

  /// Withdraws what [only] (default: every consent the user gave) let
  /// through once and was not used.
  void _revokeGrants([List<ConsentRequiredException>? only]) {
    final grants = [
      for (final consent in only ?? List.of(_grants))
        if (_grants.remove(consent)) consent,
    ];
    for (final consent in grants) {
      try {
        _repository.revokeOnce(consent);
      } on Object {
        // Withdrawing must never break the captions.
      }
    }
  }

  /// Leaves the translations that wait for consent untranslated.
  void dismissConsent() {
    if (state.consent != null) emit(state.copyWith(consent: () => null));
  }

  TranscriptEntry? _entry(int id) {
    for (final entry in state.entries) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  void _update(int id, TranscriptEntry Function(TranscriptEntry) change) {
    if (isClosed) return;
    emit(
      state.copyWith(
        entries: [
          for (final entry in state.entries)
            if (entry.id == id) change(entry) else entry,
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Options
  // ---------------------------------------------------------------------

  /// Sets the language of the sound (not while captions run).
  void setSource(Language language) {
    if (state.isActive || language.isCustom) return;
    emit(state.copyWith(source: language));
  }

  /// Sets the language of the captions; the next phrases use it.
  void setTarget(Language language) {
    if (language.isAuto || language.isCustom || language == state.target) {
      return;
    }
    emit(state.copyWith(target: language));
  }

  /// Whether the caption bar shows the original under the translation.
  void setShowOriginal({required bool enabled}) {
    if (enabled != state.showOriginal) {
      emit(state.copyWith(showOriginal: enabled));
    }
  }

  // ---------------------------------------------------------------------
  // Transcript
  // ---------------------------------------------------------------------

  /// Saves the transcript (and its translations) as one history entry, in
  /// numbered parts when it is longer than History keeps
  /// ([TranscriptHistory]); saving again updates them. While history is
  /// paused it is saved as a favourite (this is an explicit save).
  Future<void> saveToHistory() async {
    final history = _history;
    if (history == null || !state.hasTranscript) return;
    final paused = history.state.paused;
    final translated = state.entries
        .where((entry) => entry.isTranslated && entry.engineId != null)
        .lastOrNull;
    final now = _clock();
    final entry = HistoryEntry(
      id: _historyId ??= now.microsecondsSinceEpoch.toString(),
      text: TranscriptExport.plain(state.entries),
      translation: TranscriptExport.plainTranslation(state.entries),
      source: state.source,
      target: state.target,
      engineId: translated?.engineId ?? TranslationEngine.offlineId,
      engineName: translated?.engineName ?? 'Whisper',
      createdAt: now,
      detectedSource: state.source.isAuto ? state.detectedLanguage : null,
      isFavorite: paused,
    );
    LiveCaptionsNotice notice;
    try {
      _historyParts = await TranscriptHistory.save(
        history,
        entry,
        state.entries,
        savedParts: _historyParts,
      );
      notice = paused
          ? LiveCaptionsNotice.savedAsFavorite
          : LiveCaptionsNotice.saved;
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
      notice = LiveCaptionsNotice.saveFailed;
    }
    if (isClosed) return;
    emit(state.copyWith(notice: notice, notices: state.notices + 1));
  }

  /// Deletes the transcript (not while captions run); a later save is a
  /// new history entry.
  void clear() {
    if (state.isActive) return;
    _waiting.clear();
    unawaited(_translation?.cancel());
    _translation = null;
    _translations = Future.value();
    _offset = Duration.zero;
    _historyId = null;
    _historyParts = 0;
    emit(
      state.copyWith(
        entries: const [],
        detectedLanguage: () => null,
        consent: () => null,
        pending: 0,
      ),
    );
  }

  static Duration _durationOf(int samples) =>
      Duration(microseconds: samples * 1000000 ~/ _sampleRate);

  @override
  Future<void> close() async {
    // The capture and the bar first: nothing may stay on.
    final running = state.isActive;
    final recording = _recording;
    _recording = null;
    _waiting.clear();
    _revokeGrants();
    await Future.wait<void>([
      if (running) _host.stop(),
      ?recording?.cancel(),
      _events.cancel(),
      ?_lockChanges?.cancel(),
      ?_audio?.cancel(),
      ?_heat?.cancel(),
      ?_translation?.cancel(),
    ]);
    await super.close();
  }
}
