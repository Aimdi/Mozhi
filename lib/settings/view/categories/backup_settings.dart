import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/backup/data/backup_status_store.dart';
import 'package:mozhi/backup/view/backup_create_dialog.dart';
import 'package:mozhi/backup/view/backup_restore_dialog.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/pairing/view/pairing_entries.dart';
import 'package:mozhi/pairing/view/pairing_unavailable.dart'
    show isPairingSupported;
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/widgets/settings_search.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';
import 'package:mozhi/sync/view/sync_settings_section.dart';

/// Anchors ([SettingsAnchor.id]) of the Backup & sync settings.
abstract final class BackupAnchors {
  static const backUp = 'backup_now';
  static const restore = 'backup_restore';
}

/// The Backup & sync settings (`/settings/backup`): the encrypted backup
/// (**Back up now**, with the date of the last one, and **Restore from a
/// backup**), then sync ([SyncSettingsSection]) and phone to phone
/// ([PairingSettingsSection]).
class BackupSettings extends StatelessWidget {
  const new({required this.settings, super.key});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const EncryptedBackupSettings(),
        // End-to-end-encrypted sync with the user's WebDAV folder; the
        // last group in the web app, which has no phone to phone.
        SyncSettingsSection(divider: isPairingSupported),
        // Phone to phone over the local network (Android).
        const PairingSettingsSection(divider: false),
      ],
    );
  }
}

/// The encrypted backup rows: an introduction, **Back up now** (with the
/// last backup's date) and **Restore from a backup**.
class EncryptedBackupSettings extends StatefulWidget {
  const new({super.key});

  @override
  State<EncryptedBackupSettings> createState() =>
      _EncryptedBackupSettingsState();
}

class _EncryptedBackupSettingsState extends State<EncryptedBackupSettings> {
  DateTime? _lastBackup;

  @override
  void initState() {
    super.initState();
    unawaited(_loadLastBackup());
  }

  BackupStatusStore? get _status {
    try {
      return BackupStatusStore(context.read<KeyValueStore>());
    } on ProviderNotFoundException {
      return null;
    }
  }

  Future<void> _loadLastBackup() async {
    final DateTime? last;
    try {
      last = await _status?.lastBackupAt();
    } on Object {
      return;
    }
    if (mounted) setState(() => _lastBackup = last);
  }

  Future<void> _backUp() async {
    if (await showBackupCreateDialog(context)) await _loadLastBackup();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final last = _lastBackup;
    return SettingsSection(
      title: l10n.settingsBackupSectionTitle,
      // Sync and phone to phone follow.
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.lg,
            AppSpacing.sm,
          ),
          child: Text(
            l10n.settingsBackupIntro,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        SettingsAnchor(
          id: BackupAnchors.backUp,
          child: ListTile(
            key: const Key('settings_backup_create'),
            leading: const SettingsIcon(Icons.backup_outlined),
            title: Text(l10n.settingsBackupCreate),
            subtitle: Text(
              last == null
                  ? l10n.settingsBackupCreateNever
                  : l10n.settingsBackupCreateLast(formatBackupDate(l10n, last)),
            ),
            onTap: _backUp,
          ),
        ),
        SettingsAnchor(
          id: BackupAnchors.restore,
          child: ListTile(
            key: const Key('settings_backup_restore'),
            leading: const SettingsIcon(Icons.settings_backup_restore),
            title: Text(l10n.settingsBackupRestore),
            subtitle: Text(l10n.settingsBackupRestoreSubtitle),
            onTap: () => showBackupRestoreDialog(context),
          ),
        ),
      ],
    );
  }
}
