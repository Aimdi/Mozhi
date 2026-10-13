import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/speech/audio_output.dart';
import 'package:mozhi/speech/device_tts.dart';
import 'package:mozhi/speech/speech_language.dart';
import 'package:translation_repository/translation_repository.dart';

export 'audio_output.dart';
export 'device_tts.dart';
export 'speech_language.dart';

/// Thrown by [SpeechService.toggle] when no backend can read the text aloud:
/// Mozhi is not configured or failed, and the device has no voice for
/// [languageCode]. [cause] is the first underlying failure, if any.
class SpeechUnavailableException implements Exception {
  const new(this.languageCode, {this.cause});

  final String languageCode;
  final Object? cause;

  @override
  String toString() =>
      'SpeechUnavailableException($languageCode'
      '${cause == null ? '' : ', cause: $cause'})';
}

enum _Backend { mozhi, device }

enum _Outcome { skipped, superseded, started }

/// Reads text aloud.
///
/// Strategy: Mozhi `/api/tts` first (google, falling back to reverso, via
/// [TranslationRepository.textToSpeech]) when at least one instance is
/// configured and the language looks speakable; the MP3 is played with
/// [AudioOutput] and the last 20 clips are cached in memory. On any
/// fetch/playback failure, or without instances, the device engine
/// ([DeviceTts]) speaks it if it has a voice for the language. Otherwise
/// [toggle] throws [SpeechUnavailableException]. With [preferDeviceVoice]
/// the device engine is tried first and Mozhi is only the fallback.
///
/// [speaking] exposes the id of the clip currently playing (null = idle) so
/// buttons can show a stop icon. The id is reported as speaking from the
/// moment [toggle] is called (including while the clip is being fetched)
/// until it completes, is stopped, or fails.
///
/// `output` defaults to [AudioPlayersOutput] and `deviceTts` to
/// [FlutterTtsDeviceTts]; the service owns both and disposes them in
/// [dispose]. `store` persists [preferDeviceVoice] under [preferDeviceKey].
/// `mozhiSupportsLanguage` decides which codes are sent to Mozhi (default
/// [isSpeakableLanguageCode]).
class SpeechService {
  new({
    required this._repository,
    AudioOutput? output,
    DeviceTts? deviceTts,
    this._store,
    bool Function(String languageCode)? mozhiSupportsLanguage,
  }) : _output = output ?? AudioPlayersOutput(),
       _device = deviceTts ?? FlutterTtsDeviceTts(),
       _mozhiSupports = mozhiSupportsLanguage ?? isSpeakableLanguageCode {
    _completions = _output.onComplete.listen(
      (_) => _onComplete(_Backend.mozhi),
    );
    _deviceCompletions = _device.onComplete.listen(
      (_) => _onComplete(_Backend.device),
    );
  }

  /// Number of clips kept in the in-memory LRU cache.
  static const cacheSize = 20;

  /// [AudioOutput] playback rate for `slow` Mozhi clips.
  static const slowPlaybackRate = 0.7;

  /// [KeyValueStore] key of [preferDeviceVoice] (`'true'` / `'false'`).
  static const preferDeviceKey = 'speech.preferDevice';

  final TranslationRepository _repository;
  final AudioOutput _output;
  final DeviceTts _device;
  final KeyValueStore? _store;
  final bool Function(String languageCode) _mozhiSupports;
  final StreamController<String?> _speaking = StreamController.broadcast();
  final LinkedHashMap<String, Uint8List> _cache = LinkedHashMap();
  late final StreamSubscription<void> _completions;
  late final StreamSubscription<void> _deviceCompletions;

  String? _current;

  /// Bumped by every [toggle]/[stop] so stale fetches/plays are ignored.
  int _generation = 0;

  /// Generation whose clip is currently playing, if any, and its backend.
  int? _playing;
  _Backend? _playingBackend;

  /// Generation that last started each backend; a superseded request only
  /// stops a backend nobody newer has taken over.
  int? _audioOwner;
  int? _deviceOwner;

  bool? _preferDevice;
  Future<bool>? _preferDeviceLoad;

  /// Broadcast stream of the speaking id (null = idle); emits on change.
  Stream<String?> get speaking => _speaking.stream;
  String? get current => _current;

  /// Whether this platform has a device speech engine (hide the
  /// "use device voice" setting when false).
  bool get deviceVoiceSupported => _device.isSupported;

  /// Whether the device voice is tried before Mozhi. False until
  /// [loadPreferDeviceVoice] has read the stored value.
  bool get preferDeviceVoice => _preferDevice ?? false;

  /// Reads [preferDeviceVoice] from the store (once; later calls reuse the
  /// result). A failing store reads as false.
  Future<bool> loadPreferDeviceVoice() =>
      _preferDeviceLoad ??= _readPreferDevice();

  Future<bool> _readPreferDevice() async {
    try {
      final stored = await _store?.read(preferDeviceKey);
      return _preferDevice ??= stored == 'true';
    } on Object {
      return _preferDevice ??= false;
    }
  }

  /// Updates [preferDeviceVoice] immediately and persists it; throws when
  /// the store fails (the new value still applies until restart).
  Future<void> setPreferDeviceVoice({required bool enabled}) async {
    _preferDevice = enabled;
    _preferDeviceLoad = Future.value(enabled);
    await _store?.write(preferDeviceKey, '$enabled');
  }

  /// Plays [text] in [languageCode]; [id] identifies the button (e.g.
  /// `source` / `target`). Calling with the id that is playing stops it.
  /// [slow] plays Mozhi clips at [slowPlaybackRate] and uses the device
  /// engine's slow rate. Throws [SpeechUnavailableException] when neither
  /// Mozhi nor the device can speak it (caller shows a snackbar).
  Future<void> toggle({
    required String id,
    required String text,
    required String languageCode,
    bool slow = false,
  }) async {
    final trimmed = text.trim();
    if (_current == id || trimmed.isEmpty) {
      await stop();
      return;
    }

    final previous = _current;
    final generation = ++_generation;
    _playing = null;
    _playingBackend = null;
    _setCurrent(id);
    try {
      if (previous != null) await _stopOutputs();
      final preferDevice = await loadPreferDeviceVoice();
      Object? cause;
      for (final backend in [
        if (!preferDevice) _Backend.mozhi,
        _Backend.device,
        if (preferDevice) _Backend.mozhi,
      ]) {
        if (generation != _generation) return;
        try {
          final outcome = switch (backend) {
            _Backend.mozhi => await _playMozhi(
              trimmed,
              languageCode,
              slow: slow,
              generation: generation,
            ),
            _Backend.device => await _speakOnDevice(
              trimmed,
              languageCode,
              slow: slow,
              generation: generation,
            ),
          };
          if (outcome != _Outcome.skipped) return;
        } on Object catch (error) {
          cause ??= error;
        }
      }
      if (generation != _generation) return;
      throw SpeechUnavailableException(languageCode, cause: cause);
    } on Object {
      if (generation != _generation) return;
      _setCurrent(null);
      rethrow;
    }
  }

  Future<_Outcome> _playMozhi(
    String text,
    String languageCode, {
    required bool slow,
    required int generation,
  }) async {
    if (_repository.instances.isEmpty || !_mozhiSupports(languageCode)) {
      return _Outcome.skipped;
    }
    await _output.setPlaybackRate(slow ? slowPlaybackRate : 1);
    final bytes = await _fetch(text, languageCode);
    if (generation != _generation) return _Outcome.superseded;
    _audioOwner = generation;
    await _output.play(bytes);
    if (generation != _generation) {
      // Stopped while starting: make sure nothing keeps playing.
      if (_audioOwner == generation) await _output.stop();
      return _Outcome.superseded;
    }
    _playing = generation;
    _playingBackend = _Backend.mozhi;
    return _Outcome.started;
  }

  Future<_Outcome> _speakOnDevice(
    String text,
    String languageCode, {
    required bool slow,
    required int generation,
  }) async {
    final tag = speechLanguageTag(languageCode);
    if (tag == null ||
        !_device.isSupported ||
        !await _device.isLanguageAvailable(tag)) {
      return _Outcome.skipped;
    }
    if (generation != _generation) return _Outcome.superseded;
    await _device.setLanguage(tag);
    if (generation != _generation) return _Outcome.superseded;
    await _device.setSpeechRate(slow: slow);
    if (generation != _generation) return _Outcome.superseded;
    _deviceOwner = generation;
    // Utterances can end before speak() returns; interrupted ones never
    // emit, so any completion from now on belongs to this request.
    _playing = generation;
    _playingBackend = _Backend.device;
    try {
      await _device.speak(text);
    } on Object {
      if (_playing == generation) {
        _playing = null;
        _playingBackend = null;
      }
      rethrow;
    }
    if (generation != _generation) {
      if (_deviceOwner == generation) await _device.stop();
      return _Outcome.superseded;
    }
    return _Outcome.started;
  }

  Future<void> stop() async {
    _generation++;
    _playing = null;
    _playingBackend = null;
    _setCurrent(null);
    await _stopOutputs();
  }

  Future<void> _stopOutputs() async {
    await _output.stop();
    await _device.stop();
  }

  /// Stops playback and releases the audio output and device engine. The
  /// service cannot be used afterwards.
  Future<void> dispose() async {
    _generation++;
    _playing = null;
    _playingBackend = null;
    _current = null;
    await _completions.cancel();
    await _deviceCompletions.cancel();
    await _speaking.close();
    await _output.dispose();
    await _device.dispose();
  }

  Future<Uint8List> _fetch(String text, String languageCode) async {
    final key = '$languageCode\u0000$text';
    final cached = _cache.remove(key);
    if (cached != null) return _cache[key] = cached;

    final bytes = await _repository.textToSpeech(
      text: text,
      languageCode: languageCode,
    );
    if (bytes.isEmpty) {
      throw const FormatException('Text-to-speech returned no audio');
    }
    _cache[key] = bytes;
    while (_cache.length > cacheSize) {
      _cache.remove(_cache.keys.first);
    }
    return bytes;
  }

  void _onComplete(_Backend backend) {
    if (_playing == null ||
        _playing != _generation ||
        _playingBackend != backend) {
      return;
    }
    _playing = null;
    _playingBackend = null;
    _setCurrent(null);
  }

  void _setCurrent(String? id) {
    if (_current == id) return;
    _current = id;
    if (!_speaking.isClosed) _speaking.add(id);
  }
}
