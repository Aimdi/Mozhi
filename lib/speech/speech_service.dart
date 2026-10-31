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
import 'package:mozhi/speech/spoken_range.dart';
import 'package:translation_repository/translation_repository.dart';

export 'audio_output.dart';
export 'device_tts.dart';
export 'speech_language.dart';
export 'speech_settings.dart';
export 'spoken_range.dart';

/// Longest part of a text the device's speech engine is given at once, in
/// UTF-16 code units: below Android's limit
/// (`TextToSpeech.getMaxSpeechInputLength()`, 4,000), which rejects longer
/// texts. Longer texts are read in parts ([speechChunks]), one after
/// another.
const maxDeviceSpeechChunkLength = 3900;

/// Thrown by [SpeechService.toggle] when no backend can read the text aloud:
/// the device has no voice for [languageCode] (or its voice failed, or is
/// an online voice the user has not allowed yet), and Mozhi is not
/// configured, not allowed or failed. [cause] is the first underlying
/// failure, if any.
///
/// [noDeviceEngine] tells that the device has no speech engine at all
/// ([DeviceTtsEngines.hasEngine] answered false): no voice can be
/// installed for the language before a text-to-speech app is (common on
/// Android phones without Google services).
class SpeechUnavailableException implements Exception {
  const new(this.languageCode, {this.cause, this.noDeviceEngine = false});

  final String languageCode;
  final Object? cause;

  /// Whether the device has no speech engine installed at all.
  final bool noDeviceEngine;

  /// This failure without its [cause] (e.g. without the Mozhi instance
  /// that could have read the text with the user's consent, when that is
  /// not offered), keeping [noDeviceEngine].
  SpeechUnavailableException withoutCause() =>
      SpeechUnavailableException(languageCode, noDeviceEngine: noDeviceEngine);

  /// The consent that lets a Mozhi instance read the text aloud once, when
  /// the privacy settings stopped it ([PrivacyMode.offlineFirst] and the
  /// language was not approved), or lets an online device voice read it
  /// (asked once per voice, see [SpeechService.isOnlineVoiceConsent]): pass
  /// it as `allowOnline` to [SpeechService.toggle] after the user chose
  /// "Listen online". Null otherwise, also in [PrivacyMode.offlineOnly],
  /// which cannot be overridden.
  ConsentRequiredException? get onlineConsent => switch (cause) {
    final ConsentRequiredException consent
        when consent.kind != ConsentKind.offlineOnly =>
      consent,
    _ => null,
  };

  @override
  String toString() =>
      'SpeechUnavailableException($languageCode'
      '${cause == null ? '' : ', cause: $cause'}'
      '${noDeviceEngine ? ', no device engine' : ''})';
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

  /// The user's approval to send [text] to the instance despite the privacy
  /// settings, renewed for every chunk; null when none was needed.
  ConsentRequiredException? consent;

  /// Index of the chunk playing, or last played.
  int index = 0;

  /// Audio of the chunk after [index], fetched while [index] plays; null
  /// when it could not be fetched.
  Future<Uint8List?>? next;

  bool get hasNext => index + 1 < chunks.length;
}

/// One read-aloud by the device engine: the text in [chunks] (one, unless
/// the text is longer than the engine takes at once), spoken one after
/// another.
class _DevicePlayback {
  new({required this.generation, required this.chunks});

  final int generation;

  /// The parts, with their offsets in the text given to the service.
  final List<SpeechChunk> chunks;

  /// Index of the chunk being spoken.
  int index = 0;

  bool get hasNext => index + 1 < chunks.length;

  SpeechChunk get current => chunks[index];
}

/// Reads text aloud.
///
/// Strategy (privacy first): the device engine ([DeviceTts]) reads the text
/// whenever it has a voice for the language (the voice chosen in
/// [SpeechSettings.voices], else its default one). Only when the device has
/// no voice for it is Mozhi `/api/tts` used (google, falling back to
/// reverso, via [TranslationRepository.textToSpeech]), and only when an
/// instance is configured, the language looks speakable and the privacy
/// settings allow it: the repository refuses in [PrivacyMode.offlineOnly],
/// and in [PrivacyMode.offlineFirst] unless the language was approved
/// (then [SpeechUnavailableException.onlineConsent] lets the caller offer
/// "Listen online" and retry with `allowOnline`). A device voice
/// that fails is not replaced by Mozhi, and with [preferDeviceVoice]
/// ("device voice only") Mozhi is never used.
///
/// Device voices can be online voices too ([DeviceVoice.networkRequired]:
/// Chrome's "Google …" voices in the web app, Android voices without
/// voice data on the phone), which send the text to their speech service.
/// Where the language has a voice on the device, the engine reads with it
/// ([DeviceTts.setLanguage]). Before an online voice reads for the first
/// time, [toggle] stops with a [SpeechUnavailableException] whose
/// [SpeechUnavailableException.onlineConsent] names the voice
/// ([isOnlineVoiceConsent]); once the user agreed, the voice is remembered
/// in [SpeechSettings.onlineVoices] and is not asked about again. In
/// [PrivacyMode.offlineOnly] online voices never read, not even a preview.
/// The personal data shield cannot apply to speech: a voice would read the
/// placeholders aloud.
///
/// Mozhi's `/api/tts` only accepts GET: the text travels in the request
/// URL, so it can end up in the instance's (and any reverse proxy's)
/// access logs. The request line is limited to ~4 KiB, so the text is split
/// into chunks of at most [maxSpeechChunkLength] characters at sentence,
/// clause or word breaks ([splitTextForSpeech]); the MP3 clips are played
/// one after another with [AudioOutput], the next one being fetched while
/// the current one plays, and the last 20 clips are cached in memory. When
/// the first clip cannot be fetched or played, [toggle] throws
/// [SpeechUnavailableException]; when a later one fails, the clip playing is
/// finished and the service becomes idle.
///
/// [settings] hold the speech rate (applied to the Mozhi clips through
/// [AudioOutput.setPlaybackRate] when the player supports it, and to the
/// device engine) and the device voice per language. `slow` playback ("listen
/// slowly", [replaySlowly]) runs at [slowPlaybackRate] times that rate.
/// [speak] always starts from the beginning (e.g. to replay at another
/// speed), [toggle] stops when the same id is playing.
///
/// [speaking] exposes the id of the clip currently playing (null = idle) so
/// buttons can show a stop icon. The id is reported as speaking from the
/// moment [toggle] is called (including while the clips are being fetched)
/// until the last one completes, is stopped, or fails.
///
/// [spokenRanges] tells which word of the text is being read, when the
/// device engine reports its progress ([DeviceTtsProgress]: Android 8.0+
/// and browsers that send `boundary` events): offsets into the text given
/// to [toggle] or [speak], also across the parts of a long text (the
/// device engine reads at most [maxDeviceSpeechChunkLength] code units at
/// once, `deviceChunkLength` in tests). Mozhi clips and engines without
/// progress report no range; null follows whenever reading starts,
/// stops, ends or fails.
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
    this._deviceChunkLength = maxDeviceSpeechChunkLength,
  }) : _output = output ?? AudioPlayersOutput(),
       _device = deviceTts ?? FlutterTtsDeviceTts(),
       _mozhiSupports = mozhiSupportsLanguage ?? isSpeakableLanguageCode {
    _completions = _output.onComplete.listen(
      (_) => _onComplete(_Backend.mozhi),
    );
    _deviceCompletions = _device.onComplete.listen(
      (_) => _onComplete(_Backend.device),
    );
    if (_device case final DeviceTtsProgress progress) {
      _deviceProgress = progress.onProgress.listen(_onDeviceProgress);
    }
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

  /// Prefix of the `engineId` of a consent for an online device voice
  /// ([isOnlineVoiceConsent]), followed by the voice's [DeviceVoice.id].
  static const onlineVoicePrefix = 'voice:';

  /// Whether [consent] is about an online device voice rather than a Mozhi
  /// instance: its `destination` names who receives the text (a
  /// [CloudProviderDestination], with an empty name when the voice does
  /// not tell), and [onlineVoiceOf] the voice.
  static bool isOnlineVoiceConsent(ConsentRequiredException consent) =>
      consent.engineId.startsWith(onlineVoicePrefix);

  /// The voice (its name and locale) an online voice consent is about
  /// ([isOnlineVoiceConsent]), or null for other consents.
  static DeviceVoice? onlineVoiceOf(ConsentRequiredException consent) {
    if (!isOnlineVoiceConsent(consent)) return null;
    final id = consent.engineId.substring(onlineVoicePrefix.length);
    final slash = id.indexOf('/');
    return DeviceVoice(
      name: slash < 0 ? id : id.substring(slash + 1),
      locale: slash < 0 ? '' : id.substring(0, slash),
      networkRequired: true,
    );
  }

  /// The consent asked for before the online [voice] reads (of [kind]
  /// [ConsentKind.offlineOnly] when it may not).
  static ConsentRequiredException onlineVoiceConsent(
    DeviceVoice voice, {
    ConsentKind kind = ConsentKind.cloudProvider,
  }) => ConsentRequiredException(
    kind: kind,
    destination: CloudProviderDestination(voice.onlineProvider ?? ''),
    engineId: '$onlineVoicePrefix${voice.id}',
  );

  final TranslationRepository _repository;
  final AudioOutput _output;
  final DeviceTts _device;
  final KeyValueStore? _store;
  final bool Function(String languageCode) _mozhiSupports;
  final int _deviceChunkLength;
  final StreamController<String?> _speaking = StreamController.broadcast();
  final StreamController<SpokenRange?> _ranges = StreamController.broadcast();
  StreamSubscription<SpokenRange>? _deviceProgress;

  /// The latest range reported on [spokenRanges].
  SpokenRange? _range;

  /// The latest read-aloud of the device engine.
  _DevicePlayback? _devicePlayback;
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

  /// The approval [_last] was read aloud with, reused by [replaySlowly].
  ConsentRequiredException? _lastConsent;

  /// Broadcast stream of the speaking id (null = idle); emits on change.
  Stream<String?> get speaking => _speaking.stream;
  String? get current => _current;

  /// Broadcast stream of the part of the [current] clip's text being read
  /// (offsets into the text given to [toggle] or [speak]), as the device
  /// engine reports it; null when reading starts, stops, ends or fails.
  /// Never emits for Mozhi clips and engines that report no progress.
  Stream<SpokenRange?> get spokenRanges => _ranges.stream;

  /// Whether this platform has a device speech engine (hide the
  /// "use device voice" setting when false).
  bool get deviceVoiceSupported => _device.isSupported;

  /// "Device voice only": whether Mozhi is never used to read aloud, not
  /// even for languages the device has no voice for (the device voice is
  /// always tried first). False until [loadPreferDeviceVoice] has read the
  /// stored value.
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
  /// store fails (the choice still applies until restart).
  Future<void> setVoice(String languageCode, DeviceVoice? voice) =>
      _updateSettings((settings) => settings.withVoice(languageCode, voice));

  /// Forgets which online voices the user allowed
  /// ([SpeechSettings.onlineVoices]): each asks again before it reads.
  /// Throws when the store fails (forgotten until restart anyway).
  Future<void> forgetOnlineVoices() =>
      _updateSettings((settings) => settings.copyWith(onlineVoices: const {}));

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
  /// [SpeechUnavailableException] when neither the device nor Mozhi can
  /// (or may) speak it (caller shows a snackbar, see `speechErrorMessage`).
  ///
  /// [allowOnline] is the [SpeechUnavailableException.onlineConsent] of an
  /// earlier attempt the user then approved ("Listen online"): the
  /// instance may receive this text despite the privacy settings, for this
  /// playback only; an online device voice is allowed from now on.
  ///
  /// Once playback has started, [text] becomes the [lastUtterance] unless
  /// [remember] is false (e.g. a sample read by a settings preview).
  Future<void> toggle({
    required String id,
    required String text,
    required String languageCode,
    bool slow = false,
    bool remember = true,
    ConsentRequiredException? allowOnline,
  }) => _start(
    id: id,
    text: text,
    languageCode: languageCode,
    slow: slow,
    toggles: true,
    remember: remember,
    allowOnline: allowOnline,
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
    ConsentRequiredException? allowOnline,
  }) => _start(
    id: id,
    text: text,
    languageCode: languageCode,
    slow: slow,
    toggles: false,
    remember: remember,
    allowOnline: allowOnline,
  );

  /// Reads the [lastUtterance] again, slowly ([slowPlaybackRate]) and from
  /// the start, under its id (with the approval it was read with, if any).
  /// Mozhi clips come from the in-memory cache, so this usually needs no
  /// network. False when nothing was read aloud yet; throws like [speak].
  Future<bool> replaySlowly() async {
    final last = _last;
    if (last == null) return false;
    await speak(
      id: last.id,
      text: last.text,
      languageCode: last.languageCode,
      slow: true,
      allowOnline: _lastConsent,
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
  /// started. [preview]: device only, with that voice. [allowOnline]: see
  /// [toggle].
  Future<void> _start({
    required String id,
    required String text,
    required String languageCode,
    required bool slow,
    required bool toggles,
    required bool remember,
    ConsentRequiredException? allowOnline,
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
    _setRange(null);
    _setCurrent(id);
    try {
      if (previous != null) await _stopOutputs();
      final deviceOnly = preview != null || await loadPreferDeviceVoice();
      final settings = await loadSettings();
      final voice = preview != null
          ? preview.voice
          : settings.voiceFor(languageCode);
      final consent = allowOnline?.kind == ConsentKind.offlineOnly
          ? null
          : allowOnline;
      final voiceConsent = consent != null && isOnlineVoiceConsent(consent)
          ? consent
          : null;
      Object? cause;
      var deviceSkipped = false;
      for (final backend in [
        _Backend.device,
        if (!deviceOnly) _Backend.mozhi,
      ]) {
        if (generation != _generation) return;
        try {
          final outcome = switch (backend) {
            _Backend.mozhi => await _playMozhi(
              trimmed,
              languageCode,
              slow: slow,
              generation: generation,
              consent: voiceConsent == null ? consent : null,
            ),
            _Backend.device => await _speakOnDevice(
              trimmed,
              languageCode,
              offset: text.length - text.trimLeft().length,
              slow: slow,
              generation: generation,
              voice: voice,
              consent: voiceConsent,
              preview: preview != null,
            ),
          };
          if (outcome == _Outcome.started && remember) {
            _last = SpeechUtterance(
              id: id,
              text: trimmed,
              languageCode: languageCode,
            );
            _lastConsent = backend == _Backend.mozhi && voiceConsent == null
                ? consent
                : null;
          }
          if (outcome != _Outcome.skipped) return;
          if (backend == _Backend.device) deviceSkipped = true;
        } on Object catch (error) {
          cause ??= error;
          // A device voice that fails is not replaced by a server: the text
          // only leaves the device when the device has no voice for it.
          if (backend == _Backend.device) break;
        }
      }
      if (generation != _generation) return;
      final noEngine = deviceSkipped && await _hasNoDeviceEngine();
      if (generation != _generation) return;
      throw SpeechUnavailableException(
        languageCode,
        cause: cause,
        noDeviceEngine: noEngine,
      );
    } on Object {
      if (generation != _generation) return;
      _setCurrent(null);
      rethrow;
    }
  }

  /// Whether the device engine says the device has no speech engine at
  /// all ([DeviceTtsEngines.hasEngine]); false when it cannot tell.
  Future<bool> _hasNoDeviceEngine() async {
    if (!_device.isSupported) return false;
    if (_device case final DeviceTtsEngines engines) {
      try {
        return await engines.hasEngine() == false;
      } on Object {
        return false;
      }
    }
    return false;
  }

  /// Whether the device has no speech engine installed at all (an Android
  /// phone without any text-to-speech app, see [DeviceTtsEngines]): false
  /// when it has one or when that is unknown. Never throws.
  Future<bool> hasNoDeviceEngine() => _hasNoDeviceEngine();

  /// Fetches and starts the first chunk of [text]; completions play the
  /// rest ([_playNextChunk]).
  Future<_Outcome> _playMozhi(
    String text,
    String languageCode, {
    required bool slow,
    required int generation,
    required ConsentRequiredException? consent,
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
    )..consent = consent;
    await _setPlaybackRate(settings.speed(slow: slow));
    final bytes = await _fetch(playback.chunks.first, languageCode, consent);
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

  /// Starts fetching the chunk after the current one; null when it cannot
  /// be fetched (the playback then ends after the current chunk).
  void _prefetchNext(_MozhiPlayback playback) {
    if (!playback.hasNext) return;
    playback.next = _fetch(
      playback.chunks[playback.index + 1],
      playback.languageCode,
      playback.consent,
    ).then<Uint8List?>((bytes) => bytes, onError: (Object _) => null);
  }

  /// Called when [playback]'s current chunk has finished: plays the next
  /// one once it is fetched. When it could not be fetched or played the
  /// service becomes idle (toggle() has returned already; the device has no
  /// voice to take over, or Mozhi would not have been used).
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
    _setCurrent(null);
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

  /// Speaks [text] on the device with [voice] (null: the default voice),
  /// in parts of at most [_deviceChunkLength] code units ([offset]: where
  /// [text] starts in the text given to the service, for [spokenRanges]).
  /// An online voice reads only when allowed ([_allowVoice]; previews
  /// whenever the privacy mode allows the network).
  Future<_Outcome> _speakOnDevice(
    String text,
    String languageCode, {
    required int offset,
    required bool slow,
    required int generation,
    required DeviceVoice? voice,
    required ConsentRequiredException? consent,
    required bool preview,
  }) async {
    final resolved = await _deviceTag(languageCode);
    if (resolved == null) return _Outcome.skipped;
    if (generation != _generation) return _Outcome.superseded;
    await _device.setLanguage(resolved, voice: voice);
    if (generation != _generation) return _Outcome.superseded;
    await _allowVoice(_device.activeVoice, consent, preview: preview);
    if (generation != _generation) return _Outcome.superseded;
    await _device.setSpeechRate(slow: slow, rate: settings.rate);
    if (generation != _generation) return _Outcome.superseded;
    _deviceOwner = generation;
    final playback = _devicePlayback = _DevicePlayback(
      generation: generation,
      chunks: [
        for (final chunk in speechChunks(text, maxLength: _deviceChunkLength))
          SpeechChunk(chunk.start + offset, chunk.text),
      ],
    );
    // Utterances can end before speak() returns; interrupted ones never
    // emit, so any completion from now on belongs to this request.
    _playing = generation;
    _playingBackend = _Backend.device;
    try {
      await _device.speak(playback.current.text);
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

  /// Returns when the device voice [voice] (null: unknown, a voice on the
  /// device) may read: always when it is on the device; an online voice
  /// ([DeviceVoice.networkRequired]) never in [PrivacyMode.offlineOnly]
  /// (a [ConsentRequiredException] of [ConsentKind.offlineOnly]), else when
  /// the user allowed it before ([SpeechSettings.onlineVoices]), now
  /// ([consent] for it, which is remembered), or for a [preview]. Otherwise
  /// throws [onlineVoiceConsent] to ask the user with.
  Future<void> _allowVoice(
    DeviceVoice? voice,
    ConsentRequiredException? consent, {
    required bool preview,
  }) async {
    if (voice == null || !voice.networkRequired) return;
    if (_repository.privacyMode == PrivacyMode.offlineOnly) {
      throw onlineVoiceConsent(voice, kind: ConsentKind.offlineOnly);
    }
    if (preview || settings.allowsOnlineVoice(voice)) return;
    final asked = onlineVoiceConsent(voice);
    if (consent?.engineId != asked.engineId) throw asked;
    try {
      await _updateSettings((settings) => settings.withOnlineVoice(voice));
    } on Object {
      // Allowed until the app closes; the next start asks again.
    }
  }

  /// Called when [playback]'s current part has been read: reads the next
  /// one. When the engine rejects it, the service becomes idle.
  Future<void> _speakNextDeviceChunk(_DevicePlayback playback) async {
    final generation = playback.generation;
    playback.index++;
    try {
      await _device.speak(playback.current.text);
    } on Object {
      if (generation != _generation) return;
      _playing = null;
      _playingBackend = null;
      _setCurrent(null);
      return;
    }
    if (generation != _generation && _deviceOwner == generation) {
      await _device.stop();
    }
  }

  /// The device engine reads [range] of its current part.
  void _onDeviceProgress(SpokenRange range) {
    final playback = _devicePlayback;
    if (playback == null ||
        playback.generation != _generation ||
        _playing != playback.generation ||
        _playingBackend != _Backend.device) {
      return;
    }
    final chunk = playback.current;
    if (range.isEmpty || range.start < 0 || range.end > chunk.text.length) {
      return;
    }
    _setRange(range.shift(chunk.start));
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

  /// Stops playback and forgets what this service keeps in memory: the
  /// cached clips (spoken text), the last utterance ([lastUtterance]) and
  /// the loaded [settings] and [preferDeviceVoice], which read as the
  /// defaults until loaded again. Used after the stored data was deleted
  /// ("Delete all local data"), so nothing of it is played or written back.
  Future<void> forgetLocalData() async {
    _cache.clear();
    _last = null;
    _lastConsent = null;
    _mozhi = null;
    _devicePlayback = null;
    _settings = null;
    _settingsLoad = null;
    _preferDevice = null;
    _preferDeviceLoad = null;
    await stop();
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
    await _deviceProgress?.cancel();
    await _speaking.close();
    await _ranges.close();
    await _output.dispose();
    await _device.dispose();
  }

  /// The clip of [text], from the cache or Mozhi. A [consent] approved by
  /// the user is granted to this one request first.
  Future<Uint8List> _fetch(
    String text,
    String languageCode,
    ConsentRequiredException? consent,
  ) async {
    final key = '$languageCode\u0000$text';
    final cached = _cache.remove(key);
    if (cached != null) return _cache[key] = cached;

    if (consent != null) _repository.allowOnce(consent);
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
    } else if (_devicePlayback case final playback?
        when playback.generation == _playing && playback.hasNext) {
      unawaited(_speakNextDeviceChunk(playback));
      return;
    }
    _playing = null;
    _playingBackend = null;
    _setCurrent(null);
  }

  void _setCurrent(String? id) {
    if (id == null) _setRange(null);
    if (_current == id) return;
    _current = id;
    if (!_speaking.isClosed) _speaking.add(id);
  }

  void _setRange(SpokenRange? range) {
    if (_range == range) return;
    _range = range;
    if (!_ranges.isClosed) _ranges.add(range);
  }
}
