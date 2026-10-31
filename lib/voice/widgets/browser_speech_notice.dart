import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/voice/speech_input_service.dart';

/// Before the first voice input of the web app, says that the browser's
/// speech recognition hears what is said and that most browsers send the
/// audio to their maker (Chrome to Google), with "Use speech recognition"
/// and "Cancel" ([SpeechInputService.needsBrowserNotice]; once accepted it
/// is not shown again, [SpeechInputService.acceptBrowserNotice]).
///
/// Returns whether voice input may go on: true right away where no notice
/// is needed (the Android app, Offline only, accepted before).
Future<bool> confirmBrowserSpeech(
  BuildContext context,
  SpeechInputService service,
) async {
  if (!service.usesBrowserRecognizer) return true;
  if (!await service.needsBrowserNotice()) return true;
  if (!context.mounted) return false;
  final accepted = await showDialog<bool>(
    context: context,
    builder: (context) => const BrowserSpeechNoticeDialog(),
  );
  if (!(accepted ?? false)) return false;
  await service.acceptBrowserNotice();
  return true;
}

/// The dialog of [confirmBrowserSpeech]: pops `true` to go on.
class BrowserSpeechNoticeDialog extends StatelessWidget {
  const new({super.key});

  /// Key of the button that goes on.
  static const continueKey = Key('voice_browser_notice_continue');

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      icon: const Icon(Icons.public),
      title: Text(l10n.voiceBrowserNoticeTitle),
      content: Text(l10n.voiceBrowserNoticeBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          key: continueKey,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.voiceBrowserNoticeContinue),
        ),
      ],
    );
  }
}
