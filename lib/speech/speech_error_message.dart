import 'package:mozhi/core/network/network_policy.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:translation_repository/translation_repository.dart';

/// User-facing message for an error thrown by [SpeechService.toggle]:
/// * an online device voice that the user has not allowed yet
///   ([SpeechService.isOnlineVoiceConsent]): it names the voice and who
///   receives the text ([AppLocalizations.speechOnlineVoiceConsent]; offer
///   [speechListenOnlineLabel] as the action), and in offline-only mode
///   that it may not read ([AppLocalizations.speechOnlineVoiceOfflineOnly]);
/// * no device voice, but a Mozhi instance could read the text with the
///   user's consent ([SpeechUnavailableException.onlineConsent]):
///   [AppLocalizations.speechUnavailableOnline], naming the instance
///   (offer [speechListenOnlineLabel] as the action);
/// * no device voice in offline-only mode:
///   [AppLocalizations.speechUnavailableOfflineOnly];
/// * Mozhi refused by the network policy (plain http, `.onion` without a
///   proxy): that policy's message ([describeNetworkPolicyError]);
/// * the Mozhi servers failed or did not answer ([speechServersFailed]):
///   [AppLocalizations.speechErrorServersUnavailable], in plain words and
///   without an HTTP status, like the translator's "Volunteer servers
///   unavailable" (offer Retry);
/// * otherwise [AppLocalizations.speechUnavailable] when no voice can read
///   the language, else the generic [AppLocalizations.translateSpeechError].
String speechErrorMessage(AppLocalizations l10n, Object error) =>
    switch (error) {
      SpeechUnavailableException(cause: final ConsentRequiredException consent)
          when SpeechService.isOnlineVoiceConsent(consent) =>
        _onlineVoiceMessage(l10n, consent),
      SpeechUnavailableException(onlineConsent: final consent?) =>
        l10n.speechUnavailableOnline(speechConsentHost(consent)),
      SpeechUnavailableException(
        cause: ConsentRequiredException(kind: ConsentKind.offlineOnly),
      ) =>
        l10n.speechUnavailableOfflineOnly,
      SpeechUnavailableException(:final cause) =>
        describeNetworkPolicyError(l10n, cause) ??
            (speechServersFailed(error)
                ? l10n.speechErrorServersUnavailable
                : l10n.speechUnavailable),
      _ => l10n.translateSpeechError,
    };

/// Whether [error] (of [SpeechService.toggle]) says the Mozhi servers
/// could not read the text aloud just now: every server failed
/// (`AllInstancesFailedException`), or the server got no answer through (no
/// connection, the Mozhi client's timeout). Trying again later may work,
/// unlike for a language no voice reads, a refusal by the network policy or
/// the privacy settings.
bool speechServersFailed(Object error) => switch (error) {
  SpeechUnavailableException(:final cause?)
      when NetworkPolicyError.of(cause) == null =>
    switch (cause) {
      AllInstancesFailedException() => true,
      MozhiApiException(statusCode: null, isRetryable: true) => true,
      _ => false,
    },
  _ => false,
};

/// What an online voice consent ([SpeechService.isOnlineVoiceConsent]) is
/// about.
String _onlineVoiceMessage(
  AppLocalizations l10n,
  ConsentRequiredException consent,
) {
  final online = SpeechService.onlineVoiceOf(consent);
  final variant = online?.engineVariant;
  final voice = variant == null
      ? online?.name ?? ''
      : l10n.speechVoiceVariant(variant.toUpperCase());
  if (consent.kind == ConsentKind.offlineOnly) {
    return l10n.speechOnlineVoiceOfflineOnly(voice);
  }
  final provider = speechConsentHost(consent);
  return provider.isEmpty
      ? l10n.speechOnlineVoiceConsentUnknown(voice)
      : l10n.speechOnlineVoiceConsent(voice, provider);
}

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
