import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/speech/speech_service.dart';

/// User-facing message for an error thrown by [SpeechService.toggle]:
/// [AppLocalizations.speechUnavailable] when no voice can read the
/// language, else the generic [AppLocalizations.translateSpeechError].
String speechErrorMessage(AppLocalizations l10n, Object error) =>
    error is SpeechUnavailableException
    ? l10n.speechUnavailable
    : l10n.translateSpeechError;
