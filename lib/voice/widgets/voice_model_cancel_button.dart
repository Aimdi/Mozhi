import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';

/// "Cancel" next to the progress of a speech model download (the voice
/// input settings, the download offer), in the look of the offline
/// languages' cancel button: a 48 dp text button whose tooltip and
/// screen-reader label name the model ([model], its display name).
class VoiceModelCancelButton extends StatelessWidget {
  const new({required this.model, required this.onPressed, super.key});

  /// Key of the button.
  static const buttonKey = Key('voice_model_cancel_download');

  /// The display name of the model being downloaded (e.g. "Fast").
  final String model;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final label = l10n.voiceModelCancelDownloadTooltip(model);
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        enabled: onPressed != null,
        onTap: onPressed,
        child: TextButton(
          key: buttonKey,
          style: TextButton.styleFrom(
            minimumSize: const Size(48, 48),
            tapTargetSize: MaterialTapTargetSize.padded,
          ),
          onPressed: onPressed,
          child: Text(l10n.commonCancel),
        ),
      ),
    );
  }
}
