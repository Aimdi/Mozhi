import 'dart:async';

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
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

/// Location of the voice input settings (the offline speech models).
const voiceSettingsLocation = '/settings/voice';

/// Explains a voice input [failure] in a [SnackBar] (replacing the current
/// one), like the microphone buttons do: permanent failures stay longer and
/// can be closed; when an offline speech model would help
/// ([voiceInputFailureNeedsOfflineModel]) and a [GoRouter] is above
/// [context], it offers to open the voice input settings
/// ([voiceSettingsLocation]) to download one.
///
/// [onDevice] and [offlineSupported] are what [voiceInputErrorMessage] and
/// [voiceInputFailureNeedsOfflineModel] need (`SpeechInputService`'s
/// `preferOnDevice` and `isOfflineSupported`). Does nothing without a
/// [ScaffoldMessenger].
void showVoiceInputErrorSnackBar(
  BuildContext context,
  SpeechInputFailure failure, {
  required bool onDevice,
  required bool offlineSupported,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final l10n = context.l10n;
  final needsModel = voiceInputFailureNeedsOfflineModel(
    failure,
    offlineSupported: offlineSupported,
  );
  final router = needsModel ? GoRouter.maybeOf(context) : null;
  final message = voiceInputErrorMessage(
    l10n,
    failure,
    onDevice: onDevice,
    offlineModelDownloadable: needsModel,
  );
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        showCloseIcon: failure.isPermanent,
        duration: failure.isPermanent
            ? const Duration(seconds: 8)
            : const Duration(seconds: 4),
        action: router == null
            ? null
            : SnackBarAction(
                label: l10n.voiceDownloadModelAction,
                onPressed: () =>
                    unawaited(router.push<void>(voiceSettingsLocation)),
              ),
      ),
    );
}
