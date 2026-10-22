import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/backup/cubit/backup_restore_cubit.dart';
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/backup/sections/settings_backup_section.dart';
import 'package:mozhi/backup/view/backup_section_labels.dart';
import 'package:mozhi/backup/view/backup_services.dart';
import 'package:mozhi/backup/view/widgets/backup_dialog_frame.dart';
import 'package:mozhi/backup/view/widgets/backup_status_views.dart';
import 'package:mozhi/backup/view/widgets/passphrase_field.dart';
import 'package:mozhi/l10n/l10n.dart';

/// "Restore from a backup": pick a `.mozhibackup` file, enter its
/// passphrase, see what it holds (the parts, how many items each, when it
/// was made and by which version), choose the parts and **Replace my
/// data** or **Merge with my data**; the result says what changed. Returns
/// whether anything was restored.
///
/// With [snapshot] (a backup already decrypted, e.g. received from
/// another phone) it starts at what the backup holds.
///
/// Uses the [BackupRegistry] from [context].
Future<bool> showBackupRestoreDialog(
  BuildContext context, {
  BackupSnapshot? snapshot,
}) async {
  final registry = context.read<BackupRegistry>();
  final restored = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => BlocProvider(
      create: (_) => BackupRestoreCubit(
        registry: registry,
        files: BackupServices.files,
        codec: BackupServices.codec,
        snapshot: snapshot,
      ),
      child: RepositoryProvider.value(
        value: registry,
        child: const BackupRestoreView(),
      ),
    ),
  );
  return restored ?? false;
}

/// The content of [showBackupRestoreDialog], driven by the
/// [BackupRestoreCubit] above (and the [BackupRegistry] for what each part
/// holds).
class BackupRestoreView extends StatefulWidget {
  const new({super.key});

  @override
  State<BackupRestoreView> createState() => _BackupRestoreViewState();
}

class _BackupRestoreViewState extends State<BackupRestoreView> {
  final _passphrase = TextEditingController();

  @override
  void dispose() {
    _passphrase.dispose();
    super.dispose();
  }

  void _unlock(BackupRestoreCubit cubit) {
    if (_passphrase.text.isEmpty) return;
    unawaited(cubit.unlock(_passphrase.text));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<BackupRestoreCubit>();
    final state = context.watch<BackupRestoreCubit>().state;
    final title = l10n.backupRestoreTitle;
    void close({required bool restored}) => Navigator.of(context).pop(restored);
    switch (state.step) {
      case BackupRestoreStep.pick:
        return BackupDialogFrame(
          title: title,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.backupRestorePickBody),
              if (_failure(l10n, state.failure) case final failure?) ...[
                const SizedBox(height: AppSpacing.lg),
                BackupErrorText(failure),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => close(restored: false),
              child: Text(l10n.commonCancel),
            ),
            FilledButton.icon(
              key: const Key('backup_restore_pick'),
              onPressed: cubit.pickFile,
              icon: const Icon(Icons.file_open_outlined),
              label: Text(l10n.backupRestorePick),
            ),
          ],
        );
      case BackupRestoreStep.locked:
        final wrong = state.failure == BackupRestoreFailure.wrongPassphrase;
        return BackupDialogFrame(
          title: title,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _FileInfo(
                name: state.fileName,
                createdAt: state.header?.createdAt,
                appVersion: state.header?.appVersion,
              ),
              const SizedBox(height: AppSpacing.lg),
              AutofillGroup(
                child: PassphraseField(
                  key: const Key('backup_restore_passphrase'),
                  controller: _passphrase,
                  autofocus: true,
                  errorText: wrong ? l10n.backupRestoreWrongPassphrase : null,
                  textInputAction: TextInputAction.done,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _unlock(cubit),
                ),
              ),
              if (!wrong)
                if (_failure(l10n, state.failure) case final failure?) ...[
                  const SizedBox(height: AppSpacing.lg),
                  BackupErrorText(failure),
                ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                _passphrase.clear();
                cubit.startOver();
              },
              child: Text(l10n.backupRestoreChooseOther),
            ),
            FilledButton(
              key: const Key('backup_restore_unlock'),
              onPressed: _passphrase.text.isEmpty ? null : () => _unlock(cubit),
              child: Text(l10n.backupRestoreUnlock),
            ),
          ],
        );
      case BackupRestoreStep.unlocking:
        return BackupDialogFrame(
          title: title,
          canClose: false,
          body: BackupProgressView(
            key: const Key('backup_restore_unlocking'),
            label: l10n.backupRestoreUnlocking,
          ),
        );
      case BackupRestoreStep.review:
        final enabled = state.selected.isNotEmpty;
        return BackupDialogFrame(
          title: title,
          body: _Review(state: state),
          actions: [
            TextButton(
              key: const Key('backup_restore_replace'),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: enabled
                  ? () => cubit.restore(BackupRestoreMode.replace)
                  : null,
              child: Text(l10n.backupRestoreReplace),
            ),
            FilledButton(
              key: const Key('backup_restore_merge'),
              onPressed: enabled
                  ? () => cubit.restore(BackupRestoreMode.merge)
                  : null,
              child: Text(l10n.backupRestoreMerge),
            ),
          ],
        );
      case BackupRestoreStep.restoring:
        return BackupDialogFrame(
          title: title,
          canClose: false,
          body: BackupProgressView(
            key: const Key('backup_restore_restoring'),
            label: l10n.backupRestoreRestoring,
          ),
        );
      case BackupRestoreStep.done:
        return BackupDialogFrame(
          title: title,
          body: _Result(state: state),
          actions: [
            FilledButton(
              key: const Key('backup_restore_done'),
              onPressed: () => close(restored: true),
              child: Text(l10n.backupDone),
            ),
          ],
        );
    }
  }

  static String? _failure(
    AppLocalizations l10n,
    BackupRestoreFailure? failure,
  ) => switch (failure) {
    BackupRestoreFailure.notBackup => l10n.backupRestoreNotBackup,
    BackupRestoreFailure.newerVersion => l10n.backupRestoreNewerVersion,
    BackupRestoreFailure.tooLarge => l10n.backupRestoreTooLarge,
    BackupRestoreFailure.unreadable => l10n.backupRestoreUnreadable,
    BackupRestoreFailure.wrongPassphrase => l10n.backupRestoreWrongPassphrase,
    BackupRestoreFailure.restore || null => null,
  };
}

/// "Made on `date` with Mozhi `version`", under the file's name.
class _FileInfo extends StatelessWidget {
  const new({this.name, this.createdAt, this.appVersion});

  final String? name;
  final DateTime? createdAt;
  final String? appVersion;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final created = createdAt;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(
          child: Icon(
            Icons.lock_outline,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (name case final name?)
                Text(name, style: theme.textTheme.titleSmall),
              if (created != null)
                Text(
                  l10n.backupRestoreFileInfo(
                    formatBackupDate(l10n, created),
                    appVersion ?? '',
                  ),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// What the backup holds: a checkbox per part this app knows (with how
/// many items it has), the parts it doesn't, and what Replace and Merge
/// do.
class _Review extends StatelessWidget {
  const new({required this.state});

  final BackupRestoreState state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final cubit = context.read<BackupRestoreCubit>();
    final registry = context.read<BackupRegistry>();
    final snapshot = state.snapshot!;
    final known = [
      for (final section in registry.sections)
        if (snapshot.sections.containsKey(section.id)) section,
    ];
    final unknown = [
      for (final id in snapshot.sections.keys)
        if (registry.section(id) == null) id,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FileInfo(
          name: state.fileName,
          createdAt: snapshot.createdAt,
          appVersion: snapshot.appVersion,
        ),
        const SizedBox(height: AppSpacing.lg),
        Semantics(
          header: true,
          child: Text(
            l10n.backupRestoreHolds,
            style: theme.textTheme.titleSmall,
          ),
        ),
        for (final section in known)
          CheckboxListTile(
            key: Key('backup_restore_section_${section.id}'),
            contentPadding: EdgeInsets.zero,
            secondary: Icon(BackupSectionLabels.icon(section.id)),
            title: Text(BackupSectionLabels.name(l10n, section.id)),
            subtitle: _subtitle(l10n, section, snapshot.sections[section.id]!),
            value: state.selected.contains(section.id),
            onChanged: (value) =>
                cubit.toggleSection(section.id, selected: value ?? false),
          ),
        if (unknown.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: Text(
              l10n.backupRestoreUnsupported(unknown.join(', ')),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        const SizedBox(height: AppSpacing.lg),
        Text(
          l10n.backupRestoreModesBody,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  static Widget? _subtitle(
    AppLocalizations l10n,
    BackupSection section,
    BackupSectionData data,
  ) {
    final parts = [
      if (section case final BackupItemCounter counter)
        if (counter.countItems(data.data, version: data.version)
            case final count?)
          l10n.backupRestoreItems(count),
      if (section.id == SettingsBackupSection.sectionId &&
          SettingsBackupSection.hasSecrets(data.data))
        l10n.backupRestoreWithSecrets,
    ];
    return parts.isEmpty ? null : Text(parts.join(' · '));
  }
}

/// What the restore did: per part restored, the item counts before and
/// after (or "Restored"); or which part failed. (Parts this version
/// doesn't know were named before, and never restored.)
class _Result extends StatelessWidget {
  const new({required this.state});

  final BackupRestoreState state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (state.failure == BackupRestoreFailure.restore) {
      return BackupOutcomeView(
        key: const Key('backup_restore_failed'),
        icon: Icons.error_outline,
        error: true,
        title: l10n.backupRestoreFailedSection(
          BackupSectionLabels.name(l10n, state.failedSection ?? ''),
        ),
      );
    }
    final report = state.report;
    return BackupOutcomeView(
      key: const Key('backup_restore_result'),
      icon: Icons.check_circle_outline,
      title: l10n.backupRestoreDone,
      children: [
        for (final id in report?.restored ?? const <String>[])
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(BackupSectionLabels.icon(id)),
            title: Text(BackupSectionLabels.name(l10n, id)),
            subtitle: Text(switch (report?.changes[id]) {
              final change? => l10n.backupRestoreChange(
                change.after,
                change.before,
              ),
              null => l10n.backupRestoreRestored,
            }),
          ),
      ],
    );
  }
}

/// [at] as the backup screens show it ("Oct 22, 2026, 3:12 PM" in
/// English).
String formatBackupDate(AppLocalizations l10n, DateTime at) =>
    DateFormat.yMMMd(l10n.localeName).add_jm().format(at.toLocal());
