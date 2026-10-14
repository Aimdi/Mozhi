part of 'speech_settings_cubit.dart';

enum SpeechSettingsStatus { loading, ready }

class SpeechSettingsState extends Equatable {
  const new({
    this.status = SpeechSettingsStatus.loading,
    this.settings = const SpeechSettings(),
    this.deviceVoiceSupported = false,
    this.speakingId,
    this.voices = const {},
    this.loadingVoicesFor,
    this.previewError,
    this.failedPreviewId,
  });

  final SpeechSettingsStatus status;

  /// The speech rate and the chosen device voices.
  final SpeechSettings settings;

  /// Whether the device has a speech engine (voices can be chosen).
  final bool deviceVoiceSupported;

  /// The id `SpeechService` is reading aloud (null = idle), e.g.
  /// [SpeechSettingsCubit.ratePreviewId].
  final String? speakingId;

  /// The device voices listed per language tag ([speechLanguageTag]).
  final Map<String, List<DeviceVoice>> voices;

  /// Tag of the language whose voices are being listed.
  final String? loadingVoicesFor;

  /// Why the last preview could not be played (shown once).
  final Object? previewError;

  /// [SpeechService] id of the preview that failed with [previewError],
  /// e.g. [SpeechSettingsCubit.ratePreviewId] or a
  /// [SpeechSettingsCubit.voicePreviewId].
  final String? failedPreviewId;

  /// Whether [previewError] comes from a voice preview of the language
  /// [languageTag] (shown in the voice picker, not as a snackbar).
  bool voicePreviewFailed(String languageTag) =>
      previewError != null &&
      (failedPreviewId?.startsWith(
            SpeechSettingsCubit.voicePreviewPrefix(languageTag),
          ) ??
          false);

  /// Whether the speech rate preview is playing.
  bool get previewingRate => speakingId == SpeechSettingsCubit.ratePreviewId;

  SpeechSettingsState copyWith({
    SpeechSettingsStatus? status,
    SpeechSettings? settings,
    bool? deviceVoiceSupported,
    String? Function()? speakingId,
    Map<String, List<DeviceVoice>>? voices,
    String? Function()? loadingVoicesFor,
    Object? Function()? previewError,
    String? Function()? failedPreviewId,
  }) {
    return SpeechSettingsState(
      status: status ?? this.status,
      settings: settings ?? this.settings,
      deviceVoiceSupported: deviceVoiceSupported ?? this.deviceVoiceSupported,
      speakingId: speakingId != null ? speakingId() : this.speakingId,
      voices: voices ?? this.voices,
      loadingVoicesFor: loadingVoicesFor != null
          ? loadingVoicesFor()
          : this.loadingVoicesFor,
      previewError: previewError != null ? previewError() : this.previewError,
      failedPreviewId: failedPreviewId != null
          ? failedPreviewId()
          : this.failedPreviewId,
    );
  }

  @override
  List<Object?> get props => [
    status,
    settings,
    deviceVoiceSupported,
    speakingId,
    voices,
    loadingVoicesFor,
    previewError,
    failedPreviewId,
  ];
}
