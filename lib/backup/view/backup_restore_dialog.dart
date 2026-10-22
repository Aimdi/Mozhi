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
import 'package:translation_repository/translation_repository.dart'
    show AiProviderConfig, MozhiInstance;

/// "Restore from a backup": pick a `.mozhibackup` file, enter its
/// passphrase, see what it holds (the parts, how many items each, when it
/// was made and by which version, and the AI providers and Mozhi
/// instances its settings would add), choose the parts and **Replace my
/// data** or **Merge with my data**; the result says what changed (and
/// which providers and instances were added). Returns whether anything
/// was restored.
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

  /// The snapshot [_additions] are about.
  BackupSnapshot? _previewed;

  /// What its settings would add with each mode, worked out when the
  /// backup is opened (before anything is restored): listed in the review
  /// and, for the mode used, in the result. Null until known, and when it
  /// holds no settings or they can't be read.
  Map<BackupRestoreMode, SettingsBackupAdditions>? _additions;

  /// Works out [_additions] for [snapshot], once per snapshot.
  void _preview(BackupRegistry registry, BackupSnapshot? snapshot) {
    if (snapshot == null || identical(snapshot, _previewed)) return;
    _previewed = snapshot;
    _additions = null;
    unawaited(
      _settingsAdditions(registry, snapshot).then((additions) {
        if (!mounted || !identical(snapshot, _previewed)) return;
        setState(() => _additions = additions);
      }),
    );
  }

  static Future<Map<BackupRestoreMode, SettingsBackupAdditions>?>
  _settingsAdditions(BackupRegistry registry, BackupSnapshot snapshot) async {
    final section = registry.section(SettingsBackupSection.sectionId);
    final data = snapshot.sections[SettingsBackupSection.sectionId];
    if (section is! SettingsBackupSection || data == null) return null;
    try {
      return await section.additions(data.data, version: data.version);
    } on Object {
      // The restore reports it, if the part is restored.
      return null;
    }
  }

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
    _preview(context.read<BackupRegistry>(), state.snapshot);
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
          body: _Review(state: state, additions: _additions),
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
          body: _Result(state: state, additions: _additions),
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
/// many items it has; for the settings, the AI providers and Mozhi
/// instances that are new here), the parts it doesn't, and what Replace
/// and Merge do.
class _Review extends StatelessWidget {
  const new({required this.state, this.additions});

  final BackupRestoreState state;

  /// What the settings would add, per mode.
  final Map<BackupRestoreMode, SettingsBackupAdditions>? additions;

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
            subtitle: _subtitle([
              ?_summary(l10n, section, snapshot.sections[section.id]!),
              if (section.id == SettingsBackupSection.sectionId)
                ..._newServers(l10n, additions),
            ]),
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
        if (known.any((s) => s.id == SettingsBackupSection.sectionId)) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            l10n.backupRestoreSettingsModesBody,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  /// How many items the part has, and whether it holds secrets.
  static String? _summary(
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
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// The AI providers that either mode would add, and the Mozhi
  /// instances that Replace would.
  static List<String> _newServers(
    AppLocalizations l10n,
    Map<BackupRestoreMode, SettingsBackupAdditions>? additions,
  ) {
    if (additions == null) return const [];
    const none = SettingsBackupAdditions();
    final replace = additions[BackupRestoreMode.replace] ?? none;
    final merge = additions[BackupRestoreMode.merge] ?? none;
    // Both lists come from the backup's providers, without secrets.
    final providers = {...replace.providers, ...merge.providers}.toList();
    return [
      if (providers.isNotEmpty)
        l10n.backupRestoreNewProviders(_providerList(l10n, providers)),
      if (replace.instances.isNotEmpty)
        l10n.backupRestoreNewInstances(_instanceList(replace.instances)),
    ];
  }
}

/// [lines] one below the other, or null without any.
Widget? _subtitle(List<String> lines) =>
    lines.isEmpty ? null : Text(lines.join('\n'));

/// [providers] as "Name (host), ...".
String _providerList(
  AppLocalizations l10n,
  List<AiProviderConfig> providers,
) => [
  for (final provider in providers)
    switch ((provider.name.trim(), SettingsBackupAdditions.hostOf(provider))) {
      (final name, '') => name,
      ('', final host) => host,
      (final name, final host) => l10n.backupRestoreProviderHost(name, host),
    },
].join(', ');

/// The hosts of [instances], "host, ...".
String _instanceList(List<MozhiInstance> instances) => [
  for (final instance in instances)
    SettingsBackupAdditions.instanceHostOf(instance),
].join(', ');

/// What the restore did: per part restored, the item counts before and
/// after (or "Restored"), and for the settings the AI providers (apart:
/// those Merge turned off) and Mozhi instances it added (and, after
/// Merge, the instances it left out); or
/// which part failed. (Parts this version doesn't know were named before,
/// and never restored.)
class _Result extends StatelessWidget {
  const new({required this.state, this.additions});

  final BackupRestoreState state;

  /// What the settings would add, per mode (worked out before the
  /// restore).
  final Map<BackupRestoreMode, SettingsBackupAdditions>? additions;

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
            subtitle: _subtitle([
              switch (report?.changes[id]) {
                final change? => l10n.backupRestoreChange(
                  change.after,
                  change.before,
                ),
                null => l10n.backupRestoreRestored,
              },
              if (id == SettingsBackupSection.sectionId) ..._added(l10n),
            ]),
          ),
      ],
    );
  }

  /// The AI providers and Mozhi instances the settings added with the
  /// mode used, and the instances Merge left out.
  List<String> _added(AppLocalizations l10n) {
    final mode = state.mode;
    final all = additions;
    final added = mode == null || all == null ? null : all[mode];
    if (all == null || added == null) return const [];
    final replace = all[BackupRestoreMode.replace];
    final skipped = mode == BackupRestoreMode.merge && replace != null
        ? replace.instances
        : const <MozhiInstance>[];
    // Merge turns off those that would get text without asking first.
    bool turnedOff(AiProviderConfig provider) =>
        mode == BackupRestoreMode.merge &&
        !provider.enabled &&
        !SettingsBackupSection.asksBeforeFirstUse(provider);
    final on = [...added.providers.where((p) => !turnedOff(p))];
    final off = [...added.providers.where(turnedOff)];
    return [
      if (on.isNotEmpty)
        l10n.backupRestoreAddedProviders(_providerList(l10n, on)),
      if (off.isNotEmpty)
        l10n.backupRestoreAddedProvidersOff(_providerList(l10n, off)),
      if (added.instances.isNotEmpty)
        l10n.backupRestoreAddedInstances(_instanceList(added.instances)),
      if (skipped.isNotEmpty)
        l10n.backupRestoreSkippedInstances(_instanceList(skipped)),
    ];
  }
}

/// [at] as the backup screens show it ("Oct 22, 2026, 3:12 PM" in
/// English).
String formatBackupDate(AppLocalizations l10n, DateTime at) =>
    DateFormat.yMMMd(l10n.localeName).add_jm().format(at.toLocal());
