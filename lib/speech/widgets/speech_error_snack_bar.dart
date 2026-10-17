import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
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
void showSpeechErrorSnackBar(
  BuildContext context,
  Object error, {
  void Function(ConsentRequiredException consent)? onListenOnline,
}) {
  final l10n = context.l10n;
  final consent = switch (error) {
    SpeechUnavailableException(:final onlineConsent?)
        when onListenOnline != null =>
      onlineConsent,
    _ => null,
  };
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        consent == null
            ? speechErrorMessage(
                l10n,
                // Without an action, the instance is not offered.
                switch (error) {
                  SpeechUnavailableException(:final languageCode)
                      when error.onlineConsent != null =>
                    SpeechUnavailableException(languageCode),
                  _ => error,
                },
              )
            : speechErrorMessage(l10n, error),
      ),
      // Long enough to read the notice and decide.
      duration: Duration(seconds: consent == null ? 4 : 10),
      action: consent == null
          ? null
          : SnackBarAction(
              label: l10n.speechListenOnline,
              onPressed: () => onListenOnline!(consent),
            ),
    ),
  );
}
