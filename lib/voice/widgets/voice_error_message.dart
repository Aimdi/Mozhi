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
/// has no speech recognition"), and a denied microphone, a language the
/// recogniser lacks and a network failure get the browser's advice (its
/// site settings; nothing to install, no on-device recognition there).
String voiceInputErrorMessage(
  AppLocalizations l10n,
  SpeechInputFailure failure, {
  bool onDevice = false,
  bool offlineModelDownloadable = false,
  bool isWeb = kIsWeb,
}) => switch (failure) {
  SpeechInputFailure.permissionDenied =>
    isWeb ? l10n.voiceErrorPermissionWeb : l10n.voiceErrorPermission,
  SpeechInputFailure.languageUnavailable =>
    isWeb
        ? l10n.voiceErrorLanguageWeb
        : onDevice
        ? l10n.voiceErrorLanguageOnDevice
        : l10n.voiceErrorLanguage,
  SpeechInputFailure.recognizerUnavailable =>
    offlineModelDownloadable
        ? l10n.voiceErrorUnavailableOfflineModel
        : isWeb
        ? l10n.voiceErrorUnavailableBrowser
        : l10n.voiceErrorUnavailable,
  SpeechInputFailure.audio => l10n.voiceErrorAudio,
  SpeechInputFailure.noMatch => l10n.voiceErrorNoMatch,
  SpeechInputFailure.network =>
    isWeb ? l10n.voiceErrorNetworkWeb : l10n.voiceErrorNetwork,
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
  final message = voiceInputErrorMessage(
    l10n,
    failure,
    onDevice: onDevice,
    offlineModelDownloadable: needsModel,
  );
  final fix = voiceInputErrorAction(
    context,
    failure,
    offlineSupported: offlineSupported,
  );
  final action = fix == null
      ? null
      : SnackBarAction(
          key: fix.key,
          label: fix.label,
          onPressed: fix.onPressed,
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
        action: action,
      ),
    );
}

/// What the user can do about a voice input [failure] right away, as
/// [showVoiceInputErrorSnackBar] offers it: "Download model" where an
/// offline speech model helps (the download offer where Whisper runs, else
/// the voice input settings, with a [GoRouter] above [context]), "Open
/// settings" for a denied microphone in the Android app; null when there
/// is nothing to tap (e.g. a browser's site settings, which only the
/// browser opens).
({String label, Key? key, VoidCallback onPressed})? voiceInputErrorAction(
  BuildContext context,
  SpeechInputFailure failure, {
  required bool offlineSupported,
}) {
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
  if (offline != null && service != null && navigator != null) {
    return (
      label: l10n.voiceDownloadModelAction,
      key: voiceDownloadModelActionKey,
      onPressed: () => unawaited(
        offerVoiceModel(
          navigator.context,
          service: service,
          offline: offline,
          failure: failure,
        ),
      ),
    );
  }
  if (router != null) {
    return (
      label: l10n.voiceDownloadModelAction,
      key: voiceDownloadModelActionKey,
      onPressed: () => unawaited(router.push<void>(voiceSettingsLocation)),
    );
  }
  if (failure == SpeechInputFailure.permissionDenied &&
      SystemAppSettings.isSupported) {
    return (
      label: l10n.commonOpenAppSettings,
      key: voiceOpenSettingsActionKey,
      onPressed: () => unawaited(SystemAppSettings.open()),
    );
  }
  return null;
}

/// Key of the "Download model" action of a missing offline speech model.
const voiceDownloadModelActionKey = Key('voice_download_model');

/// Key of the "Open settings" action of a denied microphone.
const voiceOpenSettingsActionKey = Key('voice_open_settings');

SpeechInputService? _speechInputOf(BuildContext context) {
  try {
    return context.read<SpeechInputService>();
  } on ProviderNotFoundException {
    return null;
  }
}
