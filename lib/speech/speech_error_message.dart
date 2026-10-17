import 'package:mozhi/core/network/network_policy.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:translation_repository/translation_repository.dart';

/// User-facing message for an error thrown by [SpeechService.toggle]:
/// * no device voice, but a Mozhi instance could read the text with the
///   user's consent ([SpeechUnavailableException.onlineConsent]):
///   [AppLocalizations.speechUnavailableOnline], naming the instance
///   (offer [speechListenOnlineLabel] as the action);
/// * no device voice in offline-only mode:
///   [AppLocalizations.speechUnavailableOfflineOnly];
/// * Mozhi refused by the network policy (plain http, `.onion` without a
///   proxy): that policy's message ([describeNetworkPolicyError]);
/// * otherwise [AppLocalizations.speechUnavailable] when no voice can read
///   the language, else the generic [AppLocalizations.translateSpeechError].
String speechErrorMessage(AppLocalizations l10n, Object error) =>
    switch (error) {
      SpeechUnavailableException(onlineConsent: final consent?) =>
        l10n.speechUnavailableOnline(speechConsentHost(consent)),
      SpeechUnavailableException(
        cause: ConsentRequiredException(kind: ConsentKind.offlineOnly),
      ) =>
        l10n.speechUnavailableOfflineOnly,
      SpeechUnavailableException(:final cause) =>
        describeNetworkPolicyError(l10n, cause) ?? l10n.speechUnavailable,
      _ => l10n.translateSpeechError,
    };

/// "Listen online": the action that retries with `allowOnline: consent`,
/// or null when [error] offers none. The message
/// ([AppLocalizations.speechUnavailableOnline]) names the instance, so the
/// label stays short enough for a snack bar on a phone.
String? speechListenOnlineLabel(AppLocalizations l10n, Object error) =>
    switch (error) {
      SpeechUnavailableException(onlineConsent: _?) => l10n.speechListenOnline,
      _ => null,
    };

/// The server (or provider) a [consent] is about, for the user.
String speechConsentHost(ConsentRequiredException consent) =>
    switch (consent.destination) {
      SelfHostedDestination(:final host) => host,
      PublicInstanceDestination(:final host) => host,
      CloudProviderDestination(:final name) => name,
      OnDeviceDestination() => '',
    };
