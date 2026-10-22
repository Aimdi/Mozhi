import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/on_device_ai_access.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/on_device_ai/data/on_device_models.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';

/// Whether on-device AI can run here: its models are provided (the Android
/// app on a 64-bit phone; [maybeOnDeviceModels]).
bool onDeviceAiOffered(BuildContext context) =>
    maybeOnDeviceModels(context) != null;

/// "On-device AI" in the settings (Settings › AI, Translation engines):
/// what it is, or the models in use ("In use: Hy-MT2 1.8B"); opens the
/// On-device AI settings. Where on-device AI can't run ([models], default
/// [maybeOnDeviceModels], is null: the web, 32-bit phones) it says what it
/// needs and opens nothing.
class OnDeviceAiTile extends StatelessWidget {
  const new({this.models, super.key});

  final OnDeviceModels? models;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final models = this.models ?? maybeOnDeviceModels(context);
    if (models == null) {
      return ListTile(
        key: const Key('settings_on_device_ai_unavailable'),
        leading: const SettingsIcon(Icons.memory),
        title: Text(l10n.settingsOnDeviceAi),
        subtitle: Text(l10n.settingsOnDeviceAiUnavailable),
      );
    }
    return StreamBuilder<void>(
      stream: models.changes,
      builder: (context, _) {
        final names = onDeviceAiModelNames(models);
        return ListTile(
          key: const Key('settings_on_device_ai'),
          leading: const SettingsIcon(Icons.memory),
          title: Text(l10n.settingsOnDeviceAi),
          subtitle: Text(
            names.isEmpty
                ? l10n.settingsOnDeviceAiSubtitle
                : l10n.settingsOnDeviceAiInUse(names),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => openOnDeviceAiSettings(context),
        );
      },
    );
  }
}

/// "On-device AI" on the offline languages screen, where on-device AI can
/// run ([models], default [maybeOnDeviceModels]; nothing elsewhere): opens
/// its settings.
class OnDeviceAiOfflineEntry extends StatelessWidget {
  const new({this.models, super.key});

  final OnDeviceModels? models;

  @override
  Widget build(BuildContext context) {
    if ((models ?? maybeOnDeviceModels(context)) == null) {
      return const SizedBox.shrink();
    }
    final l10n = context.l10n;
    return ListTile(
      key: const Key('offline_on_device_ai'),
      leading: const Icon(Icons.memory),
      title: Text(l10n.offlineOnDeviceAiTitle),
      subtitle: Text(
        l10n.offlineOnDeviceAiSubtitle,
        style: TextStyle(color: AppPalette.of(context).secondaryText),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => openOnDeviceAiSettings(context),
    );
  }
}
