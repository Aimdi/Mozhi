import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:equatable/equatable.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/speech/audio_output.dart';
import 'package:mozhi/speech/device_tts.dart';
import 'package:mozhi/speech/speech_chunker.dart';
import 'package:mozhi/speech/speech_language.dart';
import 'package:mozhi/speech/speech_settings.dart';
import 'package:translation_repository/translation_repository.dart';

export 'audio_output.dart';
export 'device_tts.dart';
export 'speech_language.dart';
export 'speech_settings.dart';

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

/// Something [SpeechService] read aloud (see [SpeechService.lastUtterance]).
class SpeechUtterance extends Equatable {
  const new({required this.id, required this.text, required this.languageCode});

  /// The id it was played under (e.g. `source` / `target`).
  final String id;

  /// The (trimmed) text.
  final String text;
  final String languageCode;

  @override
  List<Object?> get props => [id, text, languageCode];
}

enum _Backend { mozhi, device }

enum _Outcome { skipped, superseded, started }

/// One Mozhi read-aloud: [text] split into [chunks] that are fetched and
/// played one after another.
class _MozhiPlayback {
  new({
    required this.generation,
    required this.text,
    required this.languageCode,
    required this.slow,
    required this.chunks,
  });

  final int generation;
  final String text;
  final String languageCode;
  final bool slow;
  final List<String> chunks;

  /// Index of the chunk playing, or last played.
  int index = 0;

  /// Audio of the chunk after [index], fetched while [index] plays; null
  /// when it could not be fetched.
  Future<Uint8List?>? next;

  /// Whether the device engine has taken over reading [text].
  bool handedOver = false;

  bool get hasNext => index + 1 < chunks.length;
}

/// Reads text aloud.
///
/// Strategy: Mozhi `/api/tts` first (google, falling back to reverso, via
/// [TranslationRepository.textToSpeech]) when at least one instance is
/// configured and the language looks speakable. The endpoint is GET-only
/// with a ~4 KiB request line, so the text is split into chunks of at most
/// [maxSpeechChunkLength] characters at sentence, clause or word breaks
/// ([splitTextForSpeech]); the MP3 clips are played one after another with
/// [AudioOutput], the next one being fetched while the current one plays,
/// and the last 20 clips are cached in memory. On any fetch/playback
/// failure, or without instances, the device engine ([DeviceTts]) speaks the
/// whole text if it has a voice for the language. Otherwise [toggle] throws
/// [SpeechUnavailableException]. With [preferDeviceVoice], or when a
/// device voice was chosen for the language ([SpeechSettings.voices]), the
/// device engine is tried first and Mozhi is only the fallback.
///
/// [settings] hold the speech rate (applied to the Mozhi clips through
/// [AudioOutput.setPlaybackRate] when the player supports it, and to the
/// device engine) and the device voice per language. `slow` playback ("listen
/// slowly", [replaySlowly]) runs at [slowPlaybackRate] times that rate.
/// [speak] always starts from the beginning (e.g. to replay at another
/// speed), [toggle] stops when the same id is playing.
///
/// A later chunk failing does not make [toggle] throw (it has already
/// returned): the device engine reads the whole text from the start instead,
/// or, without a device voice, the clip playing is finished and the service
/// becomes idle.
///
/// [speaking] exposes the id of the clip currently playing (null = idle) so
/// buttons can show a stop icon. The id is reported as speaking from the
/// moment [toggle] is called (including while the clips are being fetched)
/// until the last one completes, is stopped, or fails.
///
/// `output` defaults to [AudioPlayersOutput] and `deviceTts` to
/// [FlutterTtsDeviceTts]; the service owns both and disposes them in
/// [dispose]. `store` persists [preferDeviceVoice] under [preferDeviceKey]
/// and the [settings] (JSON) under [settingsKey]; without it they only last
/// for the session. `mozhiSupportsLanguage` decides which codes are sent to
/// Mozhi (default [isSpeakableLanguageCode]).
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

  /// Number of clips (chunks) kept in the in-memory LRU cache.
  static const cacheSize = 20;

  /// Speed factor of `slow` playback relative to [SpeechSettings.rate]
  /// (0.6x at the default rate), for Mozhi clips and the device engine.
  static const double slowPlaybackRate = SpeechSettings.slowFactor;

  /// [KeyValueStore] key of [preferDeviceVoice] (`'true'` / `'false'`).
  static const preferDeviceKey = 'speech.preferDevice';

  /// [KeyValueStore] key of the [settings] ([SpeechSettings.toJson]).
  static const settingsKey = 'speech.settings';

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

  /// The latest Mozhi read-aloud (set as its first chunk starts).
  _MozhiPlayback? _mozhi;

  bool? _preferDevice;
  Future<bool>? _preferDeviceLoad;

  SpeechSettings? _settings;
  Future<SpeechSettings>? _settingsLoad;

  SpeechUtterance? _last;

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

  /// The speech rate and device voices. Defaults until [loadSettings] has
  /// read the stored value.
  SpeechSettings get settings => _settings ?? const SpeechSettings();

  /// Reads [settings] from the store (once; later calls reuse the result).
  /// Missing, invalid or unreadable settings read as the defaults.
  Future<SpeechSettings> loadSettings() => _settingsLoad ??= _readSettings();

  Future<SpeechSettings> _readSettings() async {
    try {
      final stored = await _store?.read(settingsKey);
      final json = stored == null ? null : jsonDecode(stored);
      return _settings ??= json is Map<String, dynamic>
          ? SpeechSettings.fromJson(json)
          : const SpeechSettings();
    } on Object {
      return _settings ??= const SpeechSettings();
    }
  }

  /// Sets the speech rate ([SpeechSettings.normalizeRate]: 0.5x to 1.5x in
  /// 0.1 steps) for the next playback and persists it; throws when the
  /// store fails (the new rate still applies until restart).
  Future<void> setSpeechRate(double rate) =>
      _updateSettings((settings) => settings.copyWith(rate: rate));

  /// Chooses the device [voice] for [languageCode] (null: the engine's
  /// default voice) for the next playback and persists it; throws when the
  /// store fails (the choice still applies until restart). A chosen voice
  /// makes the device engine read the language before Mozhi.
  Future<void> setVoice(String languageCode, DeviceVoice? voice) =>
      _updateSettings((settings) => settings.withVoice(languageCode, voice));

  Future<void> _updateSettings(
    SpeechSettings Function(SpeechSettings settings) update,
  ) async {
    // Load first so the change does not drop the stored values.
    await loadSettings();
    final updated = update(settings);
    if (updated == settings) return;
    _settings = updated;
    _settingsLoad = Future.value(updated);
    await _store?.write(settingsKey, jsonEncode(updated.toJson()));
  }

  /// The device voices for [languageCode], best match first; empty when
  /// the device has no speech engine or no voice for it. Never throws.
  Future<List<DeviceVoice>> deviceVoices(String languageCode) async {
    final tag = speechLanguageTag(languageCode);
    if (tag == null || !_device.isSupported) return const [];
    try {
      return await _device.voices(tag);
    } on Object {
      return const [];
    }
  }

  /// The last text [toggle] or [speak] started reading (null before the
  /// first one), for [replaySlowly]. Attempts that fail or are stopped
  /// before any audio starts, previews ([previewVoice]) and calls with
  /// `remember: false` leave it unchanged.
  SpeechUtterance? get lastUtterance => _last;

  /// Plays [text] in [languageCode]; [id] identifies the button (e.g.
  /// `source` / `target`). Calling with the id that is playing stops it.
  /// [slow] plays at [slowPlaybackRate] times the [settings] rate. Throws
  /// [SpeechUnavailableException] when neither Mozhi nor the device can
  /// speak it (caller shows a snackbar).
  ///
  /// Once playback has started, [text] becomes the [lastUtterance] unless
  /// [remember] is false (e.g. a sample read by a settings preview).
  Future<void> toggle({
    required String id,
    required String text,
    required String languageCode,
    bool slow = false,
    bool remember = true,
  }) => _start(
    id: id,
    text: text,
    languageCode: languageCode,
    slow: slow,
    toggles: true,
    remember: remember,
  );

  /// Like [toggle], but always (re)starts reading [text] from the beginning,
  /// even when [id] is playing: e.g. a long press on a listen button
  /// replaying the text with `slow: true`.
  Future<void> speak({
    required String id,
    required String text,
    required String languageCode,
    bool slow = false,
    bool remember = true,
  }) => _start(
    id: id,
    text: text,
    languageCode: languageCode,
    slow: slow,
    toggles: false,
    remember: remember,
  );

  /// Reads the [lastUtterance] again, slowly ([slowPlaybackRate]) and from
  /// the start, under its id. Mozhi clips come from the in-memory cache, so
  /// this usually needs no network. False when nothing was read aloud yet;
  /// throws like [speak].
  Future<bool> replaySlowly() async {
    final last = _last;
    if (last == null) return false;
    await speak(
      id: last.id,
      text: last.text,
      languageCode: last.languageCode,
      slow: true,
    );
    return true;
  }

  /// Reads [text] with the device [voice] (null: the language's default
  /// device voice) at the [settings] rate, so a voice can be heard before it
  /// is chosen. Toggles like [toggle] for [id]; never uses Mozhi and does not
  /// change [lastUtterance]. Throws [SpeechUnavailableException] when the
  /// device cannot speak [languageCode].
  Future<void> previewVoice({
    required String id,
    required String text,
    required String languageCode,
    DeviceVoice? voice,
  }) => _start(
    id: id,
    text: text,
    languageCode: languageCode,
    slow: false,
    toggles: true,
    remember: false,
    preview: (voice: voice),
  );

  /// Starts reading [text] under [id]. [toggles]: stop instead when [id] is
  /// playing. [remember]: make it the [lastUtterance] once a backend has
  /// started. [preview]: device only, with that voice.
  Future<void> _start({
    required String id,
    required String text,
    required String languageCode,
    required bool slow,
    required bool toggles,
    required bool remember,
    ({DeviceVoice? voice})? preview,
  }) async {
    final trimmed = text.trim();
    if ((toggles && _current == id) || trimmed.isEmpty) {
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
      final settings = await loadSettings();
      final voice = preview != null
          ? preview.voice
          : settings.voiceFor(languageCode);
      final deviceFirst = preview != null || preferDevice || voice != null;
      Object? cause;
      for (final backend in [
        if (!deviceFirst) _Backend.mozhi,
        _Backend.device,
        if (deviceFirst && preview == null) _Backend.mozhi,
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
              voice: voice,
            ),
          };
          if (outcome == _Outcome.started && remember) {
            _last = SpeechUtterance(
              id: id,
              text: trimmed,
              languageCode: languageCode,
            );
          }
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

  /// Fetches and starts the first chunk of [text]; completions play the
  /// rest ([_playNextChunk]).
  Future<_Outcome> _playMozhi(
    String text,
    String languageCode, {
    required bool slow,
    required int generation,
  }) async {
    if (_repository.instances.isEmpty || !_mozhiSupports(languageCode)) {
      return _Outcome.skipped;
    }
    final playback = _MozhiPlayback(
      generation: generation,
      text: text,
      languageCode: languageCode,
      slow: slow,
      chunks: splitTextForSpeech(text),
    );
    await _setPlaybackRate(settings.speed(slow: slow));
    final bytes = await _fetch(playback.chunks.first, languageCode);
    if (generation != _generation) return _Outcome.superseded;
    _mozhi = playback;
    if (!await _startChunk(playback, bytes)) return _Outcome.superseded;
    return _Outcome.started;
  }

  /// Applies [rate] to the audio output; a player that cannot change its
  /// speed plays at normal speed.
  Future<void> _setPlaybackRate(double rate) async {
    try {
      await _output.setPlaybackRate(rate);
    } on Object {
      // Best effort.
    }
  }

  /// Plays [bytes] as [playback]'s current chunk and prefetches the next
  /// one. False when [playback] was superseded meanwhile.
  Future<bool> _startChunk(_MozhiPlayback playback, Uint8List bytes) async {
    final generation = playback.generation;
    _audioOwner = generation;
    await _output.play(bytes);
    if (generation != _generation) {
      // Stopped while starting: make sure nothing keeps playing.
      if (_audioOwner == generation) await _output.stop();
      return false;
    }
    _playing = generation;
    _playingBackend = _Backend.mozhi;
    _prefetchNext(playback);
    return true;
  }

  /// Starts fetching the chunk after the current one. A failure hands the
  /// whole text over to the device engine ([_interruptForDevice]).
  void _prefetchNext(_MozhiPlayback playback) {
    if (!playback.hasNext) return;
    playback.next =
        _fetch(
          playback.chunks[playback.index + 1],
          playback.languageCode,
        ).then<Uint8List?>(
          (bytes) => bytes,
          onError: (Object _) {
            if (playback.generation == _generation) {
              unawaited(_interruptForDevice(playback));
            }
            return null;
          },
        );
  }

  /// Called when [playback]'s current chunk has finished: plays the next
  /// one once it is fetched, or hands over to the device engine.
  Future<void> _playNextChunk(_MozhiPlayback playback) async {
    final generation = playback.generation;
    // Completions are ignored until the next chunk has started.
    _playing = null;
    _playingBackend = null;
    final bytes = await playback.next;
    if (generation != _generation) return;
    if (bytes != null) {
      playback.index++;
      try {
        await _startChunk(playback, bytes);
        return;
      } on Object {
        if (generation != _generation) return;
      }
    }
    await _handOverToDevice(playback);
  }

  /// A later chunk could not be fetched while the current one plays: stops
  /// it and lets the device engine read the whole text, unless the device
  /// has no voice for it (then the current chunk plays out and
  /// [_playNextChunk] ends the playback).
  Future<void> _interruptForDevice(_MozhiPlayback playback) async {
    final generation = playback.generation;
    final tag = await _deviceTag(playback.languageCode);
    if (tag == null ||
        generation != _generation ||
        _playing != generation ||
        playback.handedOver) {
      return;
    }
    await _handOverToDevice(playback, tag: tag);
  }

  /// Reads [playback]'s whole text on the device engine after a chunk
  /// failed; becomes idle when the device cannot. A [tag] means the device
  /// voice is known to exist and a chunk is still playing.
  Future<void> _handOverToDevice(_MozhiPlayback playback, {String? tag}) async {
    if (playback.handedOver) return;
    playback.handedOver = true;
    final generation = playback.generation;
    _playing = null;
    _playingBackend = null;
    try {
      if (tag != null) await _output.stop();
      final outcome = await _speakOnDevice(
        playback.text,
        playback.languageCode,
        slow: playback.slow,
        generation: generation,
        voice: settings.voiceFor(playback.languageCode),
        tag: tag,
      );
      if (outcome != _Outcome.skipped) return;
    } on Object {
      // toggle() has returned already; there is nothing left to try.
    }
    if (generation == _generation) _setCurrent(null);
  }

  /// The device engine's tag for [languageCode], or null when it has no
  /// voice for it.
  Future<String?> _deviceTag(String languageCode) async {
    final tag = speechLanguageTag(languageCode);
    if (tag == null ||
        !_device.isSupported ||
        !await _device.isLanguageAvailable(tag)) {
      return null;
    }
    return tag;
  }

  /// Speaks [text] on the device with [voice] (null: the default voice);
  /// [tag] skips the availability check.
  Future<_Outcome> _speakOnDevice(
    String text,
    String languageCode, {
    required bool slow,
    required int generation,
    required DeviceVoice? voice,
    String? tag,
  }) async {
    final resolved = tag ?? await _deviceTag(languageCode);
    if (resolved == null) return _Outcome.skipped;
    if (generation != _generation) return _Outcome.superseded;
    await _device.setLanguage(resolved, voice: voice);
    if (generation != _generation) return _Outcome.superseded;
    await _device.setSpeechRate(slow: slow, rate: settings.rate);
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
    if (backend == _Backend.mozhi) {
      if (_mozhi case final playback?
          when playback.generation == _playing && playback.hasNext) {
        unawaited(_playNextChunk(playback));
        return;
      }
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
