import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/notification_translate/cubit/notification_translate_settings_cubit.dart';
import 'package:mozhi/notification_translate/data/notification_translate_controls.dart';
import 'package:mozhi/settings/view/widgets/settings_search.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';

/// Anchors ([SettingsAnchor.id]) of notification translation settings.
abstract final class NotificationTranslateAnchors {
  static const translateNotifications = 'translate_notifications';
}

/// Opt-in offline notification translation setting under Settings › General.
class NotificationTranslateSettingsSection extends StatelessWidget {
  const new({this.controls, super.key});

  final NotificationTranslateControls? controls;

  static bool supported([NotificationTranslateControls? controls]) =>
      (controls ?? MethodChannelNotificationTranslateControls.instance)
          .isSupported;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final controls =
        this.controls ?? MethodChannelNotificationTranslateControls.instance;
    if (!controls.isSupported) {
      return SettingsSection(
        divider: false,
        children: [
          SettingsAnchor(
            id: NotificationTranslateAnchors.translateNotifications,
            child: ListTile(
              key: const Key('settings_notification_translate_unavailable'),
              leading: const SettingsIcon(Icons.notifications_none_outlined),
              title: Text(l10n.settingsNotificationTranslate),
              subtitle: Text(l10n.settingsNotificationTranslateUnavailable),
            ),
          ),
        ],
      );
    }
    return BlocProvider(
      create: (_) {
        final cubit = NotificationTranslateSettingsCubit(controls: controls);
        unawaited(cubit.refresh());
        return cubit;
      },
      child: const _NotificationTranslateSettingsView(),
    );
  }
}

class _NotificationTranslateSettingsView extends StatefulWidget {
  const new();

  @override
  State<_NotificationTranslateSettingsView> createState() =>
      _NotificationTranslateSettingsViewState();
}

class _NotificationTranslateSettingsViewState
    extends State<_NotificationTranslateSettingsView> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onResume: () {
        if (mounted) {
          unawaited(
            context.read<NotificationTranslateSettingsCubit>().refresh(),
          );
        }
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _toggle({required bool on}) async {
    final cubit = context.read<NotificationTranslateSettingsCubit>();
    if (!on) {
      await cubit.disable();
      return;
    }
    if (!cubit.state.status.hasAccess) {
      final l10n = context.l10n;
      final proceed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(l10n.settingsNotificationTranslatePermissionTitle),
          content: Text(l10n.settingsNotificationTranslatePermissionBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.settingsNotificationTranslatePermissionAction),
            ),
          ],
        ),
      );
      if (proceed != true || !mounted) return;
    }
    await cubit.enable();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<NotificationTranslateSettingsCubit>().state;
    return SettingsSection(
      divider: false,
      children: [
        SettingsAnchor(
          id: NotificationTranslateAnchors.translateNotifications,
          child: SwitchListTile(
            key: const Key('settings_notification_translate'),
            secondary: const SettingsIcon(Icons.notifications_active_outlined),
            title: Text(l10n.settingsNotificationTranslate),
            subtitle: Text(l10n.settingsNotificationTranslateSubtitle),
            value: state.status.isActive,
            onChanged: state.busy
                ? null
                : (value) => unawaited(_toggle(on: value)),
          ),
        ),
      ],
    );
  }
}
