import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:mozhi/speech/browser_voices.dart' as browser;
import 'package:mozhi/speech/speech_language.dart';
import 'package:mozhi/speech/speech_settings.dart';
import 'package:mozhi/speech/spoken_range.dart';

export 'device_voice.dart';

/// Thrown when the device speech engine rejects a request (e.g. no voice
/// for the language, or the engine refused the text).
class DeviceTtsException implements Exception {
  const new(this.message);

  final String message;

  @override
  String toString() => 'DeviceTtsException: $message';
}

/// The platform's own text-to-speech engine. Works offline when the voice
/// data is installed, so it is the fallback when no Mozhi instance can read
/// the text aloud.
abstract interface class DeviceTts {
  /// Whether this platform has a speech engine at all (false on Linux and
  /// Fuchsia, where `flutter_tts` has no implementation).
  bool get isSupported;

  /// Whether [languageTag] (BCP-47, e.g. `fr`, `pt-BR`) can be spoken.
  /// Never throws; false when unknown.
  Future<bool> isLanguageAvailable(String languageTag);

  /// Selects the voice language for later [speak] calls, and [voice] (one
  /// of [voices] for this language) or, when null, the engine's default
  /// voice for the language. Throws [DeviceTtsException] when the engine
  /// rejects the language; a voice the engine rejects (e.g. uninstalled
  /// since it was chosen) is skipped and the default voice speaks.
  ///
  /// The default voice is a voice on the device whenever the language has
  /// one: when the engine would pick an online voice
  /// ([DeviceVoice.networkRequired]) by default, a voice on the device is
  /// selected instead.
  Future<void> setLanguage(String languageTag, {DeviceVoice? voice});

  /// The voice that reads after the last [setLanguage], as far as it is
  /// known: the chosen voice (as the engine lists it now), or the
  /// language's default voice when the engine tells which one that is (on
  /// the web; on Android when only online voices speak the language).
  /// Null when unknown, then a voice on the device reads.
  DeviceVoice? get activeVoice;

  /// Speech speed for later [speak] calls: [rate] times the engine's normal
  /// speed (see [SpeechSettings.rate]), slowed down by
  /// [SpeechSettings.slowFactor] when [slow].
  Future<void> setSpeechRate({required bool slow, double rate = 1});

  /// The installed voices that speak [languageTag] (BCP-47), best match
  /// first ([DeviceVoice.sortFor]). Never throws; empty when unknown.
  Future<List<DeviceVoice>> voices(String languageTag);

  /// Starts speaking [text]. Completes once the engine accepted it; throws
  /// when it was rejected. Call [stop] first to replace current speech.
  Future<void> speak(String text);

  /// Stops speaking. The interrupted utterance does not emit [onComplete].
  Future<void> stop();

  /// Emits each time an utterance ends on its own: it finished, or the
  /// engine failed while speaking it.
  Stream<void> get onComplete;

  /// Releases all resources; the engine cannot be used afterwards.
  Future<void> dispose();
}

/// A [DeviceTts] that can tell whether the device has a speech engine
/// installed at all: many Android phones without Google services ship none
/// (no "Speech Services by Google"), so no language has a voice until the
/// user installs one, such as SherpaTTS or RHVoice.
abstract interface class DeviceTtsEngines {
  /// False when the platform reports no speech engine (an Android phone
  /// without any text-to-speech app), true when it has one, null when it
  /// cannot tell (other platforms, or the engine list failed). Never
  /// throws.
  Future<bool?> hasEngine();
}

/// [DeviceTts] backed by `flutter_tts` (Android TextToSpeech, iOS/macOS
/// AVSpeechSynthesizer, Windows SAPI/WinRT, web `speechSynthesis`).
///
/// The [FlutterTts] instance is created lazily on first use, so
/// constructing this class never touches the platform plugin. Keep a single
/// instance app-wide: `flutter_tts` routes all callbacks to the most
/// recently created [FlutterTts].
///
/// Platform notes (from the `flutter_tts` 4.2.5 sources):
/// * Rates ([speechRate]): Android multiplies by 2 (0.5 = 1.0x) and Windows
///   maps 0.5 to its default, so a speed of x is 0.5·x there (slow at the
///   default rate: 0.3). iOS/macOS pass the value to
///   `AVSpeechUtterance.rate` (default 0.5, non-linear: small steps change
///   the speed a lot), so speeds are mapped gently around 0.5 (0.6 at 1.5x,
///   0.4 for slow at 1.0x). The web uses `SpeechSynthesisUtterance.rate`
///   (1.0 = normal) as is.
/// * Voices: every engine lists them (`getVoices`) and selects them by name
///   and locale (`setVoice`, Apple also by identifier). Selecting a
///   language resets the voice to the language's default, so [setLanguage]
///   applies the voice after the language, and re-selects the language to
///   go back to the default voice. Android voices that are not downloaded
///   are not listed. Android reports whether a voice needs the network;
///   the web plugin does not, so `browserVoices` (the browser's
///   `speechSynthesis` voices) tell which voices are not a `localService`.
///   The web plugin's default voice for a language is the browser's first
///   voice whose tag starts with it; when that is an online voice and the
///   language has one on the device, [setLanguage] selects that one.
/// * Availability: Android prefers `isLanguageInstalled` (voice data on the
///   device, usable offline); it needs an exact locale (`fr-FR`), so a bare
///   `fr` falls back to `isLanguageAvailable`. Windows has no availability
///   call, so the tag is resolved against `getLanguages`. Browsers load
///   voices asynchronously, so the first negative answer on the web is
///   re-checked once after [webVoicesDelay].
/// * Stopping makes every engine report a cancel/error for the interrupted
///   utterance; those are swallowed, and [speak] waits (up to
///   [settleTimeout]) for them first, because the web plugin drops `speak`
///   calls until the cancelled utterance has ended.
/// * Progress ([onProgress]): the plugin's progress handler reports the
///   word being read as offsets into the utterance's text (Android 8.0+
///   `onRangeStart`; the web's `boundary` events, whose word the plugin
///   runs on to the next ASCII space or punctuation; Android before 8.0
///   reports the whole text once). Reports for another text than the
///   latest [speak]'s, or while nothing is being spoken, are dropped;
///   the rest are cleaned with [cleanSpokenRange].
class FlutterTtsDeviceTts
    implements DeviceTts, DeviceTtsProgress, DeviceTtsEngines {
  new({
    FlutterTts Function()? createTts,
    TargetPlatform? platform,
    this._isWeb = kIsWeb,
    this.settleTimeout = const Duration(milliseconds: 500),
    this.webVoicesDelay = const Duration(milliseconds: 300),
    List<browser.BrowserVoice> Function()? browserVoices,
  }) : _createTts = createTts ?? FlutterTts.new,
       _platform = platform ?? defaultTargetPlatform,
       _browserVoices = browserVoices ?? browser.browserVoices;

  /// Longest wait in [speak] for the engine to confirm a [stop].
  final Duration settleTimeout;

  /// Delay before re-checking a language on the web (voices load lazily).
  final Duration webVoicesDelay;

  final FlutterTts Function() _createTts;
  final TargetPlatform _platform;
  final bool _isWeb;

  /// The browser's voices, with `localService` (web only).
  final List<browser.BrowserVoice> Function() _browserVoices;

  /// Tags with an installed voice on the device (Android).
  final Set<String> _installed = {};

  /// The default voice of [_language], when known (see [activeVoice]).
  DeviceVoice? _defaultVoice;
  final StreamController<void> _completions = StreamController.broadcast();
  final StreamController<SpokenRange> _progress = StreamController.broadcast();

  /// The text of the latest [speak], whose progress is reported.
  String? _utterance;

  /// Tags known to be available, mapped to the tag to pass to the engine.
  /// Negative answers are not cached: the user may install a voice.
  final Map<String, String> _resolved = {};

  FlutterTts? _tts;
  String? _language;
  DeviceVoice? _voice;
  double? _rate;

  /// Whether the browser has reported any voice yet (web only).
  bool _webVoicesLoaded = false;

  /// Whether an utterance was accepted and has not ended yet.
  bool _speaking = false;

  /// Stopped utterances whose cancel/error event is still outstanding.
  int _stopped = 0;
  Completer<void>? _settled;

  /// The `flutter_tts` speech rate on [platform] for [rate] times the
  /// normal speed, slowed down by [SpeechSettings.slowFactor] when [slow]
  /// (see class docs). Rounded to three decimals.
  static double speechRate({
    required TargetPlatform platform,
    required bool isWeb,
    required bool slow,
    double rate = 1,
  }) {
    final speed = slow ? rate * SpeechSettings.slowFactor : rate;
    final double value;
    if (isWeb) {
      value = speed.clamp(0.1, 10).toDouble();
    } else {
      final mapped = switch (platform) {
        TargetPlatform.iOS || TargetPlatform.macOS =>
          speed <= 1 ? 0.5 - (1 - speed) * 0.25 : 0.5 + (speed - 1) * 0.2,
        _ => 0.5 * speed,
      };
      value = mapped.clamp(0.05, 1).toDouble();
    }
    return (value * 1000).round() / 1000;
  }

  @override
  bool get isSupported =>
      _isWeb ||
      switch (_platform) {
        TargetPlatform.android ||
        TargetPlatform.iOS ||
        TargetPlatform.macOS ||
        TargetPlatform.windows => true,
        TargetPlatform.linux || TargetPlatform.fuchsia => false,
      };

  bool get _isAndroid => !_isWeb && _platform == TargetPlatform.android;
  bool get _isIOS => !_isWeb && _platform == TargetPlatform.iOS;
  bool get _isWindows => !_isWeb && _platform == TargetPlatform.windows;

  @override
  Stream<void> get onComplete => _completions.stream;

  @override
  Stream<SpokenRange> get onProgress => _progress.stream;

  FlutterTts get _engine {
    if (_tts case final tts?) return tts;
    if (!isSupported) {
      throw const DeviceTtsException('No speech engine on this platform.');
    }
    return _tts = _createTts()
      ..setCompletionHandler(_onEnded)
      ..setCancelHandler(_onEnded)
      ..setErrorHandler((_) => _onEnded())
      ..setProgressHandler(_onProgress);
  }

  /// A progress report of the engine: [start] to [end] of [text].
  void _onProgress(String text, int start, int end, String word) {
    if (!_speaking || _stopped > 0 || text != _utterance) return;
    final range = cleanSpokenRange(text, start, end);
    if (range != null && !_progress.isClosed) _progress.add(range);
  }

  /// On Android, whether `TextToSpeech.getEngines` lists any engine (the
  /// manifest declares the `TTS_SERVICE` query that this needs on Android
  /// 11+); null elsewhere.
  @override
  Future<bool?> hasEngine() async {
    if (!_isAndroid) return null;
    try {
      final engines = await _engine.getEngines;
      return engines is List ? engines.isNotEmpty : null;
    } on Object {
      return null;
    }
  }

  @override
  Future<bool> isLanguageAvailable(String languageTag) async {
    if (!isSupported) return false;
    try {
      return await _resolve(languageTag) != null;
    } on Object {
      return false;
    }
  }

  /// The tag to pass to `setLanguage` for [languageTag], or null when the
  /// engine has no voice for it.
  Future<String?> _resolve(String languageTag) async {
    if (_resolved[languageTag] case final resolved?) return resolved;
    final resolved = _isWindows
        ? await _matchEngineLanguage(languageTag)
        : await _isAvailable(languageTag)
        ? languageTag
        : null;
    if (resolved != null) _resolved[languageTag] = resolved;
    return resolved;
  }

  /// Windows: no availability call, and `setLanguage` wants the exact
  /// engine tag (`en-US`), so match against `getLanguages`.
  Future<String?> _matchEngineLanguage(String languageTag) async {
    final languages = await _engine.getLanguages;
    return matchLanguageTag(languageTag, [
      if (languages is List)
        for (final language in languages)
          if (language is String) language,
    ]);
  }

  Future<bool> _isAvailable(String languageTag) async {
    final tts = _engine;
    if (_isAndroid && await _isInstalled(tts, languageTag)) {
      _installed.add(languageTag);
      return true;
    }
    var available = await tts.isLanguageAvailable(languageTag) == true;
    if (!available && _isWeb && !_webVoicesLoaded) {
      await Future<void>.delayed(webVoicesDelay);
      available = await tts.isLanguageAvailable(languageTag) == true;
    }
    _webVoicesLoaded = _webVoicesLoaded || available;
    return available;
  }

  /// Android: voice data on the device (usable offline). Needs an exact
  /// locale such as `fr-FR`.
  Future<bool> _isInstalled(FlutterTts tts, String languageTag) async {
    try {
      return await tts.isLanguageInstalled(languageTag) == true;
    } on Object {
      return false;
    }
  }

  @override
  DeviceVoice? get activeVoice => _voice ?? _defaultVoice;

  @override
  Future<void> setLanguage(String languageTag, {DeviceVoice? voice}) async {
    final tts = _engine;
    final language = await _resolve(languageTag) ?? languageTag;
    if (language != _language) {
      if (await tts.setLanguage(language) == 0) {
        throw DeviceTtsException('No voice for "$languageTag".');
      }
      _language = language;
      _voice = null; // The engine picked the language's default voice.
      _defaultVoice = await _defaultVoiceOf(tts, language);
    }
    if (voice?.id == _voice?.id) return;
    if (voice != null && await _selectVoice(tts, voice)) {
      _voice = await _listed(voice);
      return;
    }
    if (_voice != null) {
      // Selecting the language again restores its default voice.
      await tts.setLanguage(language);
      _voice = null;
      _defaultVoice = await _defaultVoiceOf(tts, language);
    }
  }

  /// [voice] as the engine lists it now (whether it needs the network may
  /// have been unknown when it was chosen); [voice] itself when it is not
  /// listed or the listing fails.
  Future<DeviceVoice> _listed(DeviceVoice voice) async {
    if (!_isWeb && !_isAndroid) return voice;
    try {
      final listed = (await _engineVoices())
          .where((v) => v.id == voice.id)
          .firstOrNull;
      return listed == null
          ? voice
          : voice.withNetworkRequired(online: listed.networkRequired);
    } on Object {
      return voice;
    }
  }

  /// The voice the engine reads [language] with by default, when it tells
  /// (see [activeVoice]); selects a voice on the device instead of an
  /// online default where the language has one. Never throws.
  Future<DeviceVoice?> _defaultVoiceOf(FlutterTts tts, String language) async {
    try {
      if (_isWeb) {
        final all = await _engineVoices();
        final prefix = language.toLowerCase();
        // The web plugin's choice.
        final first = all
            .where((voice) => voice.locale.toLowerCase().startsWith(prefix))
            .firstOrNull;
        if (first == null || !first.networkRequired) return first;
        final local = DeviceVoice.sortFor(
          language,
          all.where(
            (voice) => voice.speaks(language) && !voice.networkRequired,
          ),
        ).firstOrNull;
        if (local != null && await _selectVoice(tts, local)) return local;
        return first;
      }
      if (_isAndroid && !_installed.contains(language)) {
        final voices = DeviceVoice.sortFor(
          language,
          (await _engineVoices()).where((voice) => voice.speaks(language)),
        );
        // Without voice data on the device, the engine reads online.
        if (voices.isNotEmpty && voices.every((v) => v.networkRequired)) {
          return voices.first;
        }
      }
    } on Object {
      // Unknown: a voice on the device reads.
    }
    return null;
  }

  /// Whether the engine accepted [voice].
  Future<bool> _selectVoice(FlutterTts tts, DeviceVoice voice) async {
    try {
      return await tts.setVoice(voice.toEngine()) != 0;
    } on Object {
      return false;
    }
  }

  @override
  Future<void> setSpeechRate({required bool slow, double rate = 1}) async {
    final tts = _engine;
    final value = speechRate(
      platform: _platform,
      isWeb: _isWeb,
      slow: slow,
      rate: rate,
    );
    if (value == _rate) return;
    await tts.setSpeechRate(value);
    _rate = value;
  }

  @override
  Future<List<DeviceVoice>> voices(String languageTag) async {
    if (!isSupported) return const [];
    try {
      var all = await _engineVoices();
      if (all.isEmpty && _isWeb) {
        // Browsers load their voices lazily.
        await Future<void>.delayed(webVoicesDelay);
        all = await _engineVoices();
      }
      return DeviceVoice.sortFor(
        languageTag,
        all.where((voice) => voice.speaks(languageTag)),
      );
    } on Object {
      return const [];
    }
  }

  /// The engine's voices; on the web marked as online when the browser
  /// says they are not a `localService`.
  Future<List<DeviceVoice>> _engineVoices() async {
    final voices = await _engine.getVoices;
    final listed = [
      if (voices is List)
        for (final voice in voices) ?DeviceVoice.fromEngine(voice),
    ];
    if (!_isWeb) return listed;
    final online = {
      for (final voice in _browserVoices())
        if (!voice.localService) (voice.name, voice.lang),
    };
    return [
      for (final voice in listed)
        voice.withNetworkRequired(
          online: online.contains((voice.name, voice.locale)),
        ),
    ];
  }

  @override
  Future<void> speak(String text) async {
    final tts = _engine;
    await _settle();
    if (_isIOS) await _useSpeakerSession(tts);
    _speaking = true;
    _utterance = text;
    try {
      if (await tts.speak(text) == 0) {
        throw const DeviceTtsException('The speech engine rejected the text.');
      }
    } on Object {
      _speaking = false;
      rethrow;
    }
  }

  /// Plays through the speaker even with the silent switch on, ducking
  /// other audio. Re-applied before each utterance because speech input
  /// switches the shared session to play-and-record.
  Future<void> _useSpeakerSession(FlutterTts tts) async {
    try {
      await tts.setIosAudioCategory(
        IosTextToSpeechAudioCategory.playback,
        const [IosTextToSpeechAudioCategoryOptions.duckOthers],
        IosTextToSpeechAudioMode.spokenAudio,
      );
    } on Object {
      // Best effort: speech still works with the current session.
    }
  }

  @override
  Future<void> stop() async {
    final tts = _tts;
    if (tts == null) return;
    if (_speaking) {
      _speaking = false;
      _stopped++;
    }
    await tts.stop();
  }

  /// Waits for the cancel events of stopped utterances (bounded by
  /// [settleTimeout]) so they are not mistaken for the next utterance's.
  Future<void> _settle() async {
    if (_stopped == 0) return;
    final settled = _settled ??= Completer<void>();
    await settled.future.timeout(
      settleTimeout,
      onTimeout: () {
        // Give up on events that never came.
        _stopped = 0;
        _settled = null;
      },
    );
  }

  void _onEnded() {
    if (_stopped > 0) {
      if (--_stopped == 0) {
        _settled?.complete();
        _settled = null;
      }
      return;
    }
    if (!_speaking) return;
    _speaking = false;
    if (!_completions.isClosed) _completions.add(null);
  }

  @override
  Future<void> dispose() async {
    final speaking = _speaking;
    _speaking = false;
    await _completions.close();
    await _progress.close();
    if (speaking) await _tts?.stop();
  }
}
