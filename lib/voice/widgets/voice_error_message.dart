import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/voice/speech_input_state.dart';

/// User-facing explanation for a voice input [failure].
///
/// [onDevice] selects the on-device wording for
/// [SpeechInputFailure.languageUnavailable].
String voiceInputErrorMessage(
  AppLocalizations l10n,
  SpeechInputFailure failure, {
  bool onDevice = false,
}) => switch (failure) {
  SpeechInputFailure.permissionDenied => l10n.voiceErrorPermission,
  SpeechInputFailure.languageUnavailable =>
    onDevice ? l10n.voiceErrorLanguageOnDevice : l10n.voiceErrorLanguage,
  SpeechInputFailure.recognizerUnavailable => l10n.voiceErrorUnavailable,
  SpeechInputFailure.audio => l10n.voiceErrorAudio,
  SpeechInputFailure.noMatch => l10n.voiceErrorNoMatch,
  SpeechInputFailure.network => l10n.voiceErrorNetwork,
  SpeechInputFailure.busy => l10n.voiceErrorBusy,
  SpeechInputFailure.offlineModelMissing => l10n.voiceErrorOfflineModel,
  SpeechInputFailure.offlineUnavailable => l10n.voiceErrorOfflineOnly,
  SpeechInputFailure.unknown => l10n.voiceErrorGeneric,
};
