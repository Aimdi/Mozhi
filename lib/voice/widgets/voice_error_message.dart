import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/platform/system_app_settings.dart';
import 'package:mozhi/voice/speech_input_service.dart';
import 'package:mozhi/voice/speech_input_state.dart';
import 'package:mozhi/voice/widgets/voice_model_offer.dart';

/// User-facing explanation for a voice input [failure].
///
/// [onDevice] selects the on-device wording for
/// [SpeechInputFailure.languageUnavailable]; [offlineModelDownloadable]
/// (an offline speech model can be installed here) adds to
/// [SpeechInputFailure.recognizerUnavailable] that one can be downloaded;
/// in the web app ([isWeb]) that failure is the browser's ("This browser
/// has no speech recognition").
String voiceInputErrorMessage(
  AppLocalizations l10n,
  SpeechInputFailure failure, {
  bool onDevice = false,
  bool offlineModelDownloadable = false,
  bool isWeb = kIsWeb,
}) => switch (failure) {
  SpeechInputFailure.permissionDenied => l10n.voiceErrorPermission,
  SpeechInputFailure.languageUnavailable =>
    onDevice ? l10n.voiceErrorLanguageOnDevice : l10n.voiceErrorLanguage,
  SpeechInputFailure.recognizerUnavailable =>
    offlineModelDownloadable
        ? l10n.voiceErrorUnavailableOfflineModel
        : isWeb
        ? l10n.voiceErrorUnavailableBrowser
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
/// can be closed. When an offline speech model would help
/// ([voiceInputFailureNeedsOfflineModel]) it offers "Download model":
/// where Whisper runs ([offlineSpeechOf] and a [SpeechInputService] above
/// [context]) that opens the download offer ([offerVoiceModel]), else,
/// with a [GoRouter] above, the voice input settings
/// ([voiceSettingsLocation]). A denied microphone offers "Open settings"
/// in the Android app ([SystemAppSettings]), since a microphone denied for
/// good ("Don't ask again") can only be allowed there.
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
  final offline = needsModel ? offlineSpeechOf(context) : null;
  final service = offline == null ? null : _speechInputOf(context);
  final router = needsModel ? GoRouter.maybeOf(context) : null;
  // The dialog opens over the navigator, which outlives the button.
  final navigator = Navigator.maybeOf(context);
  final message = voiceInputErrorMessage(
    l10n,
    failure,
    onDevice: onDevice,
    offlineModelDownloadable: needsModel,
  );
  final settings =
      failure == SpeechInputFailure.permissionDenied &&
      SystemAppSettings.isSupported;
  final SnackBarAction? action;
  if (offline != null && service != null && navigator != null) {
    action = SnackBarAction(
      label: l10n.voiceDownloadModelAction,
      onPressed: () => unawaited(
        offerVoiceModel(
          navigator.context,
          service: service,
          offline: offline,
          failure: failure,
        ),
      ),
    );
  } else if (router != null) {
    action = SnackBarAction(
      label: l10n.voiceDownloadModelAction,
      onPressed: () => unawaited(router.push<void>(voiceSettingsLocation)),
    );
  } else if (settings) {
    action = SnackBarAction(
      key: voiceOpenSettingsActionKey,
      label: l10n.commonOpenAppSettings,
      onPressed: () => unawaited(SystemAppSettings.open()),
    );
  } else {
    action = null;
  }
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        showCloseIcon: failure.isPermanent,
        duration: failure.isPermanent
            ? const Duration(seconds: 8)
            : const Duration(seconds: 4),
        action: action,
      ),
    );
}

/// Key of the "Open settings" action of a denied microphone.
const voiceOpenSettingsActionKey = Key('voice_open_settings');

SpeechInputService? _speechInputOf(BuildContext context) {
  try {
    return context.read<SpeechInputService>();
  } on ProviderNotFoundException {
    return null;
  }
}
