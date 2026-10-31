import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/view/widgets/link_launcher.dart';
import 'package:mozhi/speech/speech_error_message.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:translation_repository/translation_repository.dart';

/// Shows the snack bar for an [error] of [SpeechService.toggle] or
/// [SpeechService.speak] ([speechErrorMessage]).
///
/// When a Mozhi instance could read the text aloud with the user's consent
/// ([SpeechUnavailableException.onlineConsent]) and [onListenOnline] is
/// given, the snack bar names the instance, says that it receives the text,
/// and offers "Listen online" ([speechListenOnlineLabel]; short, so it fits
/// next to the message on a phone): [onListenOnline] then gets the consent,
/// to pass as `allowOnline` when calling the service again.
///
/// When the Mozhi servers failed or did not answer ([speechServersFailed])
/// and [onRetry] is given, the snack bar says so in plain words and offers
/// Retry, which reads the text again.
///
/// When the device has no speech engine at all ([speechNeedsEngine]) the
/// snack bar says so and offers "Get SherpaTTS" ([speechGetEngineUrl], in
/// the browser).
void showSpeechErrorSnackBar(
  BuildContext context,
  Object error, {
  void Function(ConsentRequiredException consent)? onListenOnline,
  VoidCallback? onRetry,
}) {
  final l10n = context.l10n;
  final consent = switch (error) {
    SpeechUnavailableException(:final onlineConsent?)
        when onListenOnline != null =>
      onlineConsent,
    _ => null,
  };
  // Without an action, the instance is not offered.
  final shown = switch (error) {
    SpeechUnavailableException()
        when consent == null && error.onlineConsent != null =>
      error.withoutCause(),
    _ => error,
  };
  final retry = consent == null && speechServersFailed(error) ? onRetry : null;
  final getEngine =
      consent == null && retry == null && speechNeedsEngine(shown);
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(
    SnackBar(
      content: Text(speechErrorMessage(l10n, shown)),
      // Long enough to read the notice and decide.
      duration: Duration(
        seconds: consent != null || getEngine
            ? 10
            : retry != null
            ? 6
            : 4,
      ),
      action: consent != null
          ? SnackBarAction(
              label: l10n.speechListenOnline,
              onPressed: () => onListenOnline!(consent),
            )
          : retry != null
          ? SnackBarAction(label: l10n.commonRetry, onPressed: retry)
          : getEngine
          ? SnackBarAction(
              key: const Key('speech_get_engine'),
              label: l10n.speechGetEngine,
              // The messenger outlives the button that failed.
              onPressed: () => unawaited(
                LinkLauncher.open(messenger.context, speechGetEngineUrl),
              ),
            )
          : null,
    ),
  );
}
