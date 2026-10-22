import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/backup/view/backup_section_labels.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/view/widgets/settings_search.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';
import 'package:mozhi/sync/cubit/sync_cubit.dart';
import 'package:mozhi/sync/data/sync_service.dart';
import 'package:mozhi/sync/models/sync_config.dart';
import 'package:mozhi/sync/models/sync_status.dart';
import 'package:mozhi/sync/view/sync_dialogs.dart';
import 'package:mozhi/sync/view/sync_setup_page.dart';
import 'package:mozhi/sync/view/sync_texts.dart';
import 'package:mozhi/sync/view/widgets/sync_fields.dart';
import 'package:translation_repository/translation_repository.dart'
    show PrivacyMode;

/// Anchors ([SettingsAnchor.id]) of the sync rows in Backup & sync.
abstract final class SyncAnchors {
  static const sync = 'sync';

  /// Words the settings search also finds the sync rows by (product
  /// names, not translated).
  static const keywords = [
    'WebDAV',
    'Nextcloud',
    'ownCloud',
    'Synology',
    'rclone',
  ];
}

/// The Sync part of **Settings › Backup & sync**: set up, or the status
/// of the last sync with **Sync now**, unlocking (a forgotten app password
/// or passphrase), what to sync, Wi-Fi only, changing the passphrase and
/// turning sync off. Shows nothing without a [SyncService] above it.
class SyncSettingsSection extends StatelessWidget {
  const new({this.divider = true, super.key});

  /// Whether a hairline closes the section.
  final bool divider;

  /// The app's [SyncService], or null (tests, builds without sync).
  static SyncService? serviceOf(BuildContext context) {
    try {
      return context.read<SyncService>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = serviceOf(context);
    if (service == null) return const SizedBox.shrink();
    return BlocProvider(
      create: (_) => SyncCubit(service),
      child: SettingsAnchor(
        id: SyncAnchors.sync,
        child: _SyncSettingsView(service: service, divider: divider),
      ),
    );
  }
}

class _SyncSettingsView extends StatelessWidget {
  const new({required this.service, required this.divider});

  final SyncService service;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final offlineOnly =
        context.select<SettingsCubit, PrivacyMode>(
          (cubit) => cubit.state.privacyMode,
        ) ==
        PrivacyMode.offlineOnly;
    final state = context.watch<SyncCubit>().state;
    final config = state.config;
    return SettingsSection(
      title: l10n.syncTitle,
      divider: divider,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.lg,
            AppSpacing.sm,
          ),
          child: Text(
            l10n.syncIntro,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        if (offlineOnly)
          ListTile(
            key: const Key('sync_offline_only'),
            leading: const SettingsIcon(Icons.cloud_off_outlined),
            title: Text(l10n.syncOfflineOnlyNotice),
          ),
        if (!state.loaded)
          const SizedBox.shrink()
        else if (config == null)
          ListTile(
            key: const Key('sync_set_up'),
            enabled: !offlineOnly,
            leading: const SettingsIcon(Icons.cloud_sync_outlined),
            title: Text(l10n.syncSetUp),
            subtitle: Text(l10n.syncSetUpSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => unawaited(showSyncSetup(context, service)),
          )
        else
          ..._rows(context, state, config, offlineOnly: offlineOnly),
      ],
    );
  }

  List<Widget> _rows(
    BuildContext context,
    SyncState state,
    SyncConfig config, {
    required bool offlineOnly,
  }) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final cubit = context.read<SyncCubit>();
    final failure = state.status.lastFailure;
    final need = !state.unlocked
        ? SyncUnlockNeed.both
        : switch (failure) {
            SyncFailure.passphraseChanged => SyncUnlockNeed.passphrase,
            SyncFailure.authFailed => SyncUnlockNeed.password,
            _ => null,
          };
    final canSync = state.unlocked && !state.running && !offlineOnly;
    final synced = [
      for (final id in cubit.sectionIds)
        if (config.syncs(id)) BackupSectionLabels.name(l10n, id),
    ];
    return [
      ListTile(
        key: const Key('sync_status'),
        leading: state.running
            ? const SyncSpinner(size: 24)
            : SettingsIcon(
                failure == null
                    ? Icons.cloud_done_outlined
                    : Icons.sync_problem_outlined,
                color: failure == null ? null : colors.error,
              ),
        title: Text(
          l10n.syncLocation(
            config.folder.isEmpty ? '/' : config.folder,
            config.server.hasPort
                ? '${config.server.host}:${config.server.port}'
                : config.server.host,
          ),
        ),
        subtitle: Text(_status(l10n, state)),
      ),
      if (need != null)
        ListTile(
          key: const Key('sync_unlock'),
          enabled: !offlineOnly && !state.running,
          leading: const SettingsIcon(Icons.lock_open_outlined),
          title: Text(switch (need) {
            SyncUnlockNeed.both => l10n.syncUnlock,
            SyncUnlockNeed.passphrase => l10n.syncNewPassphraseTitle,
            SyncUnlockNeed.password => l10n.syncNewPasswordTitle,
          }),
          subtitle: need == SyncUnlockNeed.both
              ? Text(l10n.syncUnlockSubtitle)
              : null,
          trailing: const Icon(Icons.chevron_right),
          onTap: () => unawaited(_unlock(context, cubit, need)),
        ),
      ListTile(
        key: const Key('sync_now'),
        enabled: canSync,
        leading: const SettingsIcon(Icons.sync),
        title: Text(l10n.syncNow),
        onTap: () => unawaited(_syncNow(context, cubit)),
      ),
      ListTile(
        key: const Key('sync_options'),
        leading: const SettingsIcon(Icons.checklist),
        title: Text(l10n.syncWhatToSync),
        subtitle: Text(synced.join(', ')),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => unawaited(showSyncOptionsDialog(context, cubit, config)),
      ),
      if (!kIsWeb)
        SwitchListTile(
          key: const Key('sync_wifi_only'),
          secondary: const SettingsIcon(Icons.wifi),
          title: Text(l10n.syncWifiOnly),
          subtitle: Text(l10n.syncWifiOnlySubtitle),
          value: config.wifiOnly,
          onChanged: (value) =>
              unawaited(cubit.updateOptions(config.copyWith(wifiOnly: value))),
        ),
      ListTile(
        key: const Key('sync_change_passphrase'),
        enabled: canSync,
        leading: const SettingsIcon(Icons.password),
        title: Text(l10n.syncChangePassphrase),
        onTap: () => unawaited(_changePassphrase(context, cubit)),
      ),
      const SettingsDangerDivider(),
      ListTile(
        key: const Key('sync_turn_off'),
        enabled: !state.running,
        leading: SettingsIcon(Icons.cloud_off_outlined, color: colors.error),
        title: Text(l10n.syncTurnOff, style: TextStyle(color: colors.error)),
        onTap: () =>
            unawaited(_turnOff(context, cubit, canDeleteRemote: canSync)),
      ),
    ];
  }

  static String _status(AppLocalizations l10n, SyncState state) {
    if (state.running) return l10n.syncStatusRunning;
    final status = state.status;
    if (status.lastFailure case final failure?) {
      return l10n.syncStatusFailed(describeSyncFailure(l10n, failure));
    }
    if (status.lastSyncAt case final at?) {
      final time = DateFormat.yMMMd(l10n.localeName).add_jm().format(at);
      return l10n.syncStatusSynced(time);
    }
    return l10n.syncStatusNever;
  }

  static Future<void> _syncNow(BuildContext context, SyncCubit cubit) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final failure = await cubit.syncNow();
    final result = cubit.current.status.lastResult;
    final text = failure != null
        ? describeSyncFailure(l10n, failure)
        : result == null
        ? null
        : describeSyncResult(l10n, result);
    if (text != null) messenger?.showSnackBar(SnackBar(content: Text(text)));
  }

  static Future<void> _unlock(
    BuildContext context,
    SyncCubit cubit,
    SyncUnlockNeed need,
  ) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (!await showSyncUnlockDialog(context, cubit, need)) return;
    final result = cubit.current.status.lastResult;
    if (result != null) {
      messenger?.showSnackBar(
        SnackBar(content: Text(describeSyncResult(l10n, result))),
      );
    }
  }

  static Future<void> _changePassphrase(
    BuildContext context,
    SyncCubit cubit,
  ) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (!await showSyncChangePassphraseDialog(context, cubit)) return;
    messenger?.showSnackBar(
      SnackBar(content: Text(l10n.syncChangePassphraseDone)),
    );
  }

  static Future<void> _turnOff(
    BuildContext context,
    SyncCubit cubit, {
    required bool canDeleteRemote,
  }) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final off = await showSyncTurnOffDialog(
      context,
      cubit,
      canDeleteRemote: canDeleteRemote,
    );
    if (!off) return;
    messenger?.showSnackBar(SnackBar(content: Text(l10n.syncTurnOffDone)));
  }
}
