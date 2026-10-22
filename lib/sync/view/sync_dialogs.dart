import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/backup/view/widgets/backup_dialog_frame.dart';
import 'package:mozhi/backup/view/widgets/passphrase_field.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/sync/cubit/sync_cubit.dart';
import 'package:mozhi/sync/models/sync_config.dart';
import 'package:mozhi/sync/models/sync_status.dart';
import 'package:mozhi/sync/view/sync_texts.dart';
import 'package:mozhi/sync/view/widgets/sync_fields.dart';

/// What the unlock dialog asks for.
enum SyncUnlockNeed {
  /// The app password and the passphrase (the web app forgot both).
  both,

  /// Only the passphrase (changed on another device).
  passphrase,

  /// Only the app password (the server no longer accepts it).
  password,
}

/// Asks for what sync is missing ([need]) and unlocks it with [cubit];
/// true when it worked.
Future<bool> showSyncUnlockDialog(
  BuildContext context,
  SyncCubit cubit,
  SyncUnlockNeed need,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => SyncUnlockDialog(cubit: cubit, need: need),
    ) ??
    false;

/// The unlock dialog: the app password and/or the passphrase, checked by
/// syncing; errors show in the dialog.
class SyncUnlockDialog extends StatefulWidget {
  const new({required this.cubit, required this.need, super.key});

  final SyncCubit cubit;
  final SyncUnlockNeed need;

  @override
  State<SyncUnlockDialog> createState() => _SyncUnlockDialogState();
}

class _SyncUnlockDialogState extends State<SyncUnlockDialog> {
  final _password = TextEditingController();
  final _passphrase = TextEditingController();
  bool _busy = false;
  SyncFailure? _failure;

  bool get _asksPassword => widget.need != SyncUnlockNeed.passphrase;
  bool get _asksPassphrase => widget.need != SyncUnlockNeed.password;

  @override
  void dispose() {
    _password.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  bool get _complete =>
      (!_asksPassword || _password.text.isNotEmpty) &&
      (!_asksPassphrase || _passphrase.text.isNotEmpty);

  Future<void> _submit() async {
    if (!_complete || _busy) return;
    setState(() {
      _busy = true;
      _failure = null;
    });
    final failure = await widget.cubit.unlock(
      password: _asksPassword ? _password.text : null,
      passphrase: _asksPassphrase ? _passphrase.text : null,
    );
    if (!mounted) return;
    if (failure == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _failure = failure;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final (title, body) = switch (widget.need) {
      SyncUnlockNeed.both => (l10n.syncUnlock, l10n.syncUnlockBody),
      SyncUnlockNeed.passphrase => (
        l10n.syncNewPassphraseTitle,
        l10n.syncNewPassphraseBody,
      ),
      SyncUnlockNeed.password => (
        l10n.syncNewPasswordTitle,
        l10n.syncNewPasswordBody,
      ),
    };
    final failure = _failure;
    final passphraseFailed = failure == SyncFailure.wrongPassphrase;
    final passwordFailed = failure == SyncFailure.authFailed;
    return BackupDialogFrame(
      title: title,
      canClose: !_busy,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(body),
          if (kIsWeb && widget.need == SyncUnlockNeed.both) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              l10n.syncUnlockWebNote,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (_asksPassword) ...[
            const SizedBox(height: AppSpacing.lg),
            SyncPasswordField(
              key: const Key('sync_unlock_password'),
              controller: _password,
              enabled: !_busy,
              autofocus: true,
              errorText: passwordFailed ? l10n.syncFailureAuth : null,
              textInputAction: _asksPassphrase
                  ? TextInputAction.next
                  : TextInputAction.done,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
            ),
          ],
          if (_asksPassphrase) ...[
            const SizedBox(height: AppSpacing.lg),
            PassphraseField(
              key: const Key('sync_unlock_passphrase'),
              controller: _passphrase,
              enabled: !_busy,
              autofocus: !_asksPassword,
              errorText: passphraseFailed
                  ? l10n.syncFailureWrongPassphrase
                  : null,
              textInputAction: TextInputAction.done,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
            ),
          ],
          if (failure != null && !passphraseFailed && !passwordFailed)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.md),
              child: Text(
                describeSyncFailure(l10n, failure),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          key: const Key('sync_unlock_submit'),
          onPressed: _complete && !_busy ? _submit : null,
          child: _busy ? const SyncSpinner() : Text(l10n.syncNow),
        ),
      ],
    );
  }
}

/// Changes the sync passphrase with [cubit]; true when it worked.
Future<bool> showSyncChangePassphraseDialog(
  BuildContext context,
  SyncCubit cubit,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => SyncChangePassphraseDialog(cubit: cubit),
    ) ??
    false;

/// A new sync passphrase, twice, with its strength.
class SyncChangePassphraseDialog extends StatefulWidget {
  const new({required this.cubit, super.key});

  final SyncCubit cubit;

  @override
  State<SyncChangePassphraseDialog> createState() =>
      _SyncChangePassphraseDialogState();
}

class _SyncChangePassphraseDialogState
    extends State<SyncChangePassphraseDialog> {
  final _passphrase = TextEditingController();
  final _repeat = TextEditingController();
  bool _busy = false;
  bool _showErrors = false;
  SyncFailure? _failure;

  @override
  void dispose() {
    _passphrase.dispose();
    _repeat.dispose();
    super.dispose();
  }

  bool get _valid =>
      PassphraseStrength.of(_passphrase.text).acceptable &&
      _passphrase.text == _repeat.text;

  Future<void> _submit() async {
    if (_busy) return;
    if (!_valid) {
      setState(() => _showErrors = true);
      return;
    }
    setState(() {
      _busy = true;
      _failure = null;
    });
    final failure = await widget.cubit.changePassphrase(_passphrase.text);
    if (!mounted) return;
    if (failure == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _failure = failure;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final strength = PassphraseStrength.of(_passphrase.text);
    final failure = _failure;
    return BackupDialogFrame(
      title: l10n.syncChangePassphrase,
      canClose: !_busy,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.syncChangePassphraseBody),
          const SizedBox(height: AppSpacing.lg),
          PassphraseField(
            key: const Key('sync_new_passphrase'),
            controller: _passphrase,
            newPassphrase: true,
            autofocus: true,
            enabled: !_busy,
            helperText: l10n.syncPassphraseNewHelper,
            errorText: _showErrors && !strength.acceptable
                ? l10n.backupPassphraseTooShort(PassphraseStrength.minLength)
                : null,
            textInputAction: TextInputAction.next,
            onChanged: (_) => setState(() {}),
          ),
          PassphraseStrengthHint(passphrase: _passphrase.text),
          const SizedBox(height: AppSpacing.lg),
          PassphraseField(
            key: const Key('sync_new_passphrase_repeat'),
            controller: _repeat,
            label: l10n.backupPassphraseRepeat,
            newPassphrase: true,
            enabled: !_busy,
            errorText:
                _showErrors &&
                    strength.acceptable &&
                    _repeat.text != _passphrase.text
                ? l10n.backupPassphraseMismatch
                : null,
            textInputAction: TextInputAction.done,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          ),
          if (failure != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.md),
              child: Text(
                describeSyncFailure(l10n, failure),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          key: const Key('sync_new_passphrase_submit'),
          onPressed: _busy ? null : _submit,
          child: _busy ? const SyncSpinner() : Text(l10n.commonSave),
        ),
      ],
    );
  }
}

/// What to sync, for [config] (sections, secrets); saved with [cubit].
Future<void> showSyncOptionsDialog(
  BuildContext context,
  SyncCubit cubit,
  SyncConfig config,
) => showDialog<void>(
  context: context,
  builder: (_) => SyncOptionsDialog(cubit: cubit, config: config),
);

class SyncOptionsDialog extends StatefulWidget {
  const new({required this.cubit, required this.config, super.key});

  final SyncCubit cubit;
  final SyncConfig config;

  @override
  State<SyncOptionsDialog> createState() => _SyncOptionsDialogState();
}

class _SyncOptionsDialogState extends State<SyncOptionsDialog> {
  late Set<String> _excluded = widget.config.excludedSections;
  late bool _includeSecrets = widget.config.includeSecrets;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return BackupDialogFrame(
      title: l10n.syncWhatToSync,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.syncWhatToSyncBody),
          const SizedBox(height: AppSpacing.sm),
          SyncSectionsPicker(
            sectionIds: widget.cubit.sectionIds,
            excluded: _excluded,
            includeSecrets: _includeSecrets,
            onExcludedChanged: (value) => setState(() => _excluded = value),
            onIncludeSecretsChanged: (value) =>
                setState(() => _includeSecrets = value),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          key: const Key('sync_options_save'),
          onPressed: () async {
            final navigator = Navigator.of(context);
            await widget.cubit.updateOptions(
              widget.config.copyWith(
                excludedSections: _excluded,
                includeSecrets: _includeSecrets,
              ),
            );
            navigator.pop();
          },
          child: Text(l10n.commonSave),
        ),
      ],
    );
  }
}

/// Asks before turning sync off (and, if chosen, deleting the sync file);
/// turns it off with [cubit]. True when it was turned off.
Future<bool> showSyncTurnOffDialog(
  BuildContext context,
  SyncCubit cubit, {
  required bool canDeleteRemote,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) =>
          SyncTurnOffDialog(cubit: cubit, canDeleteRemote: canDeleteRemote),
    ) ??
    false;

class SyncTurnOffDialog extends StatefulWidget {
  const new({required this.cubit, required this.canDeleteRemote, super.key});

  final SyncCubit cubit;

  /// Whether the file can be deleted (sync is unlocked and may go online).
  final bool canDeleteRemote;

  @override
  State<SyncTurnOffDialog> createState() => _SyncTurnOffDialogState();
}

class _SyncTurnOffDialogState extends State<SyncTurnOffDialog> {
  bool _deleteRemote = false;
  bool _busy = false;
  SyncFailure? _failure;

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _failure = null;
    });
    final failure = await widget.cubit.turnOff(deleteRemote: _deleteRemote);
    if (!mounted) return;
    if (failure == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _failure = failure;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final failure = _failure;
    return AlertDialog(
      icon: Icon(Icons.cloud_off_outlined, color: colors.error),
      title: Text(l10n.syncTurnOff),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.syncTurnOffBody),
          if (widget.canDeleteRemote)
            CheckboxListTile(
              key: const Key('sync_turn_off_delete'),
              contentPadding: EdgeInsets.zero,
              value: _deleteRemote,
              title: Text(l10n.syncTurnOffDeleteRemote),
              subtitle: Text(l10n.syncTurnOffDeleteRemoteSubtitle),
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _deleteRemote = value ?? false),
            ),
          if (failure != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: Text(
                describeSyncFailure(l10n, failure),
                style: TextStyle(color: colors.error),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: Text(l10n.commonCancel),
        ),
        TextButton(
          key: const Key('sync_turn_off_confirm'),
          style: TextButton.styleFrom(foregroundColor: colors.error),
          onPressed: _busy ? null : _submit,
          child: _busy ? const SyncSpinner() : Text(l10n.syncTurnOff),
        ),
      ],
    );
  }
}
