import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/voice/speech_input_state.dart';
import 'package:mozhi/voice/speech_locale_matcher.dart';
import 'package:mozhi/voice/speech_recognizer_adapter.dart';

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
/// [SpeechInputError] after a failed session and [SpeechInputIdle]
/// otherwise. Recognised text arrives on [results].
///
/// The "Prefer on-device speech recognition" flag is stored in the given
/// `store` under [preferOnDeviceKey].
class SpeechInputService {
  new({
    required this._store,
    SpeechRecognizerAdapter? adapter,
    bool? platformSupported,
    bool? onDeviceSupported,
  }) : _adapter = adapter ?? SpeechToTextAdapter(),
       isPlatformSupported =
           platformSupported ?? isSpeechInputPlatformSupported(),
       isOnDeviceSupported =
           (platformSupported ?? isSpeechInputPlatformSupported()) &&
           (onDeviceSupported ?? isOnDeviceSpeechSupported()) {
    _state = isPlatformSupported
        ? const SpeechInputIdle()
        : const SpeechInputUnavailable();
  }

  /// [KeyValueStore] key of the on-device preference (`'true'`/`'false'`).
  static const preferOnDeviceKey = 'voice.preferOnDevice';

  final KeyValueStore _store;
  final SpeechRecognizerAdapter _adapter;

  /// Whether the platform has a speech recogniser plugin at all.
  final bool isPlatformSupported;

  /// Whether the on-device preference has any effect on this platform.
  final bool isOnDeviceSupported;

  final StreamController<SpeechInputState> _states =
      StreamController.broadcast();
  final StreamController<SpeechInputResult> _results =
      StreamController.broadcast();
  final ValueNotifier<bool> _preferOnDevice = ValueNotifier(false);

  late SpeechInputState _state;
  Future<bool>? _initializing;
  bool _initInProgress = false;
  SpeechInputFailure? _initFailure;
  bool? _available;
  Future<void>? _settingsLoading;
  List<SpeechRecognizerLocale>? _locales;
  String? _systemLocaleId;
  bool _disposed = false;

  /// Bumped on every [listen] and [cancel]; callbacks from older
  /// sessions are ignored.
  int _session = 0;
  int? _activeSession;
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
  bool? get isAvailable => _available;

  bool get isListening => _state.isListening;

  /// The "Prefer on-device speech recognition" setting. Call
  /// [loadSettings] (done by [listen] and the settings tile) before reading.
  ValueListenable<bool> get preferOnDevice => _preferOnDevice;

  /// Loads the stored preferences once; later calls return the same future.
  Future<void> loadSettings() => _settingsLoading ??= _loadSettings();

  Future<void> _loadSettings() async {
    try {
      final stored = await _store.read(preferOnDeviceKey);
      if (!_disposed) _preferOnDevice.value = stored == 'true';
    } on Object {
      // Keep the default (cloud allowed) when the store is unavailable.
    }
  }

  /// Persists the on-device preference.
  Future<void> setPreferOnDevice({required bool value}) async {
    _settingsLoading ??= Future.value();
    _preferOnDevice.value = value;
    await _store.write(preferOnDeviceKey, value.toString());
  }

  /// Initialises the recogniser on first use; returns whether speech
  /// recognition is available. Concurrent calls share one attempt; after a
  /// failure the next call tries again.
  Future<bool> initialize() {
    if (!isPlatformSupported || _disposed) return Future.value(false);
    if (_available ?? false) return Future.value(true);
    return _initializing ??= _initialize().whenComplete(
      () => _initializing = null,
    );
  }

  Future<bool> _initialize() async {
    _initFailure = null;
    _initInProgress = true;
    bool ok;
    try {
      ok = await _adapter.initialize(onError: _onError, onStatus: _onStatus);
    } on Object {
      ok = false;
    } finally {
      _initInProgress = false;
    }
    if (_disposed) return false;
    _available = ok;
    if (ok) {
      if (_state is SpeechInputUnavailable) _emit(const SpeechInputIdle());
      return true;
    }
    final failure =
        _initFailure ??
        (await _hasPermission()
            ? SpeechInputFailure.recognizerUnavailable
            : SpeechInputFailure.permissionDenied);
    if (_disposed) return false;
    _emit(SpeechInputUnavailable(failure: failure));
    return false;
  }

  Future<bool> _hasPermission() async {
    try {
      return await _adapter.hasPermission();
    } on Object {
      return true;
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
    if (!await _hasPermission() || _disposed) return;
    if (identical(_state, current)) {
      _available = null;
      _emit(const SpeechInputIdle());
    }
  }

  /// Recogniser locales (cached after the first successful call). Empty
  /// when unavailable.
  Future<List<SpeechRecognizerLocale>> locales() async {
    if (_locales case final cached?) return cached;
    if (!await initialize()) return const [];
    try {
      final locales = await _adapter.locales();
      _systemLocaleId = await _systemLocale();
      return _locales = List.unmodifiable(locales);
    } on Object {
      return const [];
    }
  }

  Future<String?> _systemLocale() async {
    try {
      return await _adapter.systemLocaleId();
    } on Object {
      return null;
    }
  }

  /// The recogniser locale id for a Mozhi/BCP-47 [languageCode], or null
  /// for the system default (see [SpeechLocaleMatcher.match]).
  Future<String?> localeIdFor(String? languageCode) async {
    if (languageCode == null) return null;
    final available = await locales();
    return SpeechLocaleMatcher.match(
      languageCode,
      available.map((locale) => locale.id),
      systemLocaleId: _systemLocaleId,
    );
  }

  /// Starts listening in [languageCode] (a Mozhi code such as `en`,
  /// `pt-BR`, `auto`; null or unknown codes use the system language).
  ///
  /// Sessions use dictation mode with partial results, stop after 3 s of
  /// silence and last at most 60 s (the [SpeechListenRequest] defaults).
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
    if (_activeSession != null) await cancel();
    final session = ++_session;
    if (!await initialize() || session != _session) return false;
    await loadSettings();
    final localeId = await localeIdFor(languageCode);
    if (session != _session || _disposed) return false;

    _activeSession = session;
    _owner = owner;
    _minLevel = null;
    _maxLevel = null;
    _emit(SpeechInputListening(owner: owner));
    try {
      await _adapter.listen(
        request: SpeechListenRequest(
          localeId: localeId,
          onDevice:
              isOnDeviceSupported && (preferOnDevice ?? _preferOnDevice.value),
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

  /// Stops listening; the final result still arrives on [results].
  Future<void> stop() async {
    if (_activeSession == null) return;
    _activeSession = null;
    _emit(const SpeechInputIdle());
    try {
      await _adapter.stop();
    } on Object {
      // Nothing to recover; the session is over either way.
    }
  }

  /// Stops listening and drops any pending results of the session.
  Future<void> cancel() async {
    _session++;
    final wasActive = _activeSession != null;
    _activeSession = null;
    _owner = null;
    if (!wasActive) return;
    _emit(const SpeechInputIdle());
    try {
      await _adapter.cancel();
    } on Object {
      // Nothing to recover; the session is over either way.
    }
  }

  /// Cancels any session and closes the streams.
  Future<void> dispose() async {
    if (_disposed) return;
    if (_activeSession != null) await cancel();
    _disposed = true;
    _session++;
    _preferOnDevice.dispose();
    await _states.close();
    await _results.close();
  }

  void _onResult(int session, String text, {required bool isFinal}) {
    if (session != _session || _disposed) return;
    _results.add(SpeechInputResult(text, isFinal: isFinal, owner: _owner));
    final current = _state;
    if (isFinal) {
      if (_activeSession == session) {
        _activeSession = null;
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

  void _onStatus(SpeechRecognizerStatus status) {
    if (_disposed || _activeSession == null) return;
    switch (status) {
      case SpeechRecognizerStatus.listening:
        // Already reported as listening when the session started.
        break;
      case SpeechRecognizerStatus.notListening:
      case SpeechRecognizerStatus.done:
        _activeSession = null;
        _emit(const SpeechInputIdle());
    }
  }

  void _onError(SpeechRecognizerError error) {
    if (_disposed) return;
    final failure = classifySpeechError(error.message);
    if (_initInProgress) {
      // Reported while initialising: explains why initialisation failed.
      _initFailure = failure ?? _initFailure;
      return;
    }
    final wasActive = _activeSession != null;
    _activeSession = null;
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

/// Maps a raw `speech_to_text` error code (Android, Apple and web codes)
/// to a [SpeechInputFailure]; null for codes that only signal a
/// cancellation.
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
    'error_client' || 'error_request_cancelled' || 'aborted' => null,
    _ => SpeechInputFailure.unknown,
  };
}
