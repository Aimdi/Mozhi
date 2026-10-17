import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/undo_snack_bar.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/view/widgets/clear_history_dialog.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/widgets/choice_dialog.dart';
import 'package:mozhi/settings/view/widgets/delete_local_data.dart';
import 'package:mozhi/settings/view/widgets/history_data_actions.dart';
import 'package:mozhi/settings/view/widgets/http_proxy_dialog.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';
import 'package:translation_repository/translation_repository.dart';

/// "Never" / "After N days" for [retention].
String historyRetentionLabel(
  AppLocalizations l10n,
  HistoryRetention retention,
) => switch (retention.maxAge) {
  null => l10n.settingsHistoryRetentionNever,
  final maxAge => l10n.settingsHistoryRetentionDays(maxAge.inDays),
};

/// The Privacy settings: privacy mode, incognito, screen protection,
/// history saving, auto-delete, export and import, the recent language
/// pairs, what the user allowed to go to the network (language pairs,
/// cloud providers), the HTTP proxy and, after a divider, "Clear history"
/// and "Delete all local data".
///
/// Reads [SettingsCubit] and (for the history rows) [HistoryCubit].
class PrivacySettingsSection extends StatelessWidget {
  const new({required this.settings, super.key});

  final AppSettings settings;

  /// Whether the screen can be protected ("Hide content in recents & block
  /// screenshots" is Android's `FLAG_SECURE`).
  static bool get secureScreenSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<SettingsCubit>();
    final error = Theme.of(context).colorScheme.error;
    return SettingsSection(
      title: l10n.settingsSectionPrivacy,
      children: [
        _PrivacyModePicker(
          value: settings.privacyMode,
          onChanged: cubit.setPrivacyMode,
        ),
        SwitchListTile(
          key: const Key('settings_incognito'),
          secondary: const SettingsIcon(Icons.visibility_off_outlined),
          title: Text(l10n.settingsIncognito),
          subtitle: Text(l10n.settingsIncognitoSubtitle),
          value: settings.incognito,
          onChanged: (value) => cubit.setIncognito(enabled: value),
        ),
        if (secureScreenSupported)
          SwitchListTile(
            key: const Key('settings_secure_screen'),
            secondary: const SettingsIcon(Icons.screen_lock_portrait_outlined),
            title: Text(l10n.settingsSecureScreen),
            subtitle: Text(l10n.settingsSecureScreenSubtitle),
            value: settings.secureScreen,
            onChanged: (value) => cubit.setSecureScreen(enabled: value),
          ),
        SwitchListTile(
          secondary: const SettingsIcon(Icons.history),
          title: Text(l10n.settingsSaveHistory),
          subtitle: Text(l10n.settingsSaveHistorySubtitle),
          value: settings.saveHistory,
          onChanged: (value) => cubit.setSaveHistory(enabled: value),
        ),
        ListTile(
          key: const Key('settings_history_retention'),
          leading: const SettingsIcon(Icons.auto_delete_outlined),
          title: Text(l10n.settingsHistoryRetention),
          subtitle: Text(
            historyRetentionLabel(l10n, settings.historyRetention),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _pickRetention(context),
        ),
        ListTile(
          key: const Key('settings_export_history'),
          leading: const SettingsIcon(Icons.upload_outlined),
          title: Text(l10n.settingsExportHistory),
          subtitle: Text(l10n.settingsExportHistorySubtitle),
          onTap: () => showExportHistorySheet(context),
        ),
        ListTile(
          key: const Key('settings_import_history'),
          leading: const SettingsIcon(Icons.download_outlined),
          title: Text(l10n.settingsImportHistory),
          subtitle: Text(l10n.settingsImportHistorySubtitle),
          onTap: () => showImportHistoryDialog(context),
        ),
        _RecentPairsTile(count: settings.recentPairs.length),
        _NetworkPairsTile(pairs: settings.networkPairs),
        _ConsentedProviders(settings: settings),
        ListTile(
          key: const Key('settings_http_proxy'),
          leading: const SettingsIcon(Icons.vpn_lock_outlined),
          title: Text(l10n.settingsHttpProxy),
          subtitle: Text(settings.httpProxy ?? l10n.settingsHttpProxyOff),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _editProxy(context),
        ),
        const SettingsDangerDivider(),
        ListTile(
          key: const Key('settings_clear_history'),
          leading: SettingsIcon(Icons.delete_sweep_outlined, color: error),
          title: Text(l10n.historyClearMenu, style: TextStyle(color: error)),
          subtitle: Text(l10n.settingsClearHistorySubtitle),
          onTap: () => confirmClearHistory(context),
        ),
        ListTile(
          key: const Key('settings_delete_all_data'),
          leading: SettingsIcon(Icons.delete_forever_outlined, color: error),
          title: Text(
            l10n.settingsDeleteAllData,
            style: TextStyle(color: error),
          ),
          subtitle: Text(l10n.settingsDeleteAllDataSubtitle),
          onTap: () => confirmDeleteLocalData(context),
        ),
      ],
    );
  }

  Future<void> _pickRetention(BuildContext context) async {
    final l10n = context.l10n;
    final cubit = context.read<SettingsCubit>();
    final current = settings.historyRetention;
    final choice = await showDialog<HistoryRetention>(
      context: context,
      builder: (context) => ChoiceDialog<HistoryRetention>(
        title: l10n.settingsHistoryRetention,
        body: l10n.settingsHistoryRetentionDialogBody,
        initialValue: current,
        options: [
          for (final retention in HistoryRetention.values)
            ChoiceDialogOption(
              value: retention,
              title: Text(historyRetentionLabel(l10n, retention)),
            ),
        ],
      ),
    );
    if (choice == null || choice == current || !context.mounted) return;
    if (!await _confirmRetention(context, choice)) return;
    cubit.setHistoryRetention(choice);
  }

  /// Asks before a [retention] that deletes existing translations right
  /// away (e.g. "Never" -> "After 1 day"); true when nothing would be
  /// deleted or the user confirmed.
  static Future<bool> _confirmRetention(
    BuildContext context,
    HistoryRetention retention,
  ) async {
    final maxAge = retention.maxAge;
    if (maxAge == null) return true;
    final expired = context.read<HistoryCubit>().state.expiredCount(
      maxAge,
      now: DateTime.now(),
    );
    if (expired == 0) return true;
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final colors = Theme.of(context).colorScheme;
        return AlertDialog(
          icon: const Icon(Icons.auto_delete_outlined),
          title: Text(l10n.settingsHistoryRetentionConfirmTitle),
          content: Text(
            l10n.settingsHistoryRetentionConfirmBody(expired, maxAge.inDays),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(l10n.commonCancel),
            ),
            TextButton(
              key: const Key('settings_history_retention_confirm'),
              style: TextButton.styleFrom(foregroundColor: colors.error),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(l10n.commonDelete),
            ),
          ],
        );
      },
    );
    return confirmed ?? false;
  }

  Future<void> _editProxy(BuildContext context) async {
    final l10n = context.l10n;
    final cubit = context.read<SettingsCubit>();
    final messenger = ScaffoldMessenger.maybeOf(context);
    final current = settings.httpProxy;
    final choice = await showDialog<HttpProxyChoice>(
      context: context,
      builder: (_) => HttpProxyDialog(initialValue: current),
    );
    if (choice == null || choice.proxy == current) return;
    cubit.setHttpProxy(choice.proxy);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          choice.proxy == null
              ? l10n.settingsHttpProxyRemoved
              : l10n.settingsHttpProxySaved,
        ),
      ),
    );
  }
}

/// The privacy mode as radio rows with a one-line explanation each.
class _PrivacyModePicker extends StatelessWidget {
  const new({required this.value, required this.onChanged});

  final PrivacyMode value;
  final ValueChanged<PrivacyMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final options = [
      (
        PrivacyMode.offlineOnly,
        Icons.wifi_off_outlined,
        l10n.settingsPrivacyModeOfflineOnly,
        l10n.settingsPrivacyModeOfflineOnlySubtitle,
      ),
      (
        PrivacyMode.offlineFirst,
        Icons.offline_pin_outlined,
        l10n.settingsPrivacyModeOfflineFirst,
        l10n.settingsPrivacyModeOfflineFirstSubtitle,
      ),
      (
        PrivacyMode.online,
        Icons.public,
        l10n.settingsPrivacyModeOnline,
        l10n.settingsPrivacyModeOnlineSubtitle,
      ),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The visible title names the group below (WCAG 1.3.1, 4.1.2).
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ExcludeSemantics(
              child: Text(
                l10n.settingsPrivacyMode,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
          ),
          Semantics(
            container: true,
            explicitChildNodes: true,
            label: l10n.settingsPrivacyMode,
            child: RadioGroup<PrivacyMode>(
              groupValue: value,
              onChanged: (mode) {
                if (mode != null && mode != value) onChanged(mode);
              },
              child: Column(
                children: [
                  for (final (mode, icon, title, subtitle) in options)
                    RadioListTile<PrivacyMode>(
                      key: Key('settings_privacy_mode_${mode.name}'),
                      value: mode,
                      title: Text(title),
                      subtitle: Text(subtitle),
                      secondary: SettingsIcon(icon),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Clear recent language pairs" (disabled without any), undoable.
class _RecentPairsTile extends StatelessWidget {
  const new({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListTile(
      key: const Key('settings_clear_recent_pairs'),
      leading: const SettingsIcon(Icons.swap_horiz),
      title: Text(l10n.settingsClearRecentPairs),
      subtitle: Text(l10n.settingsRecentPairsSummary(count)),
      enabled: count > 0,
      onTap: () => _clear(context),
    );
  }

  void _clear(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<SettingsCubit>();
    final previous = cubit.state.recentPairs;
    cubit.clearRecentPairs();
    showUndoSnackBar(
      context,
      message: l10n.settingsRecentPairsCleared,
      onUndo: () => cubit.update(
        (current) => current.copyWith(
          recentPairs: List.unmodifiable(
            [
              ...current.recentPairs,
              ...previous.where((p) => !current.recentPairs.contains(p)),
            ].take(SettingsCubit.maxRecentPairs),
          ),
        ),
      ),
    );
  }
}

/// How many language pairs may use the network without asking (Offline
/// first), with a Clear action (undoable).
class _NetworkPairsTile extends StatelessWidget {
  const new({required this.pairs});

  final List<String> pairs;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListTile(
      key: const Key('settings_network_pairs'),
      leading: const SettingsIcon(Icons.swap_horiz),
      title: Text(l10n.settingsNetworkPairs),
      subtitle: Text(l10n.settingsNetworkPairsSummary(pairs.length)),
      trailing: pairs.isEmpty
          ? null
          : TextButton(
              onPressed: () => _clear(context),
              child: Text(
                l10n.commonClear,
                semanticsLabel: l10n.settingsNetworkPairsClearTooltip,
              ),
            ),
    );
  }

  void _clear(BuildContext context) {
    final cubit = context.read<SettingsCubit>();
    final previous = cubit.state.networkPairs;
    cubit.clearNetworkPairs();
    showUndoSnackBar(
      context,
      message: context.l10n.settingsNetworkPairsCleared,
      onUndo: () => cubit.update(
        (current) => current.copyWith(
          networkPairs: List.unmodifiable({
            ...current.networkPairs,
            ...previous,
          }),
        ),
      ),
    );
  }
}

/// The cloud providers the user agreed to send text to, each with Revoke
/// (undoable).
class _ConsentedProviders extends StatelessWidget {
  const new({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final ids = settings.consentedProviders;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          key: const Key('settings_consented_providers'),
          leading: const SettingsIcon(Icons.cloud_outlined),
          title: Text(l10n.settingsConsentedProviders),
          subtitle: ids.isEmpty
              ? Text(l10n.settingsConsentedProvidersNone)
              : null,
        ),
        for (final id in ids)
          ListTile(
            key: Key('settings_consent_$id'),
            // Lines up with the titles above.
            leading: const SizedBox(width: 24),
            title: Text(_name(id)),
            trailing: TextButton(
              onPressed: () => _revoke(context, id),
              child: Text(
                l10n.settingsConsentRevoke,
                semanticsLabel: l10n.settingsConsentRevokeLabel(_name(id)),
              ),
            ),
          ),
      ],
    );
  }

  /// The provider's name, or [id] for a provider that no longer exists.
  String _name(String id) {
    for (final provider in settings.providers) {
      if (provider.id == id) return provider.name;
    }
    return id;
  }

  void _revoke(BuildContext context, String id) {
    final cubit = context.read<SettingsCubit>()..revokeProviderConsent(id);
    showUndoSnackBar(
      context,
      message: context.l10n.settingsConsentRevoked(_name(id)),
      onUndo: () => cubit.consentToProvider(id),
    );
  }
}
