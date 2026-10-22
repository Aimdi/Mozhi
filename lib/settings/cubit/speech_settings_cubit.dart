import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:mozhi/speech/speech_service.dart';

part 'speech_settings_state.dart';

/// Read-aloud settings: the speech rate and the device voice per language,
/// kept by [SpeechService] (which persists them), plus previews.
///
/// Reading the service never throws out of the cubit: a failing service
/// leaves the defaults and reports the error through [addError].
class SpeechSettingsCubit extends Cubit<SpeechSettingsState> {
  new(this._speech) : super(const SpeechSettingsState());

  /// [SpeechService] id of the speech rate preview.
  static const ratePreviewId = 'settings.speech.rate';

  /// Prefix of every preview id started here.
  static const _previewPrefix = 'settings.speech.';

  /// [SpeechService] id of the preview of [voice] (null: the default
  /// voice) for the language [languageTag].
  static String voicePreviewId(String languageTag, DeviceVoice? voice) =>
      '${voicePreviewPrefix(languageTag)}${voice?.id ?? ''}';

  /// Prefix of every [voicePreviewId] for the language [languageTag].
  static String voicePreviewPrefix(String languageTag) =>
      '${_previewPrefix}voice:$languageTag:';

  /// Whether [id] is a [voicePreviewId] (of any language).
  static bool isVoicePreviewId(String? id) =>
      id?.startsWith('${_previewPrefix}voice:') ?? false;

  final SpeechService _speech;
  StreamSubscription<String?>? _speaking;

  /// Text and language of the last rate preview, to replay it at a new rate.
  ({String text, String languageCode})? _ratePreview;

  /// Reads the stored settings and whether the device can speak, and
  /// follows what the service reads aloud. Then lists the device voices of
  /// the languages whose chosen voice has a technical engine name
  /// ([DeviceVoice.hasEngineName]), so it can be shown by number.
  Future<void> load() async {
    try {
      _speaking ??= _speech.speaking.listen((id) {
        if (!isClosed) emit(state.copyWith(speakingId: () => id));
      });
      final settings = await _speech.loadSettings();
      if (isClosed) return;
      emit(
        state.copyWith(
          status: SpeechSettingsStatus.ready,
          settings: settings,
          deviceVoiceSupported: _speech.deviceVoiceSupported,
          speakingId: () => _speech.current,
        ),
      );
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
      if (!isClosed) emit(state.copyWith(status: SpeechSettingsStatus.ready));
      return;
    }
    await _listChosenEngineVoices();
  }

  /// Lists the device voices of each language whose chosen voice has an
  /// engine name, quietly (no [SpeechSettingsState.loadingVoicesFor]).
  Future<void> _listChosenEngineVoices() async {
    for (final MapEntry(key: tag, value: voice)
        in state.settings.voices.entries) {
      if (!voice.hasEngineName || state.voices.containsKey(tag)) continue;
      final voices = await _speech.deviceVoices(tag);
      if (isClosed) return;
      if (state.voices.containsKey(tag)) continue;
      emit(
        state.copyWith(
          voices: Map.unmodifiable({...state.voices, tag: voices}),
        ),
      );
    }
  }

  /// Sets the speech rate (normalised to 0.5x-1.5x in 0.1 steps). The new
  /// rate applies even when it cannot be saved.
  Future<void> setRate(double rate) async {
    final settings = state.settings.copyWith(rate: rate);
    if (settings.rate == state.settings.rate) return;
    emit(state.copyWith(settings: settings));
    try {
      await _speech.setSpeechRate(settings.rate);
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
    }
  }

  /// Chooses the device [voice] for [languageCode] (null: the default
  /// voice). The choice applies even when it cannot be saved.
  Future<void> setVoice(String languageCode, DeviceVoice? voice) async {
    final settings = state.settings.withVoice(languageCode, voice);
    if (settings == state.settings) return;
    emit(state.copyWith(settings: settings));
    try {
      await _speech.setVoice(languageCode, voice);
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
    }
  }

  /// Forgets the online voices the user allowed to read aloud
  /// (`SpeechSettings.onlineVoices`): each asks again before it reads. It
  /// applies even when it cannot be saved.
  Future<void> forgetOnlineVoices() async {
    if (state.settings.onlineVoices.isEmpty) return;
    emit(
      state.copyWith(settings: state.settings.copyWith(onlineVoices: const {})),
    );
    try {
      await _speech.forgetOnlineVoices();
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
    }
  }

  /// Lists the device voices for [languageCode] into
  /// [SpeechSettingsState.voices] (again each time: voices can be
  /// installed meanwhile).
  Future<void> loadVoices(String languageCode) async {
    final tag = speechLanguageTag(languageCode);
    if (tag == null) return;
    emit(state.copyWith(loadingVoicesFor: () => tag));
    final voices = await _speech.deviceVoices(languageCode);
    if (isClosed) return;
    emit(
      state.copyWith(
        voices: Map.unmodifiable({...state.voices, tag: voices}),
        loadingVoicesFor: () => null,
      ),
    );
  }

  /// Reads [text] (in [languageCode]) at the current rate, or stops the
  /// rate preview when it is playing.
  Future<void> previewRate({
    required String text,
    required String languageCode,
  }) {
    _ratePreview = (text: text, languageCode: languageCode);
    return _preview(
      ratePreviewId,
      () => _speech.toggle(
        id: ratePreviewId,
        text: text,
        languageCode: languageCode,
        remember: false,
      ),
    );
  }

  /// Restarts the rate preview at the current rate when it is playing (e.g.
  /// once the rate slider is released).
  Future<void> refreshRatePreview() async {
    final preview = _ratePreview;
    if (preview == null || !state.previewingRate) return;
    await _preview(
      ratePreviewId,
      () => _speech.speak(
        id: ratePreviewId,
        text: preview.text,
        languageCode: preview.languageCode,
        remember: false,
      ),
    );
  }

  /// Reads [text] with the device [voice] (null: the default voice) for
  /// [languageCode], or stops that preview when it is playing.
  Future<void> previewVoice({
    required String languageCode,
    required String text,
    DeviceVoice? voice,
  }) {
    final tag = speechLanguageTag(languageCode) ?? languageCode;
    final id = voicePreviewId(tag, voice);
    return _preview(
      id,
      () => _speech.previewVoice(
        id: id,
        text: text,
        languageCode: languageCode,
        voice: voice,
      ),
    );
  }

  /// Runs the preview [id] with [play]; a failure becomes the
  /// [SpeechSettingsState.previewError].
  Future<void> _preview(String id, Future<void> Function() play) async {
    dismissPreviewError();
    try {
      await play();
    } on Object catch (error) {
      if (!isClosed) {
        emit(
          state.copyWith(previewError: () => error, failedPreviewId: () => id),
        );
      }
    }
  }

  /// Forgets the [SpeechSettingsState.previewError] (e.g. once the voice
  /// picker that showed it is closed).
  void dismissPreviewError() {
    if (isClosed ||
        (state.previewError == null && state.failedPreviewId == null)) {
      return;
    }
    emit(state.copyWith(previewError: () => null, failedPreviewId: () => null));
  }

  /// Stops a preview started here; other playback is left alone.
  Future<void> stopPreview() async {
    if (!(state.speakingId?.startsWith(_previewPrefix) ?? false)) return;
    try {
      await _speech.stop();
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
    }
  }

  @override
  Future<void> close() async {
    await stopPreview();
    await _speaking?.cancel();
    await super.close();
  }
}
