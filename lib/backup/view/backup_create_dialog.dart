import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/backup/cubit/backup_create_cubit.dart';
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/backup/data/backup_status_store.dart';
import 'package:mozhi/backup/view/backup_section_labels.dart';
import 'package:mozhi/backup/view/backup_services.dart';
import 'package:mozhi/backup/view/widgets/backup_dialog_frame.dart';
import 'package:mozhi/backup/view/widgets/backup_status_views.dart';
import 'package:mozhi/backup/view/widgets/passphrase_field.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/l10n/l10n.dart';

/// "Back up now": choose what to include (API keys and passwords only when
/// turned on, with a warning), set a passphrase and save the encrypted
/// `.mozhibackup` file (the save dialog on Android, a download in the web
/// app). Returns whether a backup was saved.
///
/// Uses the [BackupRegistry] and the preferences ([KeyValueStore], where
/// the date of the last backup is kept) from [context].
Future<bool> showBackupCreateDialog(BuildContext context) async {
  final registry = context.read<BackupRegistry>();
  final status = BackupStatusStore(context.read<KeyValueStore>());
  final saved = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => BlocProvider(
      create: (_) => BackupCreateCubit(
        registry: registry,
        files: BackupServices.files,
        status: status,
        codec: BackupServices.codec,
      ),
      child: const BackupCreateView(),
    ),
  );
  return saved ?? false;
}

/// The content of [showBackupCreateDialog], driven by the
/// [BackupCreateCubit] above.
class BackupCreateView extends StatefulWidget {
  const new({super.key});

  @override
  State<BackupCreateView> createState() => _BackupCreateViewState();
}

class _BackupCreateViewState extends State<BackupCreateView> {
  final _passphrase = TextEditingController();
  final _repeat = TextEditingController();

  @override
  void dispose() {
    _passphrase.dispose();
    _repeat.dispose();
    super.dispose();
  }

  bool get _passphraseOk =>
      PassphraseStrength.of(_passphrase.text).acceptable &&
      _passphrase.text == _repeat.text;

  void _create(BackupCreateCubit cubit) {
    if (!_passphraseOk || !cubit.state.canCreate) return;
    unawaited(cubit.create(_passphrase.text));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<BackupCreateCubit>();
    final state = context.watch<BackupCreateCubit>().state;
    switch (state.status) {
      case BackupCreateStatus.working:
        return BackupDialogFrame(
          title: l10n.backupCreateTitle,
          canClose: false,
          body: BackupProgressView(
            key: const Key('backup_create_working'),
            label: l10n.backupCreateWorking,
          ),
        );
      case BackupCreateStatus.saved:
        return BackupDialogFrame(
          title: l10n.backupCreateTitle,
          body: BackupOutcomeView(
            key: const Key('backup_create_saved'),
            icon: Icons.check_circle_outline,
            title: l10n.backupCreateSaved,
            children: [Text(l10n.backupCreateSavedBody(state.fileName ?? ''))],
          ),
          actions: [
            FilledButton(
              key: const Key('backup_create_done'),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(l10n.backupDone),
            ),
          ],
        );
      case BackupCreateStatus.editing:
      case BackupCreateStatus.failure:
        return BackupDialogFrame(
          title: l10n.backupCreateTitle,
          body: _form(context, cubit, state),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(l10n.commonCancel),
            ),
            FilledButton(
              key: const Key('backup_create_action'),
              onPressed: _passphraseOk && state.canCreate
                  ? () => _create(cubit)
                  : null,
              child: Text(l10n.backupCreateAction),
            ),
          ],
        );
    }
  }

  Widget _form(
    BuildContext context,
    BackupCreateCubit cubit,
    BackupCreateState state,
  ) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final mismatch =
        _repeat.text.isNotEmpty && _repeat.text != _passphrase.text;
    final failure = switch (state.failure) {
      BackupCreateFailure.section => l10n.backupCreateFailedSection(
        BackupSectionLabels.name(l10n, state.failedSection ?? ''),
      ),
      BackupCreateFailure.save => l10n.backupCreateFailedSave,
      null => null,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            l10n.backupCreateInclude,
            style: theme.textTheme.titleSmall,
          ),
        ),
        for (final id in state.sections)
          CheckboxListTile(
            key: Key('backup_section_$id'),
            contentPadding: EdgeInsets.zero,
            secondary: Icon(BackupSectionLabels.icon(id)),
            title: Text(BackupSectionLabels.name(l10n, id)),
            value: state.selected.contains(id),
            onChanged: (value) =>
                cubit.toggleSection(id, selected: value ?? false),
          ),
        SwitchListTile(
          key: const Key('backup_include_secrets'),
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.key_outlined),
          title: Text(l10n.backupIncludeSecrets),
          subtitle: state.includeSecrets
              ? null
              : Text(l10n.backupIncludeSecretsOff),
          value: state.includeSecrets,
          onChanged: (value) => cubit.setIncludeSecrets(include: value),
        ),
        if (state.includeSecrets)
          BackupWarningCard(
            key: const Key('backup_secrets_warning'),
            text: l10n.backupIncludeSecretsWarning,
          ),
        const SizedBox(height: AppSpacing.lg),
        AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PassphraseField(
                key: const Key('backup_passphrase'),
                controller: _passphrase,
                newPassphrase: true,
                helperText: l10n.backupPassphraseHelp,
                textInputAction: TextInputAction.next,
                onChanged: (_) => setState(() {}),
              ),
              PassphraseStrengthHint(passphrase: _passphrase.text),
              const SizedBox(height: AppSpacing.lg),
              PassphraseField(
                key: const Key('backup_passphrase_repeat'),
                controller: _repeat,
                newPassphrase: true,
                label: l10n.backupPassphraseRepeat,
                errorText: mismatch ? l10n.backupPassphraseMismatch : null,
                textInputAction: TextInputAction.done,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _create(cubit),
              ),
            ],
          ),
        ),
        if (failure != null) ...[
          const SizedBox(height: AppSpacing.lg),
          BackupErrorText(failure),
        ],
      ],
    );
  }
}
