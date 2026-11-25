import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/notification_translate/cubit/notification_translate_settings_cubit.dart';
import 'package:mozhi/notification_translate/data/notification_translate_controls.dart';
import 'package:mozhi/settings/view/widgets/choice_dialog.dart';
import 'package:mozhi/settings/view/widgets/settings_search.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';
import 'package:translation_repository/translation_repository.dart';

/// Anchors ([SettingsAnchor.id]) of notification translation settings.
abstract final class NotificationTranslateAnchors {
  static const translateNotifications = 'translate_notifications';
}

/// Opt-in offline notification translation setting under Settings › General.
class NotificationTranslateSettingsSection extends StatelessWidget {
  const new({this.controls, this.offline, super.key});

  final NotificationTranslateControls? controls;
  final OfflineTranslator? offline;

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
    final resolvedOffline = offline ?? _maybeOffline(context);
    return BlocProvider(
      create: (_) {
        final cubit = NotificationTranslateSettingsCubit(
          controls: controls,
          offline: resolvedOffline,
        );
        unawaited(cubit.refresh());
        return cubit;
      },
      child: _NotificationTranslateSettingsView(offline: resolvedOffline),
    );
  }

  static OfflineTranslator? _maybeOffline(BuildContext context) {
    try {
      return context.read<OfflineTranslator>();
    } on ProviderNotFoundException {
      return null;
    }
  }
}

class _NotificationTranslateSettingsView extends StatefulWidget {
  const new({this.offline});

  final OfflineTranslator? offline;

  @override
  State<_NotificationTranslateSettingsView> createState() =>
      _NotificationTranslateSettingsViewState();
}

class _NotificationTranslateSettingsViewState
    extends State<_NotificationTranslateSettingsView> {
  static const _followTranslateTab = '';

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

  Future<void> _pickTargetLanguage(
    NotificationTranslateSettingsState state,
  ) async {
    final l10n = context.l10n;
    final cubit = context.read<NotificationTranslateSettingsCubit>();
    final current = state.status.targetLanguage ?? _followTranslateTab;

    final codes =
        <String>{
          ...state.downloadedLanguages,
          if (state.downloadedLanguages.length < 2)
            ...?widget.offline?.supportedLanguages,
          if (current.isNotEmpty) current,
        }.toList()..sort(
          (a, b) =>
              LanguageCatalog.nameOf(a).compareTo(LanguageCatalog.nameOf(b)),
        );

    final choice = await showDialog<String>(
      context: context,
      builder: (context) => ChoiceDialog<String>(
        title: l10n.settingsNotificationTranslateTargetLanguage,
        body: l10n.settingsNotificationTranslateTargetDialogBody,
        initialValue: current,
        options: [
          ChoiceDialogOption(
            value: _followTranslateTab,
            title: Text(l10n.settingsNotificationTranslateTargetFollowApp),
          ),
          for (final code in codes)
            ChoiceDialogOption(
              value: code,
              title: Text(LanguageCatalog.nameOf(code)),
            ),
        ],
      ),
    );
    if (choice == null || choice == current || !mounted) return;
    await cubit.setTargetLanguage(
      choice == _followTranslateTab ? null : choice,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final cubit = context.read<NotificationTranslateSettingsCubit>();
    final state = context.watch<NotificationTranslateSettingsCubit>().state;
    final targetCode = state.status.targetLanguage;
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
        if (state.loaded && !state.hasOfflineLanguages)
          ListTile(
            key: const Key('settings_notification_translate_no_offline_hint'),
            leading: Icon(
              Icons.info_outline,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            title: Text(
              l10n.settingsNotificationTranslateNoOfflineHint,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (state.status.isActive && !state.status.notificationsAllowed)
          ListTile(
            key: const Key('settings_notification_translate_post_denied'),
            leading: Icon(
              Icons.notifications_off_outlined,
              color: theme.colorScheme.error,
            ),
            title: Text(
              l10n.settingsNotificationTranslateNotificationsDenied,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
            onTap: () => unawaited(cubit.requestNotificationPermission()),
          ),
        ListTile(
          key: const Key('settings_notification_translate_target_language'),
          leading: const SettingsIcon(Icons.translate_outlined),
          title: Text(l10n.settingsNotificationTranslateTargetLanguage),
          subtitle: Text(
            targetCode == null
                ? l10n.settingsNotificationTranslateTargetFollowApp
                : LanguageCatalog.nameOf(targetCode),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => unawaited(_pickTargetLanguage(state)),
        ),
        if (state.status.mutedPackages.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 16, 4),
            child: Text(
              l10n.settingsNotificationTranslateMutedApps,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          for (final packageName in state.status.mutedPackages)
            ListTile(
              key: ValueKey(
                'settings_notification_translate_muted_$packageName',
              ),
              leading: const SettingsIcon(Icons.notifications_paused_outlined),
              title: Text(packageName),
              trailing: TextButton(
                onPressed: () =>
                    unawaited(cubit.setPackageMuted(packageName, muted: false)),
                child: Text(l10n.settingsNotificationTranslateUnmute),
              ),
            ),
        ],
      ],
    );
  }
}
