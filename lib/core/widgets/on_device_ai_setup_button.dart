import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/on_device_ai_access.dart';
import 'package:mozhi/l10n/l10n.dart';

/// Whether "Set up on-device AI" is offered above [context]: where
/// on-device AI runs (the Android app on a phone that can run it, see
/// [maybeOnDeviceModels]; not the web) and a model of its catalogue fits
/// this phone ([onDeviceAiModelFits]).
bool offersOnDeviceAiSetup(BuildContext context) {
  final models = maybeOnDeviceModels(context);
  return models != null && onDeviceAiModelFits(models);
}

/// "Set up on-device AI": opens the On-device AI settings above the
/// current screen ([openOnDeviceAiSettings]; back returns to it), for the
/// features that need an AI model with the general prompt profile
/// (proofreading, the dictionary). Show it only where
/// [offersOnDeviceAiSetup].
class OnDeviceAiSetupButton extends StatelessWidget {
  const new({this.filled = false, this.style, super.key});

  /// A filled button (the main action) instead of an outlined one.
  final bool filled;

  /// The button's style (e.g. the look's control shape).
  final ButtonStyle? style;

  @override
  Widget build(BuildContext context) {
    final label = Text(context.l10n.commonSetUpOnDeviceAi);
    const icon = Icon(Icons.memory);
    void open() => openOnDeviceAiSettings(context);
    return filled
        ? FilledButton.icon(
            style: style,
            onPressed: open,
            icon: icon,
            label: label,
          )
        : OutlinedButton.icon(
            style: style,
            onPressed: open,
            icon: icon,
            label: label,
          );
  }
}
