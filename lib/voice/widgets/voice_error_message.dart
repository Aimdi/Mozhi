import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/voice/speech_input_state.dart';

/// User-facing explanation for a voice input [failure].
///
/// [onDevice] selects the on-device wording for
/// [SpeechInputFailure.languageUnavailable]; [offlineModelDownloadable]
/// (an offline speech model can be installed here) adds to
/// [SpeechInputFailure.recognizerUnavailable] that one can be downloaded.
String voiceInputErrorMessage(
  AppLocalizations l10n,
  SpeechInputFailure failure, {
  bool onDevice = false,
  bool offlineModelDownloadable = false,
}) => switch (failure) {
  SpeechInputFailure.permissionDenied => l10n.voiceErrorPermission,
  SpeechInputFailure.languageUnavailable =>
    onDevice ? l10n.voiceErrorLanguageOnDevice : l10n.voiceErrorLanguage,
  SpeechInputFailure.recognizerUnavailable =>
    offlineModelDownloadable
        ? l10n.voiceErrorUnavailableOfflineModel
        : l10n.voiceErrorUnavailable,
  SpeechInputFailure.audio => l10n.voiceErrorAudio,
  SpeechInputFailure.noMatch => l10n.voiceErrorNoMatch,
  SpeechInputFailure.network => l10n.voiceErrorNetwork,
  SpeechInputFailure.busy => l10n.voiceErrorBusy,
  SpeechInputFailure.offlineModelMissing => l10n.voiceErrorOfflineModel,
  SpeechInputFailure.offlineUnavailable => l10n.voiceErrorOfflineOnly,
  SpeechInputFailure.unknown => l10n.voiceErrorGeneric,
};

/// Whether installing an offline speech model fixes [failure]: it is
/// missing, or the device has no speech recogniser and
/// [offlineSupported] (`SpeechInputService.isOfflineSupported`).
bool voiceInputFailureNeedsOfflineModel(
  SpeechInputFailure failure, {
  required bool offlineSupported,
}) =>
    failure == SpeechInputFailure.offlineModelMissing ||
    (offlineSupported && failure == SpeechInputFailure.recognizerUnavailable);
