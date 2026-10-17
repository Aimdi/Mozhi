import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/voice/speech_input_state.dart';
import 'package:mozhi/voice/speech_locale_matcher.dart';
import 'package:mozhi/voice/speech_recognizer_adapter.dart';
import 'package:translation_repository/translation_repository.dart'
    show PrivacyMode;

/// Whether `speech_to_text` has an implementation for the current platform
/// (Android, iOS, macOS, Windows and the web; not Linux / Fuchsia).
bool isSpeechInputPlatformSupported({
  bool isWeb = kIsWeb,
  TargetPlatform? platform,
}) {
  if (isWeb) return true;
  return switch (platform ?? defaultTargetPlatform) {
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => true,
    TargetPlatform.linux || TargetPlatform.fuchsia => false,
  };
}

/// Whether the platform recogniser can be restricted to on-device
/// recognition (Android 12+, iOS 13+, macOS; not Windows or the web).
bool isOnDeviceSpeechSupported({
  bool isWeb = kIsWeb,
  TargetPlatform? platform,
}) {
  if (isWeb) return false;
  return switch (platform ?? defaultTargetPlatform) {
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.macOS => true,
    _ => false,
  };
}

/// Which recogniser voice input uses (the "Voice input" setting).
enum VoiceInputEngine {
  /// The device's speech recogniser (`speech_to_text`): on most Android
  /// phones Google's, which may send the audio to Google. Not used in
  /// [PrivacyMode.offlineOnly] (see [SpeechInputService]).
  system('system'),

  /// Whisper on this device ([OfflineSpeechRecognizerAdapter]); needs a
  /// downloaded or imported model.
  whisper('whisper');

  new(this.key);

  /// The value stored under [SpeechInputService.engineKey].
  final String key;

  static VoiceInputEngine? fromKey(String? key) {
    for (final engine in values) {
      if (engine.key == key) return engine;
    }
    return null;
  }
}

/// App-wide voice input (speech-to-text).
///
/// Create it once (e.g. in `createDependencies`) and provide it with a
/// `RepositoryProvider<SpeechInputService>`; `VoiceInputButton` reads it with
/// `context.read<SpeechInputService>()`. Call [dispose] when the app shuts
/// down.
///
/// The recogniser is initialised lazily on the first [listen] (or an
/// explicit [initialize]) because that may show the permission prompt.
/// [states] reports [SpeechInputUnavailable] when initialisation fails or
/// the platform is unsupported, [SpeechInputListening] (with a normalised
/// sound level and the partial text) while the microphone is open,
/// [SpeechInputTranscribing] while an offline engine transcribes what was
/// recorded, [SpeechInputError] after a failed session and
/// [SpeechInputIdle] otherwise. Recognised text arrives on [results].
///
/// Two recognisers can be behind it: the platform's (`adapter`, default
/// `speech_to_text`) and an optional offline one (`offlineAdapter`,
/// Whisper). Each session uses:
/// * the offline one when [engine] is [VoiceInputEngine.whisper] (a
///   missing model fails the session with
///   [SpeechInputFailure.offlineModelMissing]; it never falls back to the
///   platform's);
/// * in [PrivacyMode.offlineOnly] (from `privacyMode`) only the offline
///   one: the platform recogniser is never used there, because
///   `speech_to_text` cannot guarantee on-device recognition (its
///   `onDevice` option silently falls back to the default, possibly cloud,
///   recogniser where Android has no on-device one). Without a model the
///   session fails with [SpeechInputFailure.offlineModelMissing], without
///   an offline engine with [SpeechInputFailure.offlineUnavailable];
/// * otherwise the platform's, or the offline one when the device has no
///   speech recogniser (de-Googled phones) and a model is installed.
///
/// The "Prefer on-device speech recognition" flag and [engine] are stored
/// in the given `store` under [preferOnDeviceKey] and [engineKey].
class SpeechInputService {
  new({
    required this._store,
    SpeechRecognizerAdapter? adapter,
    OfflineSpeechRecognizerAdapter? offlineAdapter,
    this._privacyMode,
    bool? platformSupported,
    bool? onDeviceSupported,
  }) : _system = _Recognizer(adapter ?? SpeechToTextAdapter()),
       _offline = offlineAdapter == null
           ? null
           : _Recognizer(offlineAdapter, offline: offlineAdapter),
       isPlatformSupported =
           platformSupported ?? isSpeechInputPlatformSupported(),
       isOnDeviceSupported =
           (platformSupported ?? isSpeechInputPlatformSupported()) &&
           (onDeviceSupported ?? isOnDeviceSpeechSupported()) {
    _current = _system;
    _state = isPlatformSupported
        ? const SpeechInputIdle()
        : const SpeechInputUnavailable();
  }

  /// [KeyValueStore] key of the on-device preference (`'true'`/`'false'`).
  static const preferOnDeviceKey = 'voice.preferOnDevice';

  /// [KeyValueStore] key of the [engine] ([VoiceInputEngine.key]).
  static const engineKey = 'voice.engine';

  final KeyValueStore _store;
  final _Recognizer _system;
  final _Recognizer? _offline;
  final PrivacyMode Function()? _privacyMode;

  /// Whether the platform has a speech recogniser plugin at all.
  final bool isPlatformSupported;

  /// Whether the on-device preference has any effect on this platform.
  final bool isOnDeviceSupported;

  final StreamController<SpeechInputState> _states =
      StreamController.broadcast();
  final StreamController<SpeechInputResult> _results =
      StreamController.broadcast();
  final ValueNotifier<bool> _preferOnDevice = ValueNotifier(false);
  final ValueNotifier<VoiceInputEngine> _engine = ValueNotifier(
    VoiceInputEngine.system,
  );

  late SpeechInputState _state;

  /// The recogniser of the current (or last) session.
  late _Recognizer _current;
  Future<void>? _settingsLoading;
  bool _disposed = false;

  /// Bumped on every [listen] and [cancel]; callbacks from older
  /// sessions are ignored.
  int _session = 0;
  int? _activeSession;

  /// The session that stopped listening and waits for its final result
  /// (an offline engine transcribing).
  int? _finishingSession;
  Object? _owner;
  double? _minLevel;
  double? _maxLevel;

  /// Current state; see [states].
  SpeechInputState get state => _state;

  /// Broadcast stream of state changes (does not replay [state]).
  Stream<SpeechInputState> get states => _states.stream;

  /// Broadcast stream of recognised text, partial and final.
  Stream<SpeechInputResult> get results => _results.stream;

  /// Result of the last initialisation attempt; null before the first.
  bool? get isAvailable => _current.available;

  bool get isListening => _state.isListening;

  /// Whether an offline recogniser (Whisper) can be chosen here.
  bool get isOfflineSupported => _offline != null;

  /// The "Prefer on-device speech recognition" setting. Call
  /// [loadSettings] (done by [listen] and the settings tile) before reading.
  ValueListenable<bool> get preferOnDevice => _preferOnDevice;

  /// The "Voice input" setting (see the class docs for what is used when).
  /// Call [loadSettings] before reading.
  ValueListenable<VoiceInputEngine> get engine => _engine;

  /// Loads the stored preferences once; later calls return the same future.
  Future<void> loadSettings() => _settingsLoading ??= _loadSettings();

  Future<void> _loadSettings() async {
    try {
      final stored = await _store.read(preferOnDeviceKey);
      if (!_disposed) _preferOnDevice.value = stored == 'true';
    } on Object {
      // Keep the default (cloud allowed) when the store is unavailable.
    }
    try {
      final stored = VoiceInputEngine.fromKey(await _store.read(engineKey));
      if (!_disposed && stored != null) _engine.value = stored;
    } on Object {
      // Keep the default (the system recogniser).
    }
  }

  /// Forgets the loaded preferences ("Delete all local data" removed the
  /// stored ones): [preferOnDevice] and [engine] are back to the defaults
  /// until [loadSettings] reads the store again.
  void forgetSettings() {
    _settingsLoading = null;
    if (_disposed) return;
    _preferOnDevice.value = false;
    _engine.value = VoiceInputEngine.system;
    unawaited(offlineModelsChanged());
  }

  /// Persists the on-device preference.
  Future<void> setPreferOnDevice({required bool value}) async {
    _settingsLoading ??= Future.value();
    _preferOnDevice.value = value;
    await _store.write(preferOnDeviceKey, value.toString());
  }

  /// Persists the [engine] choice; the next session uses it.
  Future<void> setEngine(VoiceInputEngine value) async {
    _settingsLoading ??= Future.value();
    if (_engine.value != value) {
      _engine.value = value;
      _makeAvailableAgain();
    }
    await _store.write(engineKey, value.key);
  }

  /// Call after offline models were downloaded, imported or deleted: the
  /// next session checks the offline recogniser again, and voice input is
  /// offered again if it was unavailable.
  Future<void> offlineModelsChanged() async {
    _offline?.reset();
    _makeAvailableAgain();
  }

  /// Initialises the recogniser the next session would use (see the class
  /// docs) on first use; returns whether speech recognition is available.
  /// Concurrent calls share one attempt; after a failure the next call
  /// tries again.
  Future<bool> initialize() async {
    if (!isPlatformSupported || _disposed) return false;
    final route = await _route();
    if (_disposed) return false;
    if (route.blocked != null) return false;
    final (recognizer, failure) = await _prepare(route);
    if (_disposed) return false;
    _current = recognizer;
    if (failure == null) {
      if (_state is SpeechInputUnavailable) _emit(const SpeechInputIdle());
      return true;
    }
    // A missing offline model is explained when the user tries to speak.
    if (!_isOfflineFailure(failure)) {
      _emit(SpeechInputUnavailable(failure: failure));
    }
    return false;
  }

  /// Initialises [route]'s recogniser, or its fallback when the device has
  /// no platform recogniser. Returns the recogniser and why it failed (null
  /// when it is ready).
  Future<(_Recognizer, SpeechInputFailure?)> _prepare(_Route route) async {
    final recognizer = route.recognizer!;
    final failure = await _initializeRecognizer(recognizer);
    final fallback = route.fallback;
    if (failure == SpeechInputFailure.recognizerUnavailable &&
        fallback != null &&
        await _isReady(fallback)) {
      final fallbackFailure = await _initializeRecognizer(fallback);
      if (fallbackFailure == null) return (fallback, null);
    }
    return (recognizer, failure);
  }

  /// Null when [recognizer] is ready; otherwise why it is not.
  Future<SpeechInputFailure?> _initializeRecognizer(_Recognizer recognizer) {
    if (_disposed) return Future.value(SpeechInputFailure.unknown);
    // An offline recogniser is checked every time (models come and go).
    if ((recognizer.available ?? false) && recognizer.offline == null) {
      return Future.value();
    }
    return recognizer.initializing ??= _initializeOnce(recognizer)
        .whenComplete(() => recognizer.initializing = null);
  }

  Future<SpeechInputFailure?> _initializeOnce(_Recognizer recognizer) async {
    recognizer
      ..initFailure = null
      ..initInProgress = true;
    bool ok;
    try {
      ok = await recognizer.adapter.initialize(
        onError: (error) => _onError(recognizer, error),
        onStatus: (status) => _onStatus(recognizer, status),
      );
    } on Object {
      ok = false;
    } finally {
      recognizer.initInProgress = false;
    }
    if (_disposed) return SpeechInputFailure.unknown;
    recognizer.available = ok;
    if (ok) return null;
    return recognizer.initFailure ??
        (await _hasPermission(recognizer)
            ? SpeechInputFailure.recognizerUnavailable
            : SpeechInputFailure.permissionDenied);
  }

  Future<bool> _isReady(_Recognizer recognizer) async {
    try {
      return await recognizer.offline!.isReady();
    } on Object {
      return false;
    }
  }

  Future<bool> _hasPermission(_Recognizer recognizer) async {
    try {
      return await recognizer.adapter.hasPermission();
    } on Object {
      return true;
    }
  }

  /// Which recogniser a session uses now (see the class docs).
  Future<_Route> _route() async {
    await loadSettings();
    final offline = _offline;
    final offlineOnly = _privacyMode?.call() == PrivacyMode.offlineOnly;
    if (offline != null) {
      if (_engine.value == VoiceInputEngine.whisper) return _Route(offline);
      if (offlineOnly) {
        return await _isReady(offline)
            ? _Route(offline)
            : const _Route.blocked(SpeechInputFailure.offlineModelMissing);
      }
      return _Route(_system, fallback: offline);
    }
    if (offlineOnly) {
      return const _Route.blocked(SpeechInputFailure.offlineUnavailable);
    }
    return _Route(_system);
  }

  /// [SpeechInputUnavailable] hides voice input; a missing offline model is
  /// explained on every attempt instead (it can be downloaded).
  void _reportUnavailable(SpeechInputFailure failure, {Object? owner}) {
    if (_isOfflineFailure(failure)) {
      _emit(
        SpeechInputError(
          failure.name,
          permanent: true,
          failure: failure,
          owner: owner,
        ),
      );
    } else {
      _emit(SpeechInputUnavailable(failure: failure));
    }
  }

  static bool _isOfflineFailure(SpeechInputFailure failure) =>
      failure == SpeechInputFailure.offlineModelMissing ||
      failure == SpeechInputFailure.offlineUnavailable;

  /// Voice input is offered again (after a setting or the models changed).
  void _makeAvailableAgain() {
    if (_disposed) return;
    if (_state is SpeechInputUnavailable && isPlatformSupported) {
      _system.reset();
      _emit(const SpeechInputIdle());
    }
  }

  /// Re-checks availability after the user may have granted permission in
  /// the system settings (call on app resume). When initialisation failed
  /// for lack of permission and permission is now granted, the state goes
  /// back to [SpeechInputIdle] so voice input is offered again.
  Future<void> refreshAvailability() async {
    final current = _state;
    if (current is! SpeechInputUnavailable ||
        current.failure != SpeechInputFailure.permissionDenied) {
      return;
    }
    final recognizer = _current;
    if (!await _hasPermission(recognizer) || _disposed) return;
    if (identical(_state, current)) {
      recognizer.available = null;
      _emit(const SpeechInputIdle());
    }
  }

  /// Recogniser locales of the recogniser the next session would use
  /// (cached after the first successful call). Empty when unavailable.
  Future<List<SpeechRecognizerLocale>> locales() async {
    if (!await initialize()) return const [];
    return await _localesOf(_current);
  }

  Future<List<SpeechRecognizerLocale>> _localesOf(
    _Recognizer recognizer,
  ) async {
    if (recognizer.locales case final cached?) return cached;
    try {
      final locales = await recognizer.adapter.locales();
      recognizer.systemLocaleId = await _systemLocale(recognizer);
      return recognizer.locales = List.unmodifiable(locales);
    } on Object {
      return const [];
    }
  }

  Future<String?> _systemLocale(_Recognizer recognizer) async {
    try {
      return await recognizer.adapter.systemLocaleId();
    } on Object {
      return null;
    }
  }

  /// The recogniser locale id for a Mozhi/BCP-47 [languageCode], or null
  /// for the system default (see [SpeechLocaleMatcher.match]).
  Future<String?> localeIdFor(String? languageCode) async {
    if (languageCode == null) return null;
    if (!await initialize()) return null;
    return await _localeIdFor(_current, languageCode);
  }

  Future<String?> _localeIdFor(
    _Recognizer recognizer,
    String? languageCode,
  ) async {
    if (languageCode == null) return null;
    final available = await _localesOf(recognizer);
    return SpeechLocaleMatcher.match(
      languageCode,
      available.map((locale) => locale.id),
      systemLocaleId: recognizer.systemLocaleId,
    );
  }

  /// Starts listening in [languageCode] (a Mozhi code such as `en`,
  /// `pt-BR`, `auto`; null or unknown codes use the system language, or
  /// let an offline engine detect it).
  ///
  /// Sessions use dictation mode with partial results, stop after 3 s of
  /// silence and last at most 60 s (the [SpeechListenRequest] defaults; an
  /// offline engine stops at its own maximum, 30 s for Whisper).
  ///
  /// [preferOnDevice] overrides the stored setting. [owner] tags the
  /// session's states and results (see [SpeechInputState.isOwnedBy]).
  /// A session that is already running is cancelled first. Returns whether
  /// listening started; failures are reported through [states].
  Future<bool> listen(
    String? languageCode, {
    bool? preferOnDevice,
    Object? owner,
  }) async {
    if (_disposed) return false;
    if (_activeSession != null || _finishingSession != null) await cancel();
    final session = ++_session;
    if (!isPlatformSupported) return false;
    final route = await _route();
    if (session != _session || _disposed) return false;
    if (route.blocked case final failure?) {
      _reportUnavailable(failure, owner: owner);
      return false;
    }
    final (recognizer, failure) = await _prepare(route);
    if (session != _session || _disposed) return false;
    _current = recognizer;
    if (failure != null) {
      _reportUnavailable(failure, owner: owner);
      return false;
    }
    if (_state is SpeechInputUnavailable) _emit(const SpeechInputIdle());
    final localeId = await _localeIdFor(recognizer, languageCode);
    if (session != _session || _disposed) return false;

    _activeSession = session;
    _owner = owner;
    _minLevel = null;
    _maxLevel = null;
    _emit(SpeechInputListening(owner: owner));
    try {
      await recognizer.adapter.listen(
        request: SpeechListenRequest(
          localeId: localeId,
          onDevice:
              recognizer.offline != null ||
              (isOnDeviceSupported &&
                  (preferOnDevice ?? _preferOnDevice.value)),
        ),
        onResult: (text, {required isFinal}) =>
            _onResult(session, text, isFinal: isFinal),
        onSoundLevel: (level) => _onSoundLevel(session, level),
      );
    } on Object catch (error) {
      if (session != _session) return false;
      _activeSession = null;
      _emit(SpeechInputError(error.toString(), permanent: false, owner: owner));
      return false;
    }
    return session == _session;
  }

  /// Stops listening; the final result still arrives on [results] (after
  /// [SpeechInputTranscribing] with an offline engine).
  Future<void> stop() async {
    final session = _activeSession;
    if (session == null) return;
    _activeSession = null;
    if (_current.offline != null) {
      _finishingSession = session;
      _emit(SpeechInputTranscribing(owner: _owner));
    } else {
      _emit(const SpeechInputIdle());
    }
    try {
      await _current.adapter.stop();
    } on Object {
      // Nothing to recover; the session is over either way.
    }
  }

  /// Stops listening (or transcribing) and drops any pending results of
  /// the session.
  Future<void> cancel() async {
    _session++;
    final wasActive = _activeSession != null || _finishingSession != null;
    _activeSession = null;
    _finishingSession = null;
    _owner = null;
    if (!wasActive) return;
    _emit(const SpeechInputIdle());
    try {
      await _current.adapter.cancel();
    } on Object {
      // Nothing to recover; the session is over either way.
    }
  }

  /// Cancels any session and closes the streams.
  Future<void> dispose() async {
    if (_disposed) return;
    if (_activeSession != null || _finishingSession != null) await cancel();
    _disposed = true;
    _session++;
    _preferOnDevice.dispose();
    _engine.dispose();
    await _states.close();
    await _results.close();
  }

  void _onResult(int session, String text, {required bool isFinal}) {
    if (session != _session || _disposed) return;
    _results.add(SpeechInputResult(text, isFinal: isFinal, owner: _owner));
    final current = _state;
    if (isFinal) {
      if (_activeSession == session || _finishingSession == session) {
        _activeSession = null;
        _finishingSession = null;
        _emit(const SpeechInputIdle());
      }
    } else if (current is SpeechInputListening) {
      _emit(current.copyWith(partialText: text));
    }
  }

  void _onSoundLevel(int session, double raw) {
    if (session != _session || _activeSession != session) return;
    final current = _state;
    if (current is! SpeechInputListening || !raw.isFinite) return;
    final min = _minLevel = math.min(_minLevel ?? raw, raw);
    final max = _maxLevel = math.max(_maxLevel ?? raw, raw);
    final span = math.max(max - min, _minLevelSpan);
    final level = ((raw - min) / span).clamp(0.0, 1.0);
    if (level != current.level) _emit(current.copyWith(level: level));
  }

  /// Minimum dB range used to normalise sound levels, so near-silence does
  /// not make the ring jump to full size.
  static const _minLevelSpan = 10.0;

  void _onStatus(_Recognizer recognizer, SpeechRecognizerStatus status) {
    if (_disposed || !identical(recognizer, _current)) return;
    switch (status) {
      case SpeechRecognizerStatus.listening:
        // Already reported as listening when the session started.
        break;
      case SpeechRecognizerStatus.transcribing:
        final session = _activeSession ?? _finishingSession;
        if (session == null) return;
        _activeSession = null;
        _finishingSession = session;
        _emit(SpeechInputTranscribing(owner: _owner));
      case SpeechRecognizerStatus.notListening:
      case SpeechRecognizerStatus.done:
        if (_activeSession == null && _finishingSession == null) return;
        // A transcribing engine reports `done` after its final result (or
        // its error); until then it keeps transcribing.
        if (status == SpeechRecognizerStatus.notListening &&
            _finishingSession != null) {
          return;
        }
        _activeSession = null;
        _finishingSession = null;
        _emit(const SpeechInputIdle());
    }
  }

  void _onError(_Recognizer recognizer, SpeechRecognizerError error) {
    if (_disposed) return;
    final failure = classifySpeechError(error.message);
    if (recognizer.initInProgress) {
      // Reported while initialising: explains why initialisation failed.
      recognizer.initFailure = failure ?? recognizer.initFailure;
      return;
    }
    if (!identical(recognizer, _current)) return;
    final wasActive = _activeSession != null || _finishingSession != null;
    _activeSession = null;
    _finishingSession = null;
    if (failure == null) {
      // Cancellation echoes (`error_client`, `aborted`): not a failure.
      if (wasActive) _emit(const SpeechInputIdle());
      return;
    }
    _emit(
      SpeechInputError(
        error.message,
        permanent: failure.isPermanent,
        failure: failure,
        owner: _owner,
      ),
    );
  }

  void _emit(SpeechInputState state) {
    if (_disposed || state == _state) return;
    _state = state;
    _states.add(state);
  }
}

/// One recogniser behind [SpeechInputService] and what is known about it.
final class _Recognizer {
  new(this.adapter, {this.offline});

  final SpeechRecognizerAdapter adapter;

  /// [adapter] when it is the offline recogniser.
  final OfflineSpeechRecognizerAdapter? offline;

  Future<SpeechInputFailure?>? initializing;
  bool initInProgress = false;
  SpeechInputFailure? initFailure;

  /// Result of the last initialisation (null: not tried since [reset]).
  bool? available;
  List<SpeechRecognizerLocale>? locales;
  String? systemLocaleId;

  void reset() => available = null;
}

/// The recogniser a session uses, the one to try when it is unavailable,
/// or why voice input cannot be used.
final class _Route {
  const new(_Recognizer this.recognizer, {this.fallback}) : blocked = null;

  const new blocked(SpeechInputFailure this.blocked)
    : recognizer = null,
      fallback = null;

  final _Recognizer? recognizer;
  final _Recognizer? fallback;
  final SpeechInputFailure? blocked;
}

/// Maps a raw `speech_to_text` error code (Android, Apple and web codes)
/// or an [OfflineSpeechRecognizerAdapter] code to a [SpeechInputFailure];
/// null for codes that only signal a cancellation.
SpeechInputFailure? classifySpeechError(String message) {
  final code = message.trim().toLowerCase();
  if (code.startsWith('error_unknown')) return SpeechInputFailure.unknown;
  return switch (code) {
    'error_permission' ||
    'error_insufficient_permissions' ||
    'error_speech_recognizer_request_not_authorized' ||
    'not-allowed' ||
    'service-not-allowed' => SpeechInputFailure.permissionDenied,
    'error_language_not_supported' ||
    'error_language_unavailable' ||
    'error_assets_not_installed' ||
    'language-not-supported' => SpeechInputFailure.languageUnavailable,
    'error_speech_recognizer_disabled' ||
    'not supported' ||
    'speech_not_supported' => SpeechInputFailure.recognizerUnavailable,
    'error_audio_error' || 'audio-capture' => SpeechInputFailure.audio,
    'error_no_match' ||
    'error_speech_timeout' ||
    'no-speech' => SpeechInputFailure.noMatch,
    'error_network' ||
    'error_network_timeout' ||
    'error_server' ||
    'error_server_disconnected' ||
    'error_too_many_requests' ||
    'network' => SpeechInputFailure.network,
    'error_busy' ||
    'error_retry' ||
    'error_speech_recognizer_already_active' ||
    'error_speech_recognizer_connection_interrupted' ||
    'error_speech_recognizer_connection_invalidated' => SpeechInputFailure.busy,
    OfflineSpeechRecognizerAdapter.modelMissingCode =>
      SpeechInputFailure.offlineModelMissing,
    'error_client' || 'error_request_cancelled' || 'aborted' => null,
    _ => SpeechInputFailure.unknown,
  };
}
