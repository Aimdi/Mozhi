import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/platform/app_shell.dart';
import 'package:mozhi/platform/app_shell_scope.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';

/// "Keep the web app for offline use" (the web app only,
/// `AppSettings.offlineAppShell`): the switch, where the app's copy in
/// this browser is ([AppShell.status], announced as it changes) and, once
/// an update is ready, **Reload**.
class OfflineAppShellTile extends StatelessWidget {
  const new({required this.enabled, this.shell, super.key});

  /// The setting.
  final bool enabled;

  /// The shell (default: the one an `AppShellScope` provides).
  final AppShell? shell;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = AppPalette.of(context);
    final app = shell ?? appShellOf(context);
    return StreamBuilder<AppShellStatus>(
      stream: app.status,
      initialData: app.current,
      builder: (context, snapshot) {
        final status = snapshot.data ?? AppShellStatus.unsupported;
        final update = enabled && status == AppShellStatus.updateReady;
        final subtitle = !enabled
            ? l10n.settingsOfflineAppShellOff
            : switch (status) {
                AppShellStatus.unsupported =>
                  l10n.settingsOfflineAppShellUnavailable,
                AppShellStatus.installing =>
                  l10n.settingsOfflineAppShellInstalling,
                AppShellStatus.ready => l10n.settingsOfflineAppShellReady,
                AppShellStatus.updateReady =>
                  l10n.settingsOfflineAppShellUpdate,
              };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              key: const Key('settings_offline_app_shell'),
              secondary: const SettingsIcon(Icons.offline_pin_outlined),
              title: Text(l10n.settingsOfflineAppShell),
              subtitle: Semantics(
                liveRegion: true,
                child: Text(
                  subtitle,
                  key: const Key('settings_offline_app_shell_status'),
                  style: TextStyle(color: palette.secondaryText),
                ),
              ),
              value: enabled,
              onChanged: (value) => context
                  .read<SettingsCubit>()
                  .setOfflineAppShell(enabled: value),
            ),
            if (update)
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 56, end: 16),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FilledButton.tonalIcon(
                    key: const Key('settings_offline_app_shell_reload'),
                    onPressed: () => unawaited(app.applyUpdate()),
                    icon: const Icon(Icons.refresh),
                    label: Text(l10n.appShellReload),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
